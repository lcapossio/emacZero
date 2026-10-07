// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_rgmii_if_100m.v - Test rgmii_if at 100M (cfg_speed=01), then at 10M
// (cfg_speed=10). Verifies, through a TX -> RX pin loopback in which RX is
// clocked by the forwarded TXC, as a PHY would be:
//   - TX sends each byte as two TXC cycles, TXD[3:0] then TXD[7:4], with the
//     same nibble on both DDR halves of a cycle.
//   - RX pairs the two RXC cycles back into the original byte.
//   - RX holds gmii_rx_dv high across the whole burst and strobes gmii_rx_ce
//     once per byte, so a consumer sees one unbroken frame, not one per byte.
//   - TXC runs at 25 / 2.5 MHz with a 50% duty cycle, and each TXC edge is at
//     least 8 ns from any TXD / TX_CTL change (setup and hold at the PHY).
// clk_125_90 lags clk_125 by 2 ns, as on hardware.
// Verilog 2001
// =============================================================================

`timescale 1ns/1ps

module tb_rgmii_if_100m;
    reg clk_125 = 0;
    reg clk_125_90 = 0;
    reg rst_n = 0;
    reg [1:0] cfg_speed = 2'b01;

    always #4 clk_125 = ~clk_125;  // 125 MHz
    initial begin
        #2;
        forever #4 clk_125_90 = ~clk_125_90;
    end

    // RGMII pins (TX -> RX loopback)
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

    // Loopback with the same board delay on clock and data, so RX samples
    // where a PHY would.
    wire [3:0] rgmii_rxd;
    wire       rgmii_rx_ctl;
    wire       rgmii_rxc;
    assign #3 rgmii_rxd    = txd_s;
    assign #3 rgmii_rx_ctl = ctl_s;
    assign #3 rgmii_rxc    = txc_s;

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
        .gmii_tx_er  (tx_gmii_tx_er),
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

    // Capture RX bytes (dv && ce) and count dv envelopes (rising edges)
    reg [7:0]  rx_buf [0:31];
    integer    rx_idx = 0;
    integer    dv_bursts = 0;
    integer    er_bytes = 0;
    reg        dv_d = 0;

    always @(posedge rgmii_rxc) begin
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

    // ---- TXC timing monitor (armed per speed by the test sequence) ----
    reg      mon_on = 0;
    realtime t_rise, t_edge, t_data, min_margin;
    integer  txc_rises, bad_period, bad_high;
    realtime exp_half;

    function off_by;   // |a - b| above 1 ps
        input real a, b;
        off_by = (a - b > 0.001) || (b - a > 0.001);
    endfunction
    always @(txd_s or ctl_s) begin
        if (mon_on && ($realtime - t_edge) < min_margin)
            min_margin = $realtime - t_edge;
        t_data = $realtime;
    end
    always @(posedge txc_s) begin
        if (mon_on) begin
            if (($realtime - t_data) < min_margin)
                min_margin = $realtime - t_data;
            if (txc_rises > 0 && off_by($realtime - t_rise, 2.0 * exp_half))
                bad_period = bad_period + 1;
            txc_rises = txc_rises + 1;
        end
        t_rise = $realtime;
        t_edge = $realtime;
    end
    always @(negedge txc_s) begin
        if (mon_on) begin
            if (($realtime - t_data) < min_margin)
                min_margin = $realtime - t_data;
            if (txc_rises > 0 && off_by($realtime - t_rise, exp_half))
                bad_high = bad_high + 1;
        end
        t_edge = $realtime;
    end

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

    localparam N = 6;
    reg [7:0] pattern [0:N-1];
    integer k, bad, hold;

    // Each byte is held for 2 TXC periods (10 or 100 clk_125 cycles), as
    // gmii_cdc's pacer does.
    task send_burst;
        begin
            @(negedge clk_125);
            tx_gmii_tx_en = 1'b1;
            for (k = 0; k < N; k = k + 1) begin
                tx_gmii_txd = pattern[k];
                repeat (hold) @(negedge clk_125);
            end
            tx_gmii_tx_en = 1'b0;
            tx_gmii_txd   = 8'h00;
        end
    endtask

    task run_speed;
        input [1:0]   speed;
        input integer cycles_per_byte;
        input [63:0]  label;
        begin
            cfg_speed = speed;
            hold      = cycles_per_byte;
            exp_half  = cycles_per_byte * 2.0;   // TXC half period, ns
            repeat (4 * cycles_per_byte) @(negedge clk_125);

            rx_idx = 0; dv_bursts = 0; er_bytes = 0;
            txc_rises = 0; bad_period = 0; bad_high = 0;
            min_margin = 1.0e9;
            mon_on = 1'b1;

            send_burst;
            repeat (8 * cycles_per_byte) @(negedge clk_125);
            mon_on = 1'b0;

            check({label, ": RX received every byte"}, rx_idx == N);
            bad = 0;
            for (k = 0; k < N && k < rx_idx; k = k + 1)
                if (rx_buf[k] !== pattern[k]) begin
                    $display("  byte %0d: got %02x expected %02x",
                             k, rx_buf[k], pattern[k]);
                    bad = bad + 1;
                end
            check({label, ": bytes round-trip exactly (low nibble first)"},
                  bad == 0 && rx_idx == N);
            check({label, ": gmii_rx_dv is one unbroken envelope"},
                  dv_bursts == 1);
            check({label, ": no RX_ER on any byte"}, er_bytes == 0);
            $display("INFO: %0s TXC rises %0d, min TXC-to-data distance %0.1f ns",
                     label, txc_rises, min_margin);
            check({label, ": TXC period and 50% duty cycle"},
                  txc_rises > 4 && bad_period == 0 && bad_high == 0);
            check({label, ": TXC edges >= 8 ns from TXD/TX_CTL changes"},
                  min_margin > 7.999);
        end
    endtask

    initial begin
        pattern[0] = 8'h12; pattern[1] = 8'h34; pattern[2] = 8'h56;
        pattern[3] = 8'h78; pattern[4] = 8'hA5; pattern[5] = 8'h0F;

        tx_gmii_txd = 0; tx_gmii_tx_en = 0; tx_gmii_tx_er = 0;
        t_rise = 0; t_edge = 0; t_data = 0; min_margin = 1.0e9;
        txc_rises = 0; bad_period = 0; bad_high = 0; exp_half = 20.0;
        hold = 10;
        rst_n = 0;
        #100;
        rst_n = 1;
        #100;

        run_speed(2'b01, 10,  "100M");
        run_speed(2'b10, 100, "10M");

        if (fail_cnt == 0) begin
            $display("PASS: %0d tests passed", pass_cnt);
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        end
        $finish;
    end

    initial begin
        #200000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule
