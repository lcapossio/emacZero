// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
`timescale 1ns / 1ps

module tb_eth_mac_fcs;

    reg clk = 0;
    always #5 clk = ~clk;

    reg rst_n = 0;
    initial begin
        #100 rst_n = 1;
    end

    reg  [7:0] tx_data = 8'd0;
    reg        tx_valid = 1'b0;
    reg        tx_last = 1'b0;
    wire       tx_ready;

    wire [7:0] gmii_txd;
    wire       gmii_tx_en;
    wire       gmii_tx_er;

    eth_mac_tx u_mac_tx (
        .clk          (clk),
        .rst_n        (rst_n),
        .tx_start_ok  (1'b1),
        .gmii_txd     (gmii_txd),
        .gmii_tx_en   (gmii_tx_en),
        .gmii_tx_er   (gmii_tx_er),
        .s_axis_tdata (tx_data),
        .s_axis_tvalid(tx_valid),
        .s_axis_tready(tx_ready),
        .s_axis_tkeep (1'b1),
        .s_axis_tlast (tx_last),
        .tx_active    (),
        .dbg_state    (),
        .dbg_stall_cnt()
    );

    localparam integer FRAME_LEN = 74;
    reg [7:0] frame [0:FRAME_LEN-1];
    reg [7:0] wire_buf [0:255];

    integer i;
    integer tx_idx;
    integer wire_count = 0;
    integer pass_count = 0;
    integer fail_count = 0;
    reg prev_tx_en = 0;

    function [31:0] crc_step;
        input [31:0] crc_in;
        input [7:0] data;
        integer bit_idx;
        reg [31:0] c;
        begin
            c = crc_in ^ {24'd0, data};
            for (bit_idx = 0; bit_idx < 8; bit_idx = bit_idx + 1) begin
                if (c[0])
                    c = {1'b0, c[31:1]} ^ 32'hEDB88320;
                else
                    c = {1'b0, c[31:1]};
            end
            crc_step = c;
        end
    endfunction

    initial begin
        frame[0] = 8'hDA; frame[1] = 8'h02; frame[2] = 8'h03;
        frame[3] = 8'h04; frame[4] = 8'h05; frame[5] = 8'h06;
        frame[6] = 8'h02; frame[7] = 8'h00; frame[8] = 8'h00;
        frame[9] = 8'h00; frame[10] = 8'h00; frame[11] = 8'h01;
        frame[12] = 8'h08; frame[13] = 8'h00;
        for (i = 14; i < FRAME_LEN; i = i + 1)
            frame[i] = (i * 3) & 8'hFF;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_tx_en <= 1'b0;
            wire_count <= 0;
        end else begin
            prev_tx_en <= gmii_tx_en;
            if (!prev_tx_en && gmii_tx_en)
                wire_count <= 0;
            if (gmii_tx_en && wire_count < 256) begin
                wire_buf[wire_count] <= gmii_txd;
                wire_count <= wire_count + 1;
            end
        end
    end

    reg [31:0] crc_raw_calc;
    reg [31:0] crc_out_calc;
    reg [31:0] crc_residue_calc;

    initial begin
        $dumpfile("tb_eth_mac_fcs.vcd");
        $dumpvars(0, tb_eth_mac_fcs);

        @(posedge rst_n);
        #100;

        @(posedge clk);
        tx_valid <= 1'b1;
        tx_data  <= frame[0];
        tx_last  <= (FRAME_LEN == 1);

        for (tx_idx = 1; tx_idx < FRAME_LEN; tx_idx = tx_idx + 1) begin
            @(posedge clk);
            while (!tx_ready) @(posedge clk);
            tx_data <= frame[tx_idx];
            tx_last <= (tx_idx == FRAME_LEN - 1);
        end

        @(posedge clk);
        while (!tx_ready) @(posedge clk);
        tx_valid <= 1'b0;
        tx_last  <= 1'b0;

        #2000;

        if (wire_count == FRAME_LEN + 12) begin
            $display("  PASS: wire length = %0d bytes", wire_count);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: wire length = %0d (expected %0d)", wire_count, FRAME_LEN + 12);
            fail_count = fail_count + 1;
        end

        crc_raw_calc = 32'hFFFFFFFF;
        for (i = 0; i < FRAME_LEN; i = i + 1)
            crc_raw_calc = crc_step(crc_raw_calc, frame[i]);
        crc_out_calc = ~crc_raw_calc;

        if ({wire_buf[FRAME_LEN+11], wire_buf[FRAME_LEN+10], wire_buf[FRAME_LEN+9], wire_buf[FRAME_LEN+8]} == crc_out_calc) begin
            $display("  PASS: emitted FCS = 0x%08X", crc_out_calc);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: emitted FCS mismatch exp=0x%08X got=%02X%02X%02X%02X",
                     crc_out_calc,
                     wire_buf[FRAME_LEN+11], wire_buf[FRAME_LEN+10],
                     wire_buf[FRAME_LEN+9], wire_buf[FRAME_LEN+8]);
            fail_count = fail_count + 1;
        end

        crc_residue_calc = 32'hFFFFFFFF;
        for (i = 8; i < wire_count; i = i + 1)
            crc_residue_calc = crc_step(crc_residue_calc, wire_buf[i]);

        if (crc_residue_calc == 32'hDEBB20E3) begin
            $display("  PASS: full-frame residue raw = 0x%08X", crc_residue_calc);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: full-frame residue raw = 0x%08X (expected 0xDEBB20E3)",
                     crc_residue_calc);
            fail_count = fail_count + 1;
        end

        if ((~crc_residue_calc) == 32'h2144DF1C) begin
            $display("  PASS: complemented residue = 0x%08X", ~crc_residue_calc);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: complemented residue = 0x%08X (expected 0x2144DF1C)",
                     ~crc_residue_calc);
            fail_count = fail_count + 1;
        end

        if (!gmii_tx_er && fail_count == 0) begin
            $display("ETH-MAC-FCS: %0d tests passed", pass_count);
            $display("ALL TESTS PASSED");
        end else begin
            $display("TESTS FAILED");
        end

        $finish;
    end

endmodule
