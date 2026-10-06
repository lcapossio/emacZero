// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_zcu106_i2c_init.v - ZCU106 Si5328 I2C bring-up sequence
// Runs fpga/zcu106/rtl/i2c_init.v against a bus-level I2C monitor that ACKs
// every byte, decodes START/STOP and the bytes on the wire, and checks each
// transaction against the zcu106_si5328_rom.vh ROM entry by entry. A second
// pass NACKs one byte to check the abort-and-retry path, and that the retry
// uses the ROM's alternate device address.
// Verilog 2001
// =============================================================================
`timescale 1ns / 1ps

module tb_zcu106_i2c_init;

`include "zcu106_si5328_rom.vh"

    reg clk = 0;
    reg rst_n = 0;
    always #10 clk = ~clk;   // 50 MHz

    wire scl_t, sda_t;
    wire done, busy;
    wire [7:0] nack_count;

    // Open-drain bus with pull-ups; the monitor pulls SDA low to ACK.
    reg  slave_sda_low = 1'b0;
    wire scl = scl_t;
    wire sda = sda_t & ~slave_sda_low;

    i2c_init #(
        .CLK_HZ      (50_000_000),
        .I2C_HZ      (1_000_000),      // fast bus for simulation
        .START_DELAY (100),
        .RETRY_DELAY (200),
        .DONE_DELAY  (300)
    ) uut (
        .clk        (clk),
        .rst_n      (rst_n),
        .scl_t      (scl_t),
        .sda_t      (sda_t),
        .sda_i      (sda),
        .done       (done),
        .busy       (busy),
        .nack_count (nack_count)
    );

    // ---- I2C monitor ----
    integer pass_cnt = 0, fail_cnt = 0;
    integer bitn;          // bits received in the current byte
    integer nbytes;        // bytes in the current transaction
    integer txn;           // transactions completed in this pass
    integer nack_at;       // global byte index to NACK (-1 = never)
    integer byte_glob;     // bytes seen since reset
    reg [7:0]  shift;
    reg [23:0] got;        // up to 3 bytes of the current transaction
    reg        in_txn;
    reg        ack_phase;
    reg        mismatch;
    reg        exp_alt;        // ROM `alt` input expected for this pass

    initial begin
        bitn = 0; nbytes = 0; txn = 0; nack_at = -1; byte_glob = 0;
        in_txn = 0; ack_phase = 0; mismatch = 0; got = 0; exp_alt = 0;
    end

    // START / STOP: SDA edge while SCL is high
    always @(negedge sda) if (scl === 1'b1) begin
        in_txn = 1; bitn = 0; nbytes = 0; got = 0; ack_phase = 0;
    end

    always @(posedge sda) if (scl === 1'b1 && in_txn) begin
        in_txn = 0;
        check_txn;
    end

    // Data sampled on SCL rising edge
    always @(posedge scl) if (in_txn && !ack_phase) begin
        shift = {shift[6:0], sda};
        bitn  = bitn + 1;
        if (bitn == 8) begin
            got = {got[15:0], shift};
            nbytes = nbytes + 1;
            bitn = 0;
            ack_phase = 1;
        end
    end

    // ACK clock: on the SCL fall after the 8th bit, drive SDA low (or leave it
    // released to NACK); release it on the SCL fall that ends the ACK clock.
    reg ack_clk = 1'b0;
    always @(negedge scl) begin
        if (ack_phase && !ack_clk) begin
            ack_clk = 1'b1;
            slave_sda_low <= (byte_glob != nack_at);
            byte_glob = byte_glob + 1;
        end else if (ack_clk) begin
            ack_clk   = 1'b0;
            ack_phase = 0;
            slave_sda_low <= 1'b0;
        end
    end

    task check_txn;
        reg [25:0] e;
        reg [23:0] exp;
        integer    exp_n;
        begin
            if (txn >= ROM_LEN) begin
                $display("FAIL: extra transaction %0d on the bus", txn);
                mismatch = 1;
            end else begin
                e     = rom_entry(txn, exp_alt);
                exp_n = e[25:24] + 1;
                exp   = (exp_n == 2) ? {8'd0, e[23:16], e[15:8]} : e[23:0];
                if (nbytes != exp_n || got !== exp) begin
                    if (nack_at < 0)
                        $display("FAIL: txn %0d got %0d bytes %06x, expected %0d bytes %06x",
                                 txn, nbytes, got, exp_n, exp);
                    mismatch = 1;
                end
            end
            txn = txn + 1;
        end
    endtask

    initial begin
        #200 rst_n = 1;

        // ---- Pass 1: every byte ACKed ----
        wait (done === 1'b1 || $time > 200_000_000);
        if (done && txn == ROM_LEN && !mismatch && nack_count == 0) begin
            $display("PASS: %0d transactions match the ROM, done asserted", txn);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: done=%0d txn=%0d/%0d mismatch=%0d nacks=%0d",
                     done, txn, ROM_LEN, mismatch, nack_count);
            fail_cnt = fail_cnt + 1;
        end

        // ---- Pass 2: NACK the 5th byte, expect abort + full retry ----
        rst_n = 0;
        #200;
        txn = 0; mismatch = 0; byte_glob = 0; nack_at = 4;
        rst_n = 1;
        wait (nack_count == 8'd1 || $time > 400_000_000);
        // The retry restarts from entry 0: reset the scoreboard for it.
        wait (!busy);
        txn = 0; mismatch = 0; nack_at = -1; exp_alt = 1;
        wait (done === 1'b1 || $time > 600_000_000);
        if (done && txn == ROM_LEN && !mismatch && nack_count == 1) begin
            $display("PASS: NACK aborted the pass; retry at the alternate address completed");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: retry: done=%0d txn=%0d/%0d mismatch=%0d nacks=%0d",
                     done, txn, ROM_LEN, mismatch, nack_count);
            fail_cnt = fail_cnt + 1;
        end

        if (fail_cnt == 0) begin
            $display("PASS: %0d tests passed", pass_cnt);
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        end
        $finish;
    end

endmodule
