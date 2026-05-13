// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_udp_blast_trigger.v - Unit test for UDP blast trigger parser
// Verilog 2001
// =============================================================================
`timescale 1ns / 1ps

module tb_udp_blast_trigger;

    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    localparam [15:0] TRIGGER_PORT = 16'd9997;
    localparam [15:0] IPERF_PORT = 16'd5001;
    localparam [31:0] DEFAULT_COUNT = 32'd1000000;
    localparam [47:0] HOST_MAC = 48'h10_20_30_40_50_60;
    localparam [31:0] HOST_IP = 32'hC0_A8_89_01;

    reg  [7:0]  udp_rx_data;
    reg         udp_rx_valid;
    reg         udp_rx_last;
    reg  [47:0] udp_rx_src_mac;
    reg  [31:0] udp_rx_src_ip;
    reg  [15:0] udp_rx_src_port;
    reg  [15:0] udp_rx_dst_port;
    reg         busy;

    wire        start;
    wire [47:0] dst_mac;
    wire [31:0] dst_ip;
    wire [15:0] dst_port;
    wire [15:0] src_port;
    wire [23:0] ifg_delay;
    wire [31:0] packet_count;

    udp_blast_trigger #(
        .TRIGGER_PORT(TRIGGER_PORT),
        .IGNORE_SRC_PORT(IPERF_PORT),
        .DEFAULT_COUNT(DEFAULT_COUNT)
    ) u_dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .udp_rx_data     (udp_rx_data),
        .udp_rx_valid    (udp_rx_valid),
        .udp_rx_last     (udp_rx_last),
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
        .packet_count    (packet_count)
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

    task feed_byte;
        input [7:0] b;
        input last;
        begin
            @(negedge clk);
            udp_rx_data = b;
            udp_rx_valid = 1'b1;
            udp_rx_last = last;
            @(negedge clk);
            udp_rx_valid = 1'b0;
            udp_rx_last = 1'b0;
            udp_rx_data = 8'd0;
        end
    endtask

    task feed_trigger_9;
        input [15:0] dst_p;
        input [15:0] src_p;
        begin
            udp_rx_dst_port = dst_p;
            udp_rx_src_port = src_p;
            feed_byte(8'h00, 1'b0);
            feed_byte(8'h00, 1'b0);
            feed_byte(8'h05, 1'b0);
            feed_byte(8'h00, 1'b0);
            feed_byte(8'h00, 1'b0);
            feed_byte(8'h03, 1'b0);
            feed_byte(8'he8, 1'b0);
            feed_byte(8'h13, 1'b0);
            feed_byte(8'h8a, 1'b1);
            repeat (2) @(posedge clk);
        end
    endtask

    task feed_empty_trigger;
        begin
            udp_rx_dst_port = TRIGGER_PORT;
            udp_rx_src_port = 16'd41000;
            feed_byte(8'h00, 1'b1);
            repeat (2) @(posedge clk);
        end
    endtask

    initial begin
        $dumpfile("tb_udp_blast_trigger.vcd");
        $dumpvars(0, tb_udp_blast_trigger);

        udp_rx_data = 8'd0;
        udp_rx_valid = 1'b0;
        udp_rx_last = 1'b0;
        udp_rx_src_mac = HOST_MAC;
        udp_rx_src_ip = HOST_IP;
        udp_rx_src_port = 16'd40000;
        udp_rx_dst_port = TRIGGER_PORT;
        busy = 1'b0;

        #50;
        rst_n = 1'b1;
        #30;

        feed_trigger_9(TRIGGER_PORT, 16'd40000);
        check("9-byte trigger starts", start == 1'b0); // start was a pulse; outputs latched
        check("dst mac latched", dst_mac == HOST_MAC);
        check("dst ip latched", dst_ip == HOST_IP);
        check("dst port override", dst_port == 16'd5002);
        check("src port trigger", src_port == TRIGGER_PORT);
        check("ifg parsed", ifg_delay == 24'd5);
        check("count parsed", packet_count == 32'd1000);

        feed_empty_trigger;
        check("short trigger default count", packet_count == DEFAULT_COUNT);
        check("short trigger source port", dst_port == 16'd41000);

        feed_trigger_9(16'd9996, 16'd40000);
        check("wrong port ignored", packet_count == DEFAULT_COUNT && dst_port == 16'd41000);

        feed_trigger_9(TRIGGER_PORT, IPERF_PORT);
        check("iperf feedback ignored", packet_count == DEFAULT_COUNT && dst_port == 16'd41000);

        busy = 1'b1;
        feed_trigger_9(TRIGGER_PORT, 16'd40000);
        check("busy ignored", packet_count == DEFAULT_COUNT && dst_port == 16'd41000);

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
