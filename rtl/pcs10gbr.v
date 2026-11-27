// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// pcs10gbr.v - 10GBASE-R PCS (IEEE 802.3 clause 49), XGMII to 64-bit GT words
//
// TX (tx_clk = transceiver TX user clock, line rate / 64):
//   XGMII -> 64b/66b encoder -> scrambler -> 66:64 gearbox -> gt_txdata
//   The encode pipeline advances only when xgmii_tx_ready is high (32 of
//   every 33 cycles); the XGMII source must hold its transfer until then.
// RX (rx_clk = transceiver RX user clock):
//   gt_rxdata -> 64:66 gearbox -> block lock / BER monitor -> descrambler
//   -> 64b/66b decoder -> XGMII, one transfer per xgmii_rx_valid
//
// gt_txdata / gt_rxdata bit 0 is the first bit on the wire. The transceiver
// runs in raw mode with a 64-bit user interface; the gearboxes and block
// alignment are all here.
// Verilog 2001
// =============================================================================

module pcs10gbr #(
    parameter BER_TIMER_CYCLES = 20142     // 125 us at the RX user clock
) (
    // TX
    input  wire        tx_clk,
    input  wire        tx_rst_n,
    input  wire [63:0] xgmii_txd,
    input  wire [7:0]  xgmii_txc,
    output wire        xgmii_tx_ready,
    output wire [63:0] gt_txdata,

    // RX
    input  wire        rx_clk,
    input  wire        rx_rst_n,
    input  wire [63:0] gt_rxdata,
    output wire [63:0] xgmii_rxd,
    output wire [7:0]  xgmii_rxc,
    output wire        xgmii_rx_valid,

    // RX status (rx_clk domain)
    output wire        rx_block_lock,
    output wire        rx_hi_ber,
    output wire [15:0] rx_ber_cnt
);

    // ------------------------------------------------------------------ TX
    wire [1:0]  enc_hdr;
    wire [63:0] enc_pay;
    wire [63:0] scr_pay;
    reg  [1:0]  scr_hdr;
    wire        tx_ready;

    assign xgmii_tx_ready = tx_ready;

    pcs10gbr_enc u_enc (
        .clk     (tx_clk),
        .rst_n   (tx_rst_n),
        .en      (tx_ready),
        .xgmii_d (xgmii_txd),
        .xgmii_c (xgmii_txc),
        .hdr     (enc_hdr),
        .pay     (enc_pay)
    );

    pcs10gbr_scrambler #(.DESCRAMBLE(0)) u_scr (
        .clk   (tx_clk),
        .rst_n (tx_rst_n),
        .en    (tx_ready),
        .din   (enc_pay),
        .dout  (scr_pay)
    );

    always @(posedge tx_clk or negedge tx_rst_n) begin
        if (!tx_rst_n)
            scr_hdr <= 2'b01;
        else if (tx_ready)
            scr_hdr <= enc_hdr;
    end

    pcs10gbr_gearbox_tx u_gb_tx (
        .clk   (tx_clk),
        .rst_n (tx_rst_n),
        .blk   ({scr_pay, scr_hdr}),
        .ready (tx_ready),
        .dout  (gt_txdata)
    );

    // ------------------------------------------------------------------ RX
    wire [65:0] rx_blk;
    wire        rx_blk_v;
    wire        slip;
    wire        lock;
    wire        hi_ber;
    wire [63:0] dsc_pay;
    reg  [1:0]  dsc_hdr;
    reg         dsc_v;

    pcs10gbr_gearbox_rx u_gb_rx (
        .clk   (rx_clk),
        .rst_n (rx_rst_n),
        .din   (gt_rxdata),
        .slip  (slip),
        .blk   (rx_blk),
        .valid (rx_blk_v)
    );

    pcs10gbr_block_lock u_lock (
        .clk        (rx_clk),
        .rst_n      (rx_rst_n),
        .valid      (rx_blk_v),
        .hdr        (rx_blk[1:0]),
        .block_lock (lock),
        .slip       (slip)
    );

    pcs10gbr_ber_mon #(.TIMER_CYCLES(BER_TIMER_CYCLES)) u_ber (
        .clk        (rx_clk),
        .rst_n      (rx_rst_n),
        .valid      (rx_blk_v),
        .hdr        (rx_blk[1:0]),
        .block_lock (lock),
        .hi_ber     (hi_ber),
        .ber_cnt    (rx_ber_cnt)
    );

    pcs10gbr_scrambler #(.DESCRAMBLE(1)) u_dsc (
        .clk   (rx_clk),
        .rst_n (rx_rst_n),
        .en    (rx_blk_v),
        .din   (rx_blk[65:2]),
        .dout  (dsc_pay)
    );

    always @(posedge rx_clk or negedge rx_rst_n) begin
        if (!rx_rst_n) begin
            dsc_hdr <= 2'b00;
            dsc_v   <= 1'b0;
        end else begin
            dsc_v <= rx_blk_v;
            if (rx_blk_v) dsc_hdr <= rx_blk[1:0];
        end
    end

    pcs10gbr_dec u_dec (
        .clk        (rx_clk),
        .rst_n      (rx_rst_n),
        .en         (dsc_v),
        .block_lock (lock),
        .hi_ber     (hi_ber),
        .hdr        (dsc_hdr),
        .pay        (dsc_pay),
        .xgmii_d    (xgmii_rxd),
        .xgmii_c    (xgmii_rxc),
        .valid      (xgmii_rx_valid)
    );

    assign rx_block_lock = lock;
    assign rx_hi_ber     = hi_ber;

endmodule
