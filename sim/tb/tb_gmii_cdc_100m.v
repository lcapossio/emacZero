// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_gmii_cdc_100m.v - 100M rate-adaptation test for gmii_cdc TX path
// Verifies the TX paths emit data at the correct slowed rate when
// cfg_speed = 01 (100 Mbps). RX path correctness at 100M is handled by
// rgmii_if's nibble pairing and is tested separately.
// Verilog 2001
// =============================================================================

`timescale 1ns/1ps

module tb_gmii_cdc_100m;
    reg sys_clk = 0;
    reg media_clk = 0;
    reg sys_rst_n = 0;

    always #5 sys_clk   = ~sys_clk;    // 100 MHz
    always #4 media_clk = ~media_clk;  // 125 MHz

    // TX (sys-clk side)
    reg  [7:0] tx_data;
    reg        tx_en;
    reg        tx_er;

    // RX (sys-clk side) — unused in this test
    wire [7:0] rx_data;
    wire       rx_dv;
    wire       rx_er;

    // Media-clock side TX (observed)
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
        .cfg_speed      (2'b01),       // 100M

        .gmii_txd_in    (tx_data),
        .gmii_tx_en_in  (tx_en),
        .gmii_tx_er_in  (tx_er),

        .gmii_rxd_out   (rx_data),
        .gmii_rx_dv_out (rx_dv),
        .gmii_rx_er_out (rx_er),

        .gmii_txd_out   (media_txd),
        .gmii_tx_en_out (media_tx_en),
        .gmii_tx_er_out (media_tx_er),

        // Tie off media RX (we're only checking TX behaviour here)
        .gmii_rxd_in    (8'd0),
        .gmii_rx_dv_in  (1'b0),
        .gmii_rx_er_in  (1'b0),

        .tx_busy        (tx_busy),
        .tx_fifo_level  (tx_fifo_level)
    );

    integer pass_cnt = 0, fail_cnt = 0;

    // ---- Track media-clock TX timing ----
    integer media_tx_cycles_high;
    integer distinct_bytes;
    reg [7:0] last_byte;
    reg       saw_first;
    reg [7:0] captured [0:63];
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
                    if (cap_idx < 64) captured[cap_idx] <= media_txd;
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
        $dumpfile("tb_gmii_cdc_100m.vcd");
        $dumpvars(0, tb_gmii_cdc_100m);

        tx_data = 0; tx_en = 0; tx_er = 0;
        sys_rst_n = 0;
        #100;
        sys_rst_n = 1;
        #200;

        // Send a 32-byte frame with incrementing data
        begin : send
            integer i;
            @(negedge sys_clk);
            for (i = 0; i < 32; i = i + 1) begin
                tx_data = i[7:0] | 8'h80;  // make pattern non-zero so the
                                           // distinct-byte detector is robust
                tx_en   = 1'b1;
                tx_er   = 1'b0;
                @(negedge sys_clk);
            end
            tx_en   = 1'b0;
            tx_data = 8'd0;
        end

        // Wait long enough for the media-side TX to fully drain.
        // 32 bytes * 5 media_clk cycles/byte = 160 cycles. Plus some startup.
        // Add generous margin.
        #5000;

        // ---------------------------------------------------------------------
        // Verify: 32 distinct bytes appeared on the media side
        // ---------------------------------------------------------------------
        if (distinct_bytes == 32) begin
            $display("PASS: 32 distinct bytes seen on media side");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: %0d distinct bytes seen (expected 32)", distinct_bytes);
            fail_cnt = fail_cnt + 1;
        end

        // ---------------------------------------------------------------------
        // Verify: data integrity through the rate adapter
        // ---------------------------------------------------------------------
        begin : data_check
            integer i; reg bad;
            bad = 0;
            for (i = 0; i < 32; i = i + 1) begin
                if (captured[i] !== (i[7:0] | 8'h80)) begin
                    $display("  byte[%0d] got 0x%02x, expected 0x%02x",
                             i, captured[i], (i[7:0] | 8'h80));
                    bad = 1;
                end
            end
            if (!bad) begin
                $display("PASS: data integrity through rate adapter");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: data corrupted through rate adapter");
                fail_cnt = fail_cnt + 1;
            end
        end

        // ---------------------------------------------------------------------
        // Verify pacing: at 100M (1 byte / 10 cycles), 32 bytes spans
        // ~32*10 = 320 cycles. tx_en may stay high during inter-byte hold
        // and end-of-frame transition. Allow 280..340 as a sanity range.
        // ---------------------------------------------------------------------
        if (media_tx_cycles_high >= 280 && media_tx_cycles_high <= 340) begin
            $display("PASS: media TX active %0d cycles (~320 expected for 100M)",
                     media_tx_cycles_high);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: media TX active %0d cycles, expected ~320",
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
        #500000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule
