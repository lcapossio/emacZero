// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// udp_iperf_sink_p5001.v - Parity-only wrapper: udp_iperf_sink with
// LISTEN_PORT = 16'd5001, the value arty_a7_top and zcu106_eth_demo use.
// translateHDL sets integer and string parameters only, and LISTEN_PORT is a
// 16-bit vector (a std_logic_vector generic in the VHDL), so the value is set
// here. udp_iperf_sink_p5001.vhd is the VHDL twin; same ports, same instance.
// =============================================================================

module udp_iperf_sink_p5001 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  udp_rx_data,
    input  wire        udp_rx_valid,
    input  wire        udp_rx_last,
    input  wire        udp_rx_err,
    input  wire [31:0] udp_rx_src_ip,
    input  wire [15:0] udp_rx_src_port,
    input  wire [15:0] udp_rx_dst_port,
    input  wire [15:0] udp_rx_length,
    input  wire        clear_stats,
    output wire [31:0] stat_packets,
    output wire [31:0] stat_bytes,
    output wire [31:0] stat_first_seq,
    output wire [31:0] stat_last_seq,
    output wire [31:0] stat_seq_gaps,
    output wire [31:0] stat_out_of_order,
    output wire [31:0] stat_final_packets,
    output wire [31:0] stat_last_src_ip,
    output wire [15:0] stat_last_src_port
);
    udp_iperf_sink #(.LISTEN_PORT(16'd5001)) u_dut (
        .clk                (clk),
        .rst_n              (rst_n),
        .udp_rx_data        (udp_rx_data),
        .udp_rx_valid       (udp_rx_valid),
        .udp_rx_last        (udp_rx_last),
        .udp_rx_err         (udp_rx_err),
        .udp_rx_src_ip      (udp_rx_src_ip),
        .udp_rx_src_port    (udp_rx_src_port),
        .udp_rx_dst_port    (udp_rx_dst_port),
        .udp_rx_length      (udp_rx_length),
        .clear_stats        (clear_stats),
        .stat_packets       (stat_packets),
        .stat_bytes         (stat_bytes),
        .stat_first_seq     (stat_first_seq),
        .stat_last_seq      (stat_last_seq),
        .stat_seq_gaps      (stat_seq_gaps),
        .stat_out_of_order  (stat_out_of_order),
        .stat_final_packets (stat_final_packets),
        .stat_last_src_ip   (stat_last_src_ip),
        .stat_last_src_port (stat_last_src_port)
    );
endmodule
