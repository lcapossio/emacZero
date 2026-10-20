// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// Parity wrapper: udp_echo with LISTEN_PORT set from an integer parameter
// (default 9999, the port both boards use), because translateHDL param sets
// cannot set a [15:0] vector parameter / std_logic_vector generic directly.
module udp_echo_listen #(
    parameter BUF_SIZE = 1024,
    parameter integer LPORT = 9999
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [47:0] our_mac,
    input  wire [31:0] our_ip,
    input  wire [7:0]  udp_rx_data,
    input  wire        udp_rx_valid,
    input  wire        udp_rx_last,
    input  wire        udp_rx_err,
    input  wire [31:0] udp_rx_src_ip,
    input  wire [15:0] udp_rx_src_port,
    input  wire [15:0] udp_rx_dst_port,
    input  wire [15:0] udp_rx_length,
    input  wire [47:0] rx_src_mac,
    output wire [7:0]  tx_data,
    output wire        tx_valid,
    output wire        tx_last,
    input  wire        tx_ready,
    output wire        tx_start
);
    udp_echo #(
        .BUF_SIZE(BUF_SIZE), .LISTEN_PORT(LPORT[15:0])
    ) u_echo (
        .clk(clk), .rst_n(rst_n), .our_mac(our_mac), .our_ip(our_ip),
        .udp_rx_data(udp_rx_data), .udp_rx_valid(udp_rx_valid),
        .udp_rx_last(udp_rx_last), .udp_rx_err(udp_rx_err),
        .udp_rx_src_ip(udp_rx_src_ip), .udp_rx_src_port(udp_rx_src_port),
        .udp_rx_dst_port(udp_rx_dst_port), .udp_rx_length(udp_rx_length),
        .rx_src_mac(rx_src_mac), .tx_data(tx_data), .tx_valid(tx_valid),
        .tx_last(tx_last), .tx_ready(tx_ready), .tx_start(tx_start)
    );
endmodule
