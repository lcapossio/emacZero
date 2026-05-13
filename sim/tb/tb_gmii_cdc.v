// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_gmii_cdc.v - Testbench for gmii_cdc.v
// Loopback: TX GMII (sys_clk) -> FIFO -> media_clk GMII -> loopback ->
//           FIFO -> RX GMII (sys_clk). Verify frame integrity.
// =============================================================================
`timescale 1ns / 1ps

module tb_gmii_cdc;

    // ---- Clocks ----
    reg sys_clk;
    reg media_clk;
    reg sys_rst_n;

    initial sys_clk   = 0;
    initial media_clk = 0;
    always #5   sys_clk   = ~sys_clk;    // 100 MHz
    always #4   media_clk = ~media_clk;   // 125 MHz

    // ---- TX side (sys_clk domain) ----
    reg  [7:0]  tx_data;
    reg         tx_en;
    reg         tx_er;

    // ---- Media-side GMII (loopback: TX out -> RX in) ----
    wire [7:0]  media_txd;
    wire        media_tx_en;
    wire        media_tx_er;

    // ---- RX side (sys_clk domain) ----
    wire [7:0]  rx_data;
    wire        rx_dv;
    wire        rx_er;

    wire        tx_busy;
    wire [11:0] tx_fifo_level;

    gmii_cdc uut (
        .sys_clk        (sys_clk),
        .sys_rst_n      (sys_rst_n),
        .media_clk      (media_clk),
        .media_rx_clk   (media_clk),
        .cfg_speed      (2'b00),  // 1G default

        // TX from MAC
        .gmii_txd_in    (tx_data),
        .gmii_tx_en_in  (tx_en),
        .gmii_tx_er_in  (tx_er),
        // RX to MAC
        .gmii_rxd_out   (rx_data),
        .gmii_rx_dv_out (rx_dv),
        .gmii_rx_er_out (rx_er),
        // Media-side TX (looped back to RX)
        .gmii_txd_out   (media_txd),
        .gmii_tx_en_out (media_tx_en),
        .gmii_tx_er_out (media_tx_er),
        // Media-side RX (from loopback)
        .gmii_rxd_in    (media_txd),
        .gmii_rx_dv_in  (media_tx_en),
        .gmii_rx_er_in  (media_tx_er),
        // Status
        .tx_busy        (tx_busy),
        .tx_fifo_level  (tx_fifo_level)
    );

    // ---- TX frame injection (sys_clk domain) ----
    integer i;
    integer frame_len;
    integer pass_cnt, fail_cnt;

    // ---- RX capture ----
    reg [7:0] rx_buf [0:2047];
    integer   rx_idx;
    integer   rx_frame_cnt;
    reg       rx_capturing;

    always @(posedge sys_clk) begin
        if (!sys_rst_n) begin
            rx_idx        <= 0;
            rx_frame_cnt  <= 0;
            rx_capturing  <= 0;
        end else begin
            if (rx_dv) begin
                rx_buf[rx_idx] <= rx_data;
                rx_idx         <= rx_idx + 1;
                rx_capturing   <= 1;
            end else if (rx_capturing) begin
                rx_frame_cnt  <= rx_frame_cnt + 1;
                rx_capturing  <= 0;
            end
        end
    end

    task send_frame;
        input integer len;
        integer k;
        begin
            @(negedge sys_clk);
            for (k = 0; k < len; k = k + 1) begin
                tx_data = k[7:0];
                tx_en   = 1;
                tx_er   = 0;
                @(negedge sys_clk);
            end
            tx_en   = 0;
            tx_data = 0;
        end
    endtask

    task wait_rx_frame;
        input integer expected_cnt;
        integer timeout;
        begin
            timeout = 0;
            while (rx_frame_cnt < expected_cnt && timeout < 50000) begin
                @(posedge sys_clk);
                timeout = timeout + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("tb_gmii_cdc.vcd");
        $dumpvars(0, tb_gmii_cdc);

        pass_cnt = 0;
        fail_cnt = 0;

        sys_rst_n = 0;
        tx_data   = 0;
        tx_en     = 0;
        tx_er     = 0;
        #100;
        sys_rst_n = 1;
        #200;

        // =================================================================
        // Test 1: Single 64-byte frame loopback
        // =================================================================
        frame_len = 64;
        rx_idx = 0;
        rx_frame_cnt = 0;

        send_frame(frame_len);
        wait_rx_frame(1);

        // Verify
        if (rx_frame_cnt == 1 && rx_idx == frame_len) begin
            $display("PASS: frame_1 length = %0d", rx_idx);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: frame_1 rx_cnt=%0d rx_idx=%0d, expected cnt=1 len=%0d",
                     rx_frame_cnt, rx_idx, frame_len);
            fail_cnt = fail_cnt + 1;
        end

        // Verify data integrity
        begin : check_data_1
            integer bad;
            bad = 0;
            for (i = 0; i < frame_len; i = i + 1) begin
                if (rx_buf[i] !== i[7:0]) begin
                    if (bad < 5)
                        $display("  byte[%0d] got 0x%02x, expected 0x%02x",
                                 i, rx_buf[i], i[7:0]);
                    bad = bad + 1;
                end
            end
            if (bad == 0) begin
                $display("PASS: frame_1 data integrity");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: frame_1 data mismatch (%0d bytes wrong)", bad);
                fail_cnt = fail_cnt + 1;
            end
        end

        #500;

        // =================================================================
        // Test 2: 1500-byte frame (near max Ethernet)
        // =================================================================
        frame_len = 1500;
        rx_idx = 0;
        rx_frame_cnt = 0;

        send_frame(frame_len);
        wait_rx_frame(1);

        if (rx_frame_cnt == 1 && rx_idx == frame_len) begin
            $display("PASS: frame_2 length = %0d", rx_idx);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: frame_2 rx_cnt=%0d rx_idx=%0d, expected cnt=1 len=%0d",
                     rx_frame_cnt, rx_idx, frame_len);
            fail_cnt = fail_cnt + 1;
        end

        begin : check_data_2
            integer bad;
            bad = 0;
            for (i = 0; i < frame_len; i = i + 1)
                if (rx_buf[i] !== i[7:0]) bad = 1;
            if (!bad) begin
                $display("PASS: frame_2 data integrity");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: frame_2 data mismatch");
                fail_cnt = fail_cnt + 1;
            end
        end

        #500;

        // =================================================================
        // Test 3: Back-to-back short frames
        // =================================================================
        rx_idx = 0;
        rx_frame_cnt = 0;

        send_frame(10);
        #200;
        send_frame(20);
        wait_rx_frame(2);

        if (rx_frame_cnt == 2) begin
            $display("PASS: back_to_back 2 frames received");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: back_to_back rx_cnt=%0d expected 2", rx_frame_cnt);
            fail_cnt = fail_cnt + 1;
        end

        if (rx_idx == 30) begin
            $display("PASS: back_to_back total bytes = %0d", rx_idx);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: back_to_back total bytes = %0d, expected 30", rx_idx);
            fail_cnt = fail_cnt + 1;
        end

        // =================================================================
        // Summary
        // =================================================================
        #100;
        if (fail_cnt == 0) begin
            $display("PASS: %0d tests passed", pass_cnt);
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        end
        $finish;
    end

endmodule
