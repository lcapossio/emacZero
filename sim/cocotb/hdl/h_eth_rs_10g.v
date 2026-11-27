// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// Test harness: eth_rs_10g with its RX and TX sides on one clock.
module h_eth_rs_10g (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [63:0] rxd,
    input  wire [7:0]  rxc,
    input  wire        rx_valid,
    output wire [1:0]  rx_fault,
    input  wire        tx_ce,
    input  wire [63:0] mac_txd,
    input  wire [7:0]  mac_txc,
    output wire [63:0] txd,
    output wire [7:0]  txc,
    output wire        tx_fault
);
    eth_rs_10g u_rs (
        .rx_clk (clk), .rx_rst_n (rst_n),
        .rxd (rxd), .rxc (rxc), .rx_valid (rx_valid), .rx_fault (rx_fault),
        .tx_clk (clk), .tx_rst_n (rst_n), .tx_ce (tx_ce),
        .mac_txd (mac_txd), .mac_txc (mac_txc),
        .txd (txd), .txc (txc), .tx_fault (tx_fault)
    );
endmodule
