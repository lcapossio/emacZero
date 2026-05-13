// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_gmii_cdc_10m.v - 10M rate-adaptation test for gmii_cdc TX path
// At cfg_speed=10 (10 Mbps), media_clk @ 125 MHz produces 1 byte every
// 100 cycles (1 byte per 800 ns). Verifies pacing and integrity.
// Verilog 2001
// =============================================================================

`timescale 1ns/1ps

module tb_gmii_cdc_10m;
    reg sys_clk = 0;
    reg media_clk = 0;
    reg sys_rst_n = 0;

    always #5 sys_clk   = ~sys_clk;    // 100 MHz
    always #4 media_clk = ~media_clk;  // 125 MHz

    reg  [7:0] tx_data;
    reg        tx_en;
    reg        tx_er;

    wire [7:0] rx_data;
    wire       rx_dv;
    wire       rx_er;

    wire [7:0] media_txd;
    wire       media_tx_en;
    wire       media_tx_er;

    wire        tx_busy;
    wire [11:0] tx_fifo_level;

    gmii_cdc uut (
        .sys_clk        (sys_clk),
        .sys_rst_n      (sys_rst_n),
        .media_clk      (media_clk),
        .media_rx_clk   (media_clk),
        .cfg_speed      (2'b10),       // 10M

        .gmii_txd_in    (tx_data),
        .gmii_tx_en_in  (tx_en),
        .gmii_tx_er_in  (tx_er),

        .gmii_rxd_out   (rx_data),
        .gmii_rx_dv_out (rx_dv),
        .gmii_rx_er_out (rx_er),

        .gmii_txd_out   (media_txd),
        .gmii_tx_en_out (media_tx_en),
        .gmii_tx_er_out (media_tx_er),

        .gmii_rxd_in    (8'd0),
        .gmii_rx_dv_in  (1'b0),
        .gmii_rx_er_in  (1'b0),

        .tx_busy        (tx_busy),
        .tx_fifo_level  (tx_fifo_level)
    );

    integer pass_cnt = 0, fail_cnt = 0;

    // Track unique bytes appearing on media-side TX
    integer media_tx_cycles_high;
    integer distinct_bytes;
    reg [7:0] last_byte;
    reg       saw_first;
    reg [7:0] captured [0:31];
    integer   cap_idx;

    always @(posedge media_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            media_tx_cycles_high <= 0;
            distinct_bytes       <= 0;
            saw_first            <= 1'b0;
            last_byte            <= 8'd0;
            cap_idx              <= 0;
        end else begin
            if (media_tx_en) begin
                media_tx_cycles_high <= media_tx_cycles_high + 1;
                if (!saw_first || media_txd != last_byte) begin
                    if (cap_idx < 32) captured[cap_idx] <= media_txd;
                    cap_idx        <= cap_idx + 1;
                    distinct_bytes <= distinct_bytes + 1;
                    last_byte      <= media_txd;
                    saw_first      <= 1'b1;
                end
            end else begin
                saw_first <= 1'b0;
            end
        end
    end

    initial begin
        $dumpfile("tb_gmii_cdc_10m.vcd");
        $dumpvars(0, tb_gmii_cdc_10m);

        tx_data = 0; tx_en = 0; tx_er = 0;
        sys_rst_n = 0;
        #100;
        sys_rst_n = 1;
        #200;

        // Send a small 8-byte frame (10M is slow — keep it short to bound sim time)
        begin : send
            integer i;
            @(negedge sys_clk);
            for (i = 0; i < 8; i = i + 1) begin
                tx_data = i[7:0] | 8'h80;
                tx_en   = 1'b1;
                tx_er   = 1'b0;
                @(negedge sys_clk);
            end
            tx_en   = 1'b0;
            tx_data = 8'd0;
        end

        // 8 bytes * 100 media_clk cycles/byte = 800 cycles = 6.4us. Wait 12us.
        #12000;

        // ---------------------------------------------------------------------
        // Verify: 8 distinct bytes on media side
        // ---------------------------------------------------------------------
        if (distinct_bytes == 8) begin
            $display("PASS: 8 distinct bytes seen at 10M media side");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: %0d distinct bytes (expected 8)", distinct_bytes);
            fail_cnt = fail_cnt + 1;
        end

        // ---------------------------------------------------------------------
        // Verify: data integrity through 10M rate adapter
        // ---------------------------------------------------------------------
        begin : data_check
            integer i; reg bad;
            bad = 0;
            for (i = 0; i < 8; i = i + 1) begin
                if (captured[i] !== (i[7:0] | 8'h80)) begin
                    $display("  byte[%0d] got 0x%02x, expected 0x%02x",
                             i, captured[i], (i[7:0] | 8'h80));
                    bad = 1;
                end
            end
            if (!bad) begin
                $display("PASS: 10M data integrity");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: 10M data corrupted");
                fail_cnt = fail_cnt + 1;
            end
        end

        // ---------------------------------------------------------------------
        // Verify pacing: tx_en spans first pace_tick to last + 1, so
        // (N-1)*K + 1 = 7*100 + 1 = 701. Allow 690..720 sanity range.
        // ---------------------------------------------------------------------
        if (media_tx_cycles_high >= 690 && media_tx_cycles_high <= 720) begin
            $display("PASS: 10M media TX active %0d cycles (~701 expected)",
                     media_tx_cycles_high);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: 10M media TX active %0d cycles, expected ~701",
                     media_tx_cycles_high);
            fail_cnt = fail_cnt + 1;
        end

        if (fail_cnt == 0) begin
            $display("PASS: %0d tests passed", pass_cnt);
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        end
        $finish;
    end

    initial begin
        #2000000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule
