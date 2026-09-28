// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_zcu106_sfp_lb.v - ZCU106 SFP loopback tester against the emacZero demo
//
// zcu106_eth_demo (MAC + ARP/ICMP/UDP-echo, as on SFP0) and sfp_lb_tester (as
// on SFP1) are joined back to back on their GMII buses, standing in for the
// two PCS/PMA cores and the fiber. Checks:
//   1. Clean run: every ARP / ICMP / UDP request gets a correct reply - no
//      bad replies, no timeouts - across the ICMP and UDP length ranges.
//   2. One reply corrupted on the wire (a flipped data bit, so the tester's
//      MAC flags it with terror on the FCS check): exactly one bad reply,
//      reason terror, and traffic carries on.
//   3. Negative mode: no variant gets a reply (another MAC / IP / ARP
//      target / UDP port, bad IPv4 or ICMP checksum, bad FCS, tx_er), and
//      the normal requests in between are still answered.
//   4. Short payloads (ICMP 0..17, UDP 1..18 bytes, mostly padded frames):
//      every request answered with exactly its own payload, not the padding.
// Verilog 2001
// =============================================================================
`timescale 1ns / 1ps

module tb_zcu106_sfp_lb;

    reg clk = 1'b0;
    always #4 clk = ~clk;                       // 125 MHz

    reg        rst_n = 1'b0;
    reg  [3:0] ctrl  = 4'b0000;

    wire [7:0] d_txd, t_txd;
    wire       d_tx_en, d_tx_er, t_tx_en, t_tx_er;

    // Wire from the demo to the tester, with an optional one-shot bit flip
    reg        corrupt_arm = 1'b0;
    reg        corrupting  = 1'b0;
    reg  [7:0] byte_in_frame;
    always @(posedge clk) begin
        if (!d_tx_en) byte_in_frame <= 8'd0;
        else if (byte_in_frame != 8'hFF) byte_in_frame <= byte_in_frame + 8'd1;
    end
    wire flip = corrupting && d_tx_en && (byte_in_frame == 8'd40);
    always @(posedge clk) begin
        if (corrupt_arm && !d_tx_en) corrupting <= 1'b1;   // next frame
        if (flip) begin
            corrupting  <= 1'b0;
            corrupt_arm <= 1'b0;
        end
    end
    wire [7:0] d_txd_line = d_txd ^ (flip ? 8'h10 : 8'h00);

    zcu106_eth_demo u_demo (
        .clk        (clk),
        .rst_n      (rst_n),
        .gmii_txd   (d_txd),
        .gmii_tx_en (d_tx_en),
        .gmii_tx_er (d_tx_er),
        .gmii_rxd   (t_txd),
        .gmii_rx_dv (t_tx_en),
        .gmii_rx_er (t_tx_er),
        .rx_frame   (),
        .tx_frame   ()
    );

    wire [383:0] st;
    sfp_lb_tester u_tester (
        .clk        (clk),
        .rst_n      (rst_n),
        .ctrl       (ctrl),
        .link_ok    (1'b1),
        .gmii_txd   (t_txd),
        .gmii_tx_en (t_tx_en),
        .gmii_tx_er (t_tx_er),
        .gmii_rxd   (d_txd_line),
        .gmii_rx_dv (d_tx_en),
        .gmii_rx_er (d_tx_er),
        .status     (st),
        .ok_pulse   (),
        .bad_pulse  ()
    );

    wire [31:0] tx_count = st[31:0];
    wire [31:0] ok_arp   = st[63:32];
    wire [31:0] ok_icmp  = st[95:64];
    wire [31:0] ok_udp   = st[127:96];
    wire [31:0] bad      = st[159:128];
    wire [31:0] timeouts = st[191:160];
    wire [15:0] max_rtt  = st[207:192];
    wire [3:0]  f_reason = st[211:208];
    wire [1:0]  f_kind   = st[213:212];
    wire [15:0] f_idx    = st[229:214];
    wire [7:0]  f_got    = st[237:230];
    wire [7:0]  f_exp    = st[245:238];
    wire [15:0] f_seq    = st[261:246];
    wire [31:0] ok_neg   = st[295:264];
    wire [7:0]  neg_fail = st[303:296];
    wire [47:0] rx_bytes = st[351:304];
    wire [31:0] neg_rep  = st[383:352];
    wire [31:0] ok_all   = ok_arp + ok_icmp + ok_udp + ok_neg + neg_rep;
    wire [31:0] ok_valid = ok_arp + ok_icmp + ok_udp;

    integer pass = 0, fail = 0;

    task check;
        input cond;
        input [8*96-1:0] msg;
        begin
            if (cond) begin
                pass = pass + 1;
                $display("PASS: %0s", msg);
            end else begin
                fail = fail + 1;
                $display("FAIL: %0s", msg);
            end
        end
    endtask

    task show;
        begin
            $display("  tx=%0d arp=%0d icmp=%0d udp=%0d neg_ok=%0d neg_replied=%0d bad=%0d timeouts=%0d max_rtt=%0d bytes=%0d neg_fail=%b",
                     tx_count, ok_arp, ok_icmp, ok_udp, ok_neg, neg_rep, bad,
                     timeouts, max_rtt, rx_bytes, neg_fail);
            if (bad != 0 || timeouts != 0)
                $display("  first: reason=%0d kind=%0d seq=%0d idx=%0d got=%h exp=%h",
                         f_reason, f_kind, f_seq, f_idx, f_got, f_exp);
        end
    endtask

    // Run until `n` more requests have been answered or timed out
    task run_until;
        input integer n;
        integer target, guard;
        begin
            target = ok_all + bad + timeouts + n;
            guard  = 0;
            while ((ok_all + bad + timeouts) < target && guard < 4_000_000) begin
                @(posedge clk);
                guard = guard + 1;
            end
        end
    endtask

    localparam integer N_CLEAN = 48;     // 16 of each kind

    initial begin
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (200) @(posedge clk);

        // ---- 1. clean run ----
        ctrl = 4'b0001;
        run_until(N_CLEAN);
        ctrl = 4'b0000;
        repeat (40000) @(posedge clk);             // let the last one finish
        $display("clean run:");
        show;
        check(tx_count >= N_CLEAN, "clean: requests were sent");
        check(ok_arp >= 16 && ok_icmp >= 16 && ok_udp >= 16,
              "clean: >= 16 correct ARP, ICMP and UDP replies each");
        check(ok_all == tx_count, "clean: every request got a correct reply");
        check(bad == 0 && timeouts == 0, "clean: no bad replies, no timeouts");
        check(ok_neg == 0, "clean: no negative frames without negative mode");

        // ---- 2. one reply corrupted on the wire ----
        ctrl = 4'b0010;                             // clear
        repeat (10) @(posedge clk);
        ctrl = 4'b0001;
        corrupt_arm = 1'b1;
        run_until(9);
        ctrl = 4'b0000;
        repeat (40000) @(posedge clk);
        $display("corrupted run:");
        show;
        check(bad == 1 && timeouts == 0,
              "corrupt: the corrupted reply counted as exactly one bad reply");
        check(f_reason == 4'd3, "corrupt: first failure reason is terror (FCS)");
        check(ok_all == tx_count - 1, "corrupt: every other request answered");

        // ---- 3. negative frames: two rounds of all eight variants ----
        ctrl = 4'b0010;
        repeat (10) @(posedge clk);
        ctrl = 4'b0101;                             // run + negative
        run_until(64);
        ctrl = 4'b0000;
        repeat (40000) @(posedge clk);
        $display("negative run:");
        show;
        check(ok_neg + neg_rep >= 16, "negative: >= 16 negative frames (every variant twice)");
        check(neg_fail[3:0] == 4'd0,
              "negative: wrong MAC / IP / ARP target / UDP port get no reply");
        check(neg_fail[7:4] == 4'd0,
              "negative: bad IP / ICMP checksum, bad FCS, tx_er get no reply");
        check(ok_valid + ok_neg + neg_rep == tx_count && bad == 0 && timeouts == 0,
              "negative: all valid requests answered correctly");

        // ---- 4. short payloads ----
        ctrl = 4'b0010;
        repeat (10) @(posedge clk);
        ctrl = 4'b1001;                             // run + short
        run_until(54);                              // 18 of each kind
        ctrl = 4'b0000;
        repeat (40000) @(posedge clk);
        $display("short-payload run:");
        show;
        check(ok_icmp >= 18 && ok_udp >= 18,
              "short: >= 18 ICMP (0..17 B) and UDP (1..18 B) requests");
        check(ok_valid == tx_count && bad == 0 && timeouts == 0,
              "short: every short request answered with its own payload");

        if (fail == 0) begin
            $display("PASS: %0d tests passed", pass);
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAIL: %0d passed, %0d failed", pass, fail);
        end
        $finish;
    end

    initial begin
        #200_000_000;
        $display("FAIL: global timeout");
        $finish;
    end

endmodule
