// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_icmp_echo_sizes.v - icmp_echo across the request size range, and ICMP
// traffic that arrives while a reply is going out.
//   - Requests of 8 bytes up to MAX_LEN (1480: a full 1500-byte IPv4 packet)
//     are answered exactly: length, every echoed byte, and an ICMP checksum
//     that verifies over the whole reply.
//   - A request longer than MAX_LEN, standard-oversize or jumbo, gets no reply
//     at all (a reply would be truncated or wrong), and the next normal request
//     is still answered.
//   - While a long reply is stalled by tx_ready, an ICMP message of another
//     type and an echo request arrive. The reply in flight must still come out
//     exactly as asked, the request that arrived mid-reply is dropped (no
//     frame), and the responder answers the next request.
// Verilog 2001
// =============================================================================
`timescale 1ns / 1ps

module tb_icmp_echo_sizes;

    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    localparam [47:0] OUR_MAC = 48'h02_00_00_00_00_01;
    localparam [31:0] OUR_IP  = 32'hC0_A8_89_C8;     // 192.168.137.200
    localparam [47:0] REQ_MAC = 48'h02_00_00_00_00_02;
    localparam [31:0] REQ_IP  = 32'hC0_A8_89_01;     // 192.168.137.1
    localparam        MAXB    = 9100;                // largest request fed

    reg  [7:0]  icmp_rx_data  = 8'd0;
    reg         icmp_rx_valid = 1'b0;
    reg         icmp_rx_last  = 1'b0;
    reg         tx_ready      = 1'b1;
    wire [7:0]  tx_data;
    wire        tx_valid;
    wire        tx_last;
    wire        tx_start;

    icmp_echo u_dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .our_mac        (OUR_MAC),
        .our_ip         (OUR_IP),
        .icmp_rx_data   (icmp_rx_data),
        .icmp_rx_valid  (icmp_rx_valid),
        .icmp_rx_last   (icmp_rx_last),
        .icmp_rx_err    (1'b0),
        .icmp_rx_src_ip (REQ_IP),
        .rx_src_mac     (REQ_MAC),
        .tx_data        (tx_data),
        .tx_valid       (tx_valid),
        .tx_last        (tx_last),
        .tx_ready       (tx_ready),
        .tx_start       (tx_start)
    );

    integer pass_cnt = 0;
    integer fail_cnt = 0;

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

    // ---------------------------------------------------------------------
    // Request builder: type, code, checksum, id/seq, then a byte pattern.
    // The checksum is valid, so a reply whose checksum verifies is proof the
    // responder echoed every byte and adjusted the checksum correctly.
    // ---------------------------------------------------------------------
    reg [7:0] req [0:MAXB-1];
    integer   req_len;

    task build_req;
        input integer len;
        input [7:0]   typ;
        input [7:0]   seed;
        integer k;
        reg [31:0] s;
        reg [15:0] c;
        begin
            req_len = len;
            req[0] = typ;
            req[1] = 8'h00;
            req[2] = 8'h00;
            req[3] = 8'h00;
            for (k = 4; k < len; k = k + 1)
                req[k] = (k * 7 + seed) & 8'hFF;
            s = 0;
            for (k = 0; k < len; k = k + 2)
                s = s + {req[k], (k + 1 < len) ? req[k + 1] : 8'h00};
            s = s[15:0] + s[31:16];
            s = s[15:0] + s[31:16];
            c = ~s[15:0];
            req[2] = c[15:8];
            req[3] = c[7:0];
        end
    endtask

    task feed_req;
        integer k;
        begin
            @(negedge clk);
            for (k = 0; k < req_len; k = k + 1) begin
                icmp_rx_data  = req[k];
                icmp_rx_valid = 1'b1;
                icmp_rx_last  = (k == req_len - 1);
                @(negedge clk);
            end
            icmp_rx_data  = 8'd0;
            icmp_rx_valid = 1'b0;
            icmp_rx_last  = 1'b0;
        end
    endtask

    // ---------------------------------------------------------------------
    // Frame capture. frames counts completed frames (tlast seen).
    // ---------------------------------------------------------------------
    reg [7:0] cap [0:MAXB+63];
    integer   cap_cnt = 0;
    integer   frames  = 0;
    integer   last_len = 0;

    always @(posedge clk) begin
        if (tx_valid && tx_ready) begin
            if (cap_cnt < MAXB + 64)
                cap[cap_cnt] <= tx_data;
            cap_cnt <= cap_cnt + 1;
            if (tx_last) begin
                frames   <= frames + 1;
                last_len <= cap_cnt + 1;
                cap_cnt  <= 0;
            end
        end
    end

    task wait_frames;
        input integer n;
        input integer max_cycles;
        integer w;
        begin
            w = 0;
            while (frames < n && w < max_cycles) begin
                @(posedge clk);
                w = w + 1;
            end
            repeat (4) @(posedge clk);
        end
    endtask

    // Checks the last captured frame against req[0..req_len-1] as asked.
    task check_reply;
        input [255:0] tag;
        integer k;
        integer bad;
        reg [31:0] s;
        reg [15:0] iplen;
        begin
            check({tag, ": frame length 34 + request"}, last_len == 34 + req_len);
            check({tag, ": addresses swapped"},
                  {cap[0], cap[1], cap[2], cap[3], cap[4], cap[5]} == REQ_MAC &&
                  {cap[6], cap[7], cap[8], cap[9], cap[10], cap[11]} == OUR_MAC &&
                  {cap[26], cap[27], cap[28], cap[29]} == OUR_IP &&
                  {cap[30], cap[31], cap[32], cap[33]} == REQ_IP);
            iplen = {cap[16], cap[17]};
            check({tag, ": IPv4 total length"}, iplen == 20 + req_len);
            check({tag, ": echo reply type/code"}, cap[34] == 8'h00 && cap[35] == 8'h00);
            bad = 0;
            for (k = 4; k < req_len; k = k + 1)
                if (cap[34 + k] !== req[k]) bad = bad + 1;
            check({tag, ": every byte after the checksum echoed"}, bad == 0);
            s = 0;
            for (k = 0; k < req_len; k = k + 2)
                s = s + {cap[34 + k], (k + 1 < req_len) ? cap[34 + k + 1] : 8'h00};
            s = s[15:0] + s[31:16];
            s = s[15:0] + s[31:16];
            check({tag, ": ICMP checksum verifies"}, s[15:0] == 16'hFFFF);
        end
    endtask

    integer sizes [0:9];
    integer i, f0;

    initial begin
        sizes[0] = 8;    sizes[1] = 12;   sizes[2] = 255;  sizes[3] = 256;
        sizes[4] = 257;  sizes[5] = 504;  sizes[6] = 511;  sizes[7] = 512;
        sizes[8] = 1000; sizes[9] = 1480;

        #50 rst_n = 1;
        #50;

        // ---- every size up to MAX_LEN answered exactly ----
        for (i = 0; i < 10; i = i + 1) begin
            build_req(sizes[i], 8'h08, i);
            f0 = frames;
            feed_req;
            wait_frames(f0 + 1, 4000);
            check({"size ", "answered"}, frames == f0 + 1);
            $display("  (request %0d bytes)", sizes[i]);
            if (frames == f0 + 1) check_reply("reply");
        end

        // ---- oversize: no reply, then a normal request still works ----
        build_req(1481, 8'h08, 8'h21);
        f0 = frames;
        feed_req;
        wait_frames(f0 + 1, 4000);
        check("1481-byte request (one past MAX_LEN) gets no reply", frames == f0);

        build_req(9000, 8'h08, 8'h33);
        f0 = frames;
        feed_req;
        wait_frames(f0 + 1, 4000);
        check("9000-byte jumbo request gets no reply", frames == f0);

        build_req(64, 8'h08, 8'h44);
        f0 = frames;
        feed_req;
        wait_frames(f0 + 1, 4000);
        check("64-byte request after the oversize ones answered", frames == f0 + 1);
        if (frames == f0 + 1) check_reply("after oversize");

        // ---- ICMP traffic while a reply is stalled ----
        // 200 bytes: small enough for any buffer, so only the traffic that
        // arrives mid-reply can spoil it.
        build_req(200, 8'h08, 8'h55);
        f0 = frames;
        feed_req;
        // Let the reply start, then stall it.
        i = 0;
        while (cap_cnt < 60 && i < 4000) begin
            @(posedge clk);
            i = i + 1;
        end
        @(negedge clk) tx_ready = 1'b0;
        begin : mid_reply
            integer keep_len;
            reg [7:0] keep [0:199];
            integer k;
            keep_len = req_len;
            for (k = 0; k < 200; k = k + 1) keep[k] = req[k];
            // Destination-unreachable (type 3), then an echo request.
            build_req(40, 8'h03, 8'h66);
            feed_req;
            build_req(100, 8'h08, 8'h77);
            feed_req;
            repeat (20) @(posedge clk);
            @(negedge clk) tx_ready = 1'b1;
            wait_frames(f0 + 1, 4000);
            req_len = keep_len;
            for (k = 0; k < 200; k = k + 1) req[k] = keep[k];
        end
        check("stalled reply completes", frames == f0 + 1);
        if (frames >= f0 + 1) check_reply("stalled reply");
        wait_frames(f0 + 2, 4000);
        check("request that arrived mid-reply is dropped", frames == f0 + 1);

        build_req(48, 8'h08, 8'h88);
        f0 = frames;
        feed_req;
        wait_frames(f0 + 1, 4000);
        check("next request answered", frames == f0 + 1);
        if (frames == f0 + 1) check_reply("after mid-reply traffic");

        if (fail_cnt == 0) begin
            $display("PASS: %0d tests passed", pass_cnt);
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        end
        $finish;
    end

    initial begin
        #5_000_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
