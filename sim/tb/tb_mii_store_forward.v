// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
`timescale 1ns / 1ps

module tb_mii_store_forward;

    reg clk = 0;
    always #5 clk = ~clk;

    reg mii_clk = 0;
    always #20 mii_clk = ~mii_clk;

    reg rst_n = 0;
    initial begin
        #100 rst_n = 1;
    end

    reg  [7:0] tx_data  = 8'd0;
    reg        tx_valid = 1'b0;
    reg        tx_last  = 1'b0;
    wire       tx_ready;
    wire [3:0] mii_txd;
    wire       mii_tx_en;

    eth_mac u_mac (
        .clk              (clk),
        .rst_n            (rst_n),
        .mii_txd          (mii_txd),
        .mii_tx_en        (mii_tx_en),
        .mii_tx_clk       (mii_clk),
        .mii_rxd          (4'd0),
        .mii_rx_dv        (1'b0),
        .mii_rx_er        (1'b0),
        .mii_rx_clk       (mii_clk),
        .mii_col          (1'b0),
        .mii_crs          (1'b0),
        .our_mac          (48'h02_00_00_00_00_01),
        .promisc          (1'b0),
        .s_axis_tdata     (tx_data),
        .s_axis_tvalid    (tx_valid),
        .s_axis_tready    (tx_ready),
        .s_axis_tlast     (tx_last),
        .s_axis_tkeep     (1'b1),
        .m_axis_tdata     (),
        .m_axis_tvalid    (),
        .m_axis_tready    (1'b1),
        .m_axis_tlast     (),
        .m_axis_terror    (),
        .m_axis_tsof      (),
        .tx_active        (),
        .tx_fifo_busy_out (),
        .tx_fifo_level_out(),
        .dbg_tx_fifo_empty(),
        .dbg_rx_prog_empty(),
        .dbg_rx_rd_empty  (),
        .dbg_rx_reading   (),
        .dbg_rx_frames_pending(),
        .dbg_gmii_txd     (),
        .dbg_gmii_tx_en   (),
        .dbg_gmii_rxd     (),
        .dbg_gmii_rx_dv   ()
    );

    localparam integer FRAME_COUNT = 2;
    reg [15:0] frame_len [0:FRAME_COUNT-1];
    integer frame_idx;
    integer byte_idx;
    integer expected_mac_bytes;

    initial begin
        frame_len[0] = 16'd74;
        frame_len[1] = 16'd1450;
    end

    function [7:0] frame_byte;
        input integer fidx;
        input integer bidx;
        begin
            case (bidx)
                0:  frame_byte = 8'hDA;
                1:  frame_byte = 8'h02;
                2:  frame_byte = 8'h03;
                3:  frame_byte = 8'h04;
                4:  frame_byte = 8'h05;
                5:  frame_byte = 8'h06;
                6:  frame_byte = 8'h02;
                7:  frame_byte = 8'h00;
                8:  frame_byte = 8'h00;
                9:  frame_byte = 8'h00;
                10: frame_byte = 8'h00;
                11: frame_byte = fidx[7:0];
                12: frame_byte = 8'h08;
                13: frame_byte = 8'h00;
                default: frame_byte = (bidx + (fidx * 23)) & 8'hFF;
            endcase
        end
    endfunction

    integer wr_byte_count = 0;
    integer rd_byte_count = 0;
    integer len_pulse_count = 0;
    integer mii_frame_count = 0;
    integer pass_count = 0;
    integer fail_count = 0;
    integer pulse_idx;
    integer wait_cycles;

    reg [11:0] len_values [0:FRAME_COUNT-1];
    reg [11:0] expected_len [0:FRAME_COUNT-1];
    reg prev_mii_tx_en = 0;
    reg nib_sel = 0;

    initial begin
        expected_len[0] = 12'd86;
        expected_len[1] = 12'd1462;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_byte_count   <= 0;
            len_pulse_count <= 0;
        end else begin
            if (u_mac.u_mii_if.tx_wr_en && !u_mac.u_mii_if.tx_wr_full)
                wr_byte_count <= wr_byte_count + 1;

            if (u_mac.u_mii_if.tx_len_wr_en) begin
                if (len_pulse_count < FRAME_COUNT)
                    len_values[len_pulse_count] <= u_mac.u_mii_if.tx_len_wr_data;
                len_pulse_count <= len_pulse_count + 1;
            end
        end
    end

    always @(posedge mii_clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_mii_tx_en <= 1'b0;
            nib_sel        <= 1'b0;
            rd_byte_count  <= 0;
            mii_frame_count <= 0;
        end else begin
            prev_mii_tx_en <= mii_tx_en;

            if (!prev_mii_tx_en && mii_tx_en)
                nib_sel <= 1'b0;

            if (mii_tx_en) begin
                if (!nib_sel)
                    nib_sel <= 1'b1;
                else begin
                    rd_byte_count <= rd_byte_count + 1;
                    nib_sel <= 1'b0;
                end
            end

            if (prev_mii_tx_en && !mii_tx_en)
                mii_frame_count <= mii_frame_count + 1;
        end
    end

    initial begin
        $dumpfile("tb_mii_store_forward.vcd");
        $dumpvars(0, tb_mii_store_forward);

        @(posedge rst_n);
        #500;

        for (frame_idx = 0; frame_idx < FRAME_COUNT; frame_idx = frame_idx + 1) begin
            @(posedge clk);
            tx_valid <= 1'b1;
            tx_data  <= frame_byte(frame_idx, 0);
            tx_last  <= (frame_len[frame_idx] == 1);
            for (byte_idx = 1; byte_idx < frame_len[frame_idx]; byte_idx = byte_idx + 1) begin
                @(posedge clk);
                while (!tx_ready) @(posedge clk);
                tx_data <= frame_byte(frame_idx, byte_idx);
                tx_last <= (byte_idx == frame_len[frame_idx] - 1);
            end
            @(posedge clk);
            while (!tx_ready) @(posedge clk);
            tx_valid <= 1'b0;
            tx_last  <= 1'b0;
            repeat (2) @(posedge clk);
        end

        for (pulse_idx = 0; pulse_idx < FRAME_COUNT; pulse_idx = pulse_idx + 1) begin
            wait_cycles = 0;
            while (mii_frame_count <= pulse_idx && wait_cycles < 20000) begin
                @(posedge mii_clk);
                wait_cycles = wait_cycles + 1;
            end
            if (mii_frame_count > pulse_idx) begin
                $display("PASS: frame %0d drained to MII within bound", pulse_idx);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL: frame %0d never drained to MII", pulse_idx);
                fail_count = fail_count + 1;
            end
        end

        #1000;

        if (len_pulse_count == FRAME_COUNT) begin
            $display("PASS: saw %0d frame length enqueue pulses", FRAME_COUNT);
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: length enqueue count %0d != %0d", len_pulse_count, FRAME_COUNT);
            fail_count = fail_count + 1;
        end

        for (pulse_idx = 0; pulse_idx < FRAME_COUNT; pulse_idx = pulse_idx + 1) begin
            if (len_values[pulse_idx] == expected_len[pulse_idx]) begin
                $display("PASS: frame %0d queued length %0d", pulse_idx, len_values[pulse_idx]);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL: frame %0d queued length %0d != %0d",
                         pulse_idx, len_values[pulse_idx], expected_len[pulse_idx]);
                fail_count = fail_count + 1;
            end
        end

        expected_mac_bytes = expected_len[0] + expected_len[1];
        if (wr_byte_count == expected_mac_bytes) begin
            $display("PASS: write-side accepted %0d bytes", wr_byte_count);
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: write-side byte count %0d != %0d", wr_byte_count, expected_mac_bytes);
            fail_count = fail_count + 1;
        end

        if (rd_byte_count == expected_mac_bytes) begin
            $display("PASS: read-side drained %0d bytes", rd_byte_count);
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: read-side byte count %0d != %0d", rd_byte_count, expected_mac_bytes);
            fail_count = fail_count + 1;
        end

        if (fail_count == 0) begin
            $display("MII-STORE-FORWARD: %0d tests passed", pass_count);
            $display("ALL TESTS PASSED");
        end else begin
            $display("TESTS FAILED");
        end

        $finish;
    end

endmodule
