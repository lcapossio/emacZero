// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// eth_mac_sys_10g.v - 10G Ethernet MAC system: 64-bit AXI4-Stream in the
// application clock domain, XGMII to a 10GBASE-R PCS, AXI4-Lite CSRs
//
//   clk domain                       | xgmii_tx_clk             | xgmii_rx_clk
//   s_axis -> [csum insert] -> TX frame FIFO -> eth_mac_10g_tx -> RS -> XGMII TX
//   m_axis <- RX frame FIFO <- filter <- [csum check] <- eth_mac_10g_rx <- XGMII RX
//                                                                   RS <-'
//
// Link faults (eth_rs_10g, IEEE 802.3 clause 46.3.4): four local or remote
// fault sequences of one type on XGMII RX, each fewer than 128 columns after
// the one before, report that fault (STATUS [3] / [4]); a PCS without block
// lock sends local fault sequences. While a fault is reported the TX MAC
// starts no new frame: frames wait in the TX FIFO and s_axis backpressures
// once it is full; the frame part-way out is finished. With a local fault
// the idle words on XGMII TX become remote
// fault sequences, so the far end learns that its signal is not arriving;
// with a remote fault they stay idles. Traffic resumes once the fault clears
// (128 columns with no fault sequence of either type).
//
// PAUSE (IEEE 802.3 clause 31, Annex 31B; eth_pause_10g): received PAUSE
// frames are recognized at the RX MAC's output, ahead of the filter (they
// are still delivered if the filter accepts them, as on the 1G core), and
// with PAUSE_CTRL[1] they hold data frames that have not started for
// pause_time quanta, counted from the end of the frames already committed.
// PAUSE frames of our own (PAUSE_CTRL[0], or automatic from the RX FIFO
// level, PAUSE_CTRL[2]) go to the MAC ahead of data frames that have not
// started, and are not held by a received pause or by CTRL[0], only by a
// link fault. A TX arbiter picks the source of each frame as its first beat
// is offered to the MAC and keeps it until the last beat is taken.
//
// Checksum offload (the 1G core's CTRL[7] / CTRL[9], scope of csum_calc64):
//   TX_CSUM_OFFLOAD=1: tx_csum_off64 ahead of the TX FIFO. With CTRL[7] set
//     (taken at a frame's first beat) it writes the IPv4 header checksum and
//     the TCP / UDP / ICMP / ICMPv6 checksum of each frame, whatever was in
//     those fields; a UDP checksum computing to 0 goes out as 0xFFFF. It
//     stores each frame first (a buffer of 2**TX_FIFO_ADDR_WIDTH words), so
//     a frame waits there about its own length; a frame too long for it is
//     dropped (TX_DROP). A transceiver TX reset throws frames away as they
//     leave the inserter, so a frame it holds when the reset ends (taken
//     before or during the reset) is sent whole.
//   RX_CSUM_OFFLOAD=1: csum_calc64 checks each received frame (CTRL[9],
//     taken at its first beat), and a frame whose IPv4 header checksum or
//     L4 checksum is wrong is a bad frame like one with a bad FCS: dropped
//     (RX_DISCARD), or delivered with tuser under passthrough. A UDP
//     checksum of 0 means none and passes. Such frames, with no MAC error,
//     count in RX_ERR_CSUM; they still count in RX_FRAMES. The check delays
//     the RX stream by 7 xgmii_rx_clk cycles.
//   IPv4 options: csum_calc64 does not walk them; the L4 checksum is left
//   alone (TX) or not checked (RX) when any option byte is 0x83 or 0x89,
//   so every source route is covered (see rtl/csum_calc64.v).
//
// Both FIFOs are store-and-forward frame FIFOs (axis_async_frame_fifo):
//   TX: the MAC starts a frame only once it is whole in the FIFO, so it never
//       runs dry mid-frame (an underrun would corrupt the frame on the line),
//       whatever the application does with tvalid. A frame that does not fit
//       the FIFO at all is dropped (TX_DROP).
//   RX: the MAC cannot be stalled. Frames that fail the address filter, that
//       arrive while RX is disabled, or that the MAC flags bad (unless
//       passthrough is set) are dropped (RX_DISCARD); a frame that finds the
//       FIFO full is dropped whole (RX_DROP). m_axis only ever carries whole
//       frames, and may stall for as long as it likes.
//
// Rates: the TX MAC takes one 8-byte word on 32 of every 33 xgmii_tx_clk
// cycles (161.13 MHz for 10GBASE-R): 156.25 M words/s. clk must sustain that
// on both streams, so it should be at least ~160 MHz (200 MHz is a good
// choice) for line rate; a slower clk works, at the lower rate.
//
// AXI4-Stream (64-bit, tdata[7:0] is the first byte on the wire):
//   s_axis: tkeep is all ones except on the last beat, where its ones are
//           contiguous from bit 0. tuser on any beat sends the frame with a
//           bad FCS. Frames shorter than 60 bytes are padded.
//   m_axis: the frame without its FCS. tuser on the last beat marks a bad
//           frame, delivered only with passthrough (CTRL[8]) set.
//
// Register map (32-bit, byte addresses; offsets shared with axilite_regs.v
// keep their meaning there):
//   0x00 VERSION   RO  {MAJOR, MINOR, ID} from rtl/version.vh
//   0x04 CTRL      RW  [0] tx_en  [1] rx_en  [2] promisc  [6] jumbo_en
//                      [7] tx_csum_off (TX_CSUM_OFFLOAD=1)
//                      [8] passthrough (accept every address, deliver bad
//                          frames with tuser)
//                      [9] rx_csum_off (RX_CSUM_OFFLOAD=1)
//                      tx_en / rx_en act between frames only, as on the 1G
//                      core: a frame part-way through is finished whole.
//   0x08 STATUS    RO  [0] PCS block lock  [1] PCS high BER
//                      [2] TX FIFO not empty  [3] local fault  [4] remote
//                      fault (link fault reported on XGMII RX)
//                      [5] TX paused by a received PAUSE frame
//   0x0C MAC_LO    RW  station address [31:0]  (bits 47:40 = first byte)
//   0x10 MAC_HI    RW  station address [47:32]
//   0x3C SCRATCH   RW
//   0x44 MCAST_LO  RW  multicast hash table [31:0]  } MCAST_HASH_FILTER=1
//   0x48 MCAST_HI  RW  multicast hash table [63:32] } only (as axilite_regs)
//   0x40 IP_ADDR   RW  IPv4 address for a board-level L3 stack (cfg_ip_addr;
//                      not used by the MAC), as the 1G map
//   0x84 PAUSE_CTRL    RW  [0] tx_send (W1S, reads 0)  [1] rx_en  [2] auto_en
//                          RO  [3] auto_active  [4] auto_cfg_err  [5] tx_pending
//   0x88 PAUSE_QUANTA  RW  [15:0] quanta of the PAUSE frames we send
//   0x8C PAUSE_RX_CNT  valid PAUSE frames received } saturating; a write to
//   0x90 PAUSE_TX_CNT  PAUSE frames sent           } either clears both
//   0x9C PAUSE_XOFF    RW  [19:0] automatic PAUSE XOFF level, RX FIFO bytes
//   0xA0 PAUSE_XON     RW  [19:0] XON level (reset: half / a quarter of the FIFO)
//   0xA4 PAUSE_REFRESH RW  [15:0] XOFF repeat interval, quanta (0: quanta / 2)
//   0x98 CAPS      RO  [0] MCAST_HASH_FILTER  [1] TX_CSUM_OFFLOAD
//                      [2] RX_CSUM_OFFLOAD  [3] automatic PAUSE
//                      [8:4] RX FIFO size, log2 bytes
//                      [9] 1 = 10G core (64-bit streams, this map)
//                      [31:16] MAX_FRAME_JUMBO
//   Counters (write any value to clear one; 64-bit counters: reading the low
//   word latches the high word, read it next):
//   0xB0/B4 TX_FRAMES  frames sent with a good FCS
//   0xB8/BC TX_BYTES   their bytes, padding and FCS included
//   0xC0/C4 RX_FRAMES  good frames received (before the filter and FIFO)
//   0xC8/CC RX_BYTES   their bytes, FCS included
//   0xD0 RX_ERR_FCS    0xD4 RX_ERR_CTL (control character or bad SFD)
//   0xD8 RX_ERR_OVERSIZE   0xDC RX_ERR_UNDERSIZE
//   0x80 RX_ERR_CSUM   frames with a wrong IP / L4 checksum and no MAC error
//                      (CTRL[9])
//   0xE0 RX_BCAST      0xE4 RX_MCAST (good frames)
//   0xE8 RX_DROP       frames lost because the RX FIFO was full
//   0xEC RX_DISCARD    frames dropped on purpose (filter, RX disabled, bad)
//   0xF0 TX_UNDERRUN   (cannot happen with the store-and-forward FIFO; kept
//                       as a check)
//   0xF4 TX_DROP       frames too long for the TX FIFO (or the checksum
//                      buffer), or thrown away by a TX crossing reset
//   0xF8 TX_ERR        frames sent with a bad FCS on purpose (tuser)
//   0xFC LOCK_LOSS     times PCS block lock was lost
//   0xA8 LOCAL_FAULTS  times a local fault was reported
//   0xAC REMOTE_FAULTS times a remote fault was reported
//
// Clock crossings: the FIFOs, the stats FIFOs and cdc_event_count carry their
// data safely. Each crossing (TX: clk to xgmii_tx_clk, RX: xgmii_rx_clk to
// clk) is reset whole, because its FIFOs hold pointers on both sides and a
// reset of one side alone would leave the two disagreeing (the far side
// would read stale memory). Either side's reset resets the whole crossing:
// the clk side first and synchronously, then the transceiver side; the
// transceiver side comes out of reset after the clk side. So a transceiver
// reset (xgmii_*_rst_n) costs the frames in flight, and the AXIS ports stay
// well formed through it:
//   - TX: while the crossing is in reset, s_axis beats are taken and thrown
//     away, and so is the rest of a frame part-way written when it began;
//     each such frame counts in TX_DROP.
//   - RX: a frame part-way read (or a first beat waiting) when it begins is
//     closed with one extra beat: tlast, tuser, tkeep 8'h01, data 0.
// CTRL, the station address and the hash table reach the
// transceiver domains through two-flop synchronizers: they are meant to be
// set while the link is idle (a frame received while they change may be
// filtered against a mix of old and new bits).
// eth_pause_10g also carries multi-bit values between xgmii_rx_clk and
// xgmii_tx_clk (a received pause_time): when those clocks are unrelated,
// bound that path like the clk crossings (set_max_delay -datapath_only
// under a destination clock period), do not cut it.
// Verilog 2001
// =============================================================================

`include "version.vh"

module eth_mac_sys_10g #(
    parameter MAX_FRAME_JUMBO    = 9018,
    parameter TX_FIFO_ADDR_WIDTH = 11,      // 2**n 8-byte words (11: 16 KB)
    parameter RX_FIFO_ADDR_WIDTH = 11,
    parameter MCAST_HASH_FILTER  = 0,
    parameter TX_CSUM_OFFLOAD    = 0,       // 1: build the TX checksum inserter
    parameter RX_CSUM_OFFLOAD    = 0,       // 1: build the RX checksum checker
    // Reset values, for designs with no CPU: TXRX_EN_AT_RESET sets CTRL[1:0],
    // JUMBO_AT_RESET CTRL[6], MAC_ADDR_AT_RESET the station address,
    // IP_ADDR_AT_RESET IP_ADDR (the 1G core's 192.168.137.200 by default).
    parameter TXRX_EN_AT_RESET   = 0,
    parameter JUMBO_AT_RESET     = 0,
    parameter [47:0] MAC_ADDR_AT_RESET = 48'h0,
    parameter [31:0] IP_ADDR_AT_RESET  = 32'hC0A8_89C8
) (
    input  wire        clk,
    input  wire        rst_n,

    // AXI4-Lite CSR slave (clk)
    input  wire [7:0]  s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [7:0]  s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output reg  [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    // AXI4-Stream TX slave (clk)
    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tuser,

    // AXI4-Stream RX master (clk)
    output wire [63:0] m_axis_tdata,
    output wire [7:0]  m_axis_tkeep,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output wire        m_axis_tuser,

    // XGMII TX (xgmii_tx_clk): one word per xgmii_tx_ready
    input  wire        xgmii_tx_clk,
    input  wire        xgmii_tx_rst_n,
    output wire [63:0] xgmii_txd,
    output wire [7:0]  xgmii_txc,
    input  wire        xgmii_tx_ready,

    // XGMII RX (xgmii_rx_clk): one word per xgmii_rx_valid
    input  wire        xgmii_rx_clk,
    input  wire        xgmii_rx_rst_n,
    input  wire [63:0] xgmii_rxd,
    input  wire [7:0]  xgmii_rxc,
    input  wire        xgmii_rx_valid,

    // PCS status (any domain; synchronized here)
    input  wire        pcs_block_lock,
    input  wire        pcs_hi_ber,

    // IP_ADDR (clk), for a board-level L3 stack
    output wire [31:0] cfg_ip_addr
);

    // =========================================================================
    // CSRs (clk)
    // =========================================================================
    reg  [31:0] ctrl;
    reg  [47:0] mac_addr;
    reg  [63:0] mc_hash;
    reg  [31:0] scratch;
    reg  [31:0] ip_addr;
    assign cfg_ip_addr = ip_addr;
    reg         p_rx_en, p_auto_en, p_send;
    reg  [15:0] p_quanta, p_refresh;
    reg  [19:0] p_xoff, p_xon;

    wire cfg_tx_en   = ctrl[0];
    wire cfg_rx_en   = ctrl[1];
    wire cfg_promisc = ctrl[2];
    wire cfg_jumbo   = ctrl[6];
    wire cfg_pass    = ctrl[8];
    wire cfg_tx_csum = ctrl[7];
    wire cfg_rx_csum = ctrl[9];

    // ---- status synchronizers
    (* ASYNC_REG = "TRUE" *) reg [1:0] lock_s;
    (* ASYNC_REG = "TRUE" *) reg [1:0] hiber_s;
    reg lock_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lock_s  <= 2'b00;
            hiber_s <= 2'b00;
            lock_d  <= 1'b0;
        end else begin
            lock_s  <= {lock_s[0], pcs_block_lock};
            hiber_s <= {hiber_s[0], pcs_hi_ber};
            lock_d  <= lock_s[1];
        end
    end
    wire lock_lost = lock_d && !lock_s[1];

    // link fault code (eth_rs_10g, rx domain): decoded once it held for two
    // cycles, so a code passing between none and remote is not miscounted.
    // Its bits arrive at most a cycle apart only when the path is bounded
    // under a clk period, as the FIFOs' Gray pointers also need.
    wire [1:0] rx_fault;
    (* ASYNC_REG = "TRUE" *) reg [1:0] flt_s1;
    (* ASYNC_REG = "TRUE" *) reg [1:0] flt_s2;
    reg  [1:0] flt_s3, flt_st, flt_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            flt_s1 <= 2'b00;
            flt_s2 <= 2'b00;
            flt_s3 <= 2'b00;
            flt_st <= 2'b00;
            flt_d  <= 2'b00;
        end else begin
            flt_s1 <= rx_fault;
            flt_s2 <= flt_s1;
            flt_s3 <= flt_s2;
            if (flt_s2 == flt_s3)
                flt_st <= flt_s3;
            flt_d <= flt_st;
        end
    end
    wire st_lf  = (flt_st == 2'b01);
    wire st_rf  = (flt_st == 2'b11);
    wire lf_new = st_lf && (flt_d != 2'b01);
    wire rf_new = st_rf && (flt_d != 2'b11);

    // ---- crossing resets (see header)
    // clk side: catch the transceiver reset (it may be shorter than a clk
    // cycle) and synchronize it, so it asserts and releases on clk edges.
    // Transceiver side: reset at once by the clk side, released after its
    // own synchronizer.
    wire txl_arst_n = rst_n && xgmii_tx_rst_n;
    wire rxl_arst_n = rst_n && xgmii_rx_rst_n;
    (* ASYNC_REG = "TRUE" *) reg       txa_c, rxa_c;
    (* ASYNC_REG = "TRUE" *) reg [1:0] txa_s, rxa_s;
    always @(posedge clk or negedge txl_arst_n)
        if (!txl_arst_n) txa_c <= 1'b0; else txa_c <= 1'b1;
    always @(posedge clk or negedge rxl_arst_n)
        if (!rxl_arst_n) rxa_c <= 1'b0; else rxa_c <= 1'b1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            txa_s <= 2'b00;
            rxa_s <= 2'b00;
        end else begin
            txa_s <= {txa_s[0], txa_c};
            rxa_s <= {rxa_s[0], rxa_c};
        end
    end
    wire a_tx_rst_n = txa_s[1];     // TX crossing, clk side
    wire a_rx_rst_n = rxa_s[1];     // RX crossing, clk side
    wire a_rx_fall  = rxa_s[1] && !rxa_s[0];    // a_rx_rst_n falls next edge

    (* ASYNC_REG = "TRUE" *) reg [2:0] txt_s;
    (* ASYNC_REG = "TRUE" *) reg [2:0] rxt_s;
    always @(posedge xgmii_tx_clk or negedge a_tx_rst_n)
        if (!a_tx_rst_n) txt_s <= 3'b000; else txt_s <= {txt_s[1:0], 1'b1};
    always @(posedge xgmii_rx_clk or negedge a_rx_rst_n)
        if (!a_rx_rst_n) rxt_s <= 3'b000; else rxt_s <= {rxt_s[1:0], 1'b1};
    wire t_tx_rst_n = txt_s[2];     // TX crossing, xgmii_tx_clk side
    wire t_rx_rst_n = rxt_s[2];     // RX crossing, xgmii_rx_clk side

    // =========================================================================
    // TX: gating, checksum inserter, frame FIFO, MAC
    // =========================================================================
    // tx_en acts between frames (as eth_mac_sys): tx_en_eff follows CTRL[0]
    // only when no frame is part-way accepted and no first beat is waiting.
    reg  tx_en_eff, tx_mid;
    wire g_ready;                   // ready of the stage after the gate
    wire tx_take     = s_axis_tvalid && s_axis_tready;
    wire tx_mid_next = tx_take ? !s_axis_tlast : tx_mid;
    wire tx_hold     = s_axis_tvalid && tx_en_eff && !s_axis_tready;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_mid    <= 1'b0;
            tx_en_eff <= (TXRX_EN_AT_RESET != 0);
        end else begin
            tx_mid <= tx_mid_next;
            if (!tx_mid_next && !tx_hold)
                tx_en_eff <= cfg_tx_en;
        end
    end
    assign s_axis_tready = tx_en_eff && g_ready;

    // the stream written to the TX FIFO: the gated s_axis, or the inserter's
    // output (w_drop: a frame too long for its buffer, cut, to be dropped)
    wire [63:0] w_tdata;
    wire [7:0]  w_tkeep;
    wire        w_tvalid, w_tlast, w_tuser, w_drop, w_tready;

    generate
        if (TX_CSUM_OFFLOAD != 0) begin : g_tx_csum
            tx_csum_off64 #(
                .BUF_ADDR_WIDTH (TX_FIFO_ADDR_WIDTH)
            ) u_tx_csum (
                .clk           (clk),
                .rst_n         (rst_n),
                .enable        (cfg_tx_csum),
                .s_axis_tdata  (s_axis_tdata),
                .s_axis_tkeep  (s_axis_tkeep),
                .s_axis_tvalid (s_axis_tvalid && tx_en_eff),
                .s_axis_tready (g_ready),
                .s_axis_tlast  (s_axis_tlast),
                .s_axis_tuser  (s_axis_tuser),
                .m_axis_tdata  (w_tdata),
                .m_axis_tkeep  (w_tkeep),
                .m_axis_tvalid (w_tvalid),
                .m_axis_tready (w_tready),
                .m_axis_tlast  (w_tlast),
                .m_axis_tuser  (w_tuser),
                .m_drop        (w_drop)
            );
        end else begin : g_no_tx_csum
            assign w_tdata  = s_axis_tdata;
            assign w_tkeep  = s_axis_tkeep;
            assign w_tvalid = s_axis_tvalid && tx_en_eff;
            assign w_tlast  = s_axis_tlast;
            assign w_tuser  = s_axis_tuser;
            assign w_drop   = 1'b0;
            assign g_ready  = w_tready;
        end
    endgenerate

    // While the TX crossing is in reset, and for the rest of a frame part-way
    // written when it began (tx_flush), words are taken and thrown away.
    reg  w_mid, tx_flush;
    wire txf_s_ready;
    wire tx_dump    = !a_tx_rst_n || tx_flush;
    wire w_take     = w_tvalid && w_tready;
    wire w_mid_next = w_take ? !w_tlast : w_mid;
    wire tx_dumped  = w_take && w_tlast && tx_dump;      // one frame lost
    assign w_tready = tx_dump || txf_s_ready;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_mid    <= 1'b0;
            tx_flush <= 1'b0;
        end else begin
            w_mid <= w_mid_next;
            if (!a_tx_rst_n)
                tx_flush <= w_mid_next;
            else if (w_take && w_tlast)
                tx_flush <= 1'b0;
        end
    end

    wire        txf_ovf, txf_drop;
    wire [TX_FIFO_ADDR_WIDTH:0] txf_count;
    wire [72:0] txf_m_data;
    wire        txf_m_last, txf_m_valid, txf_m_ready;

    axis_async_frame_fifo #(
        .DATA_WIDTH     (73),
        .ADDR_WIDTH     (TX_FIFO_ADDR_WIDTH),
        .DROP_WHEN_FULL (0)
    ) u_tx_fifo (
        .wr_clk            (clk),
        .wr_rst_n          (a_tx_rst_n),
        .s_data            ({w_tuser, w_tkeep, w_tdata}),
        .s_last            (w_tlast),
        .s_drop            (w_drop),
        .s_valid           (w_tvalid && !tx_dump),
        .s_ready           (txf_s_ready),
        .wr_frame_ok       (),
        .wr_frame_drop     (txf_drop),
        .wr_frame_overflow (txf_ovf),
        .wr_count          (txf_count),
        .rd_clk            (xgmii_tx_clk),
        .rd_rst_n          (t_tx_rst_n),
        .m_data            (txf_m_data),
        .m_last            (txf_m_last),
        .m_valid           (txf_m_valid),
        .m_ready           (txf_m_ready)
    );

    // TX arbiter: PAUSE frames from eth_pause_10g and data frames from the
    // TX FIFO take turns at the MAC, a whole frame at a time. Between frames
    // a PAUSE frame goes first; with a link fault reported no frame starts;
    // a received pause (tx_paused) holds data frames only. The source is
    // picked when a frame's first beat is offered and kept until its last
    // beat is taken, so a beat offered to the MAC is never withdrawn.
    localparam [1:0] A_NONE = 2'd0, A_DATA = 2'd1, A_PAUSE = 2'd2;
    wire        tx_fault, tx_paused;
    wire [63:0] p_tdata;
    wire [7:0]  p_tkeep;
    wire        p_tvalid, p_tlast;
    reg  [1:0]  a_sel;              // source of the frame offered or part-way
    reg         a_mid;              // a beat of that frame was taken
    wire [1:0]  a_pick = (p_tvalid && !tx_fault)                   ? A_PAUSE :
                         (txf_m_valid && !tx_fault && !tx_paused) ? A_DATA  :
                                                                    A_NONE;
    wire [1:0]  a_cur  = (a_sel != A_NONE) ? a_sel : a_pick;
    wire        a_p    = (a_cur == A_PAUSE);
    wire        mac_valid = a_p ? p_tvalid : ((a_cur == A_DATA) && txf_m_valid);
    wire [72:0] a_data = a_p ? {1'b0, p_tkeep, p_tdata} : txf_m_data;
    wire        a_last = a_p ? p_tlast : txf_m_last;
    wire        mac_ready;
    assign      txf_m_ready = mac_ready && (a_cur == A_DATA);
    wire        p_tready    = mac_ready && a_p;
    wire        tx_beat     = mac_valid && mac_ready;
    wire        f_start     = tx_beat && !a_mid;
    wire        f_wait      = mac_valid && !mac_ready && !a_mid;
    wire        f_end;
    always @(posedge xgmii_tx_clk or negedge t_tx_rst_n) begin
        if (!t_tx_rst_n) begin
            a_sel <= A_NONE;
            a_mid <= 1'b0;
        end else begin
            a_sel <= (tx_beat && a_last) ? A_NONE : a_cur;
            if (tx_beat)
                a_mid <= !a_last;
        end
    end

    wire tx_underrun;
    wire [63:0] mac_txd;
    wire [7:0]  mac_txc;

    eth_mac_10g_tx u_mac_tx (
        .clk           (xgmii_tx_clk),
        .rst_n         (t_tx_rst_n),
        .ce            (xgmii_tx_ready),
        .s_axis_tdata  (a_data[63:0]),
        .s_axis_tkeep  (a_data[71:64]),
        .s_axis_tvalid (mac_valid),
        .s_axis_tlast  (a_last),
        .s_axis_tuser  (a_data[72]),
        .s_axis_tready (mac_ready),
        .xgmii_txd     (mac_txd),
        .xgmii_txc     (mac_txc),
        .stat_tx_frame (f_end),
        .stat_underrun (tx_underrun)
    );

    eth_rs_10g u_rs (
        .rx_clk   (xgmii_rx_clk),
        .rx_rst_n (t_rx_rst_n),
        .rxd      (xgmii_rxd),
        .rxc      (xgmii_rxc),
        .rx_valid (xgmii_rx_valid),
        .rx_fault (rx_fault),
        .tx_clk   (xgmii_tx_clk),
        .tx_rst_n (t_tx_rst_n),
        .tx_ce    (xgmii_tx_ready),
        .mac_txd  (mac_txd),
        .mac_txc  (mac_txc),
        .txd      (xgmii_txd),
        .txc      (xgmii_txc),
        .tx_fault (tx_fault)
    );

    // TX per-frame stats, counted as the MAC takes the words: length on the
    // wire (padded to 60, plus the FCS) and whether the FCS was bad on purpose
    function [3:0] ones8;
        input [7:0] k;
        integer     j;
        begin
            ones8 = 4'd0;
            for (j = 0; j < 8; j = j + 1)
                ones8 = ones8 + {3'd0, k[j]};
        end
    endfunction

    reg  [13:0] tx_acc;
    reg         tx_err_acc;
    reg         txs_wr;
    reg  [14:0] txs_data;           // {err, len}
    wire [13:0] tx_len_n  = tx_acc + {10'd0, ones8(a_data[71:64])};
    always @(posedge xgmii_tx_clk or negedge t_tx_rst_n) begin
        if (!t_tx_rst_n) begin
            tx_acc     <= 14'd0;
            tx_err_acc <= 1'b0;
            txs_wr     <= 1'b0;
            txs_data   <= 15'd0;
        end else begin
            txs_wr <= 1'b0;
            if (tx_beat) begin
                if (a_last) begin
                    tx_acc     <= 14'd0;
                    tx_err_acc <= 1'b0;
                    txs_wr     <= 1'b1;
                    txs_data   <= {tx_err_acc || a_data[72],
                                   ((tx_len_n < 14'd60) ? 14'd60 : tx_len_n) + 14'd4};
                end else begin
                    tx_acc     <= (tx_len_n > 14'h3FF7) ? 14'h3FF7 : tx_len_n;
                    tx_err_acc <= tx_err_acc || a_data[72];
                end
            end
        end
    end

    wire [14:0] txs_q;
    wire        txs_empty;
    async_fifo #(.DATA_WIDTH(15), .ADDR_WIDTH(4), .RAM_STYLE("DISTRIBUTED")) u_tx_stat (
        .wr_clk (xgmii_tx_clk), .wr_rst_n (t_tx_rst_n),
        .wr_data (txs_data), .wr_en (txs_wr), .wr_full (),
        .rd_clk (clk), .rd_rst_n (a_tx_rst_n),
        .rd_data (txs_q), .rd_en (1'b1), .rd_empty (txs_empty),
        .wr_data_count ()
    );

    // =========================================================================
    // RX: MAC, filter, frame FIFO
    // =========================================================================
    // configuration into the RX domain (quasi-static, see header)
    (* ASYNC_REG = "TRUE" *) reg [116:0] rcfg_s1;
    (* ASYNC_REG = "TRUE" *) reg [116:0] rcfg_s2;
    always @(posedge xgmii_rx_clk or negedge t_rx_rst_n) begin
        if (!t_rx_rst_n) begin
            rcfg_s1 <= 117'd0;
            rcfg_s2 <= 117'd0;
        end else begin
            rcfg_s1 <= {cfg_rx_csum, cfg_rx_en, cfg_promisc, cfg_jumbo, cfg_pass,
                        mc_hash, mac_addr};
            rcfg_s2 <= rcfg_s1;
        end
    end
    wire        r_csum    = rcfg_s2[116];
    wire        r_rx_en   = rcfg_s2[115];
    wire        r_promisc = rcfg_s2[114];
    wire        r_jumbo   = rcfg_s2[113];
    wire        r_pass    = rcfg_s2[112];
    wire [63:0] r_hash    = rcfg_s2[111:48];
    wire [47:0] r_mac     = rcfg_s2[47:0];

    wire [63:0] mrx_tdata;
    wire [7:0]  mrx_tkeep;
    wire        mrx_tvalid, mrx_tlast, mrx_tuser;
    wire        st_done, st_fcs, st_ctl, st_over, st_under, st_bc, st_mc;
    wire [13:0] st_len;

    eth_mac_10g_rx #(
        .MAX_FRAME_STD   (1518),
        .MAX_FRAME_JUMBO (MAX_FRAME_JUMBO)
    ) u_mac_rx (
        .clk                (xgmii_rx_clk),
        .rst_n              (t_rx_rst_n),
        .xgmii_rxd          (xgmii_rxd),
        .xgmii_rxc          (xgmii_rxc),
        .xgmii_rx_valid     (xgmii_rx_valid),
        .jumbo_en           (r_jumbo),
        .m_axis_tdata       (mrx_tdata),
        .m_axis_tkeep       (mrx_tkeep),
        .m_axis_tvalid      (mrx_tvalid),
        .m_axis_tlast       (mrx_tlast),
        .m_axis_tuser       (mrx_tuser),
        .stat_done          (st_done),
        .stat_len           (st_len),
        .stat_err_fcs       (st_fcs),
        .stat_err_ctl       (st_ctl),
        .stat_err_oversize  (st_over),
        .stat_err_undersize (st_under),
        .stat_is_bcast      (st_bc),
        .stat_is_mcast      (st_mc)
    );

    // checksum check: drx is mrx with tuser also set on the last beat of a
    // frame whose checksums are wrong (with RX_CSUM_OFFLOAD=0, mrx itself)
    wire [63:0] drx_tdata;
    wire [7:0]  drx_tkeep;
    wire        drx_tvalid, drx_tlast, drx_tuser;
    wire        rx_csum_evt;        // such a frame with no MAC error

    generate
        if (RX_CSUM_OFFLOAD != 0) begin : g_rx_csum
            // CTRL[9], taken with a frame's first beat, rides as the tag
            reg  ck_mid, ck_en_f;
            wire ck_en = ck_mid ? ck_en_f : r_csum;
            always @(posedge xgmii_rx_clk or negedge t_rx_rst_n) begin
                if (!t_rx_rst_n) begin
                    ck_mid  <= 1'b0;
                    ck_en_f <= 1'b0;
                end else if (mrx_tvalid) begin
                    if (!ck_mid)
                        ck_en_f <= r_csum;
                    ck_mid <= !mrx_tlast;
                end
            end

            wire        c_v, c_ip4, c_l4_ok, c_l4_udp;
            wire        c_tag;
            wire [15:0] c_ip_sum, c_l4_sum, c_l4_fld;
            csum_calc64 #(.TAG_W(1)) u_rx_csum (
                .clk          (xgmii_rx_clk),
                .rst_n        (t_rx_rst_n),
                .zero_fields  (1'b0),
                .in_valid     (mrx_tvalid),
                .in_data      (mrx_tdata),
                .in_keep      (mrx_tkeep),
                .in_last      (mrx_tlast),
                .in_tag       (ck_en),
                .res_valid    (c_v),
                .res_tag      (c_tag),
                .res_done     (),
                .res_ip4      (c_ip4),
                .res_ip_sum   (c_ip_sum),
                .res_ip_pos   (),
                .res_l4_ok    (c_l4_ok),
                .res_l4_udp   (c_l4_udp),
                .res_l4_sum   (c_l4_sum),
                .res_l4_pos   (),
                .res_l4_field (c_l4_fld)
            );
            wire ip_bad = c_ip4 && (c_ip_sum != 16'hFFFF);
            wire l4_bad = c_l4_ok && !(c_l4_udp && c_l4_fld == 16'h0000) &&
                          (c_l4_sum != 16'hFFFF);

            // The result comes LATENCY (6) cycles after the frame's last
            // beat, registered here as ck_bad; the stream is delayed 7
            // cycles to meet it with that beat.
            localparam DL = 7, DW = 74;   // {tuser, tlast, tkeep, tdata}
            reg          ck_bad;
            reg [DL-1:0] dl_v;
            reg [DL*DW-1:0] dl_d;   // no reset: shift registers
            always @(posedge xgmii_rx_clk or negedge t_rx_rst_n) begin
                if (!t_rx_rst_n) begin
                    ck_bad <= 1'b0;
                    dl_v   <= {DL{1'b0}};
                end else begin
                    ck_bad <= c_v && c_tag && (ip_bad || l4_bad);
                    dl_v   <= {dl_v[DL-2:0], mrx_tvalid};
                end
            end
            always @(posedge xgmii_rx_clk)
                dl_d <= {dl_d[(DL-1)*DW-1:0],
                         mrx_tuser, mrx_tlast, mrx_tkeep, mrx_tdata};

            wire [DW-1:0] dl_q = dl_d[DL*DW-1 -: DW];
            assign drx_tvalid  = dl_v[DL-1];
            assign drx_tdata   = dl_q[63:0];
            assign drx_tkeep   = dl_q[71:64];
            assign drx_tlast   = dl_q[72];
            assign drx_tuser   = dl_q[73] || (dl_q[72] && ck_bad);
            assign rx_csum_evt = drx_tvalid && dl_q[72] && ck_bad && !dl_q[73];
        end else begin : g_no_rx_csum
            assign drx_tdata   = mrx_tdata;
            assign drx_tkeep   = mrx_tkeep;
            assign drx_tvalid  = mrx_tvalid;
            assign drx_tlast   = mrx_tlast;
            assign drx_tuser   = mrx_tuser;
            assign rx_csum_evt = 1'b0;
        end
    endgenerate

    // address filter on the first beat (bytes 0..5 = destination address)
    reg         r_mid;              // past the first beat of a frame
    wire [47:0] dst = {drx_tdata[7:0],   drx_tdata[15:8],  drx_tdata[23:16],
                       drx_tdata[31:24], drx_tdata[39:32], drx_tdata[47:40]};
    wire        dst_bc = &dst;
    wire        dst_mc = dst[40] && !dst_bc;
    wire [5:0]  hidx   = dst[5:0]   ^ dst[11:6]  ^ dst[17:12] ^ dst[23:18] ^
                         dst[29:24] ^ dst[35:30] ^ dst[41:36] ^ dst[47:42];
    wire        mc_ok  = (MCAST_HASH_FILTER == 0) || r_hash[hidx];
    wire        accept = r_rx_en && (r_pass || r_promisc || dst == r_mac ||
                                     dst_bc || (dst_mc && mc_ok));
    wire        rx_drop = (!r_mid && !accept) ||
                          (drx_tlast && drx_tuser && !r_pass);

    always @(posedge xgmii_rx_clk or negedge t_rx_rst_n) begin
        if (!t_rx_rst_n)
            r_mid <= 1'b0;
        else if (drx_tvalid)
            r_mid <= !drx_tlast;
    end

    wire rxf_drop, rxf_ovf;
    wire [RX_FIFO_ADDR_WIDTH:0] rxf_count;
    wire [72:0] rxf_m_data;
    wire        rxf_m_last, rxf_m_valid, rxf_m_ready;

    axis_async_frame_fifo #(
        .DATA_WIDTH     (73),
        .ADDR_WIDTH     (RX_FIFO_ADDR_WIDTH),
        .DROP_WHEN_FULL (1)
    ) u_rx_fifo (
        .wr_clk            (xgmii_rx_clk),
        .wr_rst_n          (t_rx_rst_n),
        .s_data            ({drx_tuser, drx_tkeep, drx_tdata}),
        .s_last            (drx_tlast),
        .s_drop            (rx_drop),
        .s_valid           (drx_tvalid),
        .s_ready           (),
        .wr_frame_ok       (),
        .wr_frame_drop     (rxf_drop),
        .wr_frame_overflow (rxf_ovf),
        .wr_count          (rxf_count),
        .rd_clk            (clk),
        .rd_rst_n          (a_rx_rst_n),
        .m_data            (rxf_m_data),
        .m_last            (rxf_m_last),
        .m_valid           (rxf_m_valid),
        .m_ready           (rxf_m_ready)
    );

    // RX output: a frame part-way read when the crossing resets is closed
    // with one beat of tlast and tuser (see header)
    reg  rx_omid, rx_close;
    wire rx_otake = m_axis_tvalid && m_axis_tready;
    assign m_axis_tvalid = rx_close || rxf_m_valid;
    assign m_axis_tlast  = rx_close || rxf_m_last;
    assign m_axis_tuser  = rx_close || rxf_m_data[72];
    assign m_axis_tkeep  = rx_close ? 8'h01 : rxf_m_data[71:64];
    assign m_axis_tdata  = rx_close ? 64'd0 : rxf_m_data[63:0];
    assign rxf_m_ready   = m_axis_tready && !rx_close;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_omid  <= 1'b0;
            rx_close <= 1'b0;
        end else begin
            if (rx_otake)
                rx_omid <= !m_axis_tlast;
            if (a_rx_fall)
                rx_close <= (rx_otake ? !m_axis_tlast : rx_omid) ||
                            (m_axis_tvalid && !m_axis_tready);
            else if (rx_close && m_axis_tready)
                rx_close <= 1'b0;
        end
    end

    // RX per-frame stats from the MAC, carried to clk
    wire [19:0] rxs_q;
    wire        rxs_empty;
    async_fifo #(.DATA_WIDTH(20), .ADDR_WIDTH(4), .RAM_STYLE("DISTRIBUTED")) u_rx_stat (
        .wr_clk (xgmii_rx_clk), .wr_rst_n (t_rx_rst_n),
        .wr_data ({st_mc, st_bc, st_under, st_over, st_ctl, st_fcs, st_len}),
        .wr_en (st_done), .wr_full (),
        .rd_clk (clk), .rd_rst_n (a_rx_rst_n),
        .rd_data (rxs_q), .rd_en (1'b1), .rd_empty (rxs_empty),
        .wr_data_count ()
    );

    // =========================================================================
    // PAUSE
    // =========================================================================
    localparam [19:0] RXF_BYTES = 20'd8 << RX_FIFO_ADDR_WIDTH;
    wire p_pending, p_cfg_err, p_active, p_paused_sts;
    wire rx_pause_evt, tx_pause_evt;

    eth_pause_10g #(
        .LEVEL_W   (RX_FIFO_ADDR_WIDTH + 1),
        .LEVEL_MAX (RXF_BYTES - 20'd8)      // reached one word before full
    ) u_pause (
        .clk              (clk),
        .c_rst_n          (rst_n),
        .c_tx_rst_n       (a_tx_rst_n),
        .cfg_tx_send      (p_send),
        .cfg_quanta       (p_quanta),
        .cfg_rx_en        (p_rx_en),
        .cfg_auto_en      (p_auto_en),
        .cfg_auto_xoff    (p_xoff),
        .cfg_auto_xon     (p_xon),
        .cfg_auto_refresh (p_refresh),
        .our_mac          (mac_addr),
        .tx_pending       (p_pending),
        .auto_cfg_err     (p_cfg_err),
        .auto_active      (p_active),
        .paused_sts       (p_paused_sts),
        .rx_clk           (xgmii_rx_clk),
        .rx_rst_n         (t_rx_rst_n),
        .rx_tdata         (mrx_tdata),
        .rx_tvalid        (mrx_tvalid),
        .rx_tlast         (mrx_tlast),
        .rx_tuser         (mrx_tuser),
        .rx_level         (rxf_count),
        .rx_pause_evt     (rx_pause_evt),
        .tx_clk           (xgmii_tx_clk),
        .tx_rst_n         (t_tx_rst_n),
        .tx_ce            (xgmii_tx_ready),
        .f_start          (f_start),
        .f_wait           (f_wait),
        .f_end            (f_end),
        .tx_paused        (tx_paused),
        .p_tdata          (p_tdata),
        .p_tkeep          (p_tkeep),
        .p_tvalid         (p_tvalid),
        .p_tready         (p_tready),
        .p_tlast          (p_tlast),
        .tx_pause_evt     (tx_pause_evt)
    );

    // =========================================================================
    // Counters (clk)
    // =========================================================================
    // Events from the transceiver domains: a small wrapping count crosses,
    // and its growth since the last clk cycle is added to a clk counter.
    // Both ends of a count reset with their crossing, together with the
    // last value seen, so a crossing reset loses events in flight but never
    // makes a counter jump.
    wire [7:0] c_rx_drop, c_rx_disc, c_tx_unr, c_prx, c_ptx, c_csum;
    reg  [7:0] p_rx_drop, p_rx_disc, p_tx_unr, p_prx, p_ptx, p_csum;  // at the last clk cycle
    cdc_event_count #(.WIDTH(8)) u_cnt_csum (
        .src_clk (xgmii_rx_clk), .src_rst_n (t_rx_rst_n), .inc (rx_csum_evt),
        .dst_clk (clk), .dst_rst_n (a_rx_rst_n), .count (c_csum));
    cdc_event_count #(.WIDTH(8)) u_cnt_pause_rx (
        .src_clk (xgmii_rx_clk), .src_rst_n (t_rx_rst_n), .inc (rx_pause_evt),
        .dst_clk (clk), .dst_rst_n (a_rx_rst_n), .count (c_prx));
    cdc_event_count #(.WIDTH(8)) u_cnt_pause_tx (
        .src_clk (xgmii_tx_clk), .src_rst_n (t_tx_rst_n), .inc (tx_pause_evt),
        .dst_clk (clk), .dst_rst_n (a_tx_rst_n), .count (c_ptx));
    cdc_event_count #(.WIDTH(8)) u_cnt_rx_drop (
        .src_clk (xgmii_rx_clk), .src_rst_n (t_rx_rst_n), .inc (rxf_ovf),
        .dst_clk (clk), .dst_rst_n (a_rx_rst_n), .count (c_rx_drop));
    cdc_event_count #(.WIDTH(8)) u_cnt_rx_disc (
        .src_clk (xgmii_rx_clk), .src_rst_n (t_rx_rst_n), .inc (rxf_drop),
        .dst_clk (clk), .dst_rst_n (a_rx_rst_n), .count (c_rx_disc));
    cdc_event_count #(.WIDTH(8)) u_cnt_tx_unr (
        .src_clk (xgmii_tx_clk), .src_rst_n (t_tx_rst_n), .inc (tx_underrun),
        .dst_clk (clk), .dst_rst_n (a_tx_rst_n), .count (c_tx_unr));
    always @(posedge clk or negedge a_rx_rst_n) begin
        if (!a_rx_rst_n) begin
            p_rx_drop <= 8'd0;
            p_rx_disc <= 8'd0;
        end else begin
            p_rx_drop <= c_rx_drop;
            p_rx_disc <= c_rx_disc;
        end
    end
    always @(posedge clk or negedge a_rx_rst_n)
        if (!a_rx_rst_n) p_prx <= 8'd0; else p_prx <= c_prx;
    always @(posedge clk or negedge a_rx_rst_n)
        if (!a_rx_rst_n) p_csum <= 8'd0; else p_csum <= c_csum;
    always @(posedge clk or negedge a_tx_rst_n) begin
        if (!a_tx_rst_n) begin
            p_tx_unr <= 8'd0;
            p_ptx    <= 8'd0;
        end else begin
            p_tx_unr <= c_tx_unr;
            p_ptx    <= c_ptx;
        end
    end
    wire [7:0] d_rx_drop = c_rx_drop - p_rx_drop;
    wire [7:0] d_rx_disc = c_rx_disc - p_rx_disc;
    wire [7:0] d_tx_unr  = c_tx_unr  - p_tx_unr;
    wire [7:0] d_prx     = c_prx - p_prx;
    wire [7:0] d_ptx     = c_ptx - p_ptx;
    wire [7:0] d_csum    = c_csum - p_csum;
    reg  [31:0] n_rx_drop, n_rx_disc, n_tx_unr, n_pause_rx, n_pause_tx, n_rx_csum;
    wire [32:0] s_prx = {1'b0, n_pause_rx} + {25'd0, d_prx};
    wire [32:0] s_ptx = {1'b0, n_pause_tx} + {25'd0, d_ptx};

    reg [63:0] n_tx_frames, n_tx_bytes, n_rx_frames, n_rx_bytes;
    reg [31:0] n_tx_err, n_tx_drop, n_lock_loss, n_lf, n_rf;
    reg [31:0] n_rx_fcs, n_rx_ctl, n_rx_over, n_rx_under, n_rx_bc, n_rx_mc;
    reg [31:0] hi_latch;

    wire        txs_v    = !txs_empty;
    wire        rxs_v    = !rxs_empty;
    wire        rxs_good = !(|rxs_q[17:14]);

    // =========================================================================
    // AXI4-Lite
    // =========================================================================
    wire wr_go = s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid;
    assign s_axi_awready = wr_go;
    assign s_axi_wready  = wr_go;
    assign s_axi_bresp   = 2'b00;
    assign s_axi_arready = !s_axi_rvalid;
    assign s_axi_rresp   = 2'b00;
    wire rd_go = s_axi_arvalid && !s_axi_rvalid;
    wire [7:0] wa = {s_axi_awaddr[7:2], 2'b00};
    wire [7:0] ra = {s_axi_araddr[7:2], 2'b00};

    function [31:0] wmask;
        input [31:0] old;
        input [31:0] d;
        input [3:0]  s;
        begin
            wmask = {s[3] ? d[31:24] : old[31:24], s[2] ? d[23:16] : old[23:16],
                     s[1] ? d[15:8]  : old[15:8],  s[0] ? d[7:0]   : old[7:0]};
        end
    endfunction

    localparam [31:0] CTRL_RST = ((TXRX_EN_AT_RESET != 0) ? 32'h3 : 32'h0) |
                                 ((JUMBO_AT_RESET   != 0) ? 32'h40 : 32'h0);
    localparam [31:0] CAPS = {MAX_FRAME_JUMBO[15:0], 6'd0, 1'b1,
                              RX_FIFO_ADDR_WIDTH[4:0] + 5'd3, 1'b1,
                              (RX_CSUM_OFFLOAD   != 0) ? 1'b1 : 1'b0,
                              (TX_CSUM_OFFLOAD   != 0) ? 1'b1 : 1'b0,
                              (MCAST_HASH_FILTER != 0) ? 1'b1 : 1'b0};

    wire [31:0] wd_mac_hi = wmask({16'd0, mac_addr[47:32]}, s_axi_wdata, s_axi_wstrb);
    wire [31:0] wd_quanta  = wmask({16'd0, p_quanta},  s_axi_wdata, s_axi_wstrb);
    wire [31:0] wd_refresh = wmask({16'd0, p_refresh}, s_axi_wdata, s_axi_wstrb);
    wire [31:0] wd_xoff    = wmask({12'd0, p_xoff},    s_axi_wdata, s_axi_wstrb);
    wire [31:0] wd_xon     = wmask({12'd0, p_xon},     s_axi_wdata, s_axi_wstrb);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctrl      <= CTRL_RST;
            mac_addr  <= MAC_ADDR_AT_RESET;
            mc_hash   <= 64'd0;
            scratch   <= 32'd0;
            ip_addr   <= IP_ADDR_AT_RESET;
            p_rx_en   <= 1'b0;
            p_auto_en <= 1'b0;
            p_send    <= 1'b0;
            p_quanta  <= 16'd0;
            p_refresh <= 16'd0;
            p_xoff    <= RXF_BYTES >> 1;
            p_xon     <= RXF_BYTES >> 2;
            n_pause_rx <= 32'd0;
            n_pause_tx <= 32'd0;
            s_axi_bvalid <= 1'b0;
            s_axi_rvalid <= 1'b0;
            s_axi_rdata  <= 32'd0;
            hi_latch  <= 32'd0;
            n_rx_drop <= 32'd0;
            n_rx_disc <= 32'd0;
            n_tx_unr  <= 32'd0;
            n_rx_csum <= 32'd0;
            n_tx_frames <= 64'd0; n_tx_bytes <= 64'd0;
            n_rx_frames <= 64'd0; n_rx_bytes <= 64'd0;
            n_tx_err  <= 32'd0; n_tx_drop <= 32'd0; n_lock_loss <= 32'd0;
            n_lf      <= 32'd0; n_rf      <= 32'd0;
            n_rx_fcs  <= 32'd0; n_rx_ctl  <= 32'd0; n_rx_over <= 32'd0;
            n_rx_under <= 32'd0; n_rx_bc  <= 32'd0; n_rx_mc   <= 32'd0;
        end else begin
            // ---- counting
            if (txs_v) begin
                if (txs_q[14]) begin
                    n_tx_err <= n_tx_err + 32'd1;
                end else begin
                    n_tx_frames <= n_tx_frames + 64'd1;
                    n_tx_bytes  <= n_tx_bytes + {50'd0, txs_q[13:0]};
                end
            end
            if (rxs_v) begin
                if (rxs_good) begin
                    n_rx_frames <= n_rx_frames + 64'd1;
                    n_rx_bytes  <= n_rx_bytes + {50'd0, rxs_q[13:0]};
                    if (rxs_q[18]) n_rx_bc <= n_rx_bc + 32'd1;
                    if (rxs_q[19]) n_rx_mc <= n_rx_mc + 32'd1;
                end
                if (rxs_q[14]) n_rx_fcs   <= n_rx_fcs + 32'd1;
                if (rxs_q[15]) n_rx_ctl   <= n_rx_ctl + 32'd1;
                if (rxs_q[16]) n_rx_over  <= n_rx_over + 32'd1;
                if (rxs_q[17]) n_rx_under <= n_rx_under + 32'd1;
            end
            n_rx_drop <= n_rx_drop + {24'd0, d_rx_drop};
            n_rx_disc <= n_rx_disc + {24'd0, d_rx_disc};
            n_tx_unr  <= n_tx_unr  + {24'd0, d_tx_unr};
            n_rx_csum <= n_rx_csum + {24'd0, d_csum};
            n_tx_drop <= n_tx_drop + {31'd0, txf_ovf} + {31'd0, txf_drop} +
                         {31'd0, tx_dumped};
            if (lock_lost) n_lock_loss <= n_lock_loss + 32'd1;
            if (lf_new) n_lf <= n_lf + 32'd1;
            if (rf_new) n_rf <= n_rf + 32'd1;
            n_pause_rx <= s_prx[32] ? 32'hFFFF_FFFF : s_prx[31:0];
            n_pause_tx <= s_ptx[32] ? 32'hFFFF_FFFF : s_ptx[31:0];
            p_send     <= 1'b0;

            // ---- writes; a write to a counter clears it (and wins over a
            // count in the same cycle)
            if (wr_go) begin
                s_axi_bvalid <= 1'b1;
                case (wa)
                    8'h04: ctrl     <= wmask(ctrl, s_axi_wdata, s_axi_wstrb);
                    8'h0C: mac_addr[31:0]  <= wmask(mac_addr[31:0], s_axi_wdata, s_axi_wstrb);
                    8'h10: mac_addr[47:32] <= wd_mac_hi[15:0];
                    8'h3C: scratch  <= wmask(scratch, s_axi_wdata, s_axi_wstrb);
                    8'h40: ip_addr  <= wmask(ip_addr, s_axi_wdata, s_axi_wstrb);
                    8'h44: if (MCAST_HASH_FILTER != 0)
                               mc_hash[31:0]  <= wmask(mc_hash[31:0], s_axi_wdata, s_axi_wstrb);
                    8'h48: if (MCAST_HASH_FILTER != 0)
                               mc_hash[63:32] <= wmask(mc_hash[63:32], s_axi_wdata, s_axi_wstrb);
                    8'h84: if (s_axi_wstrb[0]) begin
                               p_send    <= s_axi_wdata[0];
                               p_rx_en   <= s_axi_wdata[1];
                               p_auto_en <= s_axi_wdata[2];
                           end
                    8'h88: p_quanta  <= wd_quanta[15:0];
                    8'h8C, 8'h90: begin
                               n_pause_rx <= 32'd0;
                               n_pause_tx <= 32'd0;
                           end
                    8'h9C: p_xoff    <= wd_xoff[19:0];
                    8'hA0: p_xon     <= wd_xon[19:0];
                    8'hA4: p_refresh <= wd_refresh[15:0];
                    8'hB0, 8'hB4: n_tx_frames <= 64'd0;
                    8'hB8, 8'hBC: n_tx_bytes  <= 64'd0;
                    8'hC0, 8'hC4: n_rx_frames <= 64'd0;
                    8'hC8, 8'hCC: n_rx_bytes  <= 64'd0;
                    8'hD0: n_rx_fcs   <= 32'd0;
                    8'hD4: n_rx_ctl   <= 32'd0;
                    8'hD8: n_rx_over  <= 32'd0;
                    8'hDC: n_rx_under <= 32'd0;
                    8'hE0: n_rx_bc    <= 32'd0;
                    8'hE4: n_rx_mc    <= 32'd0;
                    8'hE8: n_rx_drop  <= 32'd0;
                    8'hEC: n_rx_disc  <= 32'd0;
                    8'hF0: n_tx_unr   <= 32'd0;
                    8'hF4: n_tx_drop  <= 32'd0;
                    8'h80: n_rx_csum  <= 32'd0;
                    8'hF8: n_tx_err   <= 32'd0;
                    8'hFC: n_lock_loss <= 32'd0;
                    8'hA8: n_lf <= 32'd0;
                    8'hAC: n_rf <= 32'd0;
                    default: ;
                endcase
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end

            // ---- reads
            if (rd_go) begin
                s_axi_rvalid <= 1'b1;
                case (ra)
                    8'h00: s_axi_rdata <= {`EMZ_VERSION_MAJOR, `EMZ_VERSION_MINOR,
                                           `EMZ_VERSION_ID};
                    8'h04: s_axi_rdata <= ctrl;
                    8'h08: s_axi_rdata <= {26'd0, p_paused_sts, st_rf, st_lf,
                                           txf_count != 0, hiber_s[1], lock_s[1]};
                    8'h0C: s_axi_rdata <= mac_addr[31:0];
                    8'h10: s_axi_rdata <= {16'd0, mac_addr[47:32]};
                    8'h3C: s_axi_rdata <= scratch;
                    8'h40: s_axi_rdata <= ip_addr;
                    8'h44: s_axi_rdata <= mc_hash[31:0];
                    8'h48: s_axi_rdata <= mc_hash[63:32];
                    8'h84: s_axi_rdata <= {26'd0, p_pending, p_cfg_err, p_active,
                                           p_auto_en, p_rx_en, 1'b0};
                    8'h88: s_axi_rdata <= {16'd0, p_quanta};
                    8'h8C: s_axi_rdata <= n_pause_rx;
                    8'h90: s_axi_rdata <= n_pause_tx;
                    8'h9C: s_axi_rdata <= {12'd0, p_xoff};
                    8'hA0: s_axi_rdata <= {12'd0, p_xon};
                    8'hA4: s_axi_rdata <= {16'd0, p_refresh};
                    8'h98: s_axi_rdata <= CAPS;
                    8'hB0: begin s_axi_rdata <= n_tx_frames[31:0]; hi_latch <= n_tx_frames[63:32]; end
                    8'hB8: begin s_axi_rdata <= n_tx_bytes[31:0];  hi_latch <= n_tx_bytes[63:32];  end
                    8'hC0: begin s_axi_rdata <= n_rx_frames[31:0]; hi_latch <= n_rx_frames[63:32]; end
                    8'hC8: begin s_axi_rdata <= n_rx_bytes[31:0];  hi_latch <= n_rx_bytes[63:32];  end
                    8'hB4, 8'hBC, 8'hC4, 8'hCC: s_axi_rdata <= hi_latch;
                    8'hD0: s_axi_rdata <= n_rx_fcs;
                    8'hD4: s_axi_rdata <= n_rx_ctl;
                    8'hD8: s_axi_rdata <= n_rx_over;
                    8'hDC: s_axi_rdata <= n_rx_under;
                    8'hE0: s_axi_rdata <= n_rx_bc;
                    8'hE4: s_axi_rdata <= n_rx_mc;
                    8'hE8: s_axi_rdata <= n_rx_drop;
                    8'hEC: s_axi_rdata <= n_rx_disc;
                    8'hF0: s_axi_rdata <= n_tx_unr;
                    8'hF4: s_axi_rdata <= n_tx_drop;
                    8'h80: s_axi_rdata <= n_rx_csum;
                    8'hF8: s_axi_rdata <= n_tx_err;
                    8'hFC: s_axi_rdata <= n_lock_loss;
                    8'hA8: s_axi_rdata <= n_lf;
                    8'hAC: s_axi_rdata <= n_rf;
                    default: s_axi_rdata <= 32'd0;
                endcase
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

endmodule
