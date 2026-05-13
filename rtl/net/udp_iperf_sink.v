// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// udp_iperf_sink.v - Passive iperf2 UDP receiver/stat counter
//
// Consumes UDP payload bytes from net_rx for the selected iperf sink port.
// Parses the first 12 payload bytes as iperf2's UDP_datagram header:
//   bytes 0..3  signed packet id, big-endian
//   bytes 4..7  tv_sec  (ignored)
//   bytes 8..11 tv_usec (ignored)
//
// The module intentionally does not try to emit iperf's server report. It is a
// hardware-side counter that lets the host send ordinary iperf UDP traffic and
// then query FPGA-observed packet/byte/loss stats through udp_stats_reply.v.
// Verilog 2001
// =============================================================================

module udp_iperf_sink #(
    parameter [15:0] LISTEN_PORT = 16'd0
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire [7:0]  udp_rx_data,
    input  wire        udp_rx_valid,
    input  wire        udp_rx_last,
    input  wire [31:0] udp_rx_src_ip,
    input  wire [15:0] udp_rx_src_port,
    input  wire [15:0] udp_rx_dst_port,
    input  wire [15:0] udp_rx_length,

    input  wire        clear_stats,

    output reg  [31:0] stat_packets,
    output reg  [31:0] stat_bytes,
    output reg  [31:0] stat_first_seq,
    output reg  [31:0] stat_last_seq,
    output reg  [31:0] stat_seq_gaps,
    output reg  [31:0] stat_out_of_order,
    output reg  [31:0] stat_final_packets,
    output reg  [31:0] stat_last_src_ip,
    output reg  [15:0] stat_last_src_port
);

    reg [15:0] payload_cnt;
    reg [31:0] seq_shift;
    reg [31:0] pkt_seq;
    reg [15:0] pkt_payload_len;
    reg        pkt_has_header;
    reg        have_seq;
    reg        rx_accept;

    wire first_payload_byte = (payload_cnt == 16'd0);
    wire first_accept = (LISTEN_PORT == 16'd0) ||
                        (udp_rx_dst_port == LISTEN_PORT);
    wire this_accept = first_payload_byte ? first_accept : rx_accept;
    wire [31:0] seq_next =
        (payload_cnt < 16'd4) ? {seq_shift[23:0], udp_rx_data} : seq_shift;
    wire        pkt_has_header_next = pkt_has_header ||
                                      (payload_cnt == 16'd3);
    wire [31:0] pkt_seq_next =
        (payload_cnt == 16'd3) ? seq_next : pkt_seq;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            payload_cnt        <= 16'd0;
            seq_shift          <= 32'd0;
            pkt_seq            <= 32'd0;
            pkt_payload_len    <= 16'd0;
            pkt_has_header     <= 1'b0;
            have_seq           <= 1'b0;
            rx_accept          <= 1'b0;
            stat_packets       <= 32'd0;
            stat_bytes         <= 32'd0;
            stat_first_seq     <= 32'd0;
            stat_last_seq      <= 32'd0;
            stat_seq_gaps      <= 32'd0;
            stat_out_of_order  <= 32'd0;
            stat_final_packets <= 32'd0;
            stat_last_src_ip   <= 32'd0;
            stat_last_src_port <= 16'd0;
        end else if (clear_stats) begin
            payload_cnt        <= 16'd0;
            seq_shift          <= 32'd0;
            pkt_seq            <= 32'd0;
            pkt_payload_len    <= 16'd0;
            pkt_has_header     <= 1'b0;
            have_seq           <= 1'b0;
            rx_accept          <= 1'b0;
            stat_packets       <= 32'd0;
            stat_bytes         <= 32'd0;
            stat_first_seq     <= 32'd0;
            stat_last_seq      <= 32'd0;
            stat_seq_gaps      <= 32'd0;
            stat_out_of_order  <= 32'd0;
            stat_final_packets <= 32'd0;
            stat_last_src_ip   <= 32'd0;
            stat_last_src_port <= 16'd0;
        end else if (udp_rx_valid) begin
            if (first_payload_byte) begin
                rx_accept <= first_accept;
                pkt_payload_len <= (udp_rx_length >= 16'd8) ?
                                   (udp_rx_length - 16'd8) : 16'd0;
            end

            if (!this_accept) begin
                if (udp_rx_last) begin
                    payload_cnt     <= 16'd0;
                    seq_shift       <= 32'd0;
                    pkt_seq         <= 32'd0;
                    pkt_payload_len <= 16'd0;
                    pkt_has_header  <= 1'b0;
                    rx_accept       <= 1'b0;
                end
            end else begin
                payload_cnt <= payload_cnt + 16'd1;
                if (payload_cnt < 16'd4)
                    seq_shift <= seq_next;
                if (payload_cnt == 16'd3) begin
                    pkt_seq        <= seq_next;
                    pkt_has_header <= 1'b1;
                end

                if (udp_rx_last) begin
                    if (pkt_has_header_next) begin
                        stat_last_src_ip   <= udp_rx_src_ip;
                        stat_last_src_port <= udp_rx_src_port;
                        if (pkt_seq_next[31]) begin
                            stat_final_packets <= stat_final_packets + 32'd1;
                        end else begin
                            stat_packets <= stat_packets + 32'd1;
                            stat_bytes   <= stat_bytes + {16'd0, pkt_payload_len};
                            if (!have_seq) begin
                                have_seq       <= 1'b1;
                                stat_first_seq <= pkt_seq_next;
                                stat_last_seq  <= pkt_seq_next;
                            end else if (pkt_seq_next == stat_last_seq + 32'd1) begin
                                stat_last_seq <= pkt_seq_next;
                            end else if (pkt_seq_next > stat_last_seq + 32'd1) begin
                                stat_seq_gaps <= stat_seq_gaps +
                                                 (pkt_seq_next - stat_last_seq - 32'd1);
                                stat_last_seq <= pkt_seq_next;
                            end else begin
                                stat_out_of_order <= stat_out_of_order + 32'd1;
                            end
                        end
                    end
                    payload_cnt     <= 16'd0;
                    seq_shift       <= 32'd0;
                    pkt_seq         <= 32'd0;
                    pkt_payload_len <= 16'd0;
                    pkt_has_header  <= 1'b0;
                    rx_accept       <= 1'b0;
                end
            end
        end
    end

endmodule
