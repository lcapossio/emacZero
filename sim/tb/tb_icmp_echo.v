// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_icmp_echo.v - Unit test for icmp_echo.v
// Feeds an ICMP echo request payload (already stripped to "type/code/csum/id/
// seq/data" by net_rx) and verifies the responder produces a full Ethernet
// frame with:
//   - Swapped MAC and IP addresses
//   - Correct IPv4 header checksum
//   - ICMP type changed from 0x08 (request) to 0x00 (reply)
//   - Adjusted ICMP checksum (incremental update by 0x0800)
//   - Echoed payload bytes preserved
// Verilog 2001
// =============================================================================
`timescale 1ns / 1ps

module tb_icmp_echo;

    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    localparam [47:0] OUR_MAC = 48'h02_00_00_00_00_01;
    localparam [31:0] OUR_IP  = 32'hC0_A8_01_C8;     // 192.168.1.200
    localparam [47:0] REQ_MAC = 48'h02_AA_BB_CC_DD_EE;
    localparam [31:0] REQ_IP  = 32'hC0_A8_01_32;     // 192.168.1.50

    reg  [7:0]  icmp_rx_data;
    reg         icmp_rx_valid;
    reg         icmp_rx_last;
    reg  [31:0] icmp_rx_src_ip;
    reg  [47:0] rx_src_mac;

    wire [7:0]  tx_data;
    wire        tx_valid;
    wire        tx_last;
    reg         tx_ready;
    wire        tx_start;

    icmp_echo u_dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .our_mac        (OUR_MAC),
        .our_ip         (OUR_IP),
        .icmp_rx_data   (icmp_rx_data),
        .icmp_rx_valid  (icmp_rx_valid),
        .icmp_rx_last   (icmp_rx_last),
        .icmp_rx_src_ip (icmp_rx_src_ip),
        .rx_src_mac     (rx_src_mac),
        .tx_data        (tx_data),
        .tx_valid       (tx_valid),
        .tx_last        (tx_last),
        .tx_ready       (tx_ready),
        .tx_start       (tx_start)
    );

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task check;
        input [255:0] name;
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

    task check_byte;
        input [255:0] name;
        input integer idx;
        input [7:0]   actual;
        input [7:0]   expected;
        begin
            if (actual === expected) begin
                $display("PASS: %0s [%0d] = 0x%02x", name, idx, actual);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: %0s [%0d] = 0x%02x exp 0x%02x",
                         name, idx, actual, expected);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // ICMP request bytes the DUT will buffer (excluding eth+IP):
    //   type=0x08 code=0x00 csum=ABCD id=1234 seq=5678 data=DEADBEEF
    localparam ICMP_LEN = 12;
    reg [7:0] icmp_req [0:ICMP_LEN-1];

    initial begin
        icmp_req[0]  = 8'h08;       // echo request
        icmp_req[1]  = 8'h00;
        icmp_req[2]  = 8'hAB;       // csum hi
        icmp_req[3]  = 8'hCD;       // csum lo
        icmp_req[4]  = 8'h12;
        icmp_req[5]  = 8'h34;
        icmp_req[6]  = 8'h56;
        icmp_req[7]  = 8'h78;
        icmp_req[8]  = 8'hDE;
        icmp_req[9]  = 8'hAD;
        icmp_req[10] = 8'hBE;
        icmp_req[11] = 8'hEF;
    end

    task feed_icmp;
        integer k;
        begin
            @(negedge clk);
            for (k = 0; k < ICMP_LEN; k = k + 1) begin
                icmp_rx_data  = icmp_req[k];
                icmp_rx_valid = 1'b1;
                icmp_rx_last  = (k == ICMP_LEN - 1);
                @(negedge clk);
            end
            icmp_rx_data  = 8'd0;
            icmp_rx_valid = 1'b0;
            icmp_rx_last  = 1'b0;
        end
    endtask

    // Capture TX frame
    reg [7:0] tx_buf [0:127];
    integer   tx_byte_cnt;
    reg       tx_done;
    reg       tx_start_seen;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_byte_cnt   <= 0;
            tx_done       <= 1'b0;
            tx_start_seen <= 1'b0;
        end else begin
            if (tx_start) tx_start_seen <= 1'b1;
            if (tx_valid && tx_ready) begin
                if (tx_byte_cnt < 128)
                    tx_buf[tx_byte_cnt] <= tx_data;
                tx_byte_cnt <= tx_byte_cnt + 1;
                if (tx_last)
                    tx_done <= 1'b1;
            end
        end
    end

    // ICMP checksum after type flip: orig + 0x0800 (one's complement)
    function [15:0] adj_csum;
        input [15:0] orig;
        reg [16:0] tmp;
        begin
            tmp      = {1'b0, orig} + 17'h0800;
            adj_csum = tmp[15:0] + {15'd0, tmp[16]};
        end
    endfunction

    // IP checksum compute over 20-byte header
    function [15:0] ip_csum;
        input [7:0] b0,b1,b2,b3,b4,b5,b6,b7,b8,b9;
        input [7:0] b10,b11,b12,b13,b14,b15,b16,b17,b18,b19;
        reg [31:0] s;
        reg [16:0] f1;
        reg [15:0] f2;
        begin
            s = {16'd0, b0,b1}  + {16'd0, b2,b3}  + {16'd0, b4,b5}  +
                {16'd0, b6,b7}  + {16'd0, b8,b9}  + {16'd0, b10,b11} +
                {16'd0, b12,b13} + {16'd0, b14,b15} + {16'd0, b16,b17} +
                {16'd0, b18,b19};
            f1 = s[15:0] + s[31:16];
            f2 = f1[15:0] + {15'd0, f1[16]};
            ip_csum = ~f2;
        end
    endfunction

    integer i;
    reg [15:0] expected_ip_csum;
    reg [15:0] expected_icmp_csum;
    reg [15:0] total_len;

    initial begin
        $dumpfile("tb_icmp_echo.vcd");
        $dumpvars(0, tb_icmp_echo);

        icmp_rx_data   = 0;
        icmp_rx_valid  = 0;
        icmp_rx_last   = 0;
        icmp_rx_src_ip = REQ_IP;
        rx_src_mac     = REQ_MAC;
        tx_ready       = 1'b1;

        #50;
        rst_n = 1;
        #50;

        // Feed ICMP request
        feed_icmp;

        // Wait for tx_start and full frame drain
        repeat (200) @(posedge clk);

        // Expected reply: 14 (eth) + 20 (IP) + 12 (ICMP) = 46 bytes
        check("tx_start asserted", tx_start_seen);
        check("tx_done (tlast saw)", tx_done);
        if (tx_byte_cnt != 46) begin
            $display("FAIL: tx_byte_cnt = %0d, expected 46", tx_byte_cnt);
            fail_cnt = fail_cnt + 1;
        end else begin
            $display("PASS: tx_byte_cnt = 46");
            pass_cnt = pass_cnt + 1;
        end

        // ---- Ethernet header check ----
        // dst = REQ_MAC, src = OUR_MAC, ethertype 0x0800
        check_byte("eth.dst_mac",  0,  tx_buf[0],  REQ_MAC[47:40]);
        check_byte("eth.dst_mac",  1,  tx_buf[1],  REQ_MAC[39:32]);
        check_byte("eth.dst_mac",  2,  tx_buf[2],  REQ_MAC[31:24]);
        check_byte("eth.dst_mac",  3,  tx_buf[3],  REQ_MAC[23:16]);
        check_byte("eth.dst_mac",  4,  tx_buf[4],  REQ_MAC[15:8]);
        check_byte("eth.dst_mac",  5,  tx_buf[5],  REQ_MAC[7:0]);
        check_byte("eth.src_mac",  6,  tx_buf[6],  OUR_MAC[47:40]);
        check_byte("eth.src_mac",  11, tx_buf[11], OUR_MAC[7:0]);
        check_byte("eth.type[hi]", 12, tx_buf[12], 8'h08);
        check_byte("eth.type[lo]", 13, tx_buf[13], 8'h00);

        // ---- IP header check ----
        check_byte("ip.ver_ihl",   14, tx_buf[14], 8'h45);
        total_len = 16'd20 + ICMP_LEN;
        check_byte("ip.totlen[hi]",16, tx_buf[16], total_len[15:8]);
        check_byte("ip.totlen[lo]",17, tx_buf[17], total_len[7:0]);
        check_byte("ip.ttl",       22, tx_buf[22], 8'h40);
        check_byte("ip.proto",     23, tx_buf[23], 8'h01);
        check_byte("ip.src_ip[0]", 26, tx_buf[26], OUR_IP[31:24]);
        check_byte("ip.src_ip[3]", 29, tx_buf[29], OUR_IP[7:0]);
        check_byte("ip.dst_ip[0]", 30, tx_buf[30], REQ_IP[31:24]);
        check_byte("ip.dst_ip[3]", 33, tx_buf[33], REQ_IP[7:0]);

        // IP header checksum: recompute and compare
        expected_ip_csum = ip_csum(
            tx_buf[14], tx_buf[15], tx_buf[16], tx_buf[17],
            tx_buf[18], tx_buf[19], tx_buf[20], tx_buf[21],
            tx_buf[22], tx_buf[23], 8'h00,      8'h00,
            tx_buf[26], tx_buf[27], tx_buf[28], tx_buf[29],
            tx_buf[30], tx_buf[31], tx_buf[32], tx_buf[33]);
        if ({tx_buf[24], tx_buf[25]} === expected_ip_csum) begin
            $display("PASS: ip.checksum = 0x%04x (matches recompute)",
                     {tx_buf[24], tx_buf[25]});
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: ip.checksum = 0x%04x, expected 0x%04x",
                     {tx_buf[24], tx_buf[25]}, expected_ip_csum);
            fail_cnt = fail_cnt + 1;
        end

        // ---- ICMP check ----
        check_byte("icmp.type",    34, tx_buf[34], 8'h00);  // reply
        check_byte("icmp.code",    35, tx_buf[35], 8'h00);

        expected_icmp_csum = adj_csum(16'hABCD);
        if ({tx_buf[36], tx_buf[37]} === expected_icmp_csum) begin
            $display("PASS: icmp.csum = 0x%04x (incremental adjust)",
                     {tx_buf[36], tx_buf[37]});
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: icmp.csum = 0x%04x, expected 0x%04x",
                     {tx_buf[36], tx_buf[37]}, expected_icmp_csum);
            fail_cnt = fail_cnt + 1;
        end

        // ICMP id/seq/data echoed
        check_byte("icmp.id[hi]",  38, tx_buf[38], 8'h12);
        check_byte("icmp.id[lo]",  39, tx_buf[39], 8'h34);
        check_byte("icmp.seq[hi]", 40, tx_buf[40], 8'h56);
        check_byte("icmp.seq[lo]", 41, tx_buf[41], 8'h78);
        check_byte("icmp.data[0]", 42, tx_buf[42], 8'hDE);
        check_byte("icmp.data[1]", 43, tx_buf[43], 8'hAD);
        check_byte("icmp.data[2]", 44, tx_buf[44], 8'hBE);
        check_byte("icmp.data[3]", 45, tx_buf[45], 8'hEF);

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
