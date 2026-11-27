// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// Test harness: AXIS -> eth_mac_10g_tx -> pcs10gbr TX -> serial loopback
// with a bit offset -> pcs10gbr RX -> XGMII out, all on one clock. The MAC
// advances on the PCS's xgmii_tx_ready, as it will in the 10G system.
module h_eth_mac_10g_tx_loop #(
    parameter OFFSET = 29,                 // line bit offset, 0..63
    parameter BER_TIMER_CYCLES = 4000
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tvalid,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tuser,
    output wire        s_axis_tready,
    output wire        stat_tx_frame,
    output wire        stat_underrun,
    output wire [63:0] xgmii_rxd,
    output wire [7:0]  xgmii_rxc,
    output wire        xgmii_rx_valid,
    output wire        block_lock,
    output wire        hi_ber
);
    wire [63:0] xgmii_txd, gt_txdata;
    wire [7:0]  xgmii_txc;
    wire        xgmii_tx_ready;
    wire [15:0] ber_cnt;

    reg  [63:0] prev;
    always @(posedge clk) prev <= gt_txdata;
    wire [127:0] two = {gt_txdata, prev};
    wire [63:0]  gt_rxdata = two[OFFSET +: 64];

    eth_mac_10g_tx u_mac (
        .clk (clk), .rst_n (rst_n), .ce (xgmii_tx_ready),
        .s_axis_tdata (s_axis_tdata), .s_axis_tkeep (s_axis_tkeep),
        .s_axis_tvalid (s_axis_tvalid), .s_axis_tlast (s_axis_tlast),
        .s_axis_tuser (s_axis_tuser), .s_axis_tready (s_axis_tready),
        .xgmii_txd (xgmii_txd), .xgmii_txc (xgmii_txc),
        .stat_tx_frame (stat_tx_frame), .stat_underrun (stat_underrun)
    );

    pcs10gbr #(.BER_TIMER_CYCLES(BER_TIMER_CYCLES)) u_pcs (
        .tx_clk (clk), .tx_rst_n (rst_n), .xgmii_txd (xgmii_txd),
        .xgmii_txc (xgmii_txc), .xgmii_tx_ready (xgmii_tx_ready),
        .gt_txdata (gt_txdata),
        .rx_clk (clk), .rx_rst_n (rst_n), .gt_rxdata (gt_rxdata),
        .xgmii_rxd (xgmii_rxd), .xgmii_rxc (xgmii_rxc),
        .xgmii_rx_valid (xgmii_rx_valid),
        .rx_block_lock (block_lock), .rx_hi_ber (hi_ber), .rx_ber_cnt (ber_cnt)
    );
endmodule
