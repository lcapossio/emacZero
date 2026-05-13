// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_mdio_master.v — Unit test for mdio_master.v
//
// Regression target: verifies that MDIO read correctly captures all 16 data
// bits.  The DP83848J PHY changes its MDIO output on MDC falling edges, so
// the very first MDC rising edge in the data phase sees the PREVIOUS bit
// (TA[2]=0) rather than D[15] unless an extra wait state is inserted between
// the turnaround and the data capture window.  Before the S_RD_WAIT fix, every
// read result came back as (expected >> 1).
//
// Verilog 2001
// =============================================================================

`timescale 1ns / 1ps

module tb_mdio_master;

    // =========================================================================
    // DUT signals
    // =========================================================================
    reg  clk, rst_n;
    wire mdc;
    wire mdio_o, mdio_oe;
    reg  mdio_i;

    reg         cmd_valid;
    reg         cmd_write;
    reg  [4:0]  cmd_phy;
    reg  [4:0]  cmd_reg;
    reg  [15:0] cmd_wdata;
    wire [15:0] cmd_rdata;
    wire        cmd_done;
    wire [4:0]  dbg_rd_low_cnt;
    wire [15:0] dbg_rd_raw;

    // =========================================================================
    // DUT
    // =========================================================================
    mdio_master u_dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .mdc           (mdc),
        .mdio_i        (mdio_i),
        .mdio_o        (mdio_o),
        .mdio_oe       (mdio_oe),
        .cmd_valid     (cmd_valid),
        .cmd_write     (cmd_write),
        .cmd_phy       (cmd_phy),
        .cmd_reg       (cmd_reg),
        .cmd_wdata     (cmd_wdata),
        .cmd_c45_en    (1'b0),
        .cmd_c45_op    (2'b00),
        .cmd_rdata     (cmd_rdata),
        .cmd_done      (cmd_done),
        .dbg_rd_low_cnt(dbg_rd_low_cnt),
        .dbg_rd_raw    (dbg_rd_raw)
    );

    // =========================================================================
    // Clock: 100 MHz (10 ns period)
    // MDC runs at clk/100 = 1 MHz; one MDC period = 100 clk cycles = 1000 ns
    // =========================================================================
    initial clk = 0;
    always #5 clk = ~clk;

    // =========================================================================
    // Bookkeeping
    // =========================================================================
    integer pass_count;
    integer fail_count;

    task check16;
        input [63:0]  tag;      // 8 ASCII chars packed in 64 bits (for display)
        input [15:0]  actual;
        input [15:0]  expected;
        begin
            if (actual === expected) begin
                $display("  PASS: %s = 0x%04X (expected 0x%04X)", tag, actual, expected);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: %s = 0x%04X (expected 0x%04X)", tag, actual, expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // =========================================================================
    // PHY MDIO model
    // Drives mdio_i (master's read input) on MDC falling edges, as per
    // IEEE 802.3 Clause 22.  The PHY:
    //   - Releases the bus during TA[1] (Hi-Z → pull-up = 1)
    //   - Drives 0 during TA[2] starting from the MDC falling edge of TA[2]
    //   - Drives D[15..0] MSB-first, one bit per MDC period, starting from the
    //     MDC falling edge of the first data period
    //
    // We detect the TA[2] falling edge by watching for the turnaround window
    // after the PHYAD+REGAD fields.  The simplest approach: count MDC falling
    // edges after cmd_valid and look for the frame structure.
    //
    // Frame falling-edge count (from edge that starts S_PRE, edge index 1):
    //   Edges  1-32 : PRE (32 ones driven by master)
    //   Edge  33    : ST[0] = 0
    //   Edge  34    : ST[1] = 1
    //   Edge  35    : OP[0] = 1 (read)
    //   Edge  36    : OP[1] = 0
    //   Edges 37-41 : PHYAD[4:0]
    //   Edges 42-46 : REGAD[4:0]
    //   Edge  47    : TA[1]  master → Hi-Z
    //   Edge  48    : TA[2]  PHY drives 0 from this edge
    //   Edge  49    : D[15]  PHY drives D[15] from this edge
    //   Edges 50-64 : D[14:0]
    // =========================================================================
    reg  [15:0] phy_tx_shift;   // data the PHY will transmit
    integer     mdc_fall_cnt;   // MDC falling edge counter (1-based)
    reg         phy_active;     // true while a read frame is in progress

    // Start counting on MDC falling once the master transitions out of IDLE
    // (cmd_valid asserted).  We watch mdc (falling edge of the wire).
    always @(negedge mdc) begin
        if (phy_active) begin
            mdc_fall_cnt = mdc_fall_cnt + 1;
            if (mdc_fall_cnt == 48) begin
                // TA[2]: PHY drives 0
                mdio_i = 1'b0;
            end else if (mdc_fall_cnt >= 49 && mdc_fall_cnt <= 64) begin
                // Data bits D[15] (edge 49) … D[0] (edge 64)
                mdio_i = phy_tx_shift[15];
                phy_tx_shift = {phy_tx_shift[14:0], 1'b0};
            end else if (mdc_fall_cnt > 64) begin
                mdio_i  = 1'bz;  // release after last bit
                phy_active = 0;
            end
        end
    end

    // =========================================================================
    // Task: issue one MDIO read and wait for completion
    // =========================================================================
    task mdio_read;
        input [4:0]  phy;
        input [4:0]  reg_addr;
        input [15:0] phy_data;   // data the PHY model will respond with
        begin
            // Arm PHY model
            @(posedge clk); #1;
            phy_tx_shift = phy_data;
            mdc_fall_cnt = 0;
            phy_active   = 1;

            // Issue command
            cmd_valid = 1'b1;
            cmd_write = 1'b0;
            cmd_phy   = phy;
            cmd_reg   = reg_addr;
            cmd_wdata = 16'd0;
            @(posedge clk); #1;
            cmd_valid = 1'b0;

            // Wait for cmd_done (max 7000 MDC cycles = 700 000 clk cycles)
            begin : wait_done
                integer timeout;
                timeout = 700000;
                while (!cmd_done && timeout > 0) begin
                    @(posedge clk); #1;
                    timeout = timeout - 1;
                end
                if (timeout == 0) begin
                    $display("  ERROR: cmd_done never asserted (timeout)");
                    fail_count = fail_count + 1;
                    disable wait_done;
                end
            end
            @(posedge clk); #1;  // one extra cycle so cmd_rdata is stable
        end
    endtask

    // =========================================================================
    // Task: issue one MDIO write and wait for completion
    // =========================================================================
    task mdio_write_op;
        input [4:0]  phy;
        input [4:0]  reg_addr;
        input [15:0] wdata;
        begin
            @(posedge clk); #1;
            cmd_valid = 1'b1;
            cmd_write = 1'b1;
            cmd_phy   = phy;
            cmd_reg   = reg_addr;
            cmd_wdata = wdata;
            @(posedge clk); #1;
            cmd_valid = 1'b0;

            begin : wait_done_wr
                integer timeout;
                timeout = 700000;
                while (!cmd_done && timeout > 0) begin
                    @(posedge clk); #1;
                    timeout = timeout - 1;
                end
                if (timeout == 0) begin
                    $display("  ERROR: cmd_done (write) never asserted (timeout)");
                    fail_count = fail_count + 1;
                    disable wait_done_wr;
                end
            end
            @(posedge clk); #1;
        end
    endtask

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        // Initialise
        clk        = 0;
        rst_n      = 0;
        cmd_valid  = 0;
        cmd_write  = 0;
        cmd_phy    = 0;
        cmd_reg    = 0;
        cmd_wdata  = 0;
        mdio_i     = 1'b1;   // pull-up when idle
        phy_active = 0;
        mdc_fall_cnt = 0;
        phy_tx_shift = 0;
        pass_count = 0;
        fail_count = 0;

        // Reset
        #50;
        rst_n = 1;
        #20;

        $display("");
        $display("========================================");
        $display("MDIO Master Tests");
        $display("========================================");

        // ------------------------------------------------------------------
        // Test 1: Read PHY ID1 register — DP83848J expected value 0x2000
        // This is the primary regression: before the S_RD_WAIT fix the
        // result came back as 0x1000 (= 0x2000 >> 1).
        // ------------------------------------------------------------------
        $display("");
        $display("-- Test 1: Read PHYID1 (phy=1 reg=2) expect 0x2000 --");
        mdio_read(5'd1, 5'd2, 16'h2000);
        check16("PHYID1  ", cmd_rdata, 16'h2000);

        // ------------------------------------------------------------------
        // Test 2: Read PHY ID2 — DP83848J expected value 0x5C90
        // Before fix: 0x2E48 (= 0x5C90 >> 1).
        // ------------------------------------------------------------------
        $display("");
        $display("-- Test 2: Read PHYID2 (phy=1 reg=3) expect 0x5C90 --");
        mdio_read(5'd1, 5'd3, 16'h5C90);
        check16("PHYID2  ", cmd_rdata, 16'h5C90);

        // ------------------------------------------------------------------
        // Test 3: Read all-zeros — shifted value would be 0x0000 either way;
        // sanity-check that the result is still 0x0000 (no spurious bits).
        // ------------------------------------------------------------------
        $display("");
        $display("-- Test 3: Read all-zeros data --");
        mdio_read(5'd1, 5'd0, 16'h0000);
        check16("ALL-ZERO", cmd_rdata, 16'h0000);

        // ------------------------------------------------------------------
        // Test 4: Read all-ones
        // Before fix: 0x7FFF (missing MSB); after fix: 0xFFFF.
        // ------------------------------------------------------------------
        $display("");
        $display("-- Test 4: Read all-ones data (0xFFFF) --");
        mdio_read(5'd1, 5'd0, 16'hFFFF);
        check16("ALL-ONES", cmd_rdata, 16'hFFFF);

        // ------------------------------------------------------------------
        // Test 5: Read value with LSB set — before fix, LSB was lost.
        // 0x0001 >> 1 = 0x0000; after fix: 0x0001.
        // ------------------------------------------------------------------
        $display("");
        $display("-- Test 5: Read 0x0001 (LSB stress) --");
        mdio_read(5'd1, 5'd0, 16'h0001);
        check16("LSB-SET ", cmd_rdata, 16'h0001);

        // ------------------------------------------------------------------
        // Test 6: Read 0xAAAA (alternating bits)
        // Before fix: 0x5555; after fix: 0xAAAA.
        // ------------------------------------------------------------------
        $display("");
        $display("-- Test 6: Read 0xAAAA (alternating bits) --");
        mdio_read(5'd1, 5'd0, 16'hAAAA);
        check16("ALT-AA  ", cmd_rdata, 16'hAAAA);

        // ------------------------------------------------------------------
        // Test 7: Read 0x5555 (alternating bits, opposite phase)
        // Before fix: 0x2AAA; after fix: 0x5555.
        // ------------------------------------------------------------------
        $display("");
        $display("-- Test 7: Read 0x5555 (alternating bits) --");
        mdio_read(5'd1, 5'd0, 16'h5555);
        check16("ALT-55  ", cmd_rdata, 16'h5555);

        // ------------------------------------------------------------------
        // Test 8: Write followed by read — write must not disturb the
        // S_RD_WAIT state (writes bypass it).  Value chosen so that a
        // spurious extra wait in write mode would cause cmd_done to arrive
        // 100 clk cycles late but not otherwise corrupt data.
        // ------------------------------------------------------------------
        $display("");
        $display("-- Test 8: Write then read (write bypass check) --");
        mdio_write_op(5'd1, 5'd0, 16'hBEEF);
        mdio_read(5'd1, 5'd0, 16'hBEEF);
        check16("WR->RD  ", cmd_rdata, 16'hBEEF);

        // ------------------------------------------------------------------
        // Test 9: Two back-to-back reads — second must give the correct value
        // (verifies state resets cleanly between operations).
        // ------------------------------------------------------------------
        $display("");
        $display("-- Test 9: Back-to-back reads --");
        mdio_read(5'd1, 5'd2, 16'h1234);
        check16("BBR-1   ", cmd_rdata, 16'h1234);
        mdio_read(5'd1, 5'd3, 16'h5678);
        check16("BBR-2   ", cmd_rdata, 16'h5678);

        // ------------------------------------------------------------------
        // Summary
        // ------------------------------------------------------------------
        $display("");
        $display("========================================");
        $display("MDIO Master Results: %0d PASS, %0d FAIL", pass_count, fail_count);
        $display("========================================");
        if (fail_count == 0)
            $display("ALL TESTS PASSED");
        else
            $display("SOME TESTS FAILED");
        $finish;
    end

    // Safety timeout
    initial begin
        #50000000;
        $display("FATAL: simulation timeout");
        $finish;
    end

endmodule
