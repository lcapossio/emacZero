// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// Test harness: AXIS -> eth_mac_10g_tx -> pcs10gbr TX -> serial loopback
// with a bit offset -> pcs10gbr RX -> eth_mac_10g_rx -> AXIS, all on one
// clock: the whole 10G datapath short of the transceiver.
module h_eth_mac_10g_loop #(
    parameter OFFSET = 41,                 // line bit offset, 0..63
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
    input  wire        jumbo_en,
    output wire [63:0] m_axis_tdata,
    output wire [7:0]  m_axis_tkeep,
    output wire        m_axis_tvalid,
    output wire        m_axis_tlast,
    output wire        m_axis_tuser,
    output wire        stat_done,
    output wire [13:0] stat_len,
    output wire        stat_err_fcs,
    output wire        block_lock,
    output wire        hi_ber
);
    wire [63:0] xgmii_txd, xgmii_rxd, gt_txdata;
    wire [7:0]  xgmii_txc, xgmii_rxc;
    wire        xgmii_tx_ready, xgmii_rx_valid;
    wire [15:0] ber_cnt;

    reg  [63:0] prev;
    always @(posedge clk) prev <= gt_txdata;
    wire [127:0] two = {gt_txdata, prev};
    wire [63:0]  gt_rxdata = two[OFFSET +: 64];

    eth_mac_10g_tx u_tx (
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

    eth_mac_10g_rx u_rx (
        .clk (clk), .rst_n (rst_n),
        .xgmii_rxd (xgmii_rxd), .xgmii_rxc (xgmii_rxc),
        .xgmii_rx_valid (xgmii_rx_valid), .jumbo_en (jumbo_en),
        .m_axis_tdata (m_axis_tdata), .m_axis_tkeep (m_axis_tkeep),
        .m_axis_tvalid (m_axis_tvalid), .m_axis_tlast (m_axis_tlast),
        .m_axis_tuser (m_axis_tuser),
        .stat_done (stat_done), .stat_len (stat_len),
        .stat_err_fcs (stat_err_fcs), .stat_err_ctl (),
        .stat_err_oversize (), .stat_err_undersize (),
        .stat_is_bcast (), .stat_is_mcast ()
    );
endmodule
