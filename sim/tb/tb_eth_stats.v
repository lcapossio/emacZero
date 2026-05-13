// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_eth_stats.v - Testbench for eth_stats.v
// Tests: basic counting, saturation, clear-on-pulse
// =============================================================================
`timescale 1ns / 1ps

module tb_eth_stats;

    reg         clk;
    reg         rst_n;
    reg         gmii_tx_en;
    reg         gmii_rx_dv;
    reg         tx_frame_done;
    reg         rx_frame_good;
    reg         rx_frame_bad;
    reg         clr_tx;
    reg         clr_rx;

    wire [31:0] tx_frame_cnt;
    wire [31:0] tx_byte_cnt;
    wire [31:0] rx_frame_cnt;
    wire [31:0] rx_byte_cnt;
    wire [31:0] rx_crc_err_cnt;

    integer pass_cnt;
    integer fail_cnt;

    eth_stats uut (
        .clk            (clk),
        .rst_n          (rst_n),
        .gmii_tx_en     (gmii_tx_en),
        .gmii_rx_dv     (gmii_rx_dv),
        .tx_frame_done  (tx_frame_done),
        .rx_frame_good  (rx_frame_good),
        .rx_frame_bad   (rx_frame_bad),
        // Extended RX classification not exercised in this TB
        .rx_stat_done         (1'b0),
        .rx_stat_len          (14'd0),
        .rx_stat_err_fcs      (1'b0),
        .rx_stat_err_align    (1'b0),
        .rx_stat_err_overflow (1'b0),
        .rx_stat_err_oversize (1'b0),
        .rx_stat_is_bcast     (1'b0),
        .rx_stat_is_mcast     (1'b0),
        .tx_frame_cnt   (tx_frame_cnt),
        .tx_byte_cnt    (tx_byte_cnt),
        .rx_frame_cnt   (rx_frame_cnt),
        .rx_byte_cnt    (rx_byte_cnt),
        .rx_crc_err_cnt (rx_crc_err_cnt),
        .rx_err_align_cnt      (),
        .rx_err_overflow_cnt   (),
        .rx_err_oversize_cnt   (),
        .rx_bcast_cnt          (),
        .rx_mcast_cnt          (),
        .rx_size_64_cnt        (),
        .rx_size_65_127_cnt    (),
        .rx_size_128_255_cnt   (),
        .rx_size_256_511_cnt   (),
        .rx_size_512_1023_cnt  (),
        .rx_size_1024_1518_cnt (),
        .rx_size_jumbo_cnt     (),
        .clr_tx         (clr_tx),
        .clr_rx         (clr_rx)
    );

    // Clock: 10 ns period (100 MHz)
    initial clk = 0;
    always #5 clk = ~clk;

    task check;
        input [255:0] name;
        input [31:0]  actual;
        input [31:0]  expected;
        begin
            if (actual === expected) begin
                $display("PASS: %0s = %0d", name, actual);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: %0s = %0d, expected %0d", name, actual, expected);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // Drive stimulus on negedge to avoid race with posedge sampling
    task drive_tx_frame;
        input integer num_bytes;
        integer j;
        begin
            @(negedge clk);
            gmii_tx_en = 1;
            for (j = 0; j < num_bytes; j = j + 1)
                @(negedge clk);
            gmii_tx_en = 0;
            tx_frame_done = 1;
            @(negedge clk);
            tx_frame_done = 0;
        end
    endtask

    task drive_rx_frame;
        input integer num_bytes;
        input         is_bad;
        integer j;
        begin
            @(negedge clk);
            gmii_rx_dv = 1;
            for (j = 0; j < num_bytes; j = j + 1)
                @(negedge clk);
            gmii_rx_dv = 0;
            if (is_bad)
                rx_frame_bad = 1;
            else
                rx_frame_good = 1;
            @(negedge clk);
            rx_frame_bad = 0;
            rx_frame_good = 0;
        end
    endtask

    initial begin
        $dumpfile("tb_eth_stats.vcd");
        $dumpvars(0, tb_eth_stats);

        pass_cnt = 0;
        fail_cnt = 0;

        // Reset
        rst_n = 0;
        gmii_tx_en = 0;
        gmii_rx_dv = 0;
        tx_frame_done = 0;
        rx_frame_good = 0;
        rx_frame_bad = 0;
        clr_tx = 0;
        clr_rx = 0;
        #20;
        rst_n = 1;
        @(posedge clk); #1;

        // -----------------------------------------------------------------
        // Test 1: TX frame and byte counting (10 bytes)
        // -----------------------------------------------------------------
        drive_tx_frame(10);
        @(posedge clk); #1;

        check("tx_byte_cnt after 10B frame", tx_byte_cnt, 32'd10);
        check("tx_frame_cnt after 1 frame", tx_frame_cnt, 32'd1);

        // Second TX frame (5 bytes)
        drive_tx_frame(5);
        @(posedge clk); #1;

        check("tx_byte_cnt after 10+5B", tx_byte_cnt, 32'd15);
        check("tx_frame_cnt after 2 frames", tx_frame_cnt, 32'd2);

        // -----------------------------------------------------------------
        // Test 2: RX good frame counting (20 bytes)
        // -----------------------------------------------------------------
        drive_rx_frame(20, 0);
        @(posedge clk); #1;

        check("rx_byte_cnt after 20B", rx_byte_cnt, 32'd20);
        check("rx_frame_cnt after 1 good", rx_frame_cnt, 32'd1);
        check("rx_crc_err_cnt is 0", rx_crc_err_cnt, 32'd0);

        // -----------------------------------------------------------------
        // Test 3: RX bad frame counting (8 bytes)
        // -----------------------------------------------------------------
        drive_rx_frame(8, 1);
        @(posedge clk); #1;

        check("rx_byte_cnt after 20+8B", rx_byte_cnt, 32'd28);
        check("rx_frame_cnt after 1good+1bad", rx_frame_cnt, 32'd2);
        check("rx_crc_err_cnt after 1 bad", rx_crc_err_cnt, 32'd1);

        // -----------------------------------------------------------------
        // Test 4: Clear TX counters
        // -----------------------------------------------------------------
        @(negedge clk);
        clr_tx = 1;
        @(negedge clk);
        clr_tx = 0;
        @(posedge clk); #1;

        check("tx_frame_cnt after clr_tx", tx_frame_cnt, 32'd0);
        check("tx_byte_cnt after clr_tx", tx_byte_cnt, 32'd0);
        check("rx_frame_cnt unaffected", rx_frame_cnt, 32'd2);

        // -----------------------------------------------------------------
        // Test 5: Clear RX counters
        // -----------------------------------------------------------------
        @(negedge clk);
        clr_rx = 1;
        @(negedge clk);
        clr_rx = 0;
        @(posedge clk); #1;

        check("rx_frame_cnt after clr_rx", rx_frame_cnt, 32'd0);
        check("rx_byte_cnt after clr_rx", rx_byte_cnt, 32'd0);
        check("rx_crc_err_cnt after clr_rx", rx_crc_err_cnt, 32'd0);

        // -----------------------------------------------------------------
        // Test 6: Saturation
        // -----------------------------------------------------------------
        force uut.tx_frame_cnt = 32'hFFFFFFFE;
        @(posedge clk); #1;
        release uut.tx_frame_cnt;

        @(negedge clk);
        tx_frame_done = 1;
        @(negedge clk);
        tx_frame_done = 0;
        @(posedge clk); #1;

        check("tx_frame_cnt at max", tx_frame_cnt, 32'hFFFFFFFF);

        // One more increment should stay at max
        @(negedge clk);
        tx_frame_done = 1;
        @(negedge clk);
        tx_frame_done = 0;
        @(posedge clk); #1;

        check("tx_frame_cnt saturated", tx_frame_cnt, 32'hFFFFFFFF);

        // -----------------------------------------------------------------
        // Summary
        // -----------------------------------------------------------------
        #10;
        if (fail_cnt == 0) begin
            $display("PASS: %0d tests passed", pass_cnt);
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        end
        $finish;
    end

endmodule
