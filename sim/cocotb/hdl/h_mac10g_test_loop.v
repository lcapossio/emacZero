// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// Test harness: axis_test_gen64 -> eth_mac_10g_tx -> pcs10gbr TX -> serial
// loopback with a bit offset -> pcs10gbr RX -> eth_mac_10g_rx ->
// axis_test_chk64, all on one clock, as the ZCU106 10G design runs its MAC
// test in near-end PMA loopback.
module h_mac10g_test_loop #(
    parameter OFFSET = 23,
    parameter BER_TIMER_CYCLES = 4000
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire [15:0] len,
    input  wire        sweep,
    input  wire [7:0]  ipg,
    input  wire        inj_err,
    input  wire        clear,
    output wire [31:0] gen_frames,
    output wire [31:0] good_frames,
    output wire [31:0] bad_frames,
    output wire [31:0] tuser_frames,
    output wire [31:0] seq_gaps,
    output wire        underrun,
    output wire        block_lock
);
    wire [63:0] xgmii_txd, xgmii_rxd, gt_txdata;
    wire [7:0]  xgmii_txc, xgmii_rxc;
    wire        xgmii_tx_ready, xgmii_rx_valid, hi_ber;
    wire [15:0] ber_cnt;
    wire [63:0] g_tdata, r_tdata;
    wire [7:0]  g_tkeep, r_tkeep;
    wire        g_tvalid, g_tlast, g_tready, r_tvalid, r_tlast, r_tuser;

    reg  [63:0] prev;
    always @(posedge clk) prev <= gt_txdata;
    wire [127:0] two = {gt_txdata, prev};
    wire [63:0]  gt_rxdata = two[OFFSET +: 64];

    axis_test_gen64 u_gen (
        .clk (clk), .rst_n (rst_n), .enable (enable), .len (len),
        .sweep (sweep), .ipg (ipg), .inj_err (inj_err),
        .m_axis_tdata (g_tdata), .m_axis_tkeep (g_tkeep),
        .m_axis_tvalid (g_tvalid), .m_axis_tlast (g_tlast),
        .m_axis_tready (g_tready), .frames (gen_frames)
    );

    eth_mac_10g_tx u_tx (
        .clk (clk), .rst_n (rst_n), .ce (xgmii_tx_ready),
        .s_axis_tdata (g_tdata), .s_axis_tkeep (g_tkeep),
        .s_axis_tvalid (g_tvalid), .s_axis_tlast (g_tlast),
        .s_axis_tuser (1'b0), .s_axis_tready (g_tready),
        .xgmii_txd (xgmii_txd), .xgmii_txc (xgmii_txc),
        .stat_tx_frame (), .stat_underrun (underrun)
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
        .xgmii_rx_valid (xgmii_rx_valid), .jumbo_en (1'b1),
        .m_axis_tdata (r_tdata), .m_axis_tkeep (r_tkeep),
        .m_axis_tvalid (r_tvalid), .m_axis_tlast (r_tlast),
        .m_axis_tuser (r_tuser),
        .stat_done (), .stat_len (), .stat_err_fcs (), .stat_err_ctl (),
        .stat_err_oversize (), .stat_err_undersize (),
        .stat_is_bcast (), .stat_is_mcast ()
    );

    axis_test_chk64 u_chk (
        .clk (clk), .rst_n (rst_n), .clear (clear),
        .s_axis_tdata (r_tdata), .s_axis_tkeep (r_tkeep),
        .s_axis_tvalid (r_tvalid), .s_axis_tlast (r_tlast),
        .s_axis_tuser (r_tuser),
        .good_frames (good_frames), .bad_frames (bad_frames),
        .tuser_frames (tuser_frames), .seq_gaps (seq_gaps),
        .good_pulse (), .bad_pulse ()
    );
endmodule
