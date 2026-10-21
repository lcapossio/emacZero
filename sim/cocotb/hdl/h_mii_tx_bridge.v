// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// h_mii_tx_bridge.v - cocotb harness: eth_mac_tx feeding mii_if's TX path
//
// The DUT pair of tb_mii_tx_bridge.v (MII_DEBUG=0) and
// tb_mii_tx_burst_backpressure.v (MII_DEBUG=1), wired as both benches wire
// it: eth_mac_tx's GMII output drives mii_if's GMII TX input, mii_if's
// tx_busy holds off frame starts (tx_start_ok = ~tx_busy), the MII RX inputs
// are tied idle and both MII clocks are mii_clk. The GMII nets, tx_busy,
// tx_fifo_level and the two TX debug strobes the backpressure bench counts
// are outputs. Port names follow the benches' net names. Same entity in
// h_mii_tx_bridge.vhd.
// =============================================================================

module h_mii_tx_bridge #(
    parameter MII_DEBUG = 0
)(
    input  wire        clk,
    input  wire        mii_clk,
    input  wire        rst_n,

    input  wire [7:0]  tx_data,
    input  wire        tx_valid,
    input  wire        tx_last,
    output wire        tx_ready,

    output wire [7:0]  gmii_txd,
    output wire        gmii_tx_en,
    output wire        gmii_tx_er,

    output wire [3:0]  mii_txd,
    output wire        mii_tx_en,

    output wire        tx_busy,
    output wire [12:0] tx_fifo_level,
    output wire        dbg_tx_len_wr_en,
    output wire        dbg_tx_wr_full
);

    mii_if #(.MII_DEBUG(MII_DEBUG)) u_mii (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .mii_rxd               (4'd0),
        .mii_rx_dv             (1'b0),
        .mii_rx_er             (1'b0),
        .mii_rx_clk            (mii_clk),
        .mii_col               (1'b0),
        .mii_crs               (1'b0),
        .mii_txd               (mii_txd),
        .mii_tx_en             (mii_tx_en),
        .mii_tx_clk            (mii_clk),
        .gmii_txd              (gmii_txd),
        .gmii_tx_en            (gmii_tx_en),
        .gmii_tx_er            (gmii_tx_er),
        .gmii_rxd              (),
        .gmii_rx_dv            (),
        .gmii_rx_er            (),
        .mii_tx_clk_out        (),
        .tx_busy               (tx_busy),
        .tx_fifo_level         (tx_fifo_level),
        .dbg_tx_fifo_empty     (),
        .dbg_rx_prog_empty     (),
        .dbg_rx_rd_empty       (),
        .dbg_rx_reading        (),
        .dbg_rx_frames_pending (),
        .dbg_tx_len_wr_en      (dbg_tx_len_wr_en),
        .dbg_tx_wr_full        (dbg_tx_wr_full)
    );

    eth_mac_tx u_mac_tx (
        .clk           (clk),
        .rst_n         (rst_n),
        .tx_start_ok   (~tx_busy),
        .gmii_txd      (gmii_txd),
        .gmii_tx_en    (gmii_tx_en),
        .gmii_tx_er    (gmii_tx_er),
        .s_axis_tdata  (tx_data),
        .s_axis_tvalid (tx_valid),
        .s_axis_tready (tx_ready),
        .s_axis_tkeep  (1'b1),
        .s_axis_tlast  (tx_last),
        .tx_active     (),
        .dbg_state     (),
        .dbg_stall_cnt ()
    );

endmodule
