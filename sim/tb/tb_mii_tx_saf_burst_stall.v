// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_mii_tx_saf_burst_stall.v - Regression for the committed-frame-counter
// wrap. Bursts many SMALL frames back-to-back so more than 15 accumulate in the
// FIFO before the 25 MHz MII side can drain them. If the committed-frame counter
// is too narrow, frame_wr wraps to equal frame_rd, frame_pending reads 0, and
// the framer deadlocks in S_IDLE with a full FIFO - transmitting only a handful
// of frames. A correct design transmits every frame.
// =============================================================================
`timescale 1ns / 1ps

module tb_mii_tx_saf_burst_stall;

    reg clk = 0;      always #5  clk = ~clk;         // 100 MHz sys
    reg mii_clk = 0;  always #20 mii_clk = ~mii_clk; // 25 MHz MII
    reg rst_n = 0;

    localparam integer N_FRAMES  = 80;   // >> FIFO capacity: forces wr_full backpressure
    localparam integer FRAME_LEN = 106;  // 80*106 = 8480 B >> 4096 B FIFO

    reg  [7:0] tdata;
    reg        tvalid = 0;
    reg        tlast  = 0;
    wire       tready;

    wire [3:0]  mii_txd;
    wire        mii_tx_en;
    wire        tx_busy;
    wire [12:0] tx_fifo_level;
    wire        tx_active, tx_byte_stb, tx_frame_done;

    mii_tx_saf #(.MAX_FRAME(1518), .FIFO_ADDR_WIDTH(12)) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .s_axis_tdata  (tdata),
        .s_axis_tvalid (tvalid),
        .s_axis_tready (tready),
        .s_axis_tlast  (tlast),
        .tx_start_ok   (1'b1),
        .mii_tx_clk    (mii_clk),
        .mii_txd       (mii_txd),
        .mii_tx_en     (mii_tx_en),
        .tx_busy       (tx_busy),
        .tx_fifo_level (tx_fifo_level),
        .tx_active     (tx_active),
        .tx_byte_stb   (tx_byte_stb),
        .tx_frame_done (tx_frame_done)
    );

    // ---- Reconstruct MII frames: count them and capture each frame's first
    //      payload byte (wire byte 8, i.e. right after preamble+SFD) to verify
    //      ordering. send_frame stamps byte 0 = frame index.
    reg  en_d = 0;
    reg  nsel = 0;
    reg [3:0] lown = 0;
    integer widx = 0;
    integer rx_frames = 0;
    reg [7:0] rx_first [0:N_FRAMES-1];
    always @(posedge mii_clk or negedge rst_n) begin
        if (!rst_n) begin
            en_d <= 0; nsel <= 0; widx <= 0; rx_frames <= 0;
        end else begin
            en_d <= mii_tx_en;
            if (mii_tx_en) begin
                if (!nsel) begin lown <= mii_txd; nsel <= 1; end
                else begin
                    if (widx == 8 && rx_frames < N_FRAMES)
                        rx_first[rx_frames] <= {mii_txd, lown};  // first payload byte
                    widx <= widx + 1; nsel <= 0;
                end
            end else if (en_d) begin                 // tx_en fell -> frame complete
                rx_frames <= rx_frames + 1;
                widx <= 0; nsel <= 0;
            end
        end
    end

    // ---- Continuous AXIS burst: N_FRAMES frames, no bubbles, back-to-back ----
    // Byte 0 = frame index (order check); remaining bytes = byte index.
    task send_frame;
        input integer plen;
        input integer fidx;
        integer k;
        begin
            k = 0;
            @(negedge clk);
            tvalid = 1; tdata = fidx[7:0]; tlast = (plen == 1);
            while (k < plen) begin
                @(posedge clk);
                if (tvalid && tready) begin
                    k = k + 1;
                    @(negedge clk);
                    if (k == plen) begin
                        tvalid = 0; tlast = 0;   // brief deassert between frames
                    end else begin
                        tdata = k[7:0]; tlast = (k == plen-1);
                    end
                end
            end
        end
    endtask

    integer i;
    integer fail_cnt = 0;
    initial begin
        $dumpfile("tb_mii_tx_saf_burst_stall.vcd");
        $dumpvars(0, tb_mii_tx_saf_burst_stall);

        #200 rst_n = 1;
        #200;

        for (i = 0; i < N_FRAMES; i = i + 1)
            send_frame(FRAME_LEN, i);

        // Drain window: N_FRAMES * ~10.4us/frame at 25 MHz, plus margin.
        #1200000;

        $display("INFO: sent %0d frames, %0d appeared on the MII wire, tx_fifo_level=%0d",
                 N_FRAMES, rx_frames, tx_fifo_level);

        if (rx_frames !== N_FRAMES) begin
            $display("FAIL: only %0d/%0d frames transmitted - framer stalled (committed-frame counter wrap)",
                     rx_frames, N_FRAMES);
            fail_cnt = fail_cnt + 1;
        end else begin
            for (i = 0; i < N_FRAMES; i = i + 1)
                if (rx_first[i] !== i[7:0]) begin
                    $display("FAIL: frame %0d first payload byte = 0x%02x, expected 0x%02x (reorder/corruption)",
                             i, rx_first[i], i[7:0]);
                    fail_cnt = fail_cnt + 1;
                end
        end

        if (fail_cnt == 0) begin
            $display("PASS: all %0d frames transmitted under sustained burst", N_FRAMES);
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAIL: %0d checks failed", fail_cnt);
        end
        $finish;
    end

    // hard timeout guard
    initial begin #4000000; $display("FAIL: timeout"); $finish; end

endmodule
