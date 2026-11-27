// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// Test harness: xgmii_test_gen -> pcs10gbr TX -> serial loopback with a bit
// offset (and an XOR error mask) -> pcs10gbr RX -> xgmii_test_chk, all on
// one clock, as the ZCU106 10G bring-up design runs them in near-end PMA
// loopback.
module h_xgmii_test_loop #(
    parameter OFFSET = 17,                 // line bit offset, 0..63
    parameter BER_TIMER_CYCLES = 4000
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire [7:0]  len_words,
    input  wire [7:0]  ipg_words,
    input  wire        inj_err,
    input  wire [63:0] line_flip,          // XORed onto the line word
    input  wire        clear,
    output wire [31:0] gen_frames,
    output wire [31:0] good_frames,
    output wire [31:0] bad_frames,
    output wire [31:0] seq_gaps,
    output wire [31:0] bad_words,
    output wire [31:0] lf_words,
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
    wire [63:0]  gt_rxdata = two[OFFSET +: 64] ^ line_flip;

    xgmii_test_gen u_gen (
        .clk (clk), .rst_n (rst_n), .enable (enable), .len_words (len_words),
        .ipg_words (ipg_words), .inj_err (inj_err),
        .xgmii_tx_ready (xgmii_tx_ready), .xgmii_txd (xgmii_txd),
        .xgmii_txc (xgmii_txc), .frames (gen_frames)
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

    xgmii_test_chk u_chk (
        .clk (clk), .rst_n (rst_n), .clear (clear), .len_words (len_words),
        .xgmii_rxd (xgmii_rxd), .xgmii_rxc (xgmii_rxc),
        .xgmii_rx_valid (xgmii_rx_valid),
        .good_frames (good_frames), .bad_frames (bad_frames),
        .seq_gaps (seq_gaps), .bad_words (bad_words), .lf_words (lf_words),
        .good_pulse (), .bad_pulse ()
    );
endmodule
