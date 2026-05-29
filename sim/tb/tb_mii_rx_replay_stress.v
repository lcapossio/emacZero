// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_mii_rx_replay_stress.v - MII RX CDC/replay stress regression
//
// Drives raw MII RX nibbles directly into mii_if and checks the reconstructed
// GMII byte stream. The test is intended to run with -DXILINX_7SERIES and the
// local xpm_fifo_async_model / xpm_memory_sdpram_model so it covers the FWFT
// data_valid behavior that the plain behavioral async_fifo does not model.
// =============================================================================
`timescale 1ns / 1ps

module tb_mii_rx_replay_stress;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg mii_rx_clk = 1'b0;
    initial begin
        #7;
        forever #20 mii_rx_clk = ~mii_rx_clk;
    end

    reg mii_tx_clk = 1'b0;
    always #20 mii_tx_clk = ~mii_tx_clk;

    reg rst_n = 1'b0;
    initial begin
        #150 rst_n = 1'b1;
    end

    reg [3:0] mii_rxd = 4'd0;
    reg       mii_rx_dv = 1'b0;
    reg       mii_rx_er = 1'b0;

    wire [7:0] gmii_rxd;
    wire       gmii_rx_dv;
    wire       gmii_rx_er;

    mii_if u_mii (
        .clk(clk),
        .rst_n(rst_n),
        .mii_rxd(mii_rxd),
        .mii_rx_dv(mii_rx_dv),
        .mii_rx_er(mii_rx_er),
        .mii_rx_clk(mii_rx_clk),
        .mii_col(1'b0),
        .mii_crs(1'b0),
        .mii_txd(),
        .mii_tx_en(),
        .mii_tx_clk(mii_tx_clk),
        .gmii_txd(8'd0),
        .gmii_tx_en(1'b0),
        .gmii_tx_er(1'b0),
        .gmii_rxd(gmii_rxd),
        .gmii_rx_dv(gmii_rx_dv),
        .gmii_rx_er(gmii_rx_er),
        .mii_tx_clk_out(),
        .tx_busy(),
        .tx_fifo_level(),
        .dbg_tx_fifo_empty(),
        .dbg_rx_prog_empty(),
        .dbg_rx_rd_empty(),
        .dbg_rx_reading(),
        .dbg_rx_frames_pending(),
        .dbg_tx_wr_en(),
        .dbg_tx_len_wr_en(),
        .dbg_tx_wr_full(),
        .dbg_tx_wr_rst_busy_out(),
        .dbg_tx_rd_en(),
        .dbg_tx_frame_loaded(),
        .dbg_tx_frames_queued(),
        .dbg_tx_frames_drained(),
        .dbg_last_tx_len_wr(),
        .dbg_mii_cap_done(),
        .dbg_mii_cap_frame_len(),
        .dbg_mii_cap_word0(),
        .dbg_mii_cap_word1(),
        .dbg_mii_cap_word2(),
        .dbg_mii_cap_word3()
    );

    localparam integer FRAME_COUNT = 3;
    localparam integer MAX_FRAME_BYTES = 1530;

    reg [15:0] l2_len [0:FRAME_COUNT-1];
    reg [15:0] expected_len [0:FRAME_COUNT-1];
    reg [15:0] got_len [0:FRAME_COUNT-1];
    reg [7:0]  cap [0:FRAME_COUNT-1][0:MAX_FRAME_BYTES-1];

    integer pass_count = 0;
    integer fail_count = 0;
    integer rx_frame_count = 0;
    integer rx_idx = 0;
    reg prev_gmii_rx_dv = 1'b0;

    integer frame_i;
    integer byte_i;
    integer wait_cycles;
    integer mismatch_seen;

    initial begin
        l2_len[0] = 16'd1518;
        l2_len[1] = 16'd512;
        l2_len[2] = 16'd1518;
        expected_len[0] = 16'd1530;
        expected_len[1] = 16'd524;
        expected_len[2] = 16'd1530;
    end

    function [7:0] expected_byte;
        input integer fidx;
        input integer bidx;
        integer payload_idx;
        begin
            if (bidx < 7) begin
                expected_byte = 8'h55;
            end else if (bidx == 7) begin
                expected_byte = 8'hD5;
            end else if (bidx < (8 + l2_len[fidx])) begin
                payload_idx = bidx - 8;
                case (payload_idx)
                    0, 1, 2, 3, 4, 5:
                        expected_byte = 8'hF0 | fidx[3:0];
                    6:  expected_byte = 8'h02;
                    7:  expected_byte = 8'h00;
                    8:  expected_byte = 8'h00;
                    9:  expected_byte = 8'h00;
                    10: expected_byte = 8'h00;
                    11: expected_byte = fidx[7:0];
                    12: expected_byte = 8'h08;
                    13: expected_byte = 8'h00;
                    default: expected_byte = (payload_idx + (fidx * 37)) & 8'hFF;
                endcase
            end else begin
                payload_idx = bidx - (8 + l2_len[fidx]);
                expected_byte = (8'hA5 ^ fidx[7:0] ^ payload_idx[7:0]);
            end
        end
    endfunction

    task drive_mii_byte;
        input [7:0] value;
        begin
            @(negedge mii_rx_clk);
            mii_rxd <= value[3:0];
            mii_rx_dv <= 1'b1;
            mii_rx_er <= 1'b0;
            @(negedge mii_rx_clk);
            mii_rxd <= value[7:4];
            mii_rx_dv <= 1'b1;
            mii_rx_er <= 1'b0;
        end
    endtask

    task drive_frame;
        input integer fidx;
        integer k;
        begin
            for (k = 0; k < expected_len[fidx]; k = k + 1)
                drive_mii_byte(expected_byte(fidx, k));
            @(negedge mii_rx_clk);
            mii_rx_dv <= 1'b0;
            mii_rx_er <= 1'b0;
            mii_rxd <= 4'd0;
            repeat (24) @(negedge mii_rx_clk);
        end
    endtask

    task check_int;
        input [160*8-1:0] name;
        input integer got;
        input integer exp;
        begin
            if (got == exp) begin
                $display("PASS: %0s = %0d", name, got);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL: %0s got %0d expected %0d", name, got, exp);
                fail_count = fail_count + 1;
            end
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_frame_count <= 0;
            rx_idx <= 0;
            prev_gmii_rx_dv <= 1'b0;
        end else begin
            prev_gmii_rx_dv <= gmii_rx_dv;
            if (gmii_rx_dv) begin
                if (rx_frame_count < FRAME_COUNT && rx_idx < MAX_FRAME_BYTES)
                    cap[rx_frame_count][rx_idx] <= gmii_rxd;
                rx_idx <= rx_idx + 1;
                if (gmii_rx_er) begin
                    $display("FAIL: gmii_rx_er asserted in frame %0d byte %0d",
                             rx_frame_count, rx_idx);
                    fail_count = fail_count + 1;
                end
            end
            if (prev_gmii_rx_dv && !gmii_rx_dv) begin
                if (rx_frame_count < FRAME_COUNT)
                    got_len[rx_frame_count] <= rx_idx[15:0];
                rx_frame_count <= rx_frame_count + 1;
                rx_idx <= 0;
            end
        end
    end

    initial begin
        $dumpfile("tb_mii_rx_replay_stress.vcd");
        $dumpvars(0, tb_mii_rx_replay_stress);

        @(posedge rst_n);
        repeat (20) @(posedge mii_rx_clk);

        for (frame_i = 0; frame_i < FRAME_COUNT; frame_i = frame_i + 1)
            drive_frame(frame_i);

        wait_cycles = 0;
        while (rx_frame_count < FRAME_COUNT && wait_cycles < 200000) begin
            @(posedge clk);
            wait_cycles = wait_cycles + 1;
        end

        check_int("replayed frame count", rx_frame_count, FRAME_COUNT);

        for (frame_i = 0; frame_i < FRAME_COUNT; frame_i = frame_i + 1) begin
            check_int("replayed frame length", got_len[frame_i], expected_len[frame_i]);
            mismatch_seen = 0;
            for (byte_i = 0; byte_i < expected_len[frame_i]; byte_i = byte_i + 1) begin
                if (!mismatch_seen &&
                    cap[frame_i][byte_i] !== expected_byte(frame_i, byte_i)) begin
                    $display("FAIL: frame %0d byte %0d got %02x expected %02x",
                             frame_i, byte_i, cap[frame_i][byte_i],
                             expected_byte(frame_i, byte_i));
                    fail_count = fail_count + 1;
                    mismatch_seen = 1;
                end
            end
            if (!mismatch_seen) begin
                $display("PASS: frame %0d replay data matched", frame_i);
                pass_count = pass_count + 1;
            end
        end

        if (fail_count == 0) begin
            $display("MII-RX-REPLAY-STRESS: %0d tests passed", pass_count);
            $display("ALL TESTS PASSED");
        end else begin
            $display("TESTS FAILED: %0d passed, %0d failed", pass_count, fail_count);
        end

        $finish;
    end

    initial begin
        #5000000;
        $display("FAIL: timeout waiting for MII RX replay");
        $finish;
    end

endmodule
