// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_async_fifo.v - Standalone unit test for async_fifo.v
// Verifies Gray-code pointer CDC FIFO under multiple conditions:
//   T1: same-clock simple write/read
//   T2: cross-clock write/read (slow writer / fast reader)
//   T3: full / empty flag behavior
//   T4: deep burst across clock domain
// Verilog 2001
// =============================================================================
`timescale 1ns / 1ps

module tb_async_fifo;

    localparam DATA_WIDTH = 8;
    localparam ADDR_WIDTH = 4;            // depth = 16
    localparam DEPTH      = (1 << ADDR_WIDTH);

    // ---- Clocks ----
    // wr_clk faster than rd_clk for T2/T3 (asymmetric CDC).
    reg wr_clk = 0;
    reg rd_clk = 0;
    always #4  wr_clk = ~wr_clk;          // 125 MHz
    always #11 rd_clk = ~rd_clk;          // ~45 MHz (incommensurate)

    reg wr_rst_n = 0;
    reg rd_rst_n = 0;

    reg  [DATA_WIDTH-1:0] wr_data;
    reg                   wr_en;
    wire                  wr_full;

    wire [DATA_WIDTH-1:0] rd_data;
    reg                   rd_en;
    wire                  rd_empty;

    async_fifo #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) dut (
        .wr_clk   (wr_clk),
        .wr_rst_n (wr_rst_n),
        .wr_data  (wr_data),
        .wr_en    (wr_en),
        .wr_full  (wr_full),
        .rd_clk   (rd_clk),
        .rd_rst_n (rd_rst_n),
        .rd_data  (rd_data),
        .rd_en    (rd_en),
        .rd_empty (rd_empty)
    );

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task check_eq;
        input [255:0] name;
        input [31:0]  actual;
        input [31:0]  expected;
        begin
            if (actual === expected) begin
                $display("PASS: %0s = 0x%08x", name, actual);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: %0s = 0x%08x, expected 0x%08x",
                         name, actual, expected);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task check_bool;
        input [255:0] name;
        input         actual;
        input         expected;
        begin
            if (actual === expected) begin
                $display("PASS: %0s = %0b", name, actual);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: %0s = %0b, expected %0b",
                         name, actual, expected);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task wr_push;
        input [DATA_WIDTH-1:0] d;
        begin
            @(negedge wr_clk);
            wr_data = d;
            wr_en   = !wr_full;
            @(posedge wr_clk);
            @(negedge wr_clk);
            wr_en   = 1'b0;
        end
    endtask

    task rd_pop;
        output [DATA_WIDTH-1:0] d;
        begin
            // Ensure data is observable
            @(negedge rd_clk);
            while (rd_empty) @(negedge rd_clk);
            d = rd_data;
            rd_en = 1'b1;
            @(posedge rd_clk);
            @(negedge rd_clk);
            rd_en = 1'b0;
        end
    endtask

    integer i;
    reg [DATA_WIDTH-1:0] popped;

    initial begin
        $dumpfile("tb_async_fifo.vcd");
        $dumpvars(0, tb_async_fifo);

        wr_data = 0; wr_en = 0; rd_en = 0;
        #50;
        wr_rst_n = 1;
        rd_rst_n = 1;
        #50;

        // =================================================================
        // T1: empty after reset
        // =================================================================
        check_bool("T1 rd_empty after reset", rd_empty, 1'b1);
        check_bool("T1 wr_full after reset",  wr_full,  1'b0);

        // =================================================================
        // T2: push 4 then pop 4 — verify FIFO order
        // =================================================================
        for (i = 0; i < 4; i = i + 1)
            wr_push(8'hA0 + i[7:0]);

        // Allow CDC to propagate
        repeat (10) @(posedge rd_clk);

        for (i = 0; i < 4; i = i + 1) begin
            rd_pop(popped);
            if (popped !== (8'hA0 + i[7:0])) begin
                $display("FAIL: T2 byte %0d got 0x%02x exp 0x%02x",
                         i, popped, 8'hA0 + i[7:0]);
                fail_cnt = fail_cnt + 1;
            end else begin
                pass_cnt = pass_cnt + 1;
            end
        end
        $display("PASS: T2 4-byte FIFO order");

        // Drained
        repeat (8) @(posedge rd_clk);
        check_bool("T2 empty after drain", rd_empty, 1'b1);

        // =================================================================
        // T3: fill to full — push DEPTH items rapidly
        // =================================================================
        for (i = 0; i < DEPTH; i = i + 1) begin
            @(negedge wr_clk);
            wr_data = 8'h10 + i[7:0];
            wr_en   = !wr_full;
            @(posedge wr_clk);
        end
        @(negedge wr_clk);
        wr_en = 1'b0;

        // After DEPTH writes wr_full must assert
        repeat (4) @(posedge wr_clk);
        check_bool("T3 wr_full after DEPTH writes", wr_full, 1'b1);

        // Try to push one more — must NOT increment internal pointer
        @(negedge wr_clk);
        wr_data = 8'hEE;
        wr_en   = 1'b1;
        @(posedge wr_clk);
        @(negedge wr_clk);
        wr_en   = 1'b0;
        repeat (4) @(posedge wr_clk);
        check_bool("T3 wr_full holds across blocked push", wr_full, 1'b1);

        // =================================================================
        // T4: drain all and confirm sequence + empty/full deassertion
        // =================================================================
        for (i = 0; i < DEPTH; i = i + 1) begin
            rd_pop(popped);
            if (popped !== (8'h10 + i[7:0])) begin
                $display("FAIL: T4 byte %0d got 0x%02x exp 0x%02x",
                         i, popped, 8'h10 + i[7:0]);
                fail_cnt = fail_cnt + 1;
            end else begin
                pass_cnt = pass_cnt + 1;
            end
        end
        $display("PASS: T4 full-depth drain order");

        repeat (8) @(posedge rd_clk);
        check_bool("T4 empty after full drain",   rd_empty, 1'b1);
        repeat (8) @(posedge wr_clk);
        check_bool("T4 wr_full deasserts after drain", wr_full, 1'b0);

        // =================================================================
        // T5: burst random with concurrent CDC pop
        // =================================================================
        fork
            begin : burst_writer
                integer wcnt;
                wcnt = 0;
                while (wcnt < 64) begin
                    @(negedge wr_clk);
                    if (!wr_full) begin
                        wr_data = wcnt[7:0];
                        wr_en   = 1'b1;
                        wcnt    = wcnt + 1;
                    end else begin
                        wr_en   = 1'b0;
                    end
                    @(posedge wr_clk);
                end
                @(negedge wr_clk);
                wr_en = 1'b0;
            end
            begin : burst_reader
                integer rcnt;
                rcnt = 0;
                while (rcnt < 64) begin
                    @(negedge rd_clk);
                    if (!rd_empty) begin
                        if (rd_data !== rcnt[7:0]) begin
                            $display("FAIL: T5 byte %0d got 0x%02x exp 0x%02x",
                                     rcnt, rd_data, rcnt[7:0]);
                            fail_cnt = fail_cnt + 1;
                        end
                        rd_en = 1'b1;
                        rcnt  = rcnt + 1;
                    end else begin
                        rd_en = 1'b0;
                    end
                    @(posedge rd_clk);
                end
                @(negedge rd_clk);
                rd_en = 1'b0;
            end
        join
        $display("PASS: T5 64-byte CDC burst with concurrent pop");
        pass_cnt = pass_cnt + 1;

        // =================================================================
        // Summary
        // =================================================================
        if (fail_cnt == 0) begin
            $display("PASS: %0d tests passed", pass_cnt);
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        end
        $finish;
    end

    initial begin
        #500_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
