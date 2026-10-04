// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_rgmii_if_100m.v - Test rgmii_if at 100M (cfg_speed=01)
// Verifies, through a TX -> RX pin loopback:
//   - TX sends each byte as two TXC cycles, TXD[3:0] then TXD[7:4], with the
//     same nibble on both DDR halves of a cycle.
//   - RX pairs the two RXC cycles back into the original byte.
//   - RX holds gmii_rx_dv high across the whole burst and strobes gmii_rx_ce
//     once per byte, so a consumer sees one unbroken frame, not one per byte.
// Verilog 2001
// =============================================================================

`timescale 1ns/1ps

module tb_rgmii_if_100m;
    reg clk_25 = 0;
    reg rst_n = 0;

    always #20 clk_25 = ~clk_25;  // 25 MHz

    // RGMII pins (TX -> RX loopback)
    wire [3:0] rgmii_txd;
    wire       rgmii_tx_ctl;
    wire       rgmii_txc;

    // Pin delay well inside the 40 ns RXC period, like a PHY/board path, so
    // RX samples each nibble mid-cycle rather than racing the launch edge.
    wire [3:0] rgmii_rxd;
    wire       rgmii_rx_ctl;
    assign #10 rgmii_rxd    = rgmii_txd;
    assign #10 rgmii_rx_ctl = rgmii_tx_ctl;

    // TX side GMII inputs
    reg  [7:0] tx_gmii_txd;
    reg        tx_gmii_tx_en;
    reg        tx_gmii_tx_er;

    // RX side GMII outputs
    wire [7:0] rx_gmii_rxd;
    wire       rx_gmii_rx_dv;
    wire       rx_gmii_rx_er;
    wire       rx_gmii_rx_ce;

    rgmii_if u_tx (
        .clk_125     (1'b0),       // unused at 100M
        .clk_125_90  (1'b0),
        .clk_25      (clk_25),
        .clk_2_5     (1'b0),
        .rst_n       (rst_n),
        .cfg_speed   (2'b01),       // 100M

        .rgmii_txd   (rgmii_txd),
        .rgmii_tx_ctl(rgmii_tx_ctl),
        .rgmii_txc   (rgmii_txc),
        .rgmii_rxd   (4'd0),
        .rgmii_rx_ctl(1'b0),
        .rgmii_rxc   (1'b0),

        .gmii_txd    (tx_gmii_txd),
        .gmii_tx_en  (tx_gmii_tx_en),
        .gmii_tx_er  (tx_gmii_tx_er),
        .gmii_rxd    (),
        .gmii_rx_dv  (),
        .gmii_rx_er  (),
        .gmii_rx_ce  ()
    );

    rgmii_if u_rx (
        .clk_125     (1'b0),
        .clk_125_90  (1'b0),
        .clk_25      (clk_25),
        .clk_2_5     (1'b0),
        .rst_n       (rst_n),
        .cfg_speed   (2'b01),

        .rgmii_txd   (),
        .rgmii_tx_ctl(),
        .rgmii_txc   (),
        .rgmii_rxd   (rgmii_rxd),
        .rgmii_rx_ctl(rgmii_rx_ctl),
        .rgmii_rxc   (clk_25),

        .gmii_txd    (8'd0),
        .gmii_tx_en  (1'b0),
        .gmii_tx_er  (1'b0),
        .gmii_rxd    (rx_gmii_rxd),
        .gmii_rx_dv  (rx_gmii_rx_dv),
        .gmii_rx_er  (rx_gmii_rx_er),
        .gmii_rx_ce  (rx_gmii_rx_ce)
    );

    integer pass_cnt = 0, fail_cnt = 0;

    // Capture RX bytes (dv && ce) and count dv envelopes (rising edges)
    reg [7:0]  rx_buf [0:31];
    integer    rx_idx = 0;
    integer    dv_bursts = 0;
    integer    er_bytes = 0;
    reg        dv_d = 0;

    always @(posedge clk_25) begin
        if (rst_n) begin
            if (rx_gmii_rx_dv && rx_gmii_rx_ce) begin
                if (rx_idx < 32) rx_buf[rx_idx] = rx_gmii_rxd;
                rx_idx = rx_idx + 1;
                if (rx_gmii_rx_er) er_bytes = er_bytes + 1;
            end
            if (rx_gmii_rx_dv && !dv_d) dv_bursts = dv_bursts + 1;
            dv_d = rx_gmii_rx_dv;
        end
    end

    // Each byte is held for two clk_25 cycles, as gmii_cdc's 100M pacer does.
    task send_byte;
        input [7:0] b;
        begin
            tx_gmii_txd = b;
            @(negedge clk_25);
            @(negedge clk_25);
        end
    endtask

    localparam N = 6;
    reg [7:0] pattern [0:N-1];
    integer k, bad;

    initial begin
        pattern[0] = 8'h12; pattern[1] = 8'h34; pattern[2] = 8'h56;
        pattern[3] = 8'h78; pattern[4] = 8'hA5; pattern[5] = 8'h0F;

        tx_gmii_txd = 0; tx_gmii_tx_en = 0; tx_gmii_tx_er = 0;
        rst_n = 0;
        #100;
        rst_n = 1;
        #100;

        @(negedge clk_25);
        tx_gmii_tx_en = 1'b1;
        for (k = 0; k < N; k = k + 1)
            send_byte(pattern[k]);
        tx_gmii_tx_en = 1'b0;
        tx_gmii_txd   = 8'h00;

        repeat (20) @(posedge clk_25);

        if (rx_idx == N) begin
            $display("PASS: 100M RX received %0d bytes", rx_idx);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: 100M RX received %0d bytes, expected %0d", rx_idx, N);
            fail_cnt = fail_cnt + 1;
        end

        bad = 0;
        for (k = 0; k < N && k < rx_idx; k = k + 1)
            if (rx_buf[k] !== pattern[k]) begin
                $display("  byte %0d: got %02x expected %02x", k, rx_buf[k], pattern[k]);
                bad = bad + 1;
            end
        if (bad == 0 && rx_idx == N) begin
            $display("PASS: 100M bytes round-trip exactly (low nibble first)");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: 100M %0d byte(s) corrupted", bad);
            fail_cnt = fail_cnt + 1;
        end

        if (dv_bursts == 1) begin
            $display("PASS: gmii_rx_dv is one unbroken envelope for the burst");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: gmii_rx_dv rose %0d times for one burst", dv_bursts);
            fail_cnt = fail_cnt + 1;
        end

        if (er_bytes == 0) begin
            $display("PASS: no RX_ER on any byte");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: RX_ER on %0d byte(s)", er_bytes);
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

    initial begin
        #100000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule
