// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// h_rgmii_if_100m.v - cocotb harness: two rgmii_if, TX pins looped to RX
// through the board delay, RX clocked by the forwarded TXC
//
// The DUT pair of tb_rgmii_if_100m.v and tb_rgmii_if_speed_switch.v, which
// wire it identically (speed_switch ties u_tx's gmii_tx_er low; its test
// drives tx_gmii_tx_er 0). Both instances share cfg_speed. The nets are
// those of the benches:
//   txd_s / ctl_s / txc_s       the pins after a 10 ps inertial delay, which
//                               drops the zero-time glitches of the
//                               behavioural DDR model (the PHY's view)
//   rgmii_rxd / _rx_ctl / _rxc  those, 3 ns later (board delay, same on clock
//                               and data), into u_rx; rgmii_rxc is u_rx's RXC
// The delays are the benches' own continuous assignments. Every net the test
// reads is a port; the _i nets carry them inside (a VHDL-93 out port cannot
// be read back). Same entity in h_rgmii_if_100m.vhd.
// =============================================================================
`timescale 1ns / 1ps

module h_rgmii_if_100m (
    input  wire       clk_125,
    input  wire       clk_125_90,
    input  wire       rst_n,
    input  wire [1:0] cfg_speed,

    // u_tx GMII inputs
    input  wire [7:0] tx_gmii_txd,
    input  wire       tx_gmii_tx_en,
    input  wire       tx_gmii_tx_er,

    // u_tx RGMII pins
    output wire [3:0] rgmii_txd,
    output wire       rgmii_tx_ctl,
    output wire       rgmii_txc,

    // The pins after 10 ps
    output wire [3:0] txd_s,
    output wire       ctl_s,
    output wire       txc_s,

    // u_rx RGMII inputs (3 ns further)
    output wire [3:0] rgmii_rxd,
    output wire       rgmii_rx_ctl,
    output wire       rgmii_rxc,

    // u_rx GMII outputs
    output wire [7:0] rx_gmii_rxd,
    output wire       rx_gmii_rx_dv,
    output wire       rx_gmii_rx_er,
    output wire       rx_gmii_rx_ce
);

    wire [3:0] rgmii_txd_i;
    wire       rgmii_tx_ctl_i;
    wire       rgmii_txc_i;
    wire [3:0] txd_s_i;
    wire       ctl_s_i, txc_s_i;
    wire [3:0] rgmii_rxd_i;
    wire       rgmii_rx_ctl_i;
    wire       rgmii_rxc_i;

    assign #0.01 txd_s_i = rgmii_txd_i;
    assign #0.01 ctl_s_i = rgmii_tx_ctl_i;
    assign #0.01 txc_s_i = rgmii_txc_i;

    assign #3 rgmii_rxd_i    = txd_s_i;
    assign #3 rgmii_rx_ctl_i = ctl_s_i;
    assign #3 rgmii_rxc_i    = txc_s_i;

    assign rgmii_txd    = rgmii_txd_i;
    assign rgmii_tx_ctl = rgmii_tx_ctl_i;
    assign rgmii_txc    = rgmii_txc_i;
    assign txd_s        = txd_s_i;
    assign ctl_s        = ctl_s_i;
    assign txc_s        = txc_s_i;
    assign rgmii_rxd    = rgmii_rxd_i;
    assign rgmii_rx_ctl = rgmii_rx_ctl_i;
    assign rgmii_rxc    = rgmii_rxc_i;

    rgmii_if u_tx (
        .clk_125     (clk_125),
        .clk_125_90  (clk_125_90),
        .rst_n       (rst_n),
        .cfg_speed   (cfg_speed),
        .rgmii_txd   (rgmii_txd_i),
        .rgmii_tx_ctl(rgmii_tx_ctl_i),
        .rgmii_txc   (rgmii_txc_i),
        .rgmii_rxd   (4'd0),
        .rgmii_rx_ctl(1'b0),
        .rgmii_rxc   (1'b0),
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
        .cfg_speed   (cfg_speed),
        .rgmii_txd   (),
        .rgmii_tx_ctl(),
        .rgmii_txc   (),
        .rgmii_rxd   (rgmii_rxd_i),
        .rgmii_rx_ctl(rgmii_rx_ctl_i),
        .rgmii_rxc   (rgmii_rxc_i),
        .gmii_txd    (8'd0),
        .gmii_tx_en  (1'b0),
        .gmii_tx_er  (1'b0),
        .gmii_rxd    (rx_gmii_rxd),
        .gmii_rx_dv  (rx_gmii_rx_dv),
        .gmii_rx_er  (rx_gmii_rx_er),
        .gmii_rx_ce  (rx_gmii_rx_ce)
    );

endmodule
