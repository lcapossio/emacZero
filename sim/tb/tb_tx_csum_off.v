// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_tx_csum_off.v - Testbench for tx_csum_off
// Verifies IPv4 header and UDP checksum insertion on a known frame. The
// randomized checks (all protocols, VLAN, IPv6, backpressure) are in
// sim/cocotb/tests/test_tx_csum_off.py.
// Verilog 2001
// =============================================================================

`timescale 1ns/1ps

module tb_tx_csum_off;
    reg clk = 0;
    reg rst_n = 0;
    reg enable = 1;

    always #5 clk = ~clk;  // 100 MHz

    // Ingress
    reg  [7:0] s_tdata;
    reg        s_tvalid;
    wire       s_tready;
    reg        s_tlast;

    // Egress
    wire [7:0] m_tdata;
    wire       m_tvalid;
    reg        m_tready;
    wire       m_tlast;

    tx_csum_off #(.MAX_FRAME(64)) uut (
        .clk           (clk),
        .rst_n         (rst_n),
        .enable        (enable),
        .s_axis_tdata  (s_tdata),
        .s_axis_tvalid (s_tvalid),
        .s_axis_tready (s_tready),
        .s_axis_tlast  (s_tlast),
        .m_axis_tdata  (m_tdata),
        .m_axis_tvalid (m_tvalid),
        .m_axis_tready (m_tready),
        .m_axis_tlast  (m_tlast)
    );

    integer pass_cnt = 0, fail_cnt = 0;

    // Build a 42-byte UDP-over-IPv4 frame:
    //   [0..5]   dst MAC FF:FF:FF:FF:FF:FF
    //   [6..11]  src MAC 02:00:00:00:00:01
    //   [12..13] type    0x0800
    //   [14]     0x45  (IPv4, IHL=5)
    //   [15]     0x00  (DSCP/ECN)
    //   [16..17] 0x001C (total length 28)
    //   [18..19] 0xCAFE (id)
    //   [20..21] 0x4000 (flags+frag)
    //   [22]     0x40   (TTL=64)
    //   [23]     0x11   (protocol UDP)
    //   [24..25] 0x0000 (header checksum, to be patched)
    //   [26..29] C0 A8 89 01 (src IP 192.168.137.1)
    //   [30..33] C0 A8 89 C8 (dst IP 192.168.137.200)
    //   [34..35] 0x0035 (src port 53)
    //   [36..37] 0x1F90 (dst port 8080)
    //   [38..39] 0x0008 (UDP length 8)
    //   [40..41] 0xDEAD (UDP csum, to be replaced)
    //   No payload (just header).

    reg [7:0] frame [0:41];
    reg [7:0] expected [0:41];

    initial begin
        // Build frame
        frame[0]=8'hFF; frame[1]=8'hFF; frame[2]=8'hFF;
        frame[3]=8'hFF; frame[4]=8'hFF; frame[5]=8'hFF;
        frame[6]=8'h02; frame[7]=8'h00; frame[8]=8'h00;
        frame[9]=8'h00; frame[10]=8'h00; frame[11]=8'h01;
        frame[12]=8'h08; frame[13]=8'h00;
        frame[14]=8'h45; frame[15]=8'h00;
        frame[16]=8'h00; frame[17]=8'h1C;
        frame[18]=8'hCA; frame[19]=8'hFE;
        frame[20]=8'h40; frame[21]=8'h00;
        frame[22]=8'h40; frame[23]=8'h11;
        frame[24]=8'h00; frame[25]=8'h00;
        frame[26]=8'hC0; frame[27]=8'hA8; frame[28]=8'h89; frame[29]=8'h01;
        frame[30]=8'hC0; frame[31]=8'hA8; frame[32]=8'h89; frame[33]=8'hC8;
        frame[34]=8'h00; frame[35]=8'h35;
        frame[36]=8'h1F; frame[37]=8'h90;
        frame[38]=8'h00; frame[39]=8'h08;
        frame[40]=8'hDE; frame[41]=8'hAD;

        // Expected checksums (Python reference, sim/cocotb/lib/csum.py):
        //   IPv4 header  0xDBB7
        //   UDP          0x4BFE (pseudo-header C0A88901 C0A889C8 0011 0008)
        $dumpfile("tb_tx_csum_off.vcd");
        $dumpvars(0, tb_tx_csum_off);

        s_tvalid = 0; s_tdata = 0; s_tlast = 0;
        m_tready = 1;
        rst_n = 0;
        #50; rst_n = 1;
        #20;

        // Stream the frame in
        begin : send
            integer i;
            for (i = 0; i < 42; i = i + 1) begin
                @(posedge clk);
                s_tdata  <= frame[i];
                s_tvalid <= 1'b1;
                s_tlast  <= (i == 41);
                while (!s_tready) @(posedge clk);
            end
            @(posedge clk);
            s_tvalid <= 1'b0;
            s_tlast  <= 1'b0;
        end

        // Capture the egress
        begin : recv
            integer i;
            reg [7:0] cap [0:41];
            for (i = 0; i < 42; i = i + 1) begin
                @(posedge clk);
                while (!m_tvalid) @(posedge clk);
                cap[i] = m_tdata;
            end

            // Verify: bytes 24,25 are the IP header checksum
            if (cap[24] == 8'hDB && cap[25] == 8'hB7) begin
                $display("PASS: IP checksum inserted = 0x%02x%02x", cap[24], cap[25]);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: IP checksum = 0x%02x%02x (expected 0xDBB7)",
                         cap[24], cap[25]);
                fail_cnt = fail_cnt + 1;
            end

            // Verify: bytes 40,41 are the UDP checksum
            if (cap[40] == 8'h4B && cap[41] == 8'hFE) begin
                $display("PASS: UDP checksum inserted = 0x%02x%02x", cap[40], cap[41]);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: UDP checksum = 0x%02x%02x (expected 0x4BFE)",
                         cap[40], cap[41]);
                fail_cnt = fail_cnt + 1;
            end

            // Verify: all other bytes match input exactly
            begin : data_check
                integer j; reg bad;
                bad = 0;
                for (j = 0; j < 42; j = j + 1) begin
                    if (j != 24 && j != 25 && j != 40 && j != 41) begin
                        if (cap[j] !== frame[j]) begin
                            $display("  byte[%0d] mismatch: got 0x%02x, want 0x%02x",
                                     j, cap[j], frame[j]);
                            bad = 1;
                        end
                    end
                end
                if (!bad) begin
                    $display("PASS: payload pass-through intact");
                    pass_cnt = pass_cnt + 1;
                end else begin
                    $display("FAIL: payload corrupted");
                    fail_cnt = fail_cnt + 1;
                end
            end

            // Verify checksum is mathematically valid:
            // sum of all 16-bit IP header words (with the patched checksum
            // included) should fold to 0xFFFF.
            begin : csum_verify
                reg [31:0] s;
                reg [16:0] f1;
                reg [15:0] f2;
                s = {16'd0, cap[14], cap[15]} + {16'd0, cap[16], cap[17]}
                  + {16'd0, cap[18], cap[19]} + {16'd0, cap[20], cap[21]}
                  + {16'd0, cap[22], cap[23]} + {16'd0, cap[24], cap[25]}
                  + {16'd0, cap[26], cap[27]} + {16'd0, cap[28], cap[29]}
                  + {16'd0, cap[30], cap[31]} + {16'd0, cap[32], cap[33]};
                f1 = s[15:0] + s[31:16];
                f2 = f1[15:0] + {15'd0, f1[16]};
                if (f2 == 16'hFFFF) begin
                    $display("PASS: IP checksum verifies (fold = 0xFFFF)");
                    pass_cnt = pass_cnt + 1;
                end else begin
                    $display("FAIL: IP checksum invalid (fold = 0x%04x)", f2);
                    fail_cnt = fail_cnt + 1;
                end
            end
        end

        if (fail_cnt == 0) begin
            $display("PASS: %0d tests passed", pass_cnt);
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        end
        $finish;
    end

    initial begin
        #100000;  // safety timeout
        $display("FAIL: timeout");
        $finish;
    end
endmodule
