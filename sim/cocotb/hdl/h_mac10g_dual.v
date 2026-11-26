// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// Test harness: both ports of the ZCU106 10G design (two zcu106_10g_lane, as
// on the board) with a "fibre" between them: port 0's serial data reaches
// port 1 at bit offset OFFSET01, port 1's reaches port 0 at OFFSET10.
// clk_a carries port 0 TX and port 1 RX (on the board port 1 recovers port
// 0's transmit clock), clk_b port 1 TX and port 0 RX. ctrl0 / ctrl1 are the
// ports' EIO control words (bit map in zcu106_10g_top.v), driven as the host
// script does.
module h_mac10g_dual #(
    parameter OFFSET01 = 23,
    parameter OFFSET10 = 41,
    parameter BER_TIMER_CYCLES = 4000
) (
    input  wire         clk_a,
    input  wire         clk_b,
    input  wire         rst_n,
    input  wire         app_clk,
    input  wire         app_rst_n,
    input  wire [127:0] ctrl0,
    input  wire [127:0] ctrl1,

    output wire         block_lock0,
    output wire         block_lock1,
    output wire [31:0]  gen0,           // MAC mode generator frames
    output wire [31:0]  good0,          // MAC mode checker
    output wire [31:0]  bad0,
    output wire [31:0]  tuser0,
    output wire [31:0]  gaps0,
    output wire         csr_ack0,
    output wire [31:0]  csr_rdata0,
    output wire [31:0]  gen1,
    output wire [31:0]  good1,
    output wire [31:0]  bad1,
    output wire [31:0]  tuser1,
    output wire [31:0]  gaps1,
    output wire         csr_ack1,
    output wire [31:0]  csr_rdata1
);
    wire [63:0] tx0, tx1;
    reg  [63:0] prev0, prev1;
    always @(posedge clk_a) prev0 <= tx0;
    always @(posedge clk_b) prev1 <= tx1;
    wire [127:0] two0 = {tx0, prev0};
    wire [127:0] two1 = {tx1, prev1};
    wire [63:0]  rx1 = two0[OFFSET01 +: 64];   // clk_a
    wire [63:0]  rx0 = two1[OFFSET10 +: 64];   // clk_b

    zcu106_10g_lane #(.BER_TIMER_CYCLES(BER_TIMER_CYCLES)) u_lane0 (
        .tx_clk (clk_a), .tx_rst_n (rst_n), .rx_clk (clk_b), .rx_rst_n (rst_n),
        .clk_app (app_clk), .app_rst_n (app_rst_n), .ctrl (ctrl0),
        .gt_txdata (tx0), .gt_rxdata (rx0),
        .block_lock (block_lock0), .hi_ber (), .ber_cnt (),
        .lock_losses (), .gen_frames (), .good_frames (), .bad_frames (),
        .seq_gaps (), .bad_words (), .lf_words (),
        .mac_gen_frames (gen0), .mac_good (good0), .mac_bad (bad0),
        .mac_tuser (tuser0), .mac_seq_gaps (gaps0),
        .csr_ack (csr_ack0), .csr_rdata (csr_rdata0),
        .sel_bad_seen (), .sel_good_led ()
    );

    zcu106_10g_lane #(.BER_TIMER_CYCLES(BER_TIMER_CYCLES)) u_lane1 (
        .tx_clk (clk_b), .tx_rst_n (rst_n), .rx_clk (clk_a), .rx_rst_n (rst_n),
        .clk_app (app_clk), .app_rst_n (app_rst_n), .ctrl (ctrl1),
        .gt_txdata (tx1), .gt_rxdata (rx1),
        .block_lock (block_lock1), .hi_ber (), .ber_cnt (),
        .lock_losses (), .gen_frames (), .good_frames (), .bad_frames (),
        .seq_gaps (), .bad_words (), .lf_words (),
        .mac_gen_frames (gen1), .mac_good (good1), .mac_bad (bad1),
        .mac_tuser (tuser1), .mac_seq_gaps (gaps1),
        .csr_ack (csr_ack1), .csr_rdata (csr_rdata1),
        .sel_bad_seen (), .sel_good_led ()
    );
endmodule
