// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_mii_tx_saf_oversize.v - Regression for the uncommitted-data deadlock
// (mii_tx_saf bug #2).
//
// The store-and-forward write side writes every accepted byte into the frame
// FIFO but only "commits" (bumps the committed-frame counter that gates the
// framer) on tlast. If a single contiguous run of bytes with no tlast exceeds
// the FIFO depth - an oversized frame, or several frames merged by a dropped
// tlast upstream - the FIFO fills with uncommitted data, frame_pending never
// rises, the framer parks in S_IDLE, wr_full sticks, and the WHOLE TX path
// deadlocks permanently (observed on hardware: committed==drained, rd_empty=0,
// fifo_level > MAX_FRAME, framer IDLE).
//
// Sequence: normal frame A -> oversized no-tlast run (> FIFO) -> normal frame B.
// A robust design bounds the uncommitted run (force-terminate + drop the tail)
// so B still reaches the wire. A broken design wedges on the oversized run and
// B never transmits.
// =============================================================================
`timescale 1ns / 1ps

module tb_mii_tx_saf_oversize;

    reg clk = 0;      always #5  clk = ~clk;         // 100 MHz sys
    reg mii_clk = 0;  always #20 mii_clk = ~mii_clk; // 25 MHz MII
    reg rst_n = 0;

    localparam integer FIFO_AW   = 12;       // 4096-byte FIFO
    localparam integer OVERSIZE  = 5000;     // > 4096: forces an uncommitted overflow
    localparam [7:0]   A_TAG     = 8'hAA;     // frame A first payload byte
    localparam [7:0]   B_TAG     = 8'hBB;     // frame B first payload byte
    localparam [7:0]   O_TAG     = 8'h50;     // oversized-run first payload byte

    reg  [7:0] tdata;
    reg        tvalid = 0;
    reg        tlast  = 0;
    wire       tready;

    wire [3:0]  mii_txd;
    wire        mii_tx_en;
    wire        tx_busy;
    wire [12:0] tx_fifo_level;
    wire        tx_active, tx_byte_stb, tx_frame_done;
    wire [15:0] dbg_saf;

    mii_tx_saf #(.MAX_FRAME(1518), .FIFO_ADDR_WIDTH(FIFO_AW)) dut (
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
        .tx_frame_done (tx_frame_done),
        .dbg_saf       (dbg_saf)
    );

    // ---- Reconstruct MII frames: capture each wire frame's first payload byte
    //      (wire byte 8, right after the 7-byte preamble + SFD).
    reg  en_d = 0;
    reg  nsel = 0;
    reg [3:0] lown = 0;
    integer widx = 0;
    integer rx_frames = 0;
    reg saw_A = 0;
    reg saw_B = 0;
    reg [7:0] cur_first;
    always @(posedge mii_clk or negedge rst_n) begin
        if (!rst_n) begin
            en_d <= 0; nsel <= 0; widx <= 0; rx_frames <= 0;
            saw_A <= 0; saw_B <= 0;
        end else begin
            en_d <= mii_tx_en;
            if (mii_tx_en) begin
                if (!nsel) begin lown <= mii_txd; nsel <= 1; end
                else begin
                    if (widx == 8) begin
                        cur_first <= {mii_txd, lown};
                        if ({mii_txd, lown} == A_TAG) saw_A <= 1;
                        if ({mii_txd, lown} == B_TAG) saw_B <= 1;
                    end
                    widx <= widx + 1; nsel <= 0;
                end
            end else if (en_d) begin                 // tx_en fell -> frame complete
                rx_frames <= rx_frames + 1;
                widx <= 0; nsel <= 0;
            end
        end
    end

    // ---- AXIS send with a per-call watchdog. On the broken RTL an oversized
    //      run jams the FIFO (wr_full stuck), so tready never returns; the
    //      watchdog lets the test proceed to its verdict instead of hanging.
    integer stall;
    task send_frame;
        input integer plen;
        input [7:0]   tag;      // first payload byte
        input integer set_last; // 1 = terminate with tlast; 0 = NO tlast (oversized)
        integer k;
        begin
            k = 0;
            @(negedge clk);
            tvalid = 1; tdata = tag; tlast = (set_last != 0) && (plen == 1);
            stall = 0;
            while (k < plen && stall < 200000) begin
                @(posedge clk);
                if (tvalid && tready) begin
                    k = k + 1;
                    stall = 0;
                    @(negedge clk);
                    if (k == plen) begin
                        tvalid = 0; tlast = 0;
                    end else begin
                        tdata = (k == 0) ? tag : k[7:0];
                        tlast = (set_last != 0) && (k == plen-1);
                    end
                end else begin
                    stall = stall + 1;
                end
            end
            // If we bailed on the watchdog, drop tvalid so the bus is idle.
            @(negedge clk);
            tvalid = 0; tlast = 0;
        end
    endtask

    integer fail_cnt = 0;
    initial begin
        $dumpfile("tb_mii_tx_saf_oversize.vcd");
        $dumpvars(0, tb_mii_tx_saf_oversize);

        #200 rst_n = 1;
        #200;

        // Frame A: a normal 64-byte frame (sanity: TX works).
        send_frame(64, A_TAG, 1);
        #400000;   // let A drain

        // Oversized run: > FIFO depth with no tlast, then a final tlast byte.
        send_frame(OVERSIZE, O_TAG, 1);
        #1500000;  // give the framer time to recover / drain the truncated frame

        // Frame B: another normal frame. Must reach the wire if TX recovered.
        send_frame(64, B_TAG, 1);
        #1500000;  // let B drain

        $display("INFO: rx_frames=%0d saw_A=%0b saw_B=%0b tx_fifo_level=%0d dbg_saf=0x%04x",
                 rx_frames, saw_A, saw_B, tx_fifo_level, dbg_saf);

        if (!saw_A) begin
            $display("FAIL: frame A never transmitted - TX broken before the oversized run");
            fail_cnt = fail_cnt + 1;
        end
        if (!saw_B) begin
            $display("FAIL: frame B never transmitted - TX deadlocked by the oversized run (uncommitted-data wedge)");
            fail_cnt = fail_cnt + 1;
        end

        if (fail_cnt == 0) begin
            $display("PASS: TX recovered from an oversized (> FIFO) no-tlast run; both A and B transmitted");
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAIL: %0d checks failed", fail_cnt);
        end
        $finish;
    end

    // hard timeout guard
    initial begin #8000000; $display("FAIL: timeout"); $finish; end

endmodule
