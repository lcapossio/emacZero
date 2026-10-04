// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_net_rx.v - Unit test for net_rx.v
// Verifies Ethernet/IP parser by feeding raw byte streams and checking the
// ARP / ICMP demux outputs and parsed metadata (rx_src_mac, icmp_src_ip).
//
// Tests:
//   T1: ARP frame -> arp_valid pulses, arp_last fires
//   T2: IPv4 ICMP frame to our IP -> icmp_data stream + icmp_src_ip captured
//   T3: IPv4 ICMP frame to broadcast (255.255.255.255) -> accepted
//   T4: IPv4 ICMP frame to wrong IP -> dropped (no icmp_valid)
//   T5: IPv4 UDP frame -> dropped (no icmp_valid)
//   T6: bad IPv4 header checksum -> dropped
//   T7: bad ICMP checksum -> passed on, icmp_err with icmp_last
//   T8: terror on the last beat -> icmp_err with icmp_last
//   T9: short ICMP padded to 60 bytes -> only the 8 ICMP bytes passed on
//   T10: frame shorter than the IPv4 total length -> icmp_err
//   T11: UDP with 5 payload bytes, padded -> 5 bytes, udp_last, no udp_err
//   T12: two ICMP frames back to back -> both complete, no error
//   T13: IP version 6 in an IPv4 ethertype frame -> dropped
// (rx_src_mac is checked in T1 and T2; frames carry valid checksums unless
// a test corrupts one.)
// Verilog 2001
// =============================================================================
`timescale 1ns / 1ps

module tb_net_rx;

    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    reg  [7:0]  s_tdata;
    reg         s_tvalid;
    reg         s_tlast;
    reg         s_tsof;
    reg         s_terror;

    wire [7:0]  arp_data;
    wire        arp_valid;
    wire        arp_last;

    wire [7:0]  icmp_data;
    wire        icmp_valid;
    wire        icmp_last;
    wire        icmp_err;
    wire [31:0] icmp_src_ip;

    wire [7:0]  udp_data;
    wire        udp_valid;
    wire        udp_last;
    wire        udp_err;

    wire [47:0] rx_src_mac;

    localparam [31:0] OUR_IP = 32'hC0_A8_01_C8;  // 192.168.1.200

    net_rx u_dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .s_axis_tdata  (s_tdata),
        .s_axis_tvalid (s_tvalid),
        .s_axis_tlast  (s_tlast),
        .s_axis_tsof   (s_tsof),
        .s_axis_terror (s_terror),
        .arp_data      (arp_data),
        .arp_valid     (arp_valid),
        .arp_last      (arp_last),
        .icmp_data     (icmp_data),
        .icmp_valid    (icmp_valid),
        .icmp_last     (icmp_last),
        .icmp_err      (icmp_err),
        .icmp_src_ip   (icmp_src_ip),
        .udp_data      (udp_data),
        .udp_valid     (udp_valid),
        .udp_last      (udp_last),
        .udp_err       (udp_err),
        .rx_src_mac    (rx_src_mac),
        .our_ip        (OUR_IP)
    );

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task check_eq32;
        input [255:0] name;
        input [31:0]  actual;
        input [31:0]  expected;
        begin
            if (actual === expected) begin
                $display("PASS: %0s = 0x%08x", name, actual);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: %0s = 0x%08x, expected 0x%08x",
                         name, actual, expected);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task check_eq48;
        input [255:0] name;
        input [47:0]  actual;
        input [47:0]  expected;
        begin
            if (actual === expected) begin
                $display("PASS: %0s = 0x%012x", name, actual);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: %0s = 0x%012x, expected 0x%012x",
                         name, actual, expected);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task check_int;
        input [255:0] name;
        input integer actual;
        input integer expected;
        begin
            if (actual == expected) begin
                $display("PASS: %0s = %0d", name, actual);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: %0s = %0d, expected %0d",
                         name, actual, expected);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // ---- Counters ----
    integer arp_byte_cnt;
    integer icmp_byte_cnt;
    reg     arp_last_seen;
    reg     icmp_last_seen;
    integer icmp_last_cnt;
    reg     icmp_err_seen;
    integer udp_byte_cnt;
    reg     udp_last_seen;
    reg     udp_err_seen;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            arp_byte_cnt   <= 0;
            icmp_byte_cnt  <= 0;
            arp_last_seen  <= 1'b0;
            icmp_last_seen <= 1'b0;
            icmp_last_cnt  <= 0;
            icmp_err_seen  <= 1'b0;
            udp_byte_cnt   <= 0;
            udp_last_seen  <= 1'b0;
            udp_err_seen   <= 1'b0;
        end else begin
            if (arp_valid)  arp_byte_cnt  <= arp_byte_cnt  + 1;
            if (arp_last)   arp_last_seen <= 1'b1;
            if (icmp_valid) icmp_byte_cnt <= icmp_byte_cnt + 1;
            if (icmp_last)  icmp_last_seen <= 1'b1;
            if (icmp_last)  icmp_last_cnt <= icmp_last_cnt + 1;
            if (icmp_last && icmp_err) icmp_err_seen <= 1'b1;
            if (udp_valid)  udp_byte_cnt  <= udp_byte_cnt + 1;
            if (udp_last)   udp_last_seen <= 1'b1;
            if (udp_last && udp_err) udp_err_seen <= 1'b1;
        end
    end

    task reset_counters;
        begin
            @(negedge clk);
            arp_byte_cnt   = 0;
            icmp_byte_cnt  = 0;
            arp_last_seen  = 1'b0;
            icmp_last_seen = 1'b0;
            icmp_last_cnt  = 0;
            icmp_err_seen  = 1'b0;
            udp_byte_cnt   = 0;
            udp_last_seen  = 1'b0;
            udp_err_seen   = 1'b0;
        end
    endtask

    // ---- Frame buffer ----
    reg [7:0] frame [0:255];
    integer   frame_len;

    reg       terror_on_last = 1'b0;   // MAC flags the frame at tlast
    reg       back_to_back   = 1'b0;   // no idle cycle after this frame

    task feed_frame;
        integer k;
        begin
            @(negedge clk);
            for (k = 0; k < frame_len; k = k + 1) begin
                s_tdata  = frame[k];
                s_tvalid = 1'b1;
                s_tsof   = (k == 0);
                s_tlast  = (k == frame_len - 1);
                s_terror = terror_on_last && (k == frame_len - 1);
                if (!(back_to_back && k == frame_len - 1))
                    @(negedge clk);
            end
            if (!back_to_back) begin
                s_tdata  = 8'd0;
                s_tvalid = 1'b0;
                s_tlast  = 1'b0;
                s_tsof   = 1'b0;
                s_terror = 1'b0;
                // settle
                repeat (4) @(negedge clk);
            end
        end
    endtask

    // IPv4 header checksum (bytes 14..33) and, for ICMP, the ICMP checksum
    // over the IPv4 payload given by the total length.
    task fix_csums;
        integer i, sum, tot;
        begin
            frame[24] = 8'h00; frame[25] = 8'h00;
            sum = 0;
            for (i = 14; i < 34; i = i + 2)
                sum = sum + {frame[i], frame[i+1]};
            sum = (sum & 32'hFFFF) + (sum >> 16);
            sum = (sum & 32'hFFFF) + (sum >> 16);
            frame[24] = ~sum[15:8]; frame[25] = ~sum[7:0];
            if (frame[23] == 8'h01) begin
                tot = {frame[16], frame[17]};
                frame[36] = 8'h00; frame[37] = 8'h00;
                sum = 0;
                for (i = 34; i < 14 + tot; i = i + 2)
                    sum = sum + {frame[i], (i + 1 < 14 + tot) ? frame[i+1] : 8'h00};
                sum = (sum & 32'hFFFF) + (sum >> 16);
                sum = (sum & 32'hFFFF) + (sum >> 16);
                frame[36] = ~sum[15:8]; frame[37] = ~sum[7:0];
            end
        end
    endtask

    task load_arp_request;
        integer i;
        begin
            // dst MAC = broadcast
            frame[0]=8'hFF; frame[1]=8'hFF; frame[2]=8'hFF;
            frame[3]=8'hFF; frame[4]=8'hFF; frame[5]=8'hFF;
            // src MAC
            frame[6]=8'h02; frame[7]=8'h11; frame[8]=8'h22;
            frame[9]=8'h33; frame[10]=8'h44; frame[11]=8'h55;
            // ethertype = ARP
            frame[12]=8'h08; frame[13]=8'h06;
            // ARP payload (28 bytes — htype/ptype/hlen/plen/oper/sha/spa/tha/tpa)
            frame[14]=8'h00; frame[15]=8'h01;     // htype Ethernet
            frame[16]=8'h08; frame[17]=8'h00;     // ptype IPv4
            frame[18]=8'h06; frame[19]=8'h04;     // hlen=6, plen=4
            frame[20]=8'h00; frame[21]=8'h01;     // opcode = request
            for (i = 22; i < 42; i = i + 1) frame[i] = i[7:0];
            frame_len = 42;
        end
    endtask

    task load_icmp;
        input [31:0] dst_ip;
        integer i;
        begin
            // dst MAC = our (doesn't matter for net_rx — no MAC filter)
            frame[0]=8'h02; frame[1]=8'h00; frame[2]=8'h00;
            frame[3]=8'h00; frame[4]=8'h00; frame[5]=8'h02;
            // src MAC
            frame[6]=8'h02; frame[7]=8'hAA; frame[8]=8'hBB;
            frame[9]=8'hCC; frame[10]=8'hDD; frame[11]=8'hEE;
            // ethertype = IPv4
            frame[12]=8'h08; frame[13]=8'h00;
            // IP header (20 bytes), IHL=5
            frame[14]=8'h45; frame[15]=8'h00;
            frame[16]=8'h00; frame[17]=8'h1C;     // total len = 28
            frame[18]=8'h00; frame[19]=8'h01;     // id
            frame[20]=8'h40; frame[21]=8'h00;     // flags
            frame[22]=8'h40; frame[23]=8'h01;     // TTL=64, proto=ICMP(1)
            frame[24]=8'h00; frame[25]=8'h00;     // header csum (fix_csums)
            // src ip = 192.168.1.50
            frame[26]=8'hC0; frame[27]=8'hA8; frame[28]=8'h01; frame[29]=8'h32;
            // dst ip
            frame[30]=dst_ip[31:24]; frame[31]=dst_ip[23:16];
            frame[32]=dst_ip[15:8];  frame[33]=dst_ip[7:0];
            // ICMP echo request (8 bytes)
            frame[34]=8'h08; frame[35]=8'h00;     // type=8, code=0
            frame[36]=8'h12; frame[37]=8'h34;     // csum
            frame[38]=8'h00; frame[39]=8'h01;     // id
            frame[40]=8'h00; frame[41]=8'h02;     // seq
            frame_len = 42;
            fix_csums;
        end
    endtask

    task load_udp;
        integer i;
        begin
            // dst MAC
            frame[0]=8'h02; frame[1]=8'h00; frame[2]=8'h00;
            frame[3]=8'h00; frame[4]=8'h00; frame[5]=8'h02;
            // src MAC
            frame[6]=8'h02; frame[7]=8'hAA; frame[8]=8'hBB;
            frame[9]=8'hCC; frame[10]=8'hDD; frame[11]=8'hEE;
            // ethertype = IPv4
            frame[12]=8'h08; frame[13]=8'h00;
            // IP header — proto = UDP (17)
            frame[14]=8'h45; frame[15]=8'h00;
            frame[16]=8'h00; frame[17]=8'h1C;
            frame[18]=8'h00; frame[19]=8'h01;
            frame[20]=8'h40; frame[21]=8'h00;
            frame[22]=8'h40; frame[23]=8'h11;     // proto=UDP
            frame[24]=8'h00; frame[25]=8'h00;
            frame[26]=8'hC0; frame[27]=8'hA8; frame[28]=8'h01; frame[29]=8'h32;
            frame[30]=OUR_IP[31:24]; frame[31]=OUR_IP[23:16];
            frame[32]=OUR_IP[15:8];  frame[33]=OUR_IP[7:0];
            // UDP-ish payload
            for (i = 34; i < 42; i = i + 1) frame[i] = i[7:0];
            frame_len = 42;
            fix_csums;
        end
    endtask

    integer i;

    initial begin
        $dumpfile("tb_net_rx.vcd");
        $dumpvars(0, tb_net_rx);

        s_tdata = 0; s_tvalid = 0; s_tlast = 0; s_tsof = 0; s_terror = 0;
        #50;
        rst_n = 1;
        #50;

        // =================================================================
        // T1: ARP
        // =================================================================
        reset_counters;
        load_arp_request;
        feed_frame;
        check_int("T1 arp_byte_cnt = 28",  arp_byte_cnt, 28);
        check_int("T1 arp_last_seen = 1",  arp_last_seen, 1);
        check_int("T1 icmp_byte_cnt = 0",  icmp_byte_cnt, 0);
        check_eq48("T1 rx_src_mac",
                   rx_src_mac, 48'h02_11_22_33_44_55);

        // =================================================================
        // T2: ICMP to our IP
        // =================================================================
        reset_counters;
        load_icmp(OUR_IP);
        feed_frame;
        check_int("T2 icmp_byte_cnt = 8", icmp_byte_cnt, 8);
        check_int("T2 icmp_last_seen = 1", icmp_last_seen, 1);
        check_eq32("T2 icmp_src_ip = 192.168.1.50",
                   icmp_src_ip, 32'hC0_A8_01_32);
        check_eq48("T2 rx_src_mac",
                   rx_src_mac, 48'h02_AA_BB_CC_DD_EE);

        // =================================================================
        // T3: ICMP to broadcast IP
        // =================================================================
        reset_counters;
        load_icmp(32'hFF_FF_FF_FF);
        feed_frame;
        check_int("T3 icmp_byte_cnt = 8 (broadcast)", icmp_byte_cnt, 8);
        check_int("T3 icmp_last_seen = 1", icmp_last_seen, 1);

        // =================================================================
        // T4: ICMP to wrong IP -> dropped
        // =================================================================
        reset_counters;
        load_icmp(32'h0A_00_00_01);  // 10.0.0.1
        feed_frame;
        check_int("T4 icmp_byte_cnt = 0 (dropped)",  icmp_byte_cnt, 0);
        check_int("T4 icmp_last_seen = 0 (dropped)", icmp_last_seen, 0);

        // =================================================================
        // T5: UDP frame -> dropped (only ICMP demuxed)
        // =================================================================
        reset_counters;
        load_udp;
        feed_frame;
        check_int("T5 icmp_byte_cnt = 0 (UDP)",  icmp_byte_cnt, 0);
        check_int("T5 icmp_last_seen = 0 (UDP)", icmp_last_seen, 0);
        check_int("T5 arp_byte_cnt = 0  (UDP)",  arp_byte_cnt, 0);

        // =================================================================
        // T6: bad IPv4 header checksum -> dropped
        // =================================================================
        reset_counters;
        load_icmp(OUR_IP);
        frame[25] = frame[25] ^ 8'h01;
        feed_frame;
        check_int("T6 icmp_byte_cnt = 0 (bad IP csum)",  icmp_byte_cnt, 0);
        check_int("T6 icmp_last_seen = 0 (bad IP csum)", icmp_last_seen, 0);

        // =================================================================
        // T7: bad ICMP checksum -> icmp_err with icmp_last
        // =================================================================
        reset_counters;
        load_icmp(OUR_IP);
        frame[37] = frame[37] ^ 8'h01;
        feed_frame;
        check_int("T7 icmp_last_seen = 1", icmp_last_seen, 1);
        check_int("T7 icmp_err = 1 (bad ICMP csum)", icmp_err_seen, 1);

        // =================================================================
        // T8: terror on the last beat -> icmp_err
        // =================================================================
        reset_counters;
        load_icmp(OUR_IP);
        terror_on_last = 1'b1;
        feed_frame;
        terror_on_last = 1'b0;
        check_int("T8 icmp_last_seen = 1", icmp_last_seen, 1);
        check_int("T8 icmp_err = 1 (terror)", icmp_err_seen, 1);

        // =================================================================
        // T9: ICMP padded to the 60-byte minimum -> padding not passed on
        // =================================================================
        reset_counters;
        load_icmp(OUR_IP);
        for (i = 42; i < 60; i = i + 1) frame[i] = 8'hAA;
        frame_len = 60;
        feed_frame;
        check_int("T9 icmp_byte_cnt = 8 (padding dropped)", icmp_byte_cnt, 8);
        check_int("T9 icmp_last_seen = 1", icmp_last_seen, 1);
        check_int("T9 icmp_err = 0", icmp_err_seen, 0);

        // =================================================================
        // T10: IPv4 total length 40 in a 42-byte frame -> icmp_err
        // =================================================================
        reset_counters;
        load_icmp(OUR_IP);
        frame[17] = 8'h28;
        fix_csums;
        feed_frame;
        check_int("T10 icmp_last_seen = 1", icmp_last_seen, 1);
        check_int("T10 icmp_err = 1 (truncated)", icmp_err_seen, 1);

        // =================================================================
        // T11: UDP with 5 payload bytes, padded to 60
        // =================================================================
        reset_counters;
        load_udp;
        frame[17] = 8'h21;                        // total len = 33
        frame[38] = 8'h00; frame[39] = 8'h0D;     // UDP length = 13
        for (i = 42; i < 47; i = i + 1) frame[i] = 8'h50 + i[7:0];
        for (i = 47; i < 60; i = i + 1) frame[i] = 8'hAA;
        frame_len = 60;
        fix_csums;
        feed_frame;
        check_int("T11 udp_byte_cnt = 5", udp_byte_cnt, 5);
        check_int("T11 udp_last_seen = 1", udp_last_seen, 1);
        check_int("T11 udp_err = 0", udp_err_seen, 0);

        // =================================================================
        // T12: two ICMP frames back to back
        // =================================================================
        reset_counters;
        load_icmp(OUR_IP);
        back_to_back = 1'b1;
        feed_frame;
        back_to_back = 1'b0;
        feed_frame;
        check_int("T12 icmp_byte_cnt = 16", icmp_byte_cnt, 16);
        check_int("T12 icmp_last_cnt = 2", icmp_last_cnt, 2);
        check_int("T12 icmp_err = 0", icmp_err_seen, 0);

        // =================================================================
        // T13: IP version 6 -> dropped
        // =================================================================
        reset_counters;
        load_icmp(OUR_IP);
        frame[14] = 8'h65;
        fix_csums;
        feed_frame;
        check_int("T13 icmp_byte_cnt = 0 (version 6)", icmp_byte_cnt, 0);

        // =================================================================
        // Summary
        // =================================================================
        if (fail_cnt == 0) begin
            $display("PASS: %0d tests passed", pass_cnt);
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        end
        $finish;
    end

    initial begin
        #200_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
