// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_arp_responder.v - Unit test for the Arty demo ARP responder
//
//   T1: ARP request for our IP -> one 42-byte reply: Ethernet destination and
//       target hardware address = request's sender hardware address, source
//       and sender hardware address = our MAC, opcode 2, target IP = sender IP
//   T2: request for another IP -> no reply
//   T3: Ethernet source with the group bit set, broadcast, or all zero ->
//       no reply
//   T4: ARP sender hardware address with the group bit set or all zero ->
//       no reply (the reply would go there)
//   T5: a valid request after the dropped ones -> answered
//   T6: ARP probe (sender IP 0.0.0.0, RFC 5227) -> still answered
// Verilog 2001
// =============================================================================
`timescale 1ns / 1ps

module tb_arp_responder;

    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    localparam [47:0] OUR_MAC = 48'h02_00_00_00_00_01;
    localparam [31:0] OUR_IP  = 32'hC0_A8_01_C8;   // 192.168.1.200

    reg  [7:0] rx_tdata  = 8'd0;
    reg        rx_tvalid = 1'b0;
    reg        rx_tlast  = 1'b0;
    reg        rx_tsof   = 1'b0;
    wire [7:0] tx_tdata;
    wire       tx_tvalid;
    wire       tx_tlast;
    wire       arp_reply_sent;

    arp_responder u_dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .enable         (1'b1),
        .rx_tdata       (rx_tdata),
        .rx_tvalid      (rx_tvalid),
        .rx_tlast       (rx_tlast),
        .rx_terror      (1'b0),
        .rx_tsof        (rx_tsof),
        .tx_tdata       (tx_tdata),
        .tx_tvalid      (tx_tvalid),
        .tx_tready      (1'b1),
        .tx_tlast       (tx_tlast),
        .our_mac        (OUR_MAC),
        .our_ip         (OUR_IP),
        .arp_reply_sent (arp_reply_sent)
    );

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task check;
        input [255:0] name;
        input cond;
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

    // ---- TX capture ----
    reg [7:0] rep [0:63];
    integer   rep_n = 0;      // bytes of the reply being captured
    integer   rep_len = 0;    // length of the last completed reply
    integer   n_replies = 0;

    always @(posedge clk) if (tx_tvalid) begin
        if (rep_n < 64) rep[rep_n] = tx_tdata;
        rep_n = rep_n + 1;
        if (tx_tlast) begin
            rep_len   = rep_n;
            rep_n     = 0;
            n_replies = n_replies + 1;
        end
    end

    // ---- Request frame ----
    reg [7:0] frame [0:59];

    task load_request;
        input [31:0] target_ip;
        integer i;
        begin
            for (i = 0; i < 6; i = i + 1) frame[i] = 8'hFF;     // dst broadcast
            frame[6] = 8'h02; frame[7] = 8'h11; frame[8]  = 8'h22;  // eth src
            frame[9] = 8'h33; frame[10] = 8'h44; frame[11] = 8'h55;
            frame[12] = 8'h08; frame[13] = 8'h06;               // ARP
            frame[14] = 8'h00; frame[15] = 8'h01;               // htype
            frame[16] = 8'h08; frame[17] = 8'h00;               // ptype
            frame[18] = 8'h06; frame[19] = 8'h04;               // hlen, plen
            frame[20] = 8'h00; frame[21] = 8'h01;               // request
            frame[22] = 8'h02; frame[23] = 8'h11; frame[24] = 8'h22;  // SHA
            frame[25] = 8'h33; frame[26] = 8'h44; frame[27] = 8'h55;
            frame[28] = 8'hC0; frame[29] = 8'hA8;               // SPA 192.168.1.50
            frame[30] = 8'h01; frame[31] = 8'h32;
            for (i = 32; i < 38; i = i + 1) frame[i] = 8'h00;   // THA
            frame[38] = target_ip[31:24]; frame[39] = target_ip[23:16];
            frame[40] = target_ip[15:8];  frame[41] = target_ip[7:0];
            for (i = 42; i < 60; i = i + 1) frame[i] = 8'h00;   // padding
        end
    endtask

    task send_frame;
        integer k;
        begin
            @(negedge clk);
            for (k = 0; k < 60; k = k + 1) begin
                rx_tdata  = frame[k];
                rx_tvalid = 1'b1;
                rx_tsof   = (k == 0);
                rx_tlast  = (k == 59);
                @(negedge clk);
            end
            rx_tvalid = 1'b0; rx_tlast = 1'b0; rx_tsof = 1'b0;
            repeat (60) @(negedge clk);   // reply (if any) fully out
        end
    endtask

    integer before;
    integer i;
    reg     ok;

    initial begin
        $dumpfile("tb_arp_responder.vcd");
        $dumpvars(0, tb_arp_responder);
        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        // T1: valid request
        load_request(OUR_IP);
        before = n_replies;
        send_frame;
        check("T1 valid request answered", n_replies == before + 1);
        check("T1 reply is 42 bytes", rep_len == 42);
        ok = 1'b1;
        for (i = 0; i < 6; i = i + 1) begin
            if (rep[i]      != frame[22 + i]) ok = 1'b0;   // eth dst = SHA
            if (rep[32 + i] != frame[22 + i]) ok = 1'b0;   // THA = SHA
            if (rep[6 + i]  != OUR_MAC[47 - 8*i -: 8]) ok = 1'b0;
            if (rep[22 + i] != OUR_MAC[47 - 8*i -: 8]) ok = 1'b0;
        end
        check("T1 reply MAC addresses", ok);
        check("T1 reply opcode 2", rep[20] == 8'h00 && rep[21] == 8'h02);
        check("T1 reply target IP = sender IP",
              rep[38] == 8'hC0 && rep[39] == 8'hA8 && rep[40] == 8'h01 && rep[41] == 8'h32);
        check("T1 reply sender IP = ours",
              {rep[28], rep[29], rep[30], rep[31]} == OUR_IP);

        // T2: request for another IP
        load_request(OUR_IP + 32'd1);
        before = n_replies;
        send_frame;
        check("T2 other IP: no reply", n_replies == before);

        // T3: invalid Ethernet source
        load_request(OUR_IP);
        frame[6] = 8'h03;                                   // group bit
        before = n_replies;
        send_frame;
        check("T3 group eth src: no reply", n_replies == before);

        load_request(OUR_IP);
        for (i = 6; i < 12; i = i + 1) frame[i] = 8'hFF;    // broadcast
        before = n_replies;
        send_frame;
        check("T3 broadcast eth src: no reply", n_replies == before);

        load_request(OUR_IP);
        for (i = 6; i < 12; i = i + 1) frame[i] = 8'h00;    // zero
        before = n_replies;
        send_frame;
        check("T3 zero eth src: no reply", n_replies == before);

        // T4: invalid sender hardware address (eth src stays valid)
        load_request(OUR_IP);
        frame[22] = 8'h01;                                  // group bit
        before = n_replies;
        send_frame;
        check("T4 group SHA: no reply", n_replies == before);

        load_request(OUR_IP);
        for (i = 22; i < 28; i = i + 1) frame[i] = 8'h00;   // zero
        before = n_replies;
        send_frame;
        check("T4 zero SHA: no reply", n_replies == before);

        // T5: valid request afterwards
        load_request(OUR_IP);
        before = n_replies;
        send_frame;
        check("T5 valid after drops: answered", n_replies == before + 1);

        // T6: ARP probe, sender IP 0.0.0.0
        load_request(OUR_IP);
        frame[28] = 8'h00; frame[29] = 8'h00; frame[30] = 8'h00; frame[31] = 8'h00;
        before = n_replies;
        send_frame;
        check("T6 ARP probe answered", n_replies == before + 1);

        if (fail_cnt == 0) begin
            $display("PASS: %0d tests passed", pass_cnt);
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        end
        $finish;
    end

    initial begin
        #500_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
