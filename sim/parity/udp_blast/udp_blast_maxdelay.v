// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// Parity wrapper: udp_blast with START_DELAY_CYCLES = 32'hFFFFFFFF and
// USEC_TICK_CYCLES = 0. Yosys `hierarchy -chparam` cannot take a negative
// number and the VHDL integer generic cannot hold 2**32 - 1, so this pair
// (udp_blast_maxdelay.{v,vhd}) proves that the VHDL generic's 32-bit
// two's-complement mapping (-1 -> 32'hFFFFFFFF) matches the Verilog
// `parameter [31:0]`. Read identically by the parity manifest on both sides.
module udp_blast_maxdelay (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [47:0] our_mac,
    input  wire [31:0] our_ip,
    input  wire [47:0] dst_mac,
    input  wire [31:0] dst_ip,
    input  wire [15:0] dst_port,
    input  wire [15:0] src_port,
    input  wire [13:0] payload_size,
    input  wire        enable,
    input  wire [23:0] inter_frame_delay,
    output wire [31:0] pkts_sent,
    output wire        pkt_done_pulse,
    output wire [7:0]  tx_data,
    output wire        tx_valid,
    output wire        tx_last,
    input  wire        tx_ready,
    output wire        tx_start
);
    udp_blast #(
        .START_DELAY_CYCLES (32'hFFFFFFFF),
        .USEC_TICK_CYCLES   (7'd0)
    ) u_dut (
        .clk               (clk),
        .rst_n             (rst_n),
        .our_mac           (our_mac),
        .our_ip            (our_ip),
        .dst_mac           (dst_mac),
        .dst_ip            (dst_ip),
        .dst_port          (dst_port),
        .src_port          (src_port),
        .payload_size      (payload_size),
        .enable            (enable),
        .inter_frame_delay (inter_frame_delay),
        .pkts_sent         (pkts_sent),
        .pkt_done_pulse    (pkt_done_pulse),
        .tx_data           (tx_data),
        .tx_valid          (tx_valid),
        .tx_last           (tx_last),
        .tx_ready          (tx_ready),
        .tx_start          (tx_start)
    );
endmodule
