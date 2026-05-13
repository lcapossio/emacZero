// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
`timescale 1ns / 1ps

module tb_eth_mac_multiframe;

    reg clk = 0;
    always #5 clk = ~clk;

    reg mii_clk = 0;
    always #20 mii_clk = ~mii_clk;

    reg rst_n = 0;
    initial begin
        #100 rst_n = 1;
    end

    wire [3:0] mii_txd;
    wire       mii_tx_en;
    wire [7:0] dbg_gmii_txd;
    wire       dbg_gmii_tx_en;
    wire       tx_ready;

    reg  [7:0] tx_data  = 8'd0;
    reg        tx_valid = 1'b0;
    reg        tx_last  = 1'b0;

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
        .dbg_gmii_txd     (dbg_gmii_txd),
        .dbg_gmii_tx_en   (dbg_gmii_tx_en),
        .dbg_gmii_rxd     (),
        .dbg_gmii_rx_dv   ()
    );

    localparam integer FRAME_COUNT = 3;
    reg [15:0] frame_len [0:FRAME_COUNT-1];
    integer frame_idx;
    integer byte_idx;

    initial begin
        frame_len[0] = 16'd74;
        frame_len[1] = 16'd1450;
        frame_len[2] = 16'd512;
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
                default: frame_byte = (bidx + (fidx * 17)) & 8'hFF;
            endcase
        end
    endfunction

    reg [7:0] wire_frame_buf [0:FRAME_COUNT-1][0:2047];
    integer wire_frame_len [0:FRAME_COUNT-1];
    integer wire_frame_idx = 0;
    integer wire_byte_count = 0;
    integer mismatch_count = 0;
    integer cmp_frame;
    integer cmp_idx;
    reg prev_mii_tx_en = 0;
    reg nib_sel = 0;
    reg [3:0] low_nibble = 0;

    always @(posedge mii_clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_mii_tx_en <= 1'b0;
            nib_sel        <= 1'b0;
            low_nibble     <= 4'd0;
            wire_frame_idx <= 0;
            wire_byte_count <= 0;
        end else begin
            prev_mii_tx_en <= mii_tx_en;

            if (!prev_mii_tx_en && mii_tx_en) begin
                nib_sel         <= 1'b0;
                wire_byte_count <= 0;
            end

            if (mii_tx_en) begin
                if (!nib_sel) begin
                    low_nibble <= mii_txd;
                    nib_sel    <= 1'b1;
                end else begin
                    if (wire_frame_idx < FRAME_COUNT)
                        wire_frame_buf[wire_frame_idx][wire_byte_count] <= {mii_txd, low_nibble};
                    wire_byte_count <= wire_byte_count + 1;
                    nib_sel <= 1'b0;
                end
            end

            if (prev_mii_tx_en && !mii_tx_en) begin
                if (wire_frame_idx < FRAME_COUNT)
                    wire_frame_len[wire_frame_idx] <= wire_byte_count;
                wire_frame_idx <= wire_frame_idx + 1;
            end
        end
    end

    initial begin
        $dumpfile("tb_eth_mac_multiframe.vcd");
        $dumpvars(0, tb_eth_mac_multiframe);

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

        #700000;

        if (wire_frame_idx != FRAME_COUNT) begin
            $display("FAIL: MII frame count mismatch %0d != %0d", wire_frame_idx, FRAME_COUNT);
            mismatch_count = mismatch_count + 1;
        end

        for (cmp_frame = 0; cmp_frame < FRAME_COUNT; cmp_frame = cmp_frame + 1) begin
            $display("Frame %0d: MII bytes=%0d", cmp_frame, wire_frame_len[cmp_frame]);
            if (wire_frame_len[cmp_frame] != (frame_len[cmp_frame] + 12)) begin
                $display("FAIL: frame %0d length mismatch expected %0d got %0d",
                         cmp_frame, frame_len[cmp_frame] + 12, wire_frame_len[cmp_frame]);
                mismatch_count = mismatch_count + 1;
            end

            for (cmp_idx = 0; cmp_idx < 7 && cmp_idx < wire_frame_len[cmp_frame]; cmp_idx = cmp_idx + 1) begin
                if (wire_frame_buf[cmp_frame][cmp_idx] !== 8'h55) begin
                    $display("FAIL: frame %0d preamble byte %0d mismatch %02x",
                             cmp_frame, cmp_idx, wire_frame_buf[cmp_frame][cmp_idx]);
                    mismatch_count = mismatch_count + 1;
                    cmp_idx = 7;
                end
            end

            if (wire_frame_len[cmp_frame] > 7 && wire_frame_buf[cmp_frame][7] !== 8'hD5) begin
                $display("FAIL: frame %0d missing SFD %02x",
                         cmp_frame, wire_frame_buf[cmp_frame][7]);
                mismatch_count = mismatch_count + 1;
            end

            for (cmp_idx = 0; cmp_idx < 14 && (8 + cmp_idx) < wire_frame_len[cmp_frame]; cmp_idx = cmp_idx + 1) begin
                if (wire_frame_buf[cmp_frame][8 + cmp_idx] !== frame_byte(cmp_frame, cmp_idx)) begin
                    $display("FAIL: frame %0d payload/header byte %0d mismatch exp=%02x got=%02x",
                             cmp_frame, cmp_idx, frame_byte(cmp_frame, cmp_idx),
                             wire_frame_buf[cmp_frame][8 + cmp_idx]);
                    mismatch_count = mismatch_count + 1;
                    cmp_idx = 14;
                end
            end
        end

        if (mismatch_count == 0) begin
            $display("ETH MAC multiframe: 1 tests passed");
            $display("ALL TESTS PASSED");
        end else begin
            $display("TESTS FAILED");
        end

        $finish;
    end

endmodule
