// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â bard0 design
// =============================================================================
// eth_mac.v ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â Ethernet MAC with MII PHY interface
// Wraps eth_mac_tx + eth_mac_rx + mii_if into a single module.
// AXI4-Stream interfaces for frame TX/RX, MII pins for PHY connection.
// Verilog 2001
// =============================================================================

module eth_mac #(
    parameter MAX_FRAME = 9018,      // jumbo MTU + headers (1518 = standard)
    parameter MII_DEBUG = 0
)(
    input  wire        clk,          // system clock (100 MHz)
    input  wire        rst_n,

    // ---- MII PHY pins ----
    output wire [3:0]  mii_txd,
    output wire        mii_tx_en,
    input  wire        mii_tx_clk,
    input  wire [3:0]  mii_rxd,
    input  wire        mii_rx_dv,
    input  wire        mii_rx_er,
    input  wire        mii_rx_clk,
    input  wire        mii_col,
    input  wire        mii_crs,

    // ---- Configuration ----
    input  wire [47:0] our_mac,       // MAC address filter
    input  wire        promisc,       // accept all frames regardless of MAC

    // ---- AXI4-Stream slave ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â frame TX (from network stack) ----
    input  wire [7:0]  s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire [0:0]  s_axis_tkeep,  // unused (byte-wide, always 1)

    // ---- AXI4-Stream master ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â frame RX (to network stack) ----
    output wire [7:0]  m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output wire        m_axis_terror, // bad CRC or receive error
    output wire        m_axis_tsof,   // start of frame (first byte)

    // ---- Status ----
    output wire        tx_active,
    output wire        tx_fifo_busy_out,   // insufficient room for a max-sized frame
    output wire [12:0] tx_fifo_level_out,  // queued TX symbols in GMII->MII FIFO
    // ---- Debug ----
    output wire        dbg_tx_fifo_empty,
    output wire        dbg_rx_prog_empty,
    output wire        dbg_rx_rd_empty,
    output wire        dbg_rx_reading,
    output wire [1:0]  dbg_rx_frames_pending,
    // GMII debug (exposed for ILA)
    output wire [7:0]  dbg_gmii_txd,
    output wire        dbg_gmii_tx_en,
    output wire [7:0]  dbg_gmii_rxd,
    output wire        dbg_gmii_rx_dv,
    // MAC TX internals
    output wire [3:0]  dbg_mac_tx_state,
    output wire [3:0]  dbg_mac_tx_stall_cnt,
    // TX FIFO internals
    output wire        dbg_tx_wr_en,
    output wire        dbg_tx_len_wr_en,
    output wire        dbg_tx_wr_full,
    output wire        dbg_tx_wr_rst_busy,
    output wire        dbg_tx_rd_en,
    output wire        dbg_tx_frame_loaded,
    output wire [11:0] dbg_tx_frames_queued,
    output wire [11:0] dbg_tx_frames_drained,
    output wire [11:0] dbg_last_tx_len_wr,
    // MII TX capture
    output wire        dbg_mii_cap_done,
    output wire [11:0] dbg_mii_cap_frame_len,
    output wire [31:0] dbg_mii_cap_word0,
    output wire [31:0] dbg_mii_cap_word1,
    output wire [31:0] dbg_mii_cap_word2,
    output wire [31:0] dbg_mii_cap_word3,
    output wire [31:0] dbg_rx_fifo_full_frames,
    output wire [31:0] dbg_rx_fifo_full_writes,
    output wire [31:0] dbg_rx_fifo_overflow_pulses,
    output wire [31:0] dbg_rx_fifo_wr_level_max,
    output wire [31:0] dbg_rx_replay_gap_frames,
    output wire [31:0] dbg_rx_replay_gap_cycles,
    output wire [31:0] dbg_rx_replay_gap_byte_max
);

    // =========================================================================
    // Internal GMII bus (sys_clk domain, hidden from external)
    // =========================================================================
    wire [7:0] gmii_txd;
    assign dbg_gmii_txd  = (MII_DEBUG != 0) ? gmii_txd : 8'd0;
    assign dbg_gmii_tx_en = (MII_DEBUG != 0) ? gmii_tx_en : 1'b0;
    assign dbg_gmii_rxd  = (MII_DEBUG != 0) ? gmii_rxd : 8'd0;
    assign dbg_gmii_rx_dv = (MII_DEBUG != 0) ? gmii_rx_dv : 1'b0;
    wire       gmii_tx_en;
    wire       gmii_tx_er;
    wire [7:0] gmii_rxd;
    wire       gmii_rx_dv;
    wire       gmii_rx_er;

    // =========================================================================
    // MII PHY Interface (clock-domain crossing)
    // =========================================================================
    wire tx_fifo_busy;
    wire [12:0] tx_fifo_level;
    assign tx_fifo_busy_out  = tx_fifo_busy;
    assign tx_fifo_level_out = tx_fifo_level;

    mii_if #(.MII_DEBUG(MII_DEBUG)) u_mii_if (
        .clk            (clk),
        .rst_n          (rst_n),
        // MII pins
        .mii_rxd        (mii_rxd),
        .mii_rx_dv      (mii_rx_dv),
        .mii_rx_er      (mii_rx_er),
        .mii_rx_clk     (mii_rx_clk),
        .mii_col        (mii_col),
        .mii_crs        (mii_crs),
        .mii_txd        (mii_txd),
        .mii_tx_en      (mii_tx_en),
        .mii_tx_clk     (mii_tx_clk),
        // GMII (sys_clk domain)
        .gmii_txd       (gmii_txd),
        .gmii_tx_en     (gmii_tx_en),
        .gmii_tx_er     (gmii_tx_er),
        .gmii_rxd       (gmii_rxd),
        .gmii_rx_dv     (gmii_rx_dv),
        .gmii_rx_er     (gmii_rx_er),
        .mii_tx_clk_out (),
        .tx_busy               (tx_fifo_busy),
        .tx_fifo_level         (tx_fifo_level),
        .dbg_tx_fifo_empty     (dbg_tx_fifo_empty),
        .dbg_rx_prog_empty     (dbg_rx_prog_empty),
        .dbg_rx_rd_empty       (dbg_rx_rd_empty),
        .dbg_rx_reading        (dbg_rx_reading),
        .dbg_rx_frames_pending (dbg_rx_frames_pending),
        .dbg_tx_wr_en          (dbg_tx_wr_en),
        .dbg_tx_len_wr_en      (dbg_tx_len_wr_en),
        .dbg_tx_wr_full        (dbg_tx_wr_full),
        .dbg_tx_wr_rst_busy_out(dbg_tx_wr_rst_busy),
        .dbg_tx_rd_en          (dbg_tx_rd_en),
        .dbg_tx_frame_loaded   (dbg_tx_frame_loaded),
        .dbg_tx_frames_queued  (dbg_tx_frames_queued),
        .dbg_tx_frames_drained (dbg_tx_frames_drained),
        .dbg_last_tx_len_wr    (dbg_last_tx_len_wr),
        .dbg_mii_cap_done      (dbg_mii_cap_done),
        .dbg_mii_cap_frame_len (dbg_mii_cap_frame_len),
        .dbg_mii_cap_word0     (dbg_mii_cap_word0),
        .dbg_mii_cap_word1     (dbg_mii_cap_word1),
        .dbg_mii_cap_word2     (dbg_mii_cap_word2),
        .dbg_mii_cap_word3     (dbg_mii_cap_word3),
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
        .dbg_rx_fifo_full_frames (dbg_rx_fifo_full_frames),
        .dbg_rx_fifo_full_writes (dbg_rx_fifo_full_writes),
        .dbg_rx_fifo_overflow_pulses (dbg_rx_fifo_overflow_pulses),
        .dbg_rx_fifo_wr_level_max (dbg_rx_fifo_wr_level_max),
        .dbg_rx_replay_gap_frames (dbg_rx_replay_gap_frames),
        .dbg_rx_replay_gap_cycles (dbg_rx_replay_gap_cycles),
        .dbg_rx_replay_gap_byte_max (dbg_rx_replay_gap_byte_max),
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
        .dbg_tx_er_pulses (),
        .dbg_tx_er_frames ()
    );

    // =========================================================================
    // MAC RX ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â strips preamble/SFD, validates CRC
    // =========================================================================
    eth_mac_rx u_mac_rx (
        .clk              (clk),
        .rst_n            (rst_n),
        .gmii_rxd         (gmii_rxd),
        .gmii_rx_dv       (gmii_rx_dv),
        .gmii_rx_er       (gmii_rx_er),
        .our_mac          (our_mac),
        .promisc          (promisc),
        .passthrough      (1'b0),
        .jumbo_en         (1'b1),       // standalone wrapper: always allow jumbo
        .mcast_hash_table (64'h0),
        .m_axis_tdata     (m_axis_tdata),
        .m_axis_tvalid    (m_axis_tvalid),
        .m_axis_tready    (m_axis_tready),
        .m_axis_tlast     (m_axis_tlast),
        .m_axis_terror    (m_axis_terror),
        .m_axis_tsof      (m_axis_tsof),
        .stat_done         (),
        .stat_len          (),
        .stat_err_fcs      (),
        .stat_err_align    (),
        .stat_err_overflow (),
        .stat_err_oversize (),
        .stat_is_bcast     (),
        .stat_is_mcast     ()
    );

    // =========================================================================
    // MAC TX ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â adds preamble/SFD, pads, appends CRC
    // =========================================================================
    eth_mac_tx #(.MAX_FRAME(MAX_FRAME)) u_mac_tx (
        .clk           (clk),
        .rst_n         (rst_n),
        .tx_start_ok   (~tx_fifo_busy),
        .gmii_txd      (gmii_txd),
        .gmii_tx_en    (gmii_tx_en),
        .gmii_tx_er    (gmii_tx_er),
        .s_axis_tdata  (s_axis_tdata),
        .s_axis_tvalid (s_axis_tvalid),
        .s_axis_tready (s_axis_tready),
        .s_axis_tkeep  (s_axis_tkeep),
        .s_axis_tlast  (s_axis_tlast),
        .tx_active     (tx_active),
        .dbg_state     (dbg_mac_tx_state),
        .dbg_stall_cnt (dbg_mac_tx_stall_cnt)
    );

endmodule
