// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_udp_blast_backpressure.v - tlast must survive sink back-pressure
//
// Regression for the every-other-packet TX loss: udp_blast arms src_last one
// cycle ahead of the final payload byte, but the 1-deep output slice only
// samples src_* while src_ready is high. Clearing src_last unconditionally let
// tlast evaporate whenever the sink stalled on exactly that beat, merging the
// frame with the next one - on hardware the MAC's oversize guard then truncated
// the pair and emitted one frame for every two generated (50% loss at line
// rate, rate-dependent, invisible with a never-stalling sink).
//
// The sink here sweeps a single-cycle stall across every beat position of the
// frame, so the offending beat is always covered. Every frame must come out at
// exactly FRAME_LEN bytes with its own tlast.
// Verilog 2001
// =============================================================================
`timescale 1ns / 1ps

module tb_udp_blast_backpressure;

    localparam [13:0] PAYLOAD_SIZE = 14'd32;             // incl. 12B iperf hdr
    localparam integer FRAME_LEN   = 14 + 20 + 8 + 32;   // eth + ip + udp + payload
    localparam integer N_FRAMES    = FRAME_LEN + 4;      // sweep every stall phase

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg  enable;
    wire [7:0]  tx_data;
    wire        tx_valid;
    wire        tx_last;
    wire        tx_start;
    wire [31:0] pkts_sent;
    wire        pkt_done_pulse;

    // Sink: one-cycle stall at beat `stall_at`, swept one position per frame.
    integer stall_at   = 0;
    reg     stall_done = 1'b0;
    integer beat_idx   = 0;
    wire    do_stall   = tx_valid && !stall_done && (beat_idx == stall_at);
    wire    tx_ready   = !do_stall;
    wire    beat       = tx_valid && tx_ready;

    udp_blast #(
        .START_DELAY_CYCLES(32'd0)
    ) u_dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .our_mac          (48'h02_00_00_00_00_01),
        .our_ip           (32'hC0_A8_89_C8),
        .dst_mac          (48'h02_00_00_00_00_02),
        .dst_ip           (32'hC0_A8_89_01),
        .dst_port         (16'd5002),
        .src_port         (16'd9997),
        .payload_size     (PAYLOAD_SIZE),
        .enable           (enable),
        .inter_frame_delay(24'd0),
        .pkts_sent        (pkts_sent),
        .pkt_done_pulse   (pkt_done_pulse),
        .tx_data          (tx_data),
        .tx_valid         (tx_valid),
        .tx_last          (tx_last),
        .tx_ready         (tx_ready),
        .tx_start         (tx_start)
    );

    integer pass_cnt  = 0;
    integer fail_cnt  = 0;
    integer frames    = 0;
    integer bad_len   = 0;
    integer worst_len = 0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            beat_idx   <= 0;
            stall_done <= 1'b0;
            stall_at   <= 0;
            frames     <= 0;
            bad_len    <= 0;
            worst_len  <= 0;
        end else begin
            if (do_stall)
                stall_done <= 1'b1;

            if (beat) begin
                if (tx_last) begin
                    frames   <= frames + 1;
                    if (beat_idx + 1 != FRAME_LEN) begin
                        bad_len <= bad_len + 1;
                        if (beat_idx + 1 > worst_len)
                            worst_len <= beat_idx + 1;
                        $display("FAIL: frame %0d length %0d, expected %0d (stall_at=%0d)",
                                 frames, beat_idx + 1, FRAME_LEN, stall_at);
                    end
                    beat_idx   <= 0;
                    stall_done <= 1'b0;
                    stall_at   <= (stall_at + 1 >= FRAME_LEN) ? 0 : stall_at + 1;
                end else begin
                    beat_idx <= beat_idx + 1;
                    // A merged frame runs past FRAME_LEN with no tlast in sight.
                    if (beat_idx + 1 > 2 * FRAME_LEN) begin
                        $display("FAIL: no tlast after %0d beats (stall_at=%0d) - frames merged",
                                 beat_idx + 1, stall_at);
                        $finish;
                    end
                end
            end
        end
    end

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

    initial begin
        enable = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);
        enable = 1'b1;

        wait (frames >= N_FRAMES);
        @(posedge clk);
        enable = 1'b0;
        repeat (4) @(posedge clk);

        check("stall swept all beat phases", stall_at != 0 || frames >= FRAME_LEN);
        check("frame lengths all exact", bad_len == 0);
        check("no merged frames", worst_len == 0);
        check("frame count matches pkts_sent", pkts_sent >= N_FRAMES);

        if (fail_cnt == 0) begin
            $display("PASS: %0d tests passed", pass_cnt);
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
