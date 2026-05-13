// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_udp_stats_reply.v - Unit test for binary UDP stats responder
// Verilog 2001
// =============================================================================
`timescale 1ns / 1ps

module tb_udp_stats_reply;

    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    localparam [47:0] OUR_MAC = 48'h02_00_00_00_00_01;
    localparam [31:0] OUR_IP  = 32'hC0_A8_89_C8;
    localparam [47:0] HOST_MAC = 48'h10_20_30_40_50_60;
    localparam [31:0] HOST_IP  = 32'hC0_A8_89_01;
    localparam [15:0] STATS_PORT = 16'd9996;
    localparam [15:0] HOST_PORT  = 16'd50222;

    reg  [7:0]  udp_rx_data;
    reg         udp_rx_valid;
    reg         udp_rx_last;
    reg  [31:0] udp_rx_src_ip;
    reg  [15:0] udp_rx_src_port;
    reg  [15:0] udp_rx_dst_port;
    reg  [47:0] rx_src_mac;

    wire        clear_stats;
    wire [7:0]  tx_data;
    wire        tx_valid;
    wire        tx_last;
    reg         tx_ready;
    wire        tx_start;

    udp_stats_reply u_dut (
        .clk                (clk),
        .rst_n              (rst_n),
        .our_mac            (OUR_MAC),
        .our_ip             (OUR_IP),
        .stats_port         (STATS_PORT),
        .udp_rx_data        (udp_rx_data),
        .udp_rx_valid       (udp_rx_valid),
        .udp_rx_last        (udp_rx_last),
        .udp_rx_src_ip      (udp_rx_src_ip),
        .udp_rx_src_port    (udp_rx_src_port),
        .udp_rx_dst_port    (udp_rx_dst_port),
        .rx_src_mac         (rx_src_mac),
        .stat_packets       (32'h00000011),
        .stat_bytes         (32'h00002222),
        .stat_first_seq     (32'h00000001),
        .stat_last_seq      (32'h00000010),
        .stat_seq_gaps      (32'h00000002),
        .stat_out_of_order  (32'h00000003),
        .stat_final_packets (32'h00000004),
        .stat_last_src_ip   (HOST_IP),
        .stat_last_src_port (16'd54321),
        .clear_stats        (clear_stats),
        .tx_data            (tx_data),
        .tx_valid           (tx_valid),
        .tx_last            (tx_last),
        .tx_ready           (tx_ready),
        .tx_start           (tx_start)
    );

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task check;
        input [255:0] name;
        input cond;
        begin
            if (cond) begin
                $display("PASS: %0s", name);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: %0s", name);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task check_byte;
        input [255:0] name;
        input integer idx;
        input [7:0] actual;
        input [7:0] expected;
        begin
            if (actual === expected) begin
                $display("PASS: %0s[%0d] = 0x%02x", name, idx, actual);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: %0s[%0d] = 0x%02x expected 0x%02x",
                         name, idx, actual, expected);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task feed_query;
        input [7:0] q;
        input [15:0] dst_port;
        begin
            @(negedge clk);
            udp_rx_data = q;
            udp_rx_dst_port = dst_port;
            udp_rx_valid = 1'b1;
            udp_rx_last = 1'b1;
            @(negedge clk);
            udp_rx_valid = 1'b0;
            udp_rx_last = 1'b0;
            udp_rx_data = 8'd0;
        end
    endtask

    reg [7:0] tx_buf [0:127];
    integer tx_count;
    reg tx_done;
    reg tx_start_seen;
    reg clear_seen;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_count <= 0;
            tx_done <= 1'b0;
            tx_start_seen <= 1'b0;
            clear_seen <= 1'b0;
        end else begin
            if (tx_start)
                tx_start_seen <= 1'b1;
            if (clear_stats)
                clear_seen <= 1'b1;
            if (tx_valid && tx_ready) begin
                if (tx_count < 128)
                    tx_buf[tx_count] <= tx_data;
                tx_count <= tx_count + 1;
                if (tx_last)
                    tx_done <= 1'b1;
            end
        end
    end

    task clear_capture;
        begin
            @(negedge clk);
            tx_count = 0;
            tx_done = 1'b0;
            tx_start_seen = 1'b0;
            clear_seen = 1'b0;
        end
    endtask

    integer i;
    initial begin
        $dumpfile("tb_udp_stats_reply.vcd");
        $dumpvars(0, tb_udp_stats_reply);

        udp_rx_data = 8'd0;
        udp_rx_valid = 1'b0;
        udp_rx_last = 1'b0;
        udp_rx_src_ip = HOST_IP;
        udp_rx_src_port = HOST_PORT;
        udp_rx_dst_port = STATS_PORT;
        rx_src_mac = HOST_MAC;
        tx_ready = 1'b1;

        #50;
        rst_n = 1'b1;
        #30;

        feed_query(8'h47, STATS_PORT); // G
        repeat (120) @(posedge clk);
        check("G tx_start", tx_start_seen);
        check("G tx_done", tx_done);
        check("G no clear", !clear_seen);
        check("frame length", tx_count == 86);
        check_byte("dst mac", 0, tx_buf[0], HOST_MAC[47:40]);
        check_byte("eth type", 12, tx_buf[12], 8'h08);
        check_byte("udp src port hi", 34, tx_buf[34], STATS_PORT[15:8]);
        check_byte("udp dst port lo", 37, tx_buf[37], HOST_PORT[7:0]);
        check_byte("magic", 42, tx_buf[42], 8'h49);
        check_byte("magic", 45, tx_buf[45], 8'h30);
        check_byte("packets", 49, tx_buf[49], 8'h11);
        check_byte("done", 82, tx_buf[82], 8'h44);
        check_byte("done", 85, tx_buf[85], 8'h45);

        clear_capture;
        feed_query(8'h43, STATS_PORT); // C
        repeat (120) @(posedge clk);
        check("C clears", clear_seen);
        check("C replies", tx_done);

        clear_capture;
        feed_query(8'h47, STATS_PORT); // G after C must not clear
        repeat (120) @(posedge clk);
        check("G after C no clear", !clear_seen);
        check("G after C replies", tx_done);

        clear_capture;
        feed_query(8'h47, 16'd1234);
        repeat (80) @(posedge clk);
        check("wrong port ignored", !tx_done && !clear_seen);

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
