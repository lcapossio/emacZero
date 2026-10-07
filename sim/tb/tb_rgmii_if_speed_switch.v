// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_rgmii_if_speed_switch.v - rgmii_if TXC across speed changes and reset.
// Changes cfg_speed between every pair of 1G / 100M / 10M at 50 consecutive
// clk_125 offsets (every phase of the TX counter) and checks that:
//   - every TXC high time is that of a speed in flight (4, 20 or 200 ns), so
//     a change never sends a runt pulse;
//   - every TXC low time is at least the shortest low time of those speeds;
//   - a 100M <-> 10M change whose bits resolve a cycle apart (through 11)
//     never runs a period at 1G;
//   - TXC stays low through reset and starts with a full pulse;
//   - after each change a burst loops back byte-exact at the new speed, so
//     TXC and the data stay aligned.
// clk_125_90 lags clk_125 by 2 ns, as on hardware.
// Verilog 2001
// =============================================================================

`timescale 1ns/1ps

module tb_rgmii_if_speed_switch;
    reg clk_125 = 0;
    reg clk_125_90 = 0;
    reg rst_n = 0;
    reg [1:0] cfg_speed = 2'b01;

    always #4 clk_125 = ~clk_125;  // 125 MHz
    initial begin
        #2;
        forever #4 clk_125_90 = ~clk_125_90;
    end

    wire [3:0] rgmii_txd;
    wire       rgmii_tx_ctl;
    wire       rgmii_txc;

    // The pins as a PHY sees them: the behavioral DDR model can glitch for
    // zero time at a clock edge, which the 10 ps inertial delay drops.
    wire [3:0] txd_s;
    wire       ctl_s, txc_s;
    assign #0.01 txd_s = rgmii_txd;
    assign #0.01 ctl_s = rgmii_tx_ctl;
    assign #0.01 txc_s = rgmii_txc;

    // Loopback with the same board delay on clock and data.
    wire [3:0] rgmii_rxd;
    wire       rgmii_rx_ctl;
    wire       rgmii_rxc;
    assign #3 rgmii_rxd    = txd_s;
    assign #3 rgmii_rx_ctl = ctl_s;
    assign #3 rgmii_rxc    = txc_s;

    reg  [7:0] tx_gmii_txd   = 8'h00;
    reg        tx_gmii_tx_en = 1'b0;
    wire [7:0] rx_gmii_rxd;
    wire       rx_gmii_rx_dv, rx_gmii_rx_er, rx_gmii_rx_ce;

    rgmii_if u_tx (
        .clk_125     (clk_125),
        .clk_125_90  (clk_125_90),
        .rst_n       (rst_n),
        .cfg_speed   (cfg_speed),
        .rgmii_txd   (rgmii_txd),
        .rgmii_tx_ctl(rgmii_tx_ctl),
        .rgmii_txc   (rgmii_txc),
        .rgmii_rxd   (4'd0),
        .rgmii_rx_ctl(1'b0),
        .rgmii_rxc   (1'b0),
        .gmii_txd    (tx_gmii_txd),
        .gmii_tx_en  (tx_gmii_tx_en),
        .gmii_tx_er  (1'b0),
        .gmii_rxd    (),
        .gmii_rx_dv  (),
        .gmii_rx_er  (),
        .gmii_rx_ce  ()
    );

    rgmii_if u_rx (
        .clk_125     (clk_125),
        .clk_125_90  (clk_125_90),
        .rst_n       (rst_n),
        .cfg_speed   (cfg_speed),
        .rgmii_txd   (),
        .rgmii_tx_ctl(),
        .rgmii_txc   (),
        .rgmii_rxd   (rgmii_rxd),
        .rgmii_rx_ctl(rgmii_rx_ctl),
        .rgmii_rxc   (rgmii_rxc),
        .gmii_txd    (8'd0),
        .gmii_tx_en  (1'b0),
        .gmii_tx_er  (1'b0),
        .gmii_rxd    (rx_gmii_rxd),
        .gmii_rx_dv  (rx_gmii_rx_dv),
        .gmii_rx_er  (rx_gmii_rx_er),
        .gmii_rx_ce  (rx_gmii_rx_ce)
    );

    integer pass_cnt = 0, fail_cnt = 0;

    task check;
        input [511:0] name;
        input         cond;
        begin
            if (cond) begin
                $display("PASS: %0s", name);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: %0s", name);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // ---- TXC pulse monitor ----
    // allow[0] = 1G, allow[1] = 100M, allow[2] = 10M: the speeds whose pulses
    // may be on the pin.
    reg  [2:0] allow = 3'b000;
    reg        mon_on = 0;
    realtime   t_r = -1.0, t_f = -1.0, w;
    integer    bad_hi = 0, bad_lo = 0, n_hi = 0, rst_hi = 0;

    function near;   // |a - b| <= 1 ps
        input real a, b;
        near = (a - b <= 0.001) && (b - a <= 0.001);
    endfunction

    function real min_low;
        input [2:0] a;
        min_low = a[0] ? 4.0 : a[1] ? 20.0 : 200.0;
    endfunction

    always @(posedge txc_s) begin
        if (!rst_n) rst_hi = rst_hi + 1;
        if (mon_on && t_f >= 0.0) begin
            w = $realtime - t_f;
            if (w < min_low(allow) - 0.001) begin
                if (bad_lo < 5)
                    $display("  TXC low %0.3f ns at %0t (allow %b)", w, $time, allow);
                bad_lo = bad_lo + 1;
            end
        end
        t_r = $realtime;
    end
    always @(negedge txc_s) begin
        if (mon_on && t_r >= 0.0) begin
            w = $realtime - t_r;
            n_hi = n_hi + 1;
            if (!((allow[0] && near(w, 4.0)) || (allow[1] && near(w, 20.0)) ||
                  (allow[2] && near(w, 200.0)))) begin
                if (bad_hi < 5)
                    $display("  TXC high %0.3f ns at %0t (allow %b)", w, $time, allow);
                bad_hi = bad_hi + 1;
            end
        end
        t_f = $realtime;
    end

    // ---- RX capture ----
    reg [7:0] rx_buf [0:7];
    integer   rx_idx = 0, er_bytes = 0;
    always @(posedge rgmii_rxc) begin
        if (rst_n && rx_gmii_rx_dv && rx_gmii_rx_ce) begin
            if (rx_idx < 8) rx_buf[rx_idx] = rx_gmii_rxd;
            rx_idx = rx_idx + 1;
            if (rx_gmii_rx_er) er_bytes = er_bytes + 1;
        end
    end

    function [1:0] code;    // speed index -> cfg_speed
        input integer s;
        code = (s == 0) ? 2'b00 : (s == 1) ? 2'b01 : 2'b10;
    endfunction
    function integer cpb;   // clk_125 cycles per byte
        input integer s;
        cpb = (s == 0) ? 1 : (s == 1) ? 10 : 100;
    endfunction

    localparam NB = 4;
    reg [7:0] pattern [0:NB-1];
    integer   k, mism, cur, from, to, off, bad_burst, trials;

    // Burst at the current speed; checks it loops back byte-exact.
    task burst;
        input integer s;
        begin
            rx_idx = 0; er_bytes = 0;
            @(negedge clk_125);
            tx_gmii_tx_en = 1'b1;
            for (k = 0; k < NB; k = k + 1) begin
                tx_gmii_txd = pattern[k] ^ off[7:0];
                repeat (cpb(s)) @(negedge clk_125);
            end
            tx_gmii_tx_en = 1'b0;
            tx_gmii_txd   = 8'h00;
            repeat (8 * cpb(s) + 20) @(negedge clk_125);
            mism = 0;
            for (k = 0; k < NB && k < rx_idx; k = k + 1)
                if (rx_buf[k] !== (pattern[k] ^ off[7:0])) mism = mism + 1;
            if (rx_idx != NB || er_bytes != 0 || mism != 0) begin
                if (bad_burst < 5)
                    $display("  burst %0d -> %0d offset %0d: %0d bytes, %0d wrong, %0d RX_ER",
                             from, to, off, rx_idx, mism, er_bytes);
                bad_burst = bad_burst + 1;
            end
        end
    endtask

    // Change to speed s and wait for it to settle: up to 2 synchronizer + 1
    // settle cycles, up to 50 cycles to the period boundary, then two periods.
    task go_speed;
        input integer s;
        begin
            allow[s] = 1'b1;
            cfg_speed = code(s);
            repeat (160) @(negedge clk_125);
            allow = 3'b000;
            allow[s] = 1'b1;
            cur = s;
        end
    endtask

    initial begin
        pattern[0] = 8'h12; pattern[1] = 8'hA5; pattern[2] = 8'h3C;
        pattern[3] = 8'hF0;
        bad_burst = 0; trials = 0; off = 0;

        // Reset with 100M selected: TXC must stay low, then start with full
        // 100M pulses (no 1G pulse from the reset value).
        cfg_speed = 2'b01;
        repeat (20) @(negedge clk_125);
        allow = 3'b010;
        mon_on = 1'b1;
        rst_n = 1'b1;
        repeat (160) @(negedge clk_125);
        cur = 1;
        check("TXC stays low through reset", rst_hi == 0);
        check("TXC after reset: full 100M pulses only",
              bad_hi == 0 && bad_lo == 0 && n_hi > 4);

        for (from = 0; from < 3; from = from + 1)
            for (to = 0; to < 3; to = to + 1)
                if (from != to)
                    for (off = 0; off < 50; off = off + 1) begin
                        if (cur != from) go_speed(from);
                        repeat (off) @(negedge clk_125);
                        // Between 100M and 10M both bits change; let them
                        // resolve one cycle apart, through 11 (1G), as a
                        // 2-bit synchronizer can.
                        if (from != 0 && to != 0) begin
                            cfg_speed = 2'b11;
                            @(negedge clk_125);
                        end
                        go_speed(to);
                        burst(to);
                        trials = trials + 1;
                    end

        $display("INFO: %0d speed changes, %0d TXC pulses, %0d bad high, %0d bad low, %0d bad bursts",
                 trials, n_hi, bad_hi, bad_lo, bad_burst);
        check("speed change: TXC high times all 4/20/200 ns", bad_hi == 0);
        check("speed change: no short TXC low time", bad_lo == 0);
        check("speed change: burst after each loops back exact",
              bad_burst == 0 && trials == 300);

        if (fail_cnt == 0) begin
            $display("PASS: %0d tests passed", pass_cnt);
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        end
        $finish;
    end

    initial begin
        #20000000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule
