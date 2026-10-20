// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// h_rgmii_if_variants.v - cocotb harness: rgmii_if with each RGMII_SPEEDS
//
// The three instances of tb_rgmii_if_variants.v, all driven by the same GMII
// inputs (tx_d / tx_en / tx_er):
//   u_1g_only  RGMII_SPEEDS_1G_ONLY ("1G_ONLY"), cfg_speed 00 (1G)
//   u_10_100   RGMII_SPEEDS_10_100  ("10_100"),  cfg_speed 01 (100M),
//              clk_125_90 tied low (unused for 10_100)
//   u_all      RGMII_SPEEDS_ALL     ("ALL"),     cfg_speed 00 (1G)
// The RX sides are tied off as in the bench. txc_1g_s / txc_100_s are the two
// TXCs after the bench's 10 ps inertial delay, which drops the zero-time
// glitches of the behavioural DDR model. Every net the test reads is a port;
// the _i nets carry the TXCs to the delays (a VHDL-93 out port cannot be read
// back). Same entity in h_rgmii_if_variants.vhd.
// =============================================================================
`timescale 1ns / 1ps

module h_rgmii_if_variants #(
    parameter RGMII_SPEEDS_1G_ONLY = "1G_ONLY",
    parameter RGMII_SPEEDS_10_100  = "10_100",
    parameter RGMII_SPEEDS_ALL     = "ALL"
)(
    input  wire       clk_125,
    input  wire       clk_125_90,
    input  wire       rst_n,

    input  wire [7:0] tx_d,
    input  wire       tx_en,
    input  wire       tx_er,

    output wire [3:0] txd_1g_only,
    output wire       txctl_1g_only,
    output wire       txc_1g_only,
    output wire [3:0] txd_10_100,
    output wire       txctl_10_100,
    output wire       txc_10_100,
    output wire [3:0] txd_all,
    output wire       txctl_all,

    output wire       txc_1g_s,
    output wire       txc_100_s
);

    wire txc_1g_only_i;
    wire txc_10_100_i;

    assign txc_1g_only = txc_1g_only_i;
    assign txc_10_100  = txc_10_100_i;

    assign #0.01 txc_1g_s  = txc_1g_only_i;
    assign #0.01 txc_100_s = txc_10_100_i;

    rgmii_if #(.RGMII_SPEEDS(RGMII_SPEEDS_1G_ONLY)) u_1g_only (
        .clk_125     (clk_125),
        .clk_125_90  (clk_125_90),
        .rst_n       (rst_n),
        .cfg_speed   (2'b00),
        .rgmii_txd   (txd_1g_only),
        .rgmii_tx_ctl(txctl_1g_only),
        .rgmii_txc   (txc_1g_only_i),
        .rgmii_rxd   (4'd0),
        .rgmii_rx_ctl(1'b0),
        .rgmii_rxc   (1'b0),
        .gmii_txd    (tx_d),
        .gmii_tx_en  (tx_en),
        .gmii_tx_er  (tx_er),
        .gmii_rxd    (),
        .gmii_rx_dv  (),
        .gmii_rx_er  (),
        .gmii_rx_ce  ()
    );

    rgmii_if #(.RGMII_SPEEDS(RGMII_SPEEDS_10_100)) u_10_100 (
        .clk_125     (clk_125),
        .clk_125_90  (1'b0),
        .rst_n       (rst_n),
        .cfg_speed   (2'b01),
        .rgmii_txd   (txd_10_100),
        .rgmii_tx_ctl(txctl_10_100),
        .rgmii_txc   (txc_10_100_i),
        .rgmii_rxd   (4'd0),
        .rgmii_rx_ctl(1'b0),
        .rgmii_rxc   (1'b0),
        .gmii_txd    (tx_d),
        .gmii_tx_en  (tx_en),
        .gmii_tx_er  (tx_er),
        .gmii_rxd    (),
        .gmii_rx_dv  (),
        .gmii_rx_er  (),
        .gmii_rx_ce  ()
    );

    rgmii_if #(.RGMII_SPEEDS(RGMII_SPEEDS_ALL)) u_all (
        .clk_125     (clk_125),
        .clk_125_90  (clk_125_90),
        .rst_n       (rst_n),
        .cfg_speed   (2'b00),
        .rgmii_txd   (txd_all),
        .rgmii_tx_ctl(txctl_all),
        .rgmii_txc   (),
        .rgmii_rxd   (4'd0),
        .rgmii_rx_ctl(1'b0),
        .rgmii_rxc   (1'b0),
        .gmii_txd    (tx_d),
        .gmii_tx_en  (tx_en),
        .gmii_tx_er  (tx_er),
        .gmii_rxd    (),
        .gmii_rx_dv  (),
        .gmii_rx_er  (),
        .gmii_rx_ce  ()
    );

endmodule
