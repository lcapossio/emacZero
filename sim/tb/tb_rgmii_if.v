// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_rgmii_if.v - Testbench for rgmii_if.v DDR interface
// Tests: TX nibble encoding, TX_CTL rising/falling semantics,
//        RX nibble reassembly, RX_CTL decoding, full loopback with
//        multi-byte GMII frames, TX_ER encoding.
// Uses behavioral ddr_output/ddr_input models.
// =============================================================================
`timescale 1ns / 1ps

module tb_rgmii_if;

    // ---- Clocks ----
    // 125 MHz = 8ns period. 90-degree shift = 2ns delay.
    reg clk_125;
    reg clk_125_90;
    reg rst_n;

    initial clk_125 = 0;
    always #4 clk_125 = ~clk_125;  // 125 MHz

    // 90-degree shifted clock: 2ns delay from clk_125
    initial begin
        clk_125_90 = 0;
        #2;
        forever #4 clk_125_90 = ~clk_125_90;
    end

    // ---- TX-side GMII inputs ----
    reg [7:0]  tx_gmii_txd;
    reg        tx_gmii_tx_en;
    reg        tx_gmii_tx_er;

    // ---- RGMII wires (TX to RX loopback) ----
    wire [3:0] rgmii_txd;
    wire       rgmii_tx_ctl;
    wire       rgmii_txc;

    // ---- RX-side GMII outputs ----
    wire [7:0] rx_gmii_rxd;
    wire       rx_gmii_rx_dv;
    wire       rx_gmii_rx_er;

    // TX-side rgmii_if instance
    rgmii_if u_tx (
        .clk_125     (clk_125),
        .clk_125_90  (clk_125_90),
        .clk_25      (1'b0),
        .clk_2_5     (1'b0),
        .rst_n       (rst_n),
        .cfg_speed   (2'b00),  // 1G mode
        .rgmii_txd   (rgmii_txd),
        .rgmii_tx_ctl(rgmii_tx_ctl),
        .rgmii_txc   (rgmii_txc),
        .rgmii_rxd   (4'd0),
        .rgmii_rx_ctl(1'b0),
        .rgmii_rxc   (clk_125),
        .gmii_txd    (tx_gmii_txd),
        .gmii_tx_en  (tx_gmii_tx_en),
        .gmii_tx_er  (tx_gmii_tx_er),
        .gmii_rxd    (),
        .gmii_rx_dv  (),
        .gmii_rx_er  ()
    );

    rgmii_if u_rx (
        .clk_125     (clk_125),
        .clk_125_90  (clk_125_90),
        .clk_25      (1'b0),
        .clk_2_5     (1'b0),
        .rst_n       (rst_n),
        .cfg_speed   (2'b00),
        .rgmii_txd   (),
        .rgmii_tx_ctl(),
        .rgmii_txc   (),
        .rgmii_rxd   (rgmii_txd),
        .rgmii_rx_ctl(rgmii_tx_ctl),
        .rgmii_rxc   (clk_125_90),
        .gmii_txd    (8'd0),
        .gmii_tx_en  (1'b0),
        .gmii_tx_er  (1'b0),
        .gmii_rxd    (rx_gmii_rxd),
        .gmii_rx_dv  (rx_gmii_rx_dv),
        .gmii_rx_er  (rx_gmii_rx_er)
    );

    integer pass_cnt, fail_cnt;

    task check;
        input [255:0] name;
        input [31:0]  actual;
        input [31:0]  expected;
        begin
            if (actual === expected) begin
                $display("PASS: %0s = 0x%0x", name, actual);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: %0s = 0x%0x, expected 0x%0x", name, actual, expected);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // ---- RX capture ----
    // ddr_input SAME_EDGE_PIPELINED has 1-cycle latency for q2 alignment.
    // So GMII RX output appears ~2 clk_125 cycles after GMII TX input.
    // We capture a sequence of RX outputs and compare.
    reg [7:0]  rx_cap [0:31];
    reg        rx_dv_cap [0:31];
    reg        rx_er_cap [0:31];
    integer    rx_cap_idx;
    reg        rx_capturing;

    always @(posedge clk_125) begin
        if (!rst_n) begin
            rx_cap_idx  <= 0;
            rx_capturing <= 0;
        end else if (rx_capturing) begin
            rx_cap[rx_cap_idx]    <= rx_gmii_rxd;
            rx_dv_cap[rx_cap_idx] <= rx_gmii_rx_dv;
            rx_er_cap[rx_cap_idx] <= rx_gmii_rx_er;
            rx_cap_idx <= rx_cap_idx + 1;
        end
    end

    integer i;

    initial begin
        $dumpfile("tb_rgmii_if.vcd");
        $dumpvars(0, tb_rgmii_if);

        pass_cnt = 0;
        fail_cnt = 0;
        rst_n = 0;
        tx_gmii_txd   = 8'd0;
        tx_gmii_tx_en = 1'b0;
        tx_gmii_tx_er = 1'b0;
        #50;
        rst_n = 1;
        #50;

        // =================================================================
        // Test 1: TX nibble encoding on RGMII wires
        // Drive gmii_txd = 0xA5, tx_en = 1, tx_er = 0
        // Expected: rising edge: txd[3:0] = 4'h5, ctl = 1
        //           falling edge: txd[3:0] = 4'hA, ctl = 1 (en XOR er = 1^0=1)
        // =================================================================
        @(negedge clk_125);
        tx_gmii_txd   = 8'hA5;
        tx_gmii_tx_en = 1'b1;
        tx_gmii_tx_er = 1'b0;

        // Wait for ddr_output to register (posedge captures d1, negedge captures d2)
        @(posedge clk_125); #1;
        // After posedge: rgmii_txd should show lower nibble (d1 captured on posedge)
        check("TX rising nibble (0xA5)", {28'd0, rgmii_txd}, 32'h5);
        check("TX_CTL rising (en=1,er=0)", {31'd0, rgmii_tx_ctl}, 32'h1);

        @(negedge clk_125); #1;
        // After negedge: rgmii_txd should show upper nibble (d2 captured on negedge)
        check("TX falling nibble (0xA5)", {28'd0, rgmii_txd}, 32'hA);
        // TX_CTL falling = tx_en XOR tx_er = 1^0 = 1
        check("TX_CTL falling (en=1,er=0)", {31'd0, rgmii_tx_ctl}, 32'h1);

        // =================================================================
        // Test 2: TX_CTL with error: tx_en=1, tx_er=1
        // CTL rising = tx_en = 1, CTL falling = tx_en XOR tx_er = 0
        // =================================================================
        @(negedge clk_125);
        tx_gmii_txd   = 8'h3C;
        tx_gmii_tx_en = 1'b1;
        tx_gmii_tx_er = 1'b1;

        @(posedge clk_125); #1;
        check("TX rising nibble (0x3C)", {28'd0, rgmii_txd}, 32'hC);
        check("TX_CTL rising (en=1,er=1)", {31'd0, rgmii_tx_ctl}, 32'h1);

        @(negedge clk_125); #1;
        check("TX falling nibble (0x3C)", {28'd0, rgmii_txd}, 32'h3);
        check("TX_CTL falling (en=1,er=1)", {31'd0, rgmii_tx_ctl}, 32'h0);

        // =================================================================
        // Test 3: TX idle: tx_en=0
        // CTL rising = 0, CTL falling = 0 XOR 0 = 0
        // =================================================================
        @(negedge clk_125);
        tx_gmii_txd   = 8'h00;
        tx_gmii_tx_en = 1'b0;
        tx_gmii_tx_er = 1'b0;

        @(posedge clk_125); #1;
        check("TX_CTL rising (idle)", {31'd0, rgmii_tx_ctl}, 32'h0);

        // =================================================================
        // Test 4: Full loopback - multi-byte GMII frame through TX DDR
        //         encoding and RX DDR decoding
        // Drive 8 bytes: 0x01 0x23 0x45 0x67 0x89 0xAB 0xCD 0xEF
        // with tx_en=1, tx_er=0. Verify RX reconstructs same bytes.
        // =================================================================
        #20;
        rx_cap_idx   = 0;
        rx_capturing = 1;

        // Drive 8 bytes over 8 clk_125 cycles
        @(negedge clk_125);
        tx_gmii_tx_en = 1'b1;
        tx_gmii_tx_er = 1'b0;
        tx_gmii_txd   = 8'h01; @(negedge clk_125);
        tx_gmii_txd   = 8'h23; @(negedge clk_125);
        tx_gmii_txd   = 8'h45; @(negedge clk_125);
        tx_gmii_txd   = 8'h67; @(negedge clk_125);
        tx_gmii_txd   = 8'h89; @(negedge clk_125);
        tx_gmii_txd   = 8'hAB; @(negedge clk_125);
        tx_gmii_txd   = 8'hCD; @(negedge clk_125);
        tx_gmii_txd   = 8'hEF; @(negedge clk_125);
        tx_gmii_tx_en = 1'b0;
        tx_gmii_txd   = 8'h00;

        // Wait for pipeline: ddr_output(1 edge) + wire + ddr_input(1+pipeline) = ~3 cycles
        repeat (6) @(posedge clk_125);
        rx_capturing = 0;

        // Find the first rx_dv=1 in the capture buffer
        begin : find_frame
            integer start_idx, frame_len, j;
            start_idx = -1;
            frame_len = 0;
            for (j = 0; j < rx_cap_idx; j = j + 1) begin
                if (rx_dv_cap[j] && start_idx < 0)
                    start_idx = j;
                if (rx_dv_cap[j])
                    frame_len = frame_len + 1;
            end

            if (start_idx >= 0 && frame_len == 8) begin
                $display("PASS: loopback frame length = %0d", frame_len);
                pass_cnt = pass_cnt + 1;

                // Verify data
                begin : verify_data
                    integer bad, k;
                    reg [7:0] expected_bytes [0:7];
                    bad = 0;
                    expected_bytes[0] = 8'h01; expected_bytes[1] = 8'h23;
                    expected_bytes[2] = 8'h45; expected_bytes[3] = 8'h67;
                    expected_bytes[4] = 8'h89; expected_bytes[5] = 8'hAB;
                    expected_bytes[6] = 8'hCD; expected_bytes[7] = 8'hEF;
                    for (k = 0; k < 8; k = k + 1) begin
                        if (rx_cap[start_idx + k] !== expected_bytes[k]) begin
                            $display("  byte[%0d]: got 0x%02x, expected 0x%02x",
                                     k, rx_cap[start_idx + k], expected_bytes[k]);
                            bad = 1;
                        end
                    end
                    if (!bad) begin
                        $display("PASS: loopback data integrity (8 bytes)");
                        pass_cnt = pass_cnt + 1;
                    end else begin
                        $display("FAIL: loopback data mismatch");
                        fail_cnt = fail_cnt + 1;
                    end
                end

                // Verify no rx_er during normal frame
                begin : verify_no_er
                    integer er_seen, k;
                    er_seen = 0;
                    for (k = 0; k < 8; k = k + 1)
                        if (rx_er_cap[start_idx + k]) er_seen = 1;
                    if (!er_seen) begin
                        $display("PASS: no rx_er during frame");
                        pass_cnt = pass_cnt + 1;
                    end else begin
                        $display("FAIL: rx_er asserted during clean frame");
                        fail_cnt = fail_cnt + 1;
                    end
                end
            end else begin
                $display("FAIL: loopback frame not found (start=%0d len=%0d cap=%0d)",
                         start_idx, frame_len, rx_cap_idx);
                fail_cnt = fail_cnt + 1;
            end
        end

        // =================================================================
        // Test 5: TX_ER encoding through loopback
        // Drive 2 bytes with tx_er=1, verify rx_er=1 on RX side
        // =================================================================
        #20;
        rx_cap_idx   = 0;
        rx_capturing = 1;

        @(negedge clk_125);
        tx_gmii_tx_en = 1'b1;
        tx_gmii_tx_er = 1'b1;
        tx_gmii_txd   = 8'hFF; @(negedge clk_125);
        tx_gmii_txd   = 8'h00; @(negedge clk_125);
        tx_gmii_tx_en = 1'b0;
        tx_gmii_tx_er = 1'b0;
        tx_gmii_txd   = 8'h00;

        repeat (6) @(posedge clk_125);
        rx_capturing = 0;

        begin : find_er_frame
            integer start_idx, j;
            start_idx = -1;
            for (j = 0; j < rx_cap_idx; j = j + 1) begin
                if (rx_dv_cap[j] && start_idx < 0)
                    start_idx = j;
            end
            if (start_idx >= 0 && rx_er_cap[start_idx]) begin
                $display("PASS: rx_er propagated through DDR loopback");
                pass_cnt = pass_cnt + 1;
            end else if (start_idx >= 0) begin
                $display("FAIL: rx_er not seen (start=%0d, er=%0b)", start_idx, rx_er_cap[start_idx]);
                fail_cnt = fail_cnt + 1;
            end else begin
                $display("FAIL: tx_er frame not received");
                fail_cnt = fail_cnt + 1;
            end
        end

        // =================================================================
        // Summary
        // =================================================================
        #20;
        if (fail_cnt == 0) begin
            $display("PASS: %0d tests passed", pass_cnt);
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        end
        $finish;
    end

endmodule
