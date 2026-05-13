// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio � bard0 design
// =============================================================================
// tb_crc32.v — CRC32 Unit Test
// Verilog 2001
// =============================================================================

`timescale 1ns / 1ps

module tb_crc32;

    reg        clk;
    reg        rst_n;
    reg  [7:0] data_in;
    reg        data_valid;
    reg        crc_init;
    wire [31:0] crc_out;
    wire [31:0] crc_raw;

    // DUT
    crc32 u_dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .data_in   (data_in),
        .data_valid(data_valid),
        .crc_init  (crc_init),
        .crc_out   (crc_out),
        .crc_raw   (crc_raw)
    );

    // Clock: 125 MHz
    initial clk = 0;
    always #4 clk = ~clk;

    integer pass_count;
    integer fail_count;

    // Task: feed one byte
    task feed_byte;
        input [7:0] b;
        begin
            @(posedge clk);
            data_in    <= b;
            data_valid <= 1'b1;
            @(posedge clk);
            data_valid <= 1'b0;
        end
    endtask

    // Task: initialize CRC
    task init_crc;
        begin
            @(posedge clk);
            crc_init <= 1'b1;
            @(posedge clk);
            crc_init <= 1'b0;
        end
    endtask

    // =========================================================================
    // Test vectors
    // =========================================================================
    initial begin
        $dumpfile("tb_crc32.vcd");
        $dumpvars(0, tb_crc32);

        rst_n      = 0;
        data_in    = 0;
        data_valid = 0;
        crc_init   = 0;
        pass_count = 0;
        fail_count = 0;

        #100;
        rst_n = 1;
        #20;

        // -------------------------------------------------------
        // TC-CRC-01: Known test vector "123456789" in ASCII
        // Expected CRC-32 = 0xCBF43926
        // -------------------------------------------------------
        $display("[TC-CRC-01] CRC of ASCII '123456789'");
        init_crc;

        feed_byte(8'h31); // '1'
        feed_byte(8'h32); // '2'
        feed_byte(8'h33); // '3'
        feed_byte(8'h34); // '4'
        feed_byte(8'h35); // '5'
        feed_byte(8'h36); // '6'
        feed_byte(8'h37); // '7'
        feed_byte(8'h38); // '8'
        feed_byte(8'h39); // '9'

        @(posedge clk);
        @(posedge clk);
        if (crc_out == 32'hCBF43926) begin
            $display("  PASS: CRC = 0x%08X (expected 0xCBF43926)", crc_out);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: CRC = 0x%08X (expected 0xCBF43926)", crc_out);
            fail_count = fail_count + 1;
        end

        // -------------------------------------------------------
        // TC-CRC-02: Feed CRC'd data back, check residue
        // After feeding data + its CRC, raw register = 0xC704DD7B
        // -------------------------------------------------------
        $display("[TC-CRC-02] CRC residue check");
        init_crc;

        feed_byte(8'h31);
        feed_byte(8'h32);
        feed_byte(8'h33);
        feed_byte(8'h34);
        feed_byte(8'h35);
        feed_byte(8'h36);
        feed_byte(8'h37);
        feed_byte(8'h38);
        feed_byte(8'h39);
        // Now feed the CRC bytes (LSB first, as transmitted on wire)
        feed_byte(8'h26);  // CRC byte 0
        feed_byte(8'h39);  // CRC byte 1
        feed_byte(8'hF4);  // CRC byte 2
        feed_byte(8'hCB);  // CRC byte 3

        @(posedge clk);
        @(posedge clk);
        if (crc_raw == 32'hDEBB20E3) begin
            $display("  PASS: Residue = 0x%08X (expected 0xDEBB20E3)", crc_raw);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: Residue = 0x%08X (expected 0xDEBB20E3)", crc_raw);
            fail_count = fail_count + 1;
        end

        // -------------------------------------------------------
        // TC-CRC-03: Single byte
        // CRC32 of 0x00 = 0xD202EF8D
        // -------------------------------------------------------
        $display("[TC-CRC-03] CRC of single byte 0x00");
        init_crc;
        feed_byte(8'h00);

        @(posedge clk);
        @(posedge clk);
        if (crc_out == 32'hD202EF8D) begin
            $display("  PASS: CRC = 0x%08X (expected 0xD202EF8D)", crc_out);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: CRC = 0x%08X (expected 0xD202EF8D)", crc_out);
            fail_count = fail_count + 1;
        end

        // -------------------------------------------------------
        // Summary
        // -------------------------------------------------------
        #100;
        $display("");
        $display("========================================");
        $display("CRC32 Test Results: %0d PASS, %0d FAIL", pass_count, fail_count);
        $display("========================================");
        if (fail_count == 0)
            $display("ALL TESTS PASSED");
        else
            $display("SOME TESTS FAILED");
        $finish;
    end

endmodule
