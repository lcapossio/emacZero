// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// udp_blast_trigger.v - Parse a UDP control packet into a bounded blast request
//
// Trigger payload format:
//   bytes 0..2: extra inter-frame delay in 100 MHz cycles
//   bytes 3..6: packet count
//   bytes 7..8: destination UDP port override
//
// Short packets are accepted:
//   0..2 bytes -> defaults
//   3 bytes    -> delay only
//   7 bytes    -> delay + count
//   9+ bytes   -> delay + count + dst-port override
// Verilog 2001
// =============================================================================

module udp_blast_trigger #(
    parameter [15:0] TRIGGER_PORT = 16'd9997,
    parameter [15:0] IGNORE_SRC_PORT = 16'd5001,
    parameter [31:0] DEFAULT_COUNT = 32'd1000000
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire [7:0]  udp_rx_data,
    input  wire        udp_rx_valid,
    input  wire        udp_rx_last,
    input  wire [47:0] udp_rx_src_mac,
    input  wire [31:0] udp_rx_src_ip,
    input  wire [15:0] udp_rx_src_port,
    input  wire [15:0] udp_rx_dst_port,
    input  wire        busy,

    output reg         start,
    output reg  [47:0] dst_mac,
    output reg  [31:0] dst_ip,
    output reg  [15:0] dst_port,
    output reg  [15:0] src_port,
    output reg  [23:0] ifg_delay,
    output reg  [31:0] packet_count
);

    reg        active;
    reg        accept;
    reg [3:0]  byte_cnt;
    reg [23:0] delay_acc;
    reg [31:0] count_acc;
    reg [15:0] port_acc;

    wire is_first = !active;
    wire first_accept =
        (udp_rx_dst_port == TRIGGER_PORT) &&
        (udp_rx_src_port != IGNORE_SRC_PORT) &&
        !busy;

    wire this_accept = is_first ? first_accept : accept;
    wire take_byte = udp_rx_valid && this_accept && byte_cnt < 4'd9;

    wire [3:0] byte_cnt_next = take_byte ? (byte_cnt + 4'd1) : byte_cnt;
    wire [23:0] delay_next =
        (take_byte && byte_cnt < 4'd3) ? {delay_acc[15:0], udp_rx_data} : delay_acc;
    wire [31:0] count_next =
        (take_byte && byte_cnt >= 4'd3 && byte_cnt < 4'd7) ?
            {count_acc[23:0], udp_rx_data} : count_acc;
    wire [15:0] port_next =
        (take_byte && byte_cnt >= 4'd7) ? {port_acc[7:0], udp_rx_data} : port_acc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active       <= 1'b0;
            accept       <= 1'b0;
            byte_cnt     <= 4'd0;
            delay_acc    <= 24'd0;
            count_acc    <= 32'd0;
            port_acc     <= 16'd0;
            start        <= 1'b0;
            dst_mac      <= 48'd0;
            dst_ip       <= 32'd0;
            dst_port     <= 16'd0;
            src_port     <= 16'd0;
            ifg_delay    <= 24'd0;
            packet_count <= 32'd0;
        end else begin
            start <= 1'b0;

            if (udp_rx_valid) begin
                if (!active) begin
                    active    <= 1'b1;
                    accept    <= first_accept;
                    byte_cnt  <= 4'd0;
                    delay_acc <= 24'd0;
                    count_acc <= 32'd0;
                    port_acc  <= 16'd0;
                end

                if (this_accept) begin
                    byte_cnt  <= byte_cnt_next;
                    delay_acc <= delay_next;
                    count_acc <= count_next;
                    port_acc  <= port_next;
                end

                if (udp_rx_last) begin
                    if (this_accept) begin
                        start        <= 1'b1;
                        dst_mac      <= udp_rx_src_mac;
                        dst_ip       <= udp_rx_src_ip;
                        dst_port     <= (byte_cnt_next >= 4'd9 && port_next != 16'd0) ?
                                        port_next : udp_rx_src_port;
                        src_port     <= udp_rx_dst_port;
                        ifg_delay    <= (byte_cnt_next >= 4'd3) ? delay_next : 24'd0;
                        packet_count <= (byte_cnt_next >= 4'd7 && count_next != 32'd0) ?
                                        count_next : DEFAULT_COUNT;
                    end
                    active <= 1'b0;
                    accept <= 1'b0;
                    byte_cnt <= 4'd0;
                end
            end
        end
    end

endmodule
