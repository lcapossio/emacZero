// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_udp_echo_backpressure.v - tlast must survive sink back-pressure
//
// Companion to tb_udp_blast_backpressure. udp_echo shares the 1-deep AXIS
// output slice used by every L3 frame generator here: src_last is armed one
// cycle ahead of the final byte, and the slice samples src_* only while
// src_ready is high. A tlast cleared while the sink is stalled on exactly that
// beat is lost - the reply then ends with no tlast at all.
//
// This is also udp_echo's first directed testbench; until now it was covered
// by lint only.
// Verilog 2001
// =============================================================================
`timescale 1ns / 1ps

module tb_udp_echo_backpressure;

    localparam [47:0] OUR_MAC   = 48'h02_00_00_00_00_01;
    localparam [31:0] OUR_IP    = 32'hC0_A8_89_C8;
    localparam [47:0] REQ_MAC   = 48'h02_00_00_00_00_02;
    localparam [31:0] REQ_IP    = 32'hC0_A8_89_01;
    localparam [15:0] SRC_PORT  = 16'd50222;
    localparam [15:0] DST_PORT  = 16'd7;
    localparam [15:0]  PAY_LEN  = 16'd16;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg  [7:0]  udp_rx_data;
    reg         udp_rx_valid;
    reg         udp_rx_last;

    wire [7:0]  tx_data;
    wire        tx_valid;
    wire        tx_last;
    wire        tx_start;

    reg     stall_en   = 1'b0;
    integer stall_at   = 0;
    reg     stall_done = 1'b0;
    reg     cap_clr    = 1'b0;
    integer tx_beat    = 0;
    reg     saw_last   = 1'b0;

    wire do_stall = stall_en && tx_valid && !stall_done && (tx_beat == stall_at);
    wire tx_ready = !do_stall;

    udp_echo #(
        .BUF_SIZE   (1024),
        .LISTEN_PORT(16'd0)          // 0 = echo every UDP payload
    ) u_dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .our_mac         (OUR_MAC),
        .our_ip          (OUR_IP),
        .udp_rx_data     (udp_rx_data),
        .udp_rx_valid    (udp_rx_valid),
        .udp_rx_last     (udp_rx_last),
        .udp_rx_src_ip   (REQ_IP),
        .udp_rx_src_port (SRC_PORT),
        .udp_rx_dst_port (DST_PORT),
        .udp_rx_length   (16'd8 + PAY_LEN),
        .rx_src_mac      (REQ_MAC),
        .tx_data         (tx_data),
        .tx_valid        (tx_valid),
        .tx_last         (tx_last),
        .tx_ready        (tx_ready),
        .tx_start        (tx_start)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_beat    <= 0;
            saw_last   <= 1'b0;
            stall_done <= 1'b0;
        end else if (cap_clr) begin
            tx_beat    <= 0;
            saw_last   <= 1'b0;
            stall_done <= 1'b0;
        end else begin
            if (do_stall)
                stall_done <= 1'b1;
            if (tx_valid && tx_ready) begin
                tx_beat <= tx_beat + 1;
                if (tx_last)
                    saw_last <= 1'b1;
            end
        end
    end

    task feed_udp;
        integer k;
        begin
            @(negedge clk);
            for (k = 0; k < PAY_LEN; k = k + 1) begin
                udp_rx_data  = k[7:0] + 8'hA0;
                udp_rx_valid = 1'b1;
                udp_rx_last  = (k == PAY_LEN - 1);
                @(negedge clk);
            end
            udp_rx_data  = 8'd0;
            udp_rx_valid = 1'b0;
            udp_rx_last  = 1'b0;
        end
    endtask

    task clear_capture;
        begin
            @(negedge clk);
            cap_clr = 1'b1;
            @(negedge clk);
            cap_clr = 1'b0;
        end
    endtask

    task wait_reply;
        integer w;
        begin
            w = 0;
            while (!saw_last && w < 5000) begin
                @(posedge clk);
                w = w + 1;
            end
        end
    endtask

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task check;
        input [255:0] name;
        input cond;
        begin
            if (cond) begin
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: %0s (stall_at=%0d)", name, stall_at);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    integer s;
    integer ref_len;

    initial begin
        udp_rx_data  = 8'd0;
        udp_rx_valid = 1'b0;
        udp_rx_last  = 1'b0;

        #50; rst_n = 1'b1; #50;

        stall_en = 1'b0;
        clear_capture;
        feed_udp;
        wait_reply;
        ref_len = tx_beat;
        check("reference reply completes", saw_last);
        check("reply is eth+ip+udp+payload", ref_len == 14 + 20 + 8 + PAY_LEN);

        stall_en = 1'b1;
        for (s = 0; s < ref_len; s = s + 1) begin
            stall_at = s;
            clear_capture;
            feed_udp;
            wait_reply;
            check("reply still ends in tlast", saw_last);
            check("reply length unchanged", tx_beat == ref_len);
        end

        if (fail_cnt == 0) begin
            // No per-check "PASS:" lines: the runner counts those, and an
            // 86-position sweep would drown the log. Reporting the total here
            // lets it fall back to parsing the count instead.
            $display("%0d tests passed (%0d stall positions swept)",
                     pass_cnt, ref_len);
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        end
        $finish;
    end

    initial begin
        #2_000_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
