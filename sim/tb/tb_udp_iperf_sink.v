// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_udp_iperf_sink.v - Unit test for passive iperf2 UDP sink counters
// Verilog 2001
// =============================================================================
`timescale 1ns / 1ps

module tb_udp_iperf_sink;

    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    reg  [7:0]  udp_rx_data;
    reg         udp_rx_valid;
    reg         udp_rx_last;
    reg  [31:0] udp_rx_src_ip;
    reg  [15:0] udp_rx_src_port;
    reg  [15:0] udp_rx_dst_port;
    reg  [15:0] udp_rx_length;
    reg         clear_stats;

    wire [31:0] stat_packets;
    wire [31:0] stat_bytes;
    wire [31:0] stat_first_seq;
    wire [31:0] stat_last_seq;
    wire [31:0] stat_seq_gaps;
    wire [31:0] stat_out_of_order;
    wire [31:0] stat_final_packets;
    wire [31:0] stat_last_src_ip;
    wire [15:0] stat_last_src_port;

    udp_iperf_sink #(.LISTEN_PORT(16'd5001)) u_dut (
        .clk                (clk),
        .rst_n              (rst_n),
        .udp_rx_data        (udp_rx_data),
        .udp_rx_valid       (udp_rx_valid),
        .udp_rx_last        (udp_rx_last),
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

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task check32;
        input [255:0] name;
        input [31:0]  actual;
        input [31:0]  expected;
        begin
            if (actual === expected) begin
                $display("PASS: %0s = %0d", name, actual);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: %0s = %0d expected %0d", name, actual, expected);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task feed_pkt;
        input [31:0] seq;
        input integer payload_len;
        integer k;
        reg [7:0] b;
        begin
            @(negedge clk);
            udp_rx_length = payload_len + 8;
            for (k = 0; k < payload_len; k = k + 1) begin
                case (k)
                    0: b = seq[31:24];
                    1: b = seq[23:16];
                    2: b = seq[15:8];
                    3: b = seq[7:0];
                    default: b = k[7:0];
                endcase
                udp_rx_data  = b;
                udp_rx_valid = 1'b1;
                udp_rx_last  = (k == payload_len - 1);
                @(negedge clk);
            end
            udp_rx_data  = 8'd0;
            udp_rx_valid = 1'b0;
            udp_rx_last  = 1'b0;
        end
    endtask

    initial begin
        $dumpfile("tb_udp_iperf_sink.vcd");
        $dumpvars(0, tb_udp_iperf_sink);

        udp_rx_data     = 8'd0;
        udp_rx_valid    = 1'b0;
        udp_rx_last     = 1'b0;
        udp_rx_src_ip   = 32'hC0_A8_89_01;
        udp_rx_src_port = 16'd50123;
        udp_rx_dst_port = 16'd5001;
        udp_rx_length   = 16'd1480;
        clear_stats     = 1'b0;

        #50;
        rst_n = 1'b1;
        #20;

        feed_pkt(32'd0, 1472);
        feed_pkt(32'd1, 1472);
        feed_pkt(32'd3, 1472);
        feed_pkt(32'd2, 1472);
        feed_pkt(32'h80000004, 12);
        repeat (5) @(posedge clk);

        check32("packets", stat_packets, 32'd4);
        check32("bytes", stat_bytes, 32'd5888);
        check32("first_seq", stat_first_seq, 32'd0);
        check32("last_seq", stat_last_seq, 32'd3);
        check32("seq_gaps", stat_seq_gaps, 32'd1);
        check32("out_of_order", stat_out_of_order, 32'd1);
        check32("final_packets", stat_final_packets, 32'd1);
        check32("last_src_ip", stat_last_src_ip, 32'hC0_A8_89_01);
        check32("last_src_port", {16'd0, stat_last_src_port}, 32'd50123);

        @(negedge clk);
        clear_stats = 1'b1;
        @(negedge clk);
        clear_stats = 1'b0;
        repeat (2) @(posedge clk);

        check32("clear packets", stat_packets, 32'd0);
        check32("clear bytes", stat_bytes, 32'd0);

        feed_pkt(32'd7, 4);
        repeat (5) @(posedge clk);
        check32("4-byte header packet", stat_packets, 32'd1);
        check32("4-byte header bytes", stat_bytes, 32'd4);
        check32("4-byte header seq", stat_last_seq, 32'd7);

        udp_rx_dst_port = 16'd5002;
        feed_pkt(32'd8, 4);
        udp_rx_dst_port = 16'd5001;
        repeat (5) @(posedge clk);
        check32("wrong port ignored", stat_packets, 32'd1);

        if (fail_cnt == 0) begin
            $display("PASS: %0d tests passed", pass_cnt);
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        end
        $finish;
    end

    initial begin
        #200_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
