// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
`timescale 1ns / 1ps

module tb_mii_tx_burst_backpressure;

    reg clk = 0;
    always #5 clk = ~clk;          // 100 MHz system side

    reg mii_clk = 0;
    always #20 mii_clk = ~mii_clk; // 25 MHz MII nibble clock

    reg rst_n = 0;
    initial begin
        #100 rst_n = 1;
    end

    localparam integer FRAME_LEN   = 1514; // L2 bytes before FCS
    localparam integer TX_FRAMES   = 96;
    localparam integer MAX_RX      = 8192;
    localparam integer EXPECT_MII_BYTES = FRAME_LEN + 12; // preamble+SFD+FCS

    wire [3:0] mii_txd;
    wire       mii_tx_en;
    wire [7:0] gmii_txd;
    wire       gmii_tx_en;
    wire       gmii_tx_er;
    wire       tx_busy;
    wire [11:0] tx_fifo_level;
    wire        dbg_tx_wr_full;
    wire        dbg_tx_len_wr_en;
    wire        dbg_tx_rd_en;
    wire [11:0] dbg_last_tx_len_wr;
    wire [11:0] dbg_tx_frames_queued;
    wire [11:0] dbg_tx_frames_drained;

    mii_if #(.MII_DEBUG(1)) u_mii (
        .clk(clk),
        .rst_n(rst_n),
        .mii_rxd(4'd0),
        .mii_rx_dv(1'b0),
        .mii_rx_er(1'b0),
        .mii_rx_clk(mii_clk),
        .mii_col(1'b0),
        .mii_crs(1'b0),
        .mii_txd(mii_txd),
        .mii_tx_en(mii_tx_en),
        .mii_tx_clk(mii_clk),
        .gmii_txd(gmii_txd),
        .gmii_tx_en(gmii_tx_en),
        .gmii_tx_er(gmii_tx_er),
        .gmii_rxd(),
        .gmii_rx_dv(),
        .gmii_rx_er(),
        .mii_tx_clk_out(),
        .tx_busy(tx_busy),
        .tx_fifo_level(tx_fifo_level),
        .dbg_tx_fifo_empty(),
        .dbg_rx_prog_empty(),
        .dbg_rx_rd_empty(),
        .dbg_rx_reading(),
        .dbg_rx_frames_pending(),
        .dbg_tx_wr_en(),
        .dbg_tx_len_wr_en(dbg_tx_len_wr_en),
        .dbg_tx_wr_full(dbg_tx_wr_full),
        .dbg_tx_wr_rst_busy_out(),
        .dbg_tx_rd_en(dbg_tx_rd_en),
        .dbg_tx_frame_loaded(),
        .dbg_tx_frames_queued(dbg_tx_frames_queued),
        .dbg_tx_frames_drained(dbg_tx_frames_drained),
        .dbg_last_tx_len_wr(dbg_last_tx_len_wr),
        .dbg_mii_cap_done(),
        .dbg_mii_cap_frame_len(),
        .dbg_mii_cap_word0(),
        .dbg_mii_cap_word1(),
        .dbg_mii_cap_word2(),
        .dbg_mii_cap_word3()
    );

    reg  [7:0] tx_data = 8'd0;
    reg        tx_valid = 1'b0;
    reg        tx_last = 1'b0;
    wire       tx_ready;

    eth_mac_tx u_mac_tx (
        .clk(clk),
        .rst_n(rst_n),
        .tx_start_ok(~tx_busy),
        .gmii_txd(gmii_txd),
        .gmii_tx_en(gmii_tx_en),
        .gmii_tx_er(gmii_tx_er),
        .s_axis_tdata(tx_data),
        .s_axis_tvalid(tx_valid),
        .s_axis_tready(tx_ready),
        .s_axis_tkeep(1'b1),
        .s_axis_tlast(tx_last),
        .tx_active(),
        .dbg_state(),
        .dbg_stall_cnt()
    );

    function [7:0] frame_byte;
        input integer fidx;
        input integer bidx;
        begin
            case (bidx)
                0:  frame_byte = 8'h02;
                1:  frame_byte = 8'hAA;
                2:  frame_byte = 8'hBB;
                3:  frame_byte = 8'hCC;
                4:  frame_byte = 8'hDD;
                5:  frame_byte = 8'hEE;
                6:  frame_byte = 8'h02;
                7:  frame_byte = 8'h00;
                8:  frame_byte = 8'h00;
                9:  frame_byte = 8'h00;
                10: frame_byte = 8'h00;
                11: frame_byte = 8'h01;
                12: frame_byte = 8'h08;
                13: frame_byte = 8'h00;
                14: frame_byte = 8'h45;
                15: frame_byte = 8'h00;
                16: frame_byte = 8'h05; // IP total length 1500
                17: frame_byte = 8'hDC;
                34: frame_byte = 8'h27; // UDP src port 9999
                35: frame_byte = 8'h0F;
                36: frame_byte = 8'h13; // UDP dst port 5001
                37: frame_byte = 8'h89;
                38: frame_byte = 8'h05; // UDP len 1480
                39: frame_byte = 8'hC8;
                42: frame_byte = fidx[31:24];
                43: frame_byte = fidx[23:16];
                44: frame_byte = fidx[15:8];
                45: frame_byte = fidx[7:0];
                default: frame_byte = (bidx + fidx) & 8'hFF;
            endcase
        end
    endfunction

    integer send_frame;
    integer send_byte;
    initial begin
        @(posedge rst_n);
        repeat (50) @(posedge clk);

        for (send_frame = 0; send_frame < TX_FRAMES; send_frame = send_frame + 1) begin
            @(posedge clk);
            tx_valid <= 1'b1;
            tx_data  <= frame_byte(send_frame, 0);
            tx_last  <= 1'b0;

            for (send_byte = 1; send_byte < FRAME_LEN; send_byte = send_byte + 1) begin
                @(posedge clk);
                while (!tx_ready) @(posedge clk);
                tx_data <= frame_byte(send_frame, send_byte);
                tx_last <= (send_byte == FRAME_LEN - 1);
            end

            @(posedge clk);
            while (!tx_ready) @(posedge clk);
            tx_valid <= 1'b0;
            tx_last  <= 1'b0;
        end
    end

    reg prev_mii_tx_en = 1'b0;
    reg nib_sel = 1'b0;
    reg [3:0] low_nib = 4'd0;
    reg [7:0] rx_buf [0:MAX_RX-1];
    integer rx_idx = 0;
    integer rx_frame_count = 0;
    integer rx_len [0:TX_FRAMES-1];
    integer rx_seq [0:TX_FRAMES-1];
    integer len_wr_count = 0;
    integer wr_full_count = 0;
    integer tx_busy_cycles = 0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            len_wr_count <= 0;
            wr_full_count <= 0;
            tx_busy_cycles <= 0;
        end else begin
            if (dbg_tx_len_wr_en)
                len_wr_count <= len_wr_count + 1;
            if (dbg_tx_wr_full)
                wr_full_count <= wr_full_count + 1;
            if (tx_busy)
                tx_busy_cycles <= tx_busy_cycles + 1;
        end
    end

    always @(posedge mii_clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_mii_tx_en <= 1'b0;
            nib_sel <= 1'b0;
            low_nib <= 4'd0;
            rx_idx <= 0;
            rx_frame_count <= 0;
        end else begin
            prev_mii_tx_en <= mii_tx_en;

            if (!prev_mii_tx_en && mii_tx_en) begin
                nib_sel <= 1'b0;
                rx_idx <= 0;
            end

            if (mii_tx_en) begin
                if (!nib_sel) begin
                    low_nib <= mii_txd;
                    nib_sel <= 1'b1;
                end else begin
                    if (rx_idx < MAX_RX)
                        rx_buf[rx_idx] <= {mii_txd, low_nib};
                    rx_idx <= rx_idx + 1;
                    nib_sel <= 1'b0;
                end
            end

            if (prev_mii_tx_en && !mii_tx_en) begin
                if (rx_frame_count < TX_FRAMES) begin
                    rx_len[rx_frame_count] <= rx_idx;
                    rx_seq[rx_frame_count] <= {rx_buf[50], rx_buf[51], rx_buf[52], rx_buf[53]};
                end
                rx_frame_count <= rx_frame_count + 1;
            end
        end
    end

    integer pass_count = 0;
    integer fail_count = 0;
    integer check_idx;
    integer wait_cycles;

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

    initial begin
        $dumpfile("tb_mii_tx_burst_backpressure.vcd");
        $dumpvars(0, tb_mii_tx_burst_backpressure);

        wait_cycles = 0;
        while (rx_frame_count < TX_FRAMES && wait_cycles < 500000) begin
            @(posedge mii_clk);
            wait_cycles = wait_cycles + 1;
        end

        check_int("length enqueue count", len_wr_count, TX_FRAMES);
        check_int("mii frame count", rx_frame_count, TX_FRAMES);
        check_int("tx write full cycles", wr_full_count, 0);

        if (tx_busy_cycles > 0) begin
            $display("PASS: tx_busy asserted for %0d sys cycles", tx_busy_cycles);
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: tx_busy never asserted during oversubscribed burst");
            fail_count = fail_count + 1;
        end

        for (check_idx = 0; check_idx < TX_FRAMES; check_idx = check_idx + 1) begin
            if (rx_len[check_idx] == EXPECT_MII_BYTES) begin
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL: frame %0d MII length %0d expected %0d",
                         check_idx, rx_len[check_idx], EXPECT_MII_BYTES);
                fail_count = fail_count + 1;
            end

            if (rx_seq[check_idx] == check_idx) begin
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL: frame %0d seq %0d expected %0d",
                         check_idx, rx_seq[check_idx], check_idx);
                fail_count = fail_count + 1;
            end
        end

        if (fail_count == 0) begin
            $display("MII-TX-BURST-BACKPRESSURE: %0d tests passed", pass_count);
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAIL: %0d passed, %0d failed", pass_count, fail_count);
            $display("TESTS FAILED");
        end

        $finish;
    end

endmodule
