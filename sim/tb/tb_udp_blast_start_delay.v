// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_udp_blast_start_delay.v - UDP blast start delay and sequence reset test
// Verilog 2001
// =============================================================================
`timescale 1ns / 1ps

module tb_udp_blast_start_delay;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg        enable;
    wire [7:0] tx_data;
    wire       tx_valid;
    wire       tx_last;
    wire       tx_start;
    wire [31:0] pkts_sent;
    wire       pkt_done_pulse;

    reg [15:0] byte_idx;
    reg [31:0] iperf_id;
    reg [31:0] iperf_usec;
    reg        got_id;
    reg [31:0] first_id;
    reg [31:0] second_id;
    integer    start_cycle;
    integer    first_start_cycle;
    integer    second_start_cycle;

    udp_blast #(
        .START_DELAY_CYCLES(32'd4)
    ) u_dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .our_mac          (48'h02_00_00_00_00_01),
        .our_ip           (32'hC0_A8_89_C8),
        .dst_mac          (48'h02_00_00_00_00_02),
        .dst_ip           (32'hC0_A8_89_01),
        .dst_port         (16'd5002),
        .src_port         (16'd9997),
        .payload_size     (14'd16),
        .enable           (enable),
        .inter_frame_delay(24'd0),
        .pkts_sent        (pkts_sent),
        .pkt_done_pulse   (pkt_done_pulse),
        .tx_data          (tx_data),
        .tx_valid         (tx_valid),
        .tx_last          (tx_last),
        .tx_ready         (1'b1),
        .tx_start         (tx_start)
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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || !enable) begin
            byte_idx <= 16'd0;
            iperf_id <= 32'd0;
            iperf_usec <= 32'd0;
            got_id <= 1'b0;
        end else if (tx_valid) begin
            if (byte_idx >= 16'd42 && byte_idx < 16'd46)
                iperf_id <= {iperf_id[23:0], tx_data};
            if (byte_idx >= 16'd50 && byte_idx < 16'd54)
                iperf_usec <= {iperf_usec[23:0], tx_data};
            if (byte_idx == 16'd53)
                got_id <= 1'b1;
            if (tx_last)
                byte_idx <= 16'd0;
            else
                byte_idx <= byte_idx + 16'd1;
        end
    end

    initial begin
        $dumpfile("tb_udp_blast_start_delay.vcd");
        $dumpvars(0, tb_udp_blast_start_delay);

        enable = 1'b0;
        start_cycle = 0;
        first_start_cycle = -1;
        second_start_cycle = -1;
        first_id = 32'hffff_ffff;
        second_id = 32'hffff_ffff;

        #50;
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        start_cycle = 0;
        enable = 1'b1;
        while (!tx_start && start_cycle < 20) begin
            @(posedge clk);
            start_cycle = start_cycle + 1;
        end
        first_start_cycle = start_cycle;
        check("first burst waits for start delay", first_start_cycle >= 5);

        wait (got_id);
        first_id = iperf_id;
        check("first burst starts at sequence zero", first_id == 32'd0);
        check("first burst has valid iperf usec", iperf_usec < 32'd1000000);

        wait (pkt_done_pulse);
        enable = 1'b0;
        @(posedge clk);
        @(posedge clk);

        got_id = 1'b0;
        iperf_id = 32'd0;
        iperf_usec = 32'd0;
        start_cycle = 0;
        enable = 1'b1;
        while (!tx_start && start_cycle < 20) begin
            @(posedge clk);
            start_cycle = start_cycle + 1;
        end
        second_start_cycle = start_cycle;
        check("second burst waits for start delay", second_start_cycle >= 5);

        wait (got_id);
        second_id = iperf_id;
        check("second burst resets sequence zero", second_id == 32'd0);
        check("second burst has valid iperf usec", iperf_usec < 32'd1000000);

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
