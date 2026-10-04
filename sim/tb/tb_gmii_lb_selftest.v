// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_gmii_lb_selftest.v - Pre-silicon check of the Arty GMII loopback self-test
// Runs gmii_lb_selftest for two passes of its 8-entry length table (46..9000-
// byte payloads), stops traffic, and checks the counters it will report on
// hardware: every frame exact and clean, in order, including the big ones.
// Then injects a fault (corrupts looped-back bytes of one frame) to prove the checker
// actually flags bad frames rather than passing everything.
// =============================================================================
`timescale 1ns / 1ps

module tb_gmii_lb_selftest;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    reg [1:0] ctrl = 2'b00;
    wire [255:0] st;
    always #5 clk = ~clk;

    gmii_lb_selftest uut (.clk(clk), .rst_n(rst_n), .ctrl(ctrl), .status(st));

    wire [31:0] tx_frames = st[31:0];
    wire [31:0] rx_ok     = st[63:32];
    wire [31:0] rx_ok_big = st[95:64];
    wire [31:0] rx_bad    = st[127:96];
    wire [31:0] rx_terr   = st[159:128];
    wire [31:0] seq_gap   = st[191:160];
    wire [15:0] max_ok    = st[207:192];

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
        $display("INFO: tx=%0d ok=%0d ok_big=%0d bad=%0d terr=%0d gap=%0d max_ok=%0d init=%0d marker=%h",
                 tx_frames, rx_ok, rx_ok_big, rx_bad, rx_terr, seq_gap, max_ok,
                 st[240], st[255:244]);
    endtask

    initial begin
        #200 rst_n = 1'b1;
        #2000;
        check("marker present", st[255:244] == 12'hB0A);
        check("CSR init done", st[240]);

        ctrl[0] = 1'b1;
        wait (tx_frames >= 16);
        ctrl[0] = 1'b0;
        #300000;                        // drain
        show;
        check("16+ frames sent", tx_frames >= 16);
        check("every sent frame received exact", rx_ok == tx_frames);
        check("big frames (>4083 B) received exact", rx_ok_big == (tx_frames / 8) * 3);
        check("max exact frame is 9014 B (9018 with FCS)", max_ok == 16'd9014);
        check("no bad frames", rx_bad == 0);
        check("no terror", rx_terr == 0);
        check("no sequence gaps", seq_gap == 0);

        // Fault injection: flip one payload bit on the loopback wire mid-frame.
        ctrl[1] = 1'b1; #100; ctrl[1] = 1'b0; #100;
        ctrl[0] = 1'b1;
        wait (uut.gmii_tx_en);
        // Forced on gmii_if's RX capture register: forcing the port itself
        // would also force the looped-back net it is tied to.
        repeat (30) @(posedge uut.clk_125);    // inside the frame, past the SFD
        @(negedge uut.clk_125);
        force uut.u_lb_mac.gen_gmii.u_gmii_if.gmii_rxd_int =
              uut.u_lb_mac.gen_gmii.u_gmii_if.gmii_rxd_int ^ 8'h01;
        @(negedge uut.clk_125);
        release uut.u_lb_mac.gen_gmii.u_gmii_if.gmii_rxd_int;
        wait (tx_frames >= 4);
        ctrl[0] = 1'b0;
        #300000;
        show;
        check("fault: corrupted frame counted bad", rx_bad == 1);
        check("fault: corrupted frame flagged terror (FCS)", rx_terr == 1);
        check("fault: other frames still exact", rx_ok == tx_frames - 1);

        // Clear mid-frame: corrupt one checker input byte (no FCS error, so
        // only the byte compare can catch it) while clear is high, then drop
        // clear before the frame ends. The frame must still count as bad.
        ctrl[1] = 1'b1; #100; ctrl[1] = 1'b0; #100;
        ctrl[0] = 1'b1;
        wait (uut.rx_idx == 14'd2000);          // only frames > 2000 bytes
        ctrl[1] = 1'b1;
        wait (uut.clear);
        @(negedge uut.clk_125);
        while (!(uut.rx_tvalid && !uut.rx_tsof)) @(negedge uut.clk_125);
        force uut.rx_tdata = uut.rx_tdata ^ 8'h01;
        @(negedge uut.clk_125);
        release uut.rx_tdata;
        ctrl[1] = 1'b0;
        wait (!uut.clear);
        check("clear: frame still in progress when clear drops",
              uut.rx_idx > 14'd2000);
        ctrl[0] = 1'b0;
        #300000;
        show;
        check("clear: byte corrupted during clear counted bad", rx_bad == 1);
        check("clear: no terror on that frame", rx_terr == 0);

        if (fail_cnt == 0) begin
            $display("PASS: %0d tests passed", pass_cnt);
            $display("ALL TESTS PASSED");
        end else
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        $finish;
    end

    initial begin #20000000; $display("FAIL: simulation timeout"); $finish; end
endmodule
