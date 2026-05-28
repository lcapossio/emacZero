// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// eth_mac_sys.v - Ethernet MAC System Wrapper
// Integrates eth_mac + AXI4-Lite CSR + statistics + MDIO + MII/RGMII selection
// Verilog 2001
// =============================================================================
//
// PHY_INTERFACE parameter selects between "MII" (10/100) and "RGMII" (gigabit).
// MII mode: uses mii_if.v (existing CDC + nibble conversion).
// RGMII mode: uses gmii_cdc.v + rgmii_if.v (CDC + DDR I/O).
// =============================================================================

module eth_mac_sys #(
    parameter PHY_INTERFACE     = "MII",  // "MII" or "RGMII"
    parameter MCAST_HASH_FILTER = 0,      // 1 = enable 64-bit multicast hash filter
    parameter MAX_FRAME         = 9018,   // jumbo MTU + headers; 1518 standard
    parameter TX_CSUM_OFFLOAD   = 0,      // 1 = synthesize IPv4/UDP TX checksum patcher
    parameter MII_DEBUG         = 0
)(
    input  wire        clk,           // system clock (100 MHz)
    input  wire        rst_n,

    // ---- AXI4-Lite CSR slave (8-bit address: 0x00-0x90 used) ----
    input  wire [7:0]  s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [7:0]  s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,

    // ---- AXI4-Stream TX slave ----
    input  wire [7:0]  s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,

    // ---- AXI4-Stream RX master ----
    output wire [7:0]  m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output wire        m_axis_terror,
    output wire        m_axis_tsof,

    // ---- MII PHY pins (active when PHY_INTERFACE="MII") ----
    output wire [3:0]  mii_txd,
    output wire        mii_tx_en,
    input  wire        mii_tx_clk,
    input  wire [3:0]  mii_rxd,
    input  wire        mii_rx_dv,
    input  wire        mii_rx_er,
    input  wire        mii_rx_clk,
    input  wire        mii_col,
    input  wire        mii_crs,

    // ---- RGMII PHY pins (active when PHY_INTERFACE="RGMII") ----
    input  wire        clk_125,
    input  wire        clk_125_90,
    input  wire        clk_25,        // 25 MHz for 100M RGMII
    input  wire        clk_2_5,       // 2.5 MHz for 10M RGMII
    output wire [3:0]  rgmii_txd,
    output wire        rgmii_tx_ctl,
    output wire        rgmii_txc,
    input  wire [3:0]  rgmii_rxd,
    input  wire        rgmii_rx_ctl,
    input  wire        rgmii_rxc,

    // ---- MDIO ----
    output wire        mdc,
    input  wire        mdio_i,
    output wire        mdio_o,
    output wire        mdio_oe,

    // ---- Interrupt ----
    output wire        irq
);

    // =========================================================================
    // CSR outputs
    // =========================================================================
    wire        cfg_tx_en;
    wire        cfg_rx_en;
    wire        cfg_promisc;
    wire [1:0]  cfg_speed;        // 00=1G, 01=100M, 10=10M
    wire        cfg_full_duplex;
    wire        cfg_jumbo_en;
    wire        cfg_tx_csum_off;
    wire        cfg_passthrough;
    wire [47:0] cfg_mac_addr;
    wire [63:0] cfg_mcast_hash_table;

    // PAUSE
    wire        cfg_pause_rx_en;
    wire        cfg_pause_tx_send;
    wire [15:0] cfg_pause_tx_quanta;
    wire [31:0] stat_pause_rx_cnt;
    wire [31:0] stat_pause_tx_cnt;
    wire        stat_clr_pause;
    wire        tx_paused;
    wire [7:0]  pause_tdata;
    wire        pause_tvalid;
    wire        pause_tready;
    wire        pause_tlast;

    // MDIO CSR <-> mdio_master
    wire        mdio_go;
    wire        mdio_write;
    wire [4:0]  mdio_phy_addr;
    wire [4:0]  mdio_reg_addr;
    wire [15:0] mdio_wdata_csr;
    wire [15:0] mdio_rdata_csr;
    wire        mdio_c45_en;
    wire [1:0]  mdio_c45_op;
    wire        mdio_done;

    // Stats
    wire [31:0] stat_tx_frame_cnt;
    wire [31:0] stat_tx_byte_cnt;
    wire [31:0] stat_rx_frame_cnt;
    wire [31:0] stat_rx_byte_cnt;
    wire [31:0] stat_rx_err_cnt;
    wire [31:0] stat_rx_err_align_cnt;
    wire [31:0] stat_rx_err_overflow_cnt;
    wire [31:0] stat_rx_err_oversize_cnt;
    wire [31:0] stat_rx_bcast_cnt;
    wire [31:0] stat_rx_mcast_cnt;
    wire [31:0] stat_rx_size_64_cnt;
    wire [31:0] stat_rx_size_65_127_cnt;
    wire [31:0] stat_rx_size_128_255_cnt;
    wire [31:0] stat_rx_size_256_511_cnt;
    wire [31:0] stat_rx_size_512_1023_cnt;
    wire [31:0] stat_rx_size_1024_1518_cnt;
    wire [31:0] stat_rx_size_jumbo_cnt;

    // RX classification bus (from eth_mac_rx)
    wire        rx_stat_done;
    wire [13:0] rx_stat_len;
    wire        rx_stat_err_fcs;
    wire        rx_stat_err_align;
    wire        rx_stat_err_overflow;
    wire        rx_stat_err_oversize;
    wire        rx_stat_is_bcast;
    wire        rx_stat_is_mcast;

    wire        stat_clr_tx;
    wire        stat_clr_rx;

    // Status
    wire        tx_active;
    wire        tx_fifo_busy;
    wire [12:0] tx_fifo_level;

    // MDIO busy tracking
    reg         mdio_busy_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)       mdio_busy_r <= 1'b0;
        else if (mdio_go) mdio_busy_r <= 1'b1;
        else if (mdio_done) mdio_busy_r <= 1'b0;
    end

    // =========================================================================
    // Internal GMII bus (sys_clk domain)
    // =========================================================================
    wire [7:0] gmii_txd;
    wire       gmii_tx_en;
    wire       gmii_tx_er;
    wire [7:0] gmii_rxd;
    wire       gmii_rx_dv;
    wire       gmii_rx_er;

    // =========================================================================
    // TX/RX gating
    // =========================================================================
    // TX gating: hold tready low when tx disabled
    wire       s_axis_tvalid_gated = s_axis_tvalid & cfg_tx_en;
    wire       s_axis_tready_mac;

    // =========================================================================
    // Optional TX checksum offload.
    // TX_CSUM_OFFLOAD=0 removes the frame-buffering checksum patcher from
    // synthesis; CTRL[7] then reads/writes normally but has no datapath effect.
    // TX_CSUM_OFFLOAD=1 lets CTRL[7] select the patcher at runtime.
    // =========================================================================
    wire [7:0] user_tx_tdata;
    wire       user_tx_tvalid;
    wire       user_tx_tlast;
    wire       user_tx_tready;

    generate
        if (TX_CSUM_OFFLOAD != 0) begin : gen_tx_csum
            wire [7:0] csum_m_tdata;
            wire       csum_m_tvalid;
            wire       csum_m_tlast;
            wire       csum_s_tready;

            tx_csum_off #(.MAX_FRAME(MAX_FRAME)) u_tx_csum (
                .clk           (clk),
                .rst_n         (rst_n),
                .enable        (cfg_tx_csum_off),
                .s_axis_tdata  (s_axis_tdata),
                .s_axis_tvalid (s_axis_tvalid_gated & cfg_tx_csum_off),
                .s_axis_tready (csum_s_tready),
                .s_axis_tlast  (s_axis_tlast),
                .m_axis_tdata  (csum_m_tdata),
                .m_axis_tvalid (csum_m_tvalid),
                .m_axis_tready (s_axis_tready_mac & cfg_tx_csum_off),
                .m_axis_tlast  (csum_m_tlast)
            );

            assign user_tx_tdata  = cfg_tx_csum_off ? csum_m_tdata  : s_axis_tdata;
            assign user_tx_tvalid = cfg_tx_csum_off ? csum_m_tvalid : s_axis_tvalid_gated;
            assign user_tx_tlast  = cfg_tx_csum_off ? csum_m_tlast  : s_axis_tlast;
            assign s_axis_tready  = cfg_tx_csum_off ? (csum_s_tready & cfg_tx_en)
                                                    : (user_tx_tready & cfg_tx_en);
        end else begin : gen_no_tx_csum
            assign user_tx_tdata  = s_axis_tdata;
            assign user_tx_tvalid = s_axis_tvalid_gated;
            assign user_tx_tlast  = s_axis_tlast;
            assign s_axis_tready  = user_tx_tready & cfg_tx_en;
        end
    endgenerate

    // PAUSE-priority mux: while a pause frame is being emitted, route
    // pause_* into eth_mac_tx and stall user_*. Pause frames are short and
    // rare, so simple priority-on-tvalid is acceptable here.
    wire [7:0] mac_tx_in_tdata  = pause_tvalid ? pause_tdata  : user_tx_tdata;
    wire       mac_tx_in_tvalid = pause_tvalid ? pause_tvalid : user_tx_tvalid;
    wire       mac_tx_in_tlast  = pause_tvalid ? pause_tlast  : user_tx_tlast;
    assign     pause_tready     = pause_tvalid &  s_axis_tready_mac;
    assign     user_tx_tready   = ~pause_tvalid & s_axis_tready_mac;

    // RX gating: mask tvalid when rx disabled
    wire [7:0] m_axis_tdata_mac;
    wire       m_axis_tvalid_mac;
    wire       m_axis_tlast_mac;
    wire       m_axis_terror_mac;
    wire       m_axis_tsof_mac;
    wire       m_axis_tready_mac = cfg_rx_en ? m_axis_tready : 1'b1;

    assign m_axis_tdata  = m_axis_tdata_mac;
    assign m_axis_tvalid = m_axis_tvalid_mac & cfg_rx_en;
    assign m_axis_tlast  = m_axis_tlast_mac;
    assign m_axis_terror = m_axis_terror_mac;
    assign m_axis_tsof   = m_axis_tsof_mac;

    // =========================================================================
    // MAC TX - adds preamble/SFD, pads, appends CRC
    // =========================================================================
    eth_mac_tx #(.MAX_FRAME(MAX_FRAME)) u_mac_tx (
        .clk           (clk),
        .rst_n         (rst_n),
        // tx_start_ok also blocked by tx_paused so a received PAUSE quanta
        // gates the start of the next frame (an in-flight frame is allowed
        // to complete by design — eth_mac_tx samples tx_start_ok only in S_IDLE).
        .tx_start_ok   (~tx_fifo_busy & ~tx_paused),
        .gmii_txd      (gmii_txd),
        .gmii_tx_en    (gmii_tx_en),
        .gmii_tx_er    (gmii_tx_er),
        .s_axis_tdata  (mac_tx_in_tdata),
        .s_axis_tvalid (mac_tx_in_tvalid),
        .s_axis_tready (s_axis_tready_mac),
        .s_axis_tkeep  (1'b1),
        .s_axis_tlast  (mac_tx_in_tlast),
        .tx_active     (tx_active),
        .dbg_state     (),
        .dbg_stall_cnt ()
    );

    // =========================================================================
    // MAC RX - strips preamble/SFD, validates CRC
    // =========================================================================
    eth_mac_rx #(.MCAST_HASH_FILTER(MCAST_HASH_FILTER)) u_mac_rx (
        .clk              (clk),
        .rst_n            (rst_n),
        .gmii_rxd         (gmii_rxd),
        .gmii_rx_dv       (gmii_rx_dv),
        .gmii_rx_er       (gmii_rx_er),
        .our_mac          (cfg_mac_addr),
        .promisc          (cfg_promisc),
        .passthrough      (cfg_passthrough),
        .jumbo_en         (cfg_jumbo_en),
        .mcast_hash_table (cfg_mcast_hash_table),
        .m_axis_tdata     (m_axis_tdata_mac),
        .m_axis_tvalid    (m_axis_tvalid_mac),
        .m_axis_tready    (m_axis_tready_mac),
        .m_axis_tlast     (m_axis_tlast_mac),
        .m_axis_terror    (m_axis_terror_mac),
        .m_axis_tsof      (m_axis_tsof_mac),
        .stat_done         (rx_stat_done),
        .stat_len          (rx_stat_len),
        .stat_err_fcs      (rx_stat_err_fcs),
        .stat_err_align    (rx_stat_err_align),
        .stat_err_overflow (rx_stat_err_overflow),
        .stat_err_oversize (rx_stat_err_oversize),
        .stat_is_bcast     (rx_stat_is_bcast),
        .stat_is_mcast     (rx_stat_is_mcast)
    );

    // =========================================================================
    // 802.3x PAUSE flow control
    // =========================================================================
    eth_pause u_pause (
        .clk                 (clk),
        .rst_n               (rst_n),
        .our_mac             (cfg_mac_addr),
        .cfg_speed           (cfg_speed),
        .cfg_pause_rx_en     (cfg_pause_rx_en),
        .cfg_pause_tx_send   (cfg_pause_tx_send),
        .cfg_pause_tx_quanta (cfg_pause_tx_quanta),
        .gmii_rxd            (gmii_rxd),
        .gmii_rx_dv          (gmii_rx_dv),
        .tx_paused           (tx_paused),
        .pause_tdata         (pause_tdata),
        .pause_tvalid        (pause_tvalid),
        .pause_tready        (pause_tready),
        .pause_tlast         (pause_tlast),
        .pause_rx_cnt        (stat_pause_rx_cnt),
        .pause_tx_cnt        (stat_pause_tx_cnt)
    );

    // =========================================================================
    // PHY interface selection (MII or RGMII)
    // =========================================================================
    generate
        if (PHY_INTERFACE == "MII") begin : gen_mii
            mii_if #(.MII_DEBUG(MII_DEBUG)) u_mii_if (
                .clk            (clk),
                .rst_n          (rst_n),
                .mii_rxd        (mii_rxd),
                .mii_rx_dv      (mii_rx_dv),
                .mii_rx_er      (mii_rx_er),
                .mii_rx_clk     (mii_rx_clk),
                .mii_col        (mii_col),
                .mii_crs        (mii_crs),
                .mii_txd        (mii_txd),
                .mii_tx_en      (mii_tx_en),
                .mii_tx_clk     (mii_tx_clk),
                .gmii_txd       (gmii_txd),
                .gmii_tx_en     (gmii_tx_en),
                .gmii_tx_er     (gmii_tx_er),
                .gmii_rxd       (gmii_rxd),
                .gmii_rx_dv     (gmii_rx_dv),
                .gmii_rx_er     (gmii_rx_er),
                .mii_tx_clk_out (),
                .tx_busy               (tx_fifo_busy),
                .tx_fifo_level         (tx_fifo_level),
                .dbg_tx_fifo_empty     (),
                .dbg_rx_prog_empty     (),
                .dbg_rx_rd_empty       (),
                .dbg_rx_reading        (),
                .dbg_rx_frames_pending (),
                .dbg_tx_wr_en          (),
                .dbg_tx_len_wr_en      (),
                .dbg_tx_wr_full        (),
                .dbg_tx_wr_rst_busy_out(),
                .dbg_tx_rd_en          (),
                .dbg_tx_frame_loaded   (),
                .dbg_tx_frames_queued  (),
                .dbg_tx_frames_drained (),
                .dbg_last_tx_len_wr    (),
                .dbg_mii_cap_done      (),
                .dbg_mii_cap_frame_len (),
                .dbg_mii_cap_word0     (),
                .dbg_mii_cap_word1     (),
                .dbg_mii_cap_word2     (),
                .dbg_mii_cap_word3     (),
                .dbg_mii_cap_word4     (),
                .dbg_mii_cap_word5     (),
                .dbg_mii_cap_word6     (),
                .dbg_mii_cap_word7     (),
                .dbg_mii_cap_word8     (),
                .dbg_mii_cap_word9     (),
                .dbg_mii_cap_word10    (),
                .dbg_mii_cap_word11    (),
                .dbg_mii_cap_word12    (),
                .dbg_mii_cap_word13    (),
                .dbg_mii_cap_word14    (),
                .dbg_mii_cap_word15    (),
                .dbg_mii_txd_pre_iob   (),
                .dbg_mii_tx_en_pre_iob (),
                .dbg_rx_fifo_full_frames (),
                .dbg_rx_fifo_full_writes (),
                .dbg_rx_fifo_overflow_pulses (),
                .dbg_rx_fifo_wr_level_max (),
                .dbg_rx_replay_gap_frames (),
                .dbg_rx_replay_gap_cycles (),
                .dbg_rx_replay_gap_byte_max (),
                .dbg_rx_mii_last_len (),
                .dbg_rx_mii_word0 (),
                .dbg_rx_mii_word1 (),
                .dbg_rx_mii_word2 (),
                .dbg_rx_mii_word3 (),
                .dbg_rx_mii_word4 (),
                .dbg_rx_mii_word5 (),
                .dbg_rx_mii_word6 (),
                .dbg_rx_mii_word7 (),
                .dbg_rx_mii_word8 (),
                .dbg_rx_mii_word9 (),
                .dbg_rx_mii_word10 (),
                .dbg_rx_mii_word11 (),
                .dbg_rx_mii_word12 (),
                .dbg_rx_mii_word13 (),
                .dbg_rx_mii_word14 (),
                .dbg_rx_mii_word15 (),
                .dbg_rx_replay_last_len (),
                .dbg_rx_replay_word0 (),
                .dbg_rx_replay_word1 (),
                .dbg_rx_replay_word2 (),
                .dbg_rx_replay_word3 (),
                .dbg_rx_replay_eof_count (),
                .dbg_tx_er_pulses    (),
                .dbg_tx_er_frames    ()
            );

            // Tie off RGMII outputs
            assign rgmii_txd   = 4'd0;
            assign rgmii_tx_ctl = 1'b0;
            assign rgmii_txc   = 1'b0;
        end else begin : gen_rgmii
            // GMII-level signals between CDC and RGMII interface
            wire [7:0] media_gmii_txd;
            wire       media_gmii_tx_en;
            wire       media_gmii_tx_er;
            wire [7:0] media_gmii_rxd;
            wire       media_gmii_rx_dv;
            wire       media_gmii_rx_er;

            wire [11:0] rgmii_tx_fifo_level;

            gmii_cdc u_gmii_cdc (
                .sys_clk        (clk),
                .sys_rst_n      (rst_n),
                .media_clk      (clk_125),
                .media_rx_clk   (rgmii_rxc),
                .cfg_speed      (cfg_speed),
                .gmii_txd_in    (gmii_txd),
                .gmii_tx_en_in  (gmii_tx_en),
                .gmii_tx_er_in  (gmii_tx_er),
                .gmii_rxd_out   (gmii_rxd),
                .gmii_rx_dv_out (gmii_rx_dv),
                .gmii_rx_er_out (gmii_rx_er),
                .gmii_txd_out   (media_gmii_txd),
                .gmii_tx_en_out (media_gmii_tx_en),
                .gmii_tx_er_out (media_gmii_tx_er),
                .gmii_rxd_in    (media_gmii_rxd),
                .gmii_rx_dv_in  (media_gmii_rx_dv),
                .gmii_rx_er_in  (media_gmii_rx_er),
                .tx_busy        (tx_fifo_busy),
                .tx_fifo_level  (rgmii_tx_fifo_level)
            );

            assign tx_fifo_level = {1'b0, rgmii_tx_fifo_level};

            rgmii_if u_rgmii_if (
                .clk_125     (clk_125),
                .clk_125_90  (clk_125_90),
                .clk_25      (clk_25),
                .clk_2_5     (clk_2_5),
                .rst_n       (rst_n),
                .cfg_speed   (cfg_speed),
                .rgmii_txd   (rgmii_txd),
                .rgmii_tx_ctl(rgmii_tx_ctl),
                .rgmii_txc   (rgmii_txc),
                .rgmii_rxd   (rgmii_rxd),
                .rgmii_rx_ctl(rgmii_rx_ctl),
                .rgmii_rxc   (rgmii_rxc),
                .gmii_txd    (media_gmii_txd),
                .gmii_tx_en  (media_gmii_tx_en),
                .gmii_tx_er  (media_gmii_tx_er),
                .gmii_rxd    (media_gmii_rxd),
                .gmii_rx_dv  (media_gmii_rx_dv),
                .gmii_rx_er  (media_gmii_rx_er)
            );

            // Tie off MII outputs
            assign mii_txd   = 4'd0;
            assign mii_tx_en = 1'b0;
        end
    endgenerate

    // =========================================================================
    // Statistics counters
    // =========================================================================
    // TX frame done: falling edge of gmii_tx_en
    reg gmii_tx_en_d1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) gmii_tx_en_d1 <= 1'b0;
        else        gmii_tx_en_d1 <= gmii_tx_en;
    end
    wire tx_frame_done = gmii_tx_en_d1 & ~gmii_tx_en;

    // RX frame done pulses
    wire rx_frame_good = m_axis_tvalid_mac & m_axis_tlast_mac & ~m_axis_terror_mac;
    wire rx_frame_bad  = m_axis_tvalid_mac & m_axis_tlast_mac &  m_axis_terror_mac;

    eth_stats u_stats (
        .clk            (clk),
        .rst_n          (rst_n),
        .gmii_tx_en     (gmii_tx_en),
        .gmii_rx_dv     (gmii_rx_dv),
        .tx_frame_done  (tx_frame_done),
        .rx_frame_good  (rx_frame_good),
        .rx_frame_bad   (rx_frame_bad),
        .rx_stat_done         (rx_stat_done),
        .rx_stat_len          (rx_stat_len),
        .rx_stat_err_fcs      (rx_stat_err_fcs),
        .rx_stat_err_align    (rx_stat_err_align),
        .rx_stat_err_overflow (rx_stat_err_overflow),
        .rx_stat_err_oversize (rx_stat_err_oversize),
        .rx_stat_is_bcast     (rx_stat_is_bcast),
        .rx_stat_is_mcast     (rx_stat_is_mcast),
        .tx_frame_cnt   (stat_tx_frame_cnt),
        .tx_byte_cnt    (stat_tx_byte_cnt),
        .rx_frame_cnt   (stat_rx_frame_cnt),
        .rx_byte_cnt    (stat_rx_byte_cnt),
        .rx_crc_err_cnt (stat_rx_err_cnt),
        .rx_err_align_cnt      (stat_rx_err_align_cnt),
        .rx_err_overflow_cnt   (stat_rx_err_overflow_cnt),
        .rx_err_oversize_cnt   (stat_rx_err_oversize_cnt),
        .rx_bcast_cnt          (stat_rx_bcast_cnt),
        .rx_mcast_cnt          (stat_rx_mcast_cnt),
        .rx_size_64_cnt        (stat_rx_size_64_cnt),
        .rx_size_65_127_cnt    (stat_rx_size_65_127_cnt),
        .rx_size_128_255_cnt   (stat_rx_size_128_255_cnt),
        .rx_size_256_511_cnt   (stat_rx_size_256_511_cnt),
        .rx_size_512_1023_cnt  (stat_rx_size_512_1023_cnt),
        .rx_size_1024_1518_cnt (stat_rx_size_1024_1518_cnt),
        .rx_size_jumbo_cnt     (stat_rx_size_jumbo_cnt),
        .clr_tx         (stat_clr_tx),
        .clr_rx         (stat_clr_rx)
    );

    // =========================================================================
    // TX done event for IRQ (falling edge of tx_active)
    // =========================================================================
    reg tx_active_d1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) tx_active_d1 <= 1'b0;
        else        tx_active_d1 <= tx_active;
    end
    wire evt_tx_done  = tx_active_d1 & ~tx_active;
    wire evt_rx_frame = m_axis_tvalid_mac & m_axis_tlast_mac;

    // =========================================================================
    // AXI4-Lite CSR
    // =========================================================================
    axilite_regs #(.ADDR_WIDTH(8), .MCAST_HASH_FILTER(MCAST_HASH_FILTER)) u_csr (
        .s_axi_aclk     (clk),
        .s_axi_aresetn   (rst_n),
        .s_axi_awaddr   (s_axi_awaddr),
        .s_axi_awvalid  (s_axi_awvalid),
        .s_axi_awready  (s_axi_awready),
        .s_axi_wdata    (s_axi_wdata),
        .s_axi_wstrb    (s_axi_wstrb),
        .s_axi_wvalid   (s_axi_wvalid),
        .s_axi_wready   (s_axi_wready),
        .s_axi_bresp    (s_axi_bresp),
        .s_axi_bvalid   (s_axi_bvalid),
        .s_axi_bready   (s_axi_bready),
        .s_axi_araddr   (s_axi_araddr),
        .s_axi_arvalid  (s_axi_arvalid),
        .s_axi_arready  (s_axi_arready),
        .s_axi_rdata    (s_axi_rdata),
        .s_axi_rresp    (s_axi_rresp),
        .s_axi_rvalid   (s_axi_rvalid),
        .s_axi_rready   (s_axi_rready),
        .cfg_tx_en             (cfg_tx_en),
        .cfg_rx_en             (cfg_rx_en),
        .cfg_promisc           (cfg_promisc),
        .cfg_speed             (cfg_speed),
        .cfg_full_duplex       (cfg_full_duplex),
        .cfg_jumbo_en          (cfg_jumbo_en),
        .cfg_tx_csum_off       (cfg_tx_csum_off),
        .cfg_passthrough       (cfg_passthrough),
        .cfg_mac_addr          (cfg_mac_addr),
        .cfg_mcast_hash_table  (cfg_mcast_hash_table),
        .mdio_go        (mdio_go),
        .mdio_write     (mdio_write),
        .mdio_phy_addr  (mdio_phy_addr),
        .mdio_reg_addr  (mdio_reg_addr),
        .mdio_wdata     (mdio_wdata_csr),
        .mdio_c45_en    (mdio_c45_en),
        .mdio_c45_op    (mdio_c45_op),
        .mdio_rdata     (mdio_rdata_csr),
        .mdio_done      (mdio_done),
        .mdio_busy      (mdio_busy_r),
        .stat_tx_frame_cnt (stat_tx_frame_cnt),
        .stat_tx_byte_cnt  (stat_tx_byte_cnt),
        .stat_rx_frame_cnt (stat_rx_frame_cnt),
        .stat_rx_byte_cnt  (stat_rx_byte_cnt),
        .stat_rx_err_cnt   (stat_rx_err_cnt),
        .stat_rx_err_align_cnt    (stat_rx_err_align_cnt),
        .stat_rx_err_overflow_cnt (stat_rx_err_overflow_cnt),
        .stat_rx_err_oversize_cnt (stat_rx_err_oversize_cnt),
        .stat_rx_bcast_cnt        (stat_rx_bcast_cnt),
        .stat_rx_mcast_cnt        (stat_rx_mcast_cnt),
        .stat_rx_size_64_cnt        (stat_rx_size_64_cnt),
        .stat_rx_size_65_127_cnt    (stat_rx_size_65_127_cnt),
        .stat_rx_size_128_255_cnt   (stat_rx_size_128_255_cnt),
        .stat_rx_size_256_511_cnt   (stat_rx_size_256_511_cnt),
        .stat_rx_size_512_1023_cnt  (stat_rx_size_512_1023_cnt),
        .stat_rx_size_1024_1518_cnt (stat_rx_size_1024_1518_cnt),
        .stat_rx_size_jumbo_cnt     (stat_rx_size_jumbo_cnt),
        .cfg_pause_rx_en      (cfg_pause_rx_en),
        .cfg_pause_tx_send    (cfg_pause_tx_send),
        .cfg_pause_tx_quanta  (cfg_pause_tx_quanta),
        .stat_pause_rx_cnt    (stat_pause_rx_cnt),
        .stat_pause_tx_cnt    (stat_pause_tx_cnt),
        .stat_clr_pause       (stat_clr_pause),
        .stat_clr_tx    (stat_clr_tx),
        .stat_clr_rx    (stat_clr_rx),
        .sts_tx_active    (tx_active),
        .sts_tx_fifo_busy (tx_fifo_busy),
        .evt_tx_done    (evt_tx_done),
        .evt_rx_frame   (evt_rx_frame),
        .irq            (irq)
    );

    // =========================================================================
    // MDIO master
    // =========================================================================
    mdio_master u_mdio (
        .clk       (clk),
        .rst_n     (rst_n),
        .mdc       (mdc),
        .mdio_o    (mdio_o),
        .mdio_oe   (mdio_oe),
        .mdio_i    (mdio_i),
        .cmd_valid (mdio_go),
        .cmd_write (mdio_write),
        .cmd_phy   (mdio_phy_addr),
        .cmd_reg   (mdio_reg_addr),
        .cmd_wdata (mdio_wdata_csr),
        .cmd_c45_en(mdio_c45_en),
        .cmd_c45_op(mdio_c45_op),
        .cmd_rdata (mdio_rdata_csr),
        .cmd_done  (mdio_done),
        .dbg_rd_low_cnt (),
        .dbg_rd_raw     ()
    );

endmodule
