// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// h_rgmii_if.v - cocotb harness: two rgmii_if at 1G, TX pins looped to RX
//
// The DUT pair of tb_rgmii_if.v. u_tx sends at 1G; its RGMII pins drive
// u_rx's RGMII inputs directly (no board delay), and u_rx takes them on
// clk_125_90 as its RXC. u_tx's own RX side is tied off with RXC = clk_125,
// as in the bench. The test drives the clocks, reset and u_tx's GMII inputs.
// The pins are ports so the test can read them; the _i nets carry them to
// u_rx (a VHDL-93 out port cannot be read back). Port names follow the
// bench's net names. Same entity in h_rgmii_if.vhd.
// =============================================================================
`timescale 1ns / 1ps

module h_rgmii_if (
    input  wire       clk_125,
    input  wire       clk_125_90,
    input  wire       rst_n,

    // u_tx GMII inputs
    input  wire [7:0] tx_gmii_txd,
    input  wire       tx_gmii_tx_en,
    input  wire       tx_gmii_tx_er,

    // RGMII pins, u_tx -> u_rx
    output wire [3:0] rgmii_txd,
    output wire       rgmii_tx_ctl,
    output wire       rgmii_txc,

    // u_rx GMII outputs
    output wire [7:0] rx_gmii_rxd,
    output wire       rx_gmii_rx_dv,
    output wire       rx_gmii_rx_er
);

    wire [3:0] rgmii_txd_i;
    wire       rgmii_tx_ctl_i;
    wire       rgmii_txc_i;

    assign rgmii_txd    = rgmii_txd_i;
    assign rgmii_tx_ctl = rgmii_tx_ctl_i;
    assign rgmii_txc    = rgmii_txc_i;

    rgmii_if u_tx (
        .clk_125     (clk_125),
        .clk_125_90  (clk_125_90),
        .rst_n       (rst_n),
        .cfg_speed   (2'b00),
        .rgmii_txd   (rgmii_txd_i),
        .rgmii_tx_ctl(rgmii_tx_ctl_i),
        .rgmii_txc   (rgmii_txc_i),
        .rgmii_rxd   (4'd0),
        .rgmii_rx_ctl(1'b0),
        .rgmii_rxc   (clk_125),
        .gmii_txd    (tx_gmii_txd),
        .gmii_tx_en  (tx_gmii_tx_en),
        .gmii_tx_er  (tx_gmii_tx_er),
        .gmii_rxd    (),
        .gmii_rx_dv  (),
        .gmii_rx_er  (),
        .gmii_rx_ce  ()
    );

    rgmii_if u_rx (
        .clk_125     (clk_125),
        .clk_125_90  (clk_125_90),
        .rst_n       (rst_n),
        .cfg_speed   (2'b00),
        .rgmii_txd   (),
        .rgmii_tx_ctl(),
        .rgmii_txc   (),
        .rgmii_rxd   (rgmii_txd_i),
        .rgmii_rx_ctl(rgmii_tx_ctl_i),
        .rgmii_rxc   (clk_125_90),
        .gmii_txd    (8'd0),
        .gmii_tx_en  (1'b0),
        .gmii_tx_er  (1'b0),
        .gmii_rxd    (rx_gmii_rxd),
        .gmii_rx_dv  (rx_gmii_rx_dv),
        .gmii_rx_er  (rx_gmii_rx_er),
        .gmii_rx_ce  ()
    );

endmodule
