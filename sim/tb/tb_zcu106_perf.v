// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_zcu106_perf.v - ZCU106 demo throughput blocks at 1 Gb/s line rate
//
// zcu106_eth_demo on its GMII bus at 125 MHz, with the testbench as the host:
// it builds and sends frames itself (preamble, IPv4 checksum, FCS) and parses
// every transmitted frame (FCS, inter-frame gap, iperf2 sequence). Checks:
//   1. Blast, 1472-byte payload: every frame well formed and in sequence,
//      sent back to back at exactly the 12-byte IFG; >= 99.9% of the
//      1538-byte-time line rate.
//   2. Blast, 18-byte payload (64-byte frames): same, at 84 byte times each.
//   3. Sink: line-rate iperf2 frames to UDP/5001 at 12-byte IFG, all counted
//      (packets, bytes, no sequence gaps), read back from UDP/9996.
//   4. Full duplex: a 1472-byte blast while the host sends line-rate sink
//      traffic; both directions complete with nothing lost.
//   5. A stats query sent during a blast is answered before it ends.
//   6. A trigger that arrives while the last frame of a burst is still being
//      generated is ignored; the next trigger after it starts at sequence 0.
//   7. MAC statistics over the s_axi port: TX_FRAME equals every frame seen
//      on GMII and the demo's blast_frames every blast frame; a write clears
//      TX_FRAME.
// Verilog 2001
// =============================================================================
`timescale 1ns / 1ps

module tb_zcu106_perf;

    reg clk = 1'b0;
    always #4 clk = ~clk;                       // 125 MHz
    reg rst_n = 1'b0;

    reg  [7:0] rxd   = 8'd0;
    reg        rx_dv = 1'b0;
    wire [7:0] txd;
    wire       tx_en, tx_er;

    // MAC CSRs (AXI4-Lite)
    reg  [7:0]  awaddr = 8'd0, araddr = 8'd0;
    reg         awvalid = 1'b0, wvalid = 1'b0, arvalid = 1'b0;
    reg  [31:0] wdata = 32'd0;
    wire        awready, wready, bvalid, arready, rvalid;
    wire [31:0] rdata;
    wire [31:0] blast_frames;

    zcu106_eth_demo #(
        .BLAST_START_DELAY (32'd0)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .gmii_txd   (txd),
        .gmii_tx_en (tx_en),
        .gmii_tx_er (tx_er),
        .gmii_rxd   (rxd),
        .gmii_rx_dv (rx_dv),
        .gmii_rx_er (1'b0),
        .rx_frame   (),
        .tx_frame   (),
        .s_axi_awaddr  (awaddr),
        .s_axi_awvalid (awvalid),
        .s_axi_awready (awready),
        .s_axi_wdata   (wdata),
        .s_axi_wstrb   (4'hF),
        .s_axi_wvalid  (wvalid),
        .s_axi_wready  (wready),
        .s_axi_bresp   (),
        .s_axi_bvalid  (bvalid),
        .s_axi_bready  (1'b1),
        .s_axi_araddr  (araddr),
        .s_axi_arvalid (arvalid),
        .s_axi_arready (arready),
        .s_axi_rdata   (rdata),
        .s_axi_rresp   (),
        .s_axi_rvalid  (rvalid),
        .s_axi_rready  (1'b1),
        .blast_frames_clear (1'b0),
        .blast_frames  (blast_frames)
    );

    // ------------------------------------------------- MAC CSRs (AXI4-Lite)
    // Handshakes are sampled mid-cycle (negedge): a valid/ready pair high
    // there completes at the next posedge. The slave raises arready together
    // with rvalid, for one cycle with rready tied high.
    reg ahs, whs, rgot;
    task axi_read;
        input  [7:0]  a;
        output [31:0] d;
        begin
            @(negedge clk); araddr = a; arvalid = 1'b1; rgot = 1'b0;
            while (arvalid || !rgot) begin
                if (rvalid && !rgot) begin d = rdata; rgot = 1'b1; end
                ahs = arvalid && arready;
                @(negedge clk);
                if (ahs) arvalid = 1'b0;
            end
        end
    endtask

    task axi_write;
        input [7:0]  a;
        input [31:0] d;
        begin
            @(negedge clk); awaddr = a; wdata = d; awvalid = 1'b1; wvalid = 1'b1;
            while (awvalid || wvalid) begin
                ahs = awvalid && awready;
                whs = wvalid && wready;
                @(negedge clk);
                if (ahs) awvalid = 1'b0;
                if (whs) wvalid  = 1'b0;
            end
            while (!bvalid) @(negedge clk);
            @(negedge clk);
        end
    endtask

    localparam [47:0] DUT_MAC  = 48'h02_00_00_00_00_01;
    localparam [47:0] HOST_MAC = 48'h02_00_00_00_00_99;
    localparam [31:0] DUT_IP   = 32'hC0A8_89C8;  // 192.168.137.200
    localparam [31:0] HOST_IP  = 32'hC0A8_8901;  // 192.168.137.1

    integer pass = 0, fail = 0;
    task check;
        input cond;
        input [8*96-1:0] msg;
        begin
            if (cond) begin pass = pass + 1; $display("PASS: %0s", msg); end
            else      begin fail = fail + 1; $display("FAIL: %0s", msg); end
        end
    endtask

    // ---------------------------------------------------------------- CRC32
    function [31:0] crc_byte;
        input [31:0] c;
        input [7:0]  d;
        integer k;
        reg [31:0] r;
        begin
            r = c ^ {24'd0, d};
            for (k = 0; k < 8; k = k + 1)
                r = r[0] ? ((r >> 1) ^ 32'hEDB88320) : (r >> 1);
            crc_byte = r;
        end
    endfunction

    // ------------------------------------------------------- host TX (RX side)
    reg [7:0] f [0:1599];                       // frame being sent, no FCS
    integer   flen;

    // UDP/IPv4 frame to the DUT: payload = iperf2 header (id, then zeros)
    // plus a counting fill.
    task build_udp;
        input [15:0] sport, dport;
        input integer plen;
        input [31:0] id;
        integer i;
        reg [31:0] s;
        reg [15:0] tot;
        begin
            tot = 16'd28 + plen;
            for (i = 0; i < 6; i = i + 1) f[i]     = DUT_MAC[47-8*i -: 8];
            for (i = 0; i < 6; i = i + 1) f[6 + i] = HOST_MAC[47-8*i -: 8];
            f[12] = 8'h08; f[13] = 8'h00;
            f[14] = 8'h45; f[15] = 8'h00; f[16] = tot[15:8]; f[17] = tot[7:0];
            f[18] = id[15:8]; f[19] = id[7:0]; f[20] = 8'h40; f[21] = 8'h00;
            f[22] = 8'h40; f[23] = 8'h11; f[24] = 8'h00; f[25] = 8'h00;
            for (i = 0; i < 4; i = i + 1) f[26 + i] = HOST_IP[31-8*i -: 8];
            for (i = 0; i < 4; i = i + 1) f[30 + i] = DUT_IP[31-8*i -: 8];
            s = 0;
            for (i = 14; i < 34; i = i + 2) s = s + {f[i], f[i+1]};
            s = (s & 32'hFFFF) + (s >> 16);
            s = (s & 32'hFFFF) + (s >> 16);
            f[24] = ~s[15:8]; f[25] = ~s[7:0];
            f[34] = sport[15:8]; f[35] = sport[7:0];
            f[36] = dport[15:8]; f[37] = dport[7:0];
            f[38] = (plen + 8) >> 8; f[39] = (plen + 8) & 8'hFF;
            f[40] = 8'h00; f[41] = 8'h00;       // no UDP checksum
            for (i = 0; i < plen; i = i + 1) f[42 + i] = i[7:0];
            if (plen >= 12) begin
                f[42] = id[31:24]; f[43] = id[23:16]; f[44] = id[15:8]; f[45] = id[7:0];
                for (i = 4; i < 12; i = i + 1) f[42 + i] = 8'h00;
            end
            flen = 42 + plen;
            while (flen < 60) begin f[flen] = 8'h00; flen = flen + 1; end
        end
    endtask

    // Send f[0..flen-1] with preamble and FCS, then the 12-byte minimum IFG.
    task send_frame;
        integer i;
        reg [31:0] c;
        begin
            c = 32'hFFFFFFFF;
            @(negedge clk);
            for (i = 0; i < 7; i = i + 1) begin rx_dv = 1'b1; rxd = 8'h55; @(negedge clk); end
            rxd = 8'hD5; @(negedge clk);
            for (i = 0; i < flen; i = i + 1) begin
                rxd = f[i]; c = crc_byte(c, f[i]); @(negedge clk);
            end
            c = ~c;
            for (i = 0; i < 4; i = i + 1) begin rxd = c[8*i +: 8]; @(negedge clk); end
            rx_dv = 1'b0; rxd = 8'h00;
            repeat (11) @(negedge clk);         // + the edge above = 12 idle
        end
    endtask

    // Trigger: delay 0, count, dst port = sport, payload size
    task send_trigger;
        input [15:0] sport;
        input [31:0] count;
        input [15:0] psize;
        begin
            build_udp(sport, 16'd9997, 11, 32'd0);
            f[42] = 8'h00; f[43] = 8'h00; f[44] = 8'h00;
            f[45] = count[31:24]; f[46] = count[23:16]; f[47] = count[15:8]; f[48] = count[7:0];
            f[49] = sport[15:8]; f[50] = sport[7:0];
            f[51] = psize[15:8]; f[52] = psize[7:0];
            send_frame;
        end
    endtask

    task send_stats_query;
        input [7:0] cmd;                         // "G" or "C"
        begin
            build_udp(16'd40000, 16'd9996, 1, 32'd0);
            f[42] = cmd;
            send_frame;
        end
    endtask

    // ------------------------------------------------ DUT TX monitor (GMII)
    reg [7:0]  m [0:1599];
    integer    mlen = 0;
    reg        in_frame = 1'b0;
    integer    cyc = 0, idle = 0;
    always @(posedge clk) cyc <= cyc + 1;

    // Blast accounting for the current run
    integer    b_frames = 0, b_bad = 0, b_seq_err = 0, b_len_err = 0;
    integer    b_first = 0, b_last_end = 0, b_long_gaps = 0, b_ifg_short = 0;
    integer    b_exp_plen = 1472;
    reg [31:0] b_next_seq = 0;
    integer    other_frames = 0, tx_er_seen = 0;
    integer    tx_total = 0, blast_total = 0;   // every frame / blast frame seen
    // Last stats reply
    integer    st_replies = 0, st_reply_cyc = 0;
    reg [31:0] st_packets, st_bytes, st_gaps, st_ooo;

    integer    k;
    reg [31:0] mc;
    reg        last_was_blast = 1'b0;
    always @(posedge clk) begin
        if (tx_er) tx_er_seen = tx_er_seen + 1;
        if (tx_en) begin
            if (!in_frame) begin
                in_frame = 1'b1;
                mlen = 0;
                // Gap after a blast frame into another blast frame
                if (last_was_blast && b_frames > 0) begin
                    if (idle < 12)  b_ifg_short = b_ifg_short + 1;
                    if (idle > 12)  b_long_gaps = b_long_gaps + 1;
                end
            end
            m[mlen] = txd;
            mlen = mlen + 1;
            idle = 0;
        end else begin
            idle = idle + 1;
            if (in_frame) begin
                in_frame = 1'b0;
                tx_total = tx_total + 1;
                // m[0..6] preamble, m[7] SFD, m[8..mlen-5] data, last 4 FCS
                mc = 32'hFFFFFFFF;
                for (k = 8; k < mlen - 4; k = k + 1) mc = crc_byte(mc, m[k]);
                mc = ~mc;
                last_was_blast = 1'b0;
                if (m[7] != 8'hD5 || m[0] != 8'h55 ||
                    {m[mlen-1], m[mlen-2], m[mlen-3], m[mlen-4]} != mc) begin
                    b_bad = b_bad + 1;
                    $display("  bad frame at %0d: len %0d", cyc, mlen);
                end else if ({m[8+12], m[8+13]} == 16'h0800 && m[8+23] == 8'h11 &&
                             {m[8+34], m[8+35]} == 16'd9997) begin
                    // Blast frame: to us, from the DUT, iperf2 id in sequence
                    last_was_blast = 1'b1;
                    if (b_frames == 0) b_first = cyc - mlen;
                    b_last_end = cyc;
                    if ({m[8], m[9], m[10], m[11], m[12], m[13]} != HOST_MAC ||
                        {m[8+30], m[8+31], m[8+32], m[8+33]} != HOST_IP ||
                        {m[8+26], m[8+27], m[8+28], m[8+29]} != DUT_IP)
                        b_bad = b_bad + 1;
                    if (mlen - 12 - 42 != b_exp_plen) b_len_err = b_len_err + 1;
                    if ({m[8+42], m[8+43], m[8+44], m[8+45]} != b_next_seq)
                        b_seq_err = b_seq_err + 1;
                    b_next_seq = {m[8+42], m[8+43], m[8+44], m[8+45]} + 1;
                    b_frames = b_frames + 1;
                    blast_total = blast_total + 1;
                end else if ({m[8+12], m[8+13]} == 16'h0800 &&
                             {m[8+34], m[8+35]} == 16'd9996 &&
                             {m[8+42], m[8+43], m[8+44], m[8+45]} == "IPS0") begin
                    st_packets = {m[8+46], m[8+47], m[8+48], m[8+49]};
                    st_bytes   = {m[8+50], m[8+51], m[8+52], m[8+53]};
                    st_gaps    = {m[8+62], m[8+63], m[8+64], m[8+65]};
                    st_ooo     = {m[8+66], m[8+67], m[8+68], m[8+69]};
                    st_replies = st_replies + 1;
                    st_reply_cyc = cyc;
                end else begin
                    other_frames = other_frames + 1;
                end
            end
        end
    end

    task reset_blast_stats;
        input integer plen;
        begin
            b_frames = 0; b_bad = 0; b_seq_err = 0; b_len_err = 0;
            b_long_gaps = 0; b_ifg_short = 0; b_next_seq = 0;
            b_exp_plen = plen; last_was_blast = 1'b0;
        end
    endtask

    task wait_blast;
        input integer n;
        integer guard;
        begin
            guard = 0;
            while (b_frames < n && guard < 20_000_000) begin
                @(posedge clk); guard = guard + 1;
            end
            repeat (2000) @(posedge clk);
        end
    endtask

    // Line-rate efficiency of the run in parts per million: ideal byte times
    // (frame + FCS + preamble + IFG) over the measured span.
    function integer eff_ppm;
        input integer n, plen;
        begin
            eff_ppm = (n * (42 + plen + 4 + 8 + 12)) * 64'd1000000 /
                      (b_last_end - b_first + 12);
        end
    endfunction

    task get_stats;
        input [7:0] cmd;
        integer n0, guard;
        begin
            n0 = st_replies;
            send_stats_query(cmd);
            guard = 0;
            while (st_replies == n0 && guard < 100000) begin
                @(posedge clk); guard = guard + 1;
            end
        end
    endtask

    integer i, e, n, sent;
    reg [31:0] rd;
    integer t_q;
    initial begin
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (200) @(posedge clk);

        // ---- 1. blast, 1472-byte payload ----
        n = 400;
        reset_blast_stats(1472);
        send_trigger(16'd5002, n, 16'd1472);
        wait_blast(n);
        e = eff_ppm(n, 1472);
        $display("blast 1472: %0d frames, %0d byte times, %0d ppm of line rate, %0d long gaps",
                 b_frames, b_last_end - b_first + 12, e, b_long_gaps);
        check(b_frames == n && b_bad == 0 && b_seq_err == 0 && b_len_err == 0,
              "blast 1472: every frame well formed, FCS good, in sequence");
        check(b_ifg_short == 0 && b_long_gaps == 0,
              "blast 1472: every gap exactly the 12-byte IFG");
        check(e >= 999000, "blast 1472: >= 99.9% of 1 Gb/s line rate");

        // ---- 2. blast, 18-byte payload (64-byte frames) ----
        n = 1500;
        reset_blast_stats(18);
        send_trigger(16'd5002, n, 16'd18);
        wait_blast(n);
        e = eff_ppm(n, 18);
        $display("blast 18: %0d frames, %0d byte times, %0d ppm of line rate, %0d long gaps",
                 b_frames, b_last_end - b_first + 12, e, b_long_gaps);
        check(b_frames == n && b_bad == 0 && b_seq_err == 0 && b_len_err == 0,
              "blast 18: every 64-byte frame well formed, in sequence");
        check(b_ifg_short == 0 && b_long_gaps == 0,
              "blast 18: every gap exactly the 12-byte IFG");
        check(e >= 999000, "blast 18: >= 99.9% of line rate (1.488 Mframe/s)");

        // ---- 3. sink at line rate ----
        get_stats("C");
        n = 300;
        for (i = 0; i < n; i = i + 1) begin
            build_udp(16'd50000, 16'd5001, 1472, i);
            send_frame;
        end
        n = 1000;
        for (i = 0; i < n; i = i + 1) begin
            build_udp(16'd50000, 16'd5001, 18, 300 + i);
            send_frame;
        end
        repeat (5000) @(posedge clk);
        get_stats("G");
        $display("sink: packets=%0d bytes=%0d gaps=%0d ooo=%0d",
                 st_packets, st_bytes, st_gaps, st_ooo);
        check(st_packets == 1300 && st_bytes == 300 * 1472 + 1000 * 18 &&
              st_gaps == 0 && st_ooo == 0,
              "sink: 300 x 1472 B and 1000 x 18 B at 12-byte IFG, all counted");

        // ---- 4. full duplex ----
        get_stats("C");
        n = 300;
        reset_blast_stats(1472);
        send_trigger(16'd5002, n, 16'd1472);
        sent = 0;
        while (b_frames < n || sent < 300) begin
            if (sent < 300) begin
                build_udp(16'd50000, 16'd5001, 1472, sent);
                send_frame;
                sent = sent + 1;
            end else begin
                @(posedge clk);
            end
        end
        repeat (5000) @(posedge clk);
        e = eff_ppm(n, 1472);
        get_stats("G");
        $display("duplex: blast %0d frames at %0d ppm, sink %0d packets gaps=%0d",
                 b_frames, e, st_packets, st_gaps);
        check(b_frames == n && b_bad == 0 && b_seq_err == 0 && e >= 999000,
              "duplex: blast complete at >= 99.9% of line rate");
        check(st_packets == 300 && st_gaps == 0 && st_ooo == 0,
              "duplex: all 300 line-rate sink frames counted");

        // ---- 5. stats query answered during a blast ----
        n = 400;
        reset_blast_stats(1472);
        send_trigger(16'd5002, n, 16'd1472);
        while (b_frames < 100) @(posedge clk);
        t_q = st_replies;
        get_stats("G");
        check(st_replies == t_q + 1 && b_frames < n,
              "stats query answered while the blast runs");
        wait_blast(n);
        check(b_frames == n && b_bad == 0 && b_seq_err == 0,
              "blast with a reply in it: complete and in sequence");

        // ---- 6. trigger during the last frame of a burst ----
        // The second trigger arrives while the only frame of the first burst
        // is still being generated: the count is already 0, but the blast
        // is busy until that frame is done.
        reset_blast_stats(1472);
        send_trigger(16'd5002, 1, 16'd1472);
        send_trigger(16'd5002, 2, 16'd1472);
        wait_blast(1);
        repeat (6000) @(posedge clk);
        check(b_frames == 1 && b_bad == 0 && b_seq_err == 0,
              "trigger during the last frame: ignored, burst intact");
        reset_blast_stats(1472);
        send_trigger(16'd5002, 2, 16'd1472);
        wait_blast(2);
        check(b_frames == 2 && b_bad == 0 && b_seq_err == 0,
              "next trigger: new burst from sequence 0");

        check(tx_er_seen == 0 && other_frames == 0, "no tx_er, no unexpected frames");

        // ---- 7. MAC statistics over s_axi ----
        repeat (100) @(posedge clk);
        axi_read(8'h28, rd);
        $display("TX_FRAME %0d, frames seen %0d; blast_frames %0d, blast frames seen %0d",
                 rd, tx_total, blast_frames, blast_total);
        check(rd == tx_total && blast_frames == blast_total,
              "TX_FRAME = frames on GMII, blast_frames = blast frames");
        axi_write(8'h28, 32'd0);
        axi_read(8'h28, rd);
        check(rd == 0, "TX_FRAME cleared by a write");

        if (fail == 0) begin
            $display("PASS: %0d tests passed", pass);
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAIL: %0d passed, %0d failed", pass, fail);
        end
        $finish;
    end

    initial begin
        #400_000_000;
        $display("FAIL: global timeout");
        $finish;
    end

endmodule
