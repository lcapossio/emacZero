// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// udp_blast_trigger_alt.v - Parity-only wrapper: udp_blast_trigger with every
// parameter away from its default (TRIGGER_PORT 0x1234, IGNORE_SRC_PORT
// 0x5678, DEFAULT_COUNT 7, DEFAULT_PAYLOAD 99), so the proof also checks that
// each generic reaches the logic it should. The parameters are vectors (a
// std_logic_vector generic in the VHDL), which translateHDL cannot set, hence
// the wrapper. udp_blast_trigger_alt.vhd is the VHDL twin.
// =============================================================================

module udp_blast_trigger_alt (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  udp_rx_data,
    input  wire        udp_rx_valid,
    input  wire        udp_rx_last,
    input  wire        udp_rx_err,
    input  wire [47:0] udp_rx_src_mac,
    input  wire [31:0] udp_rx_src_ip,
    input  wire [15:0] udp_rx_src_port,
    input  wire [15:0] udp_rx_dst_port,
    input  wire        busy,
    output wire        start,
    output wire [47:0] dst_mac,
    output wire [31:0] dst_ip,
    output wire [15:0] dst_port,
    output wire [15:0] src_port,
    output wire [23:0] ifg_delay,
    output wire [31:0] packet_count,
    output wire [15:0] payload_size
);
    udp_blast_trigger #(
        .TRIGGER_PORT    (16'h1234),
        .IGNORE_SRC_PORT (16'h5678),
        .DEFAULT_COUNT   (32'd7),
        .DEFAULT_PAYLOAD (16'd99)
    ) u_dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .udp_rx_data     (udp_rx_data),
        .udp_rx_valid    (udp_rx_valid),
        .udp_rx_last     (udp_rx_last),
        .udp_rx_err      (udp_rx_err),
        .udp_rx_src_mac  (udp_rx_src_mac),
        .udp_rx_src_ip   (udp_rx_src_ip),
        .udp_rx_src_port (udp_rx_src_port),
        .udp_rx_dst_port (udp_rx_dst_port),
        .busy            (busy),
        .start           (start),
        .dst_mac         (dst_mac),
        .dst_ip          (dst_ip),
        .dst_port        (dst_port),
        .src_port        (src_port),
        .ifg_delay       (ifg_delay),
        .packet_count    (packet_count),
        .payload_size    (payload_size)
    );
endmodule
