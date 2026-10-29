// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_rgmii_lb_selftest.v - Pre-silicon check of the Arty RGMII loopback self-test
// Runs rgmii_lb_selftest at 1G for two passes of its 8-entry length table
// (46..9000-byte payloads), then at 100M for one pass and at 10M for the two
// shortest frames, checking the counters it will report on hardware after each
// speed: every frame exact and clean, in order. At 1G and 100M it also sends
// a PAUSE frame to itself, with PAUSE_CTRL rx_en set (the longest gap between
// generator frames must be the pause, within two frame times) and, at 1G,
// clear (the gap stays normal); each time the PAUSE frame must come back
// exact. The pads are modelled as plain wires (no buffer or IDELAY delays),
// so this checks the self-test logic, the speed switching and the RGMII path,
// not the pad timing. Then corrupts one looped-back RX nibble to prove the
// checker flags bad frames.
// =============================================================================
`timescale 1ns / 1ps

module tb_rgmii_lb_selftest;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg [31:0] ctrl = 32'd0;
    wire [327:0] st;
    wire [5:0] pad;
    always #5 clk = ~clk;

    rgmii_lb_selftest uut (.clk(clk), .rst_n(rst_n), .ctrl(ctrl), .status(st), .pad(pad));

    wire [31:0] tx_frames = st[31:0];
    wire [31:0] rx_ok     = st[63:32];
    wire [31:0] rx_ok_big = st[95:64];
    wire [31:0] rx_bad    = st[127:96];
    wire [31:0] rx_terr   = st[159:128];
    wire [31:0] seq_gap   = st[191:160];
    wire [15:0] max_ok    = st[207:192];
    wire [1:0]  spd_cur   = st[257:256];
    wire [4:0]  tap_cur   = st[262:258];
    wire        p_rx_cur  = st[263];
    wire [31:0] max_gap   = st[295:264];
    wire [15:0] p_ok      = st[311:296];
    wire [15:0] p_bad     = st[327:312];

    integer pass_cnt = 0, fail_cnt = 0;
    task check;
        input [511:0] name;
        input         cond;
        begin
            if (cond) begin $display("PASS: %0s", name); pass_cnt = pass_cnt + 1; end
            else      begin $display("FAIL: %0s", name); fail_cnt = fail_cnt + 1; end
        end
    endtask

    task show;
        $display("INFO: speed=%0d tx=%0d ok=%0d ok_big=%0d bad=%0d terr=%0d gap=%0d max_ok=%0d init=%0d marker=%h",
                 spd_cur, tx_frames, rx_ok, rx_ok_big, rx_bad, rx_terr, seq_gap, max_ok,
                 st[240], st[255:244]);
    endtask

    // Stop traffic, select a speed, wait for the CTRL write, clear the counters.
    task set_speed;
        input [1:0] spd;
        begin
            ctrl[0]   = 1'b0;
            ctrl[3:2] = spd;
            wait (spd_cur == spd && st[240]);
            #2000;
            ctrl[1] = 1'b1; #100; ctrl[1] = 1'b0; #100;
        end
    endtask

    // Run until n frames were handed to the MAC, stop, then wait until every
    // frame sent has been judged (or max_ns passes) and 10 us more.
    task run_frames;
        input integer n;
        input integer max_ns;
        integer waited;
        begin
            ctrl[0] = 1'b1;
            wait (tx_frames >= n);
            ctrl[0] = 1'b0;
            waited = 0;
            while (rx_ok + rx_bad < tx_frames && waited < max_ns) begin
                #1000;
                waited = waited + 1000;
            end
            #10000;
            show;
        end
    endtask

    // With PAUSE_CTRL rx_en = rx_en: clear, run, send a PAUSE of q quanta once
    // two frames have gone, run on for the pause (dur_cyc clk_125 cycles) and
    // three frame times (fm_cyc each), stop and drain.
    task pause_run;
        input [15:0]  q;
        input         rx_en;
        input integer dur_cyc;
        input integer fm_cyc;
        integer waited;
        begin
            ctrl[26] = rx_en;
            wait (p_rx_cur == rx_en && st[240]);
            ctrl[25:10] = q;
            ctrl[1] = 1'b1; #100; ctrl[1] = 1'b0; #100;
            ctrl[0] = 1'b1;
            wait (tx_frames >= 2);
            ctrl[27] = 1'b1; #100; ctrl[27] = 1'b0;
            wait (p_ok + p_bad >= 1);
            #(8 * (dur_cyc + 3 * fm_cyc));
            ctrl[0] = 1'b0;
            waited = 0;
            while (rx_ok + rx_bad < tx_frames && waited < 16 * fm_cyc) begin
                #1000;
                waited = waited + 1000;
            end
            #10000;
            show;
            $display("INFO: PAUSE q=%0d rx_en=%0d: p_ok=%0d p_bad=%0d max_gap=%0d (pause %0d, frame %0d cycles)",
                     q, rx_en, p_ok, p_bad, max_gap, dur_cyc, fm_cyc);
        end
    endtask

    // PAUSE checks after pause_run: the frame came back exact, the data
    // frames are still all exact and in order, and the longest gap is the
    // pause (honored) or no longer than two frame times (not honored).
    task pause_check;
        input [8*8-1:0] tag;
        input           honored;
        input integer   dur_cyc;
        input integer   fm_cyc;
        begin
            check({tag, ": PAUSE frame came back exact"}, p_ok == 1 && p_bad == 0);
            check({tag, ": data frames still exact and in order"},
                  tx_frames >= 2 && rx_ok == tx_frames && rx_bad == 0 && seq_gap == 0);
            if (honored)
                check({tag, ": longest gap is the pause, within two frames"},
                      max_gap + 2 * fm_cyc >= dur_cyc && max_gap <= dur_cyc + 2 * fm_cyc);
            else
                check({tag, ": longest gap stays within two frames"},
                      max_gap <= 2 * fm_cyc);
        end
    endtask

    initial begin
        #200 rst_n = 1'b1;
        #2000;
        check("marker present", st[255:244] == 12'hB0C);
        check("CSR init done", st[240]);
        check("IDELAYCTRL ready (model)", st[243]);

        // Tap load: the status reports the loaded tap.
        ctrl[8:4] = 5'd13; #100; ctrl[9] = 1'b1; #100; ctrl[9] = 1'b0; #100;
        check("tap 13 loaded", tap_cur == 5'd13);

        // 1G: two passes of the length table.
        run_frames(16, 300000);
        check("1G: 16+ frames sent", tx_frames >= 16);
        check("1G: every sent frame received exact", rx_ok == tx_frames);
        check("1G: big frames (>4083 B) received exact", rx_ok_big == (tx_frames / 8) * 3);
        check("1G: max exact frame is 9014 B (9018 with FCS)", max_ok == 16'd9014);
        check("1G: no bad frames, terror or gaps",
              rx_bad == 0 && rx_terr == 0 && seq_gap == 0);

        // 1G PAUSE: 1024 quanta x 512 ns = 65536 cycles; the longest frame
        // (9018 B + preamble + IFG) is 9038 cycles.
        pause_run(16'd1024, 1'b1, 65536, 9038);
        pause_check("1G on", 1'b1, 65536, 9038);
        pause_run(16'd1024, 1'b0, 65536, 9038);
        pause_check("1G off", 1'b0, 65536, 9038);

        // 100M: one pass, ending back at the start of the table.
        set_speed(2'b01);
        check("100M: CTRL speed written", spd_cur == 2'b01);
        run_frames(8, 2000000);
        check("100M: every sent frame received exact", tx_frames >= 8 && rx_ok == tx_frames);
        check("100M: big frames received exact", rx_ok_big >= 3);
        check("100M: max exact frame is 9014 B", max_ok == 16'd9014);
        check("100M: no bad frames, terror or gaps",
              rx_bad == 0 && rx_terr == 0 && seq_gap == 0);

        // 100M PAUSE: 1024 quanta x 5.12 us = 655360 cycles; the longest
        // frame is 90380 cycles. Through rgmii_if's nibble pairing.
        pause_run(16'd1024, 1'b1, 655360, 90380);
        pause_check("100M on", 1'b1, 655360, 90380);

        // 10M: the two shortest frames (46 and 60-byte payloads).
        set_speed(2'b10);
        check("10M: CTRL speed written", spd_cur == 2'b10);
        run_frames(2, 10000000);
        check("10M: every sent frame received exact", tx_frames >= 2 && rx_ok == tx_frames);
        check("10M: no bad frames, terror or gaps",
              rx_bad == 0 && rx_terr == 0 && seq_gap == 0);

        // Fault injection at 1G: flip one looped-back RXD bit mid-frame.
        set_speed(2'b00);
        ctrl[0] = 1'b1;
        wait (uut.rgmii_tx_ctl);
        repeat (40) @(posedge uut.clk_125);     // inside the frame, past the SFD
        @(negedge uut.clk_125);
        force uut.rx_dly = uut.pad_in[4:0] ^ 5'b00001;
        @(negedge uut.clk_125);
        release uut.rx_dly;
        wait (tx_frames >= 4);
        ctrl[0] = 1'b0;
        #300000;
        show;
        check("fault: corrupted frame counted bad", rx_bad == 1);
        check("fault: corrupted frame flagged terror (FCS)", rx_terr == 1);
        check("fault: other frames still exact", rx_ok == tx_frames - 1);

        if (fail_cnt == 0) begin
            $display("PASS: %0d tests passed", pass_cnt);
            $display("ALL TESTS PASSED");
        end else
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        $finish;
    end

    initial begin #60000000; $display("FAIL: simulation timeout"); $finish; end
endmodule
