// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_mii_tx_saf.v - Testbench for the store-and-forward MII TX path.
// Feeds AXIS frames WITH bubbles (per-byte gaps + a long mid-frame stall) and
// verifies the reconstructed MII wire frame byte-exactly: preamble/SFD, payload,
// pad-to-60, and a recomputed CRC-32 FCS. Bubbles must not corrupt the output.
// =============================================================================
`timescale 1ns / 1ps

module tb_mii_tx_saf;

    reg clk = 0;      always #5  clk = ~clk;        // 100 MHz sys
    reg mii_clk = 0;  always #20 mii_clk = ~mii_clk; // 25 MHz MII
    reg rst_n = 0;

    reg  [7:0] tdata;
    reg        tvalid = 0;
    reg        tlast  = 0;
    wire       tready;

    wire [3:0]  mii_txd;
    wire        mii_tx_en;
    wire        tx_busy;
    wire [12:0] tx_fifo_level;
    wire        tx_active, tx_byte_stb, tx_frame_done;

    mii_tx_saf #(.MAX_FRAME(1518), .FIFO_ADDR_WIDTH(12)) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .s_axis_tdata  (tdata),
        .s_axis_tvalid (tvalid),
        .s_axis_tready (tready),
        .s_axis_tlast  (tlast),
        .tx_start_ok   (1'b1),
        .mii_tx_clk    (mii_clk),
        .mii_txd       (mii_txd),
        .mii_tx_en     (mii_tx_en),
        .tx_busy       (tx_busy),
        .tx_fifo_level (tx_fifo_level),
        .tx_active     (tx_active),
        .tx_byte_stb   (tx_byte_stb),
        .tx_frame_done (tx_frame_done)
    );

    integer pass_cnt = 0, fail_cnt = 0;

    // Reference CRC-32 (Ethernet FCS)
    function [31:0] crc_step;
        input [31:0] c_in; input [7:0] d; integer i; reg [31:0] c;
        begin
            c = c_in ^ {24'd0, d};
            for (i = 0; i < 8; i = i + 1)
                c = c[0] ? ({1'b0, c[31:1]} ^ 32'hEDB88320) : {1'b0, c[31:1]};
            crc_step = c;
        end
    endfunction

    // Count sys-clk tx_byte_stb pulses to cross-check against wire bytes.
    integer byte_stb_cnt = 0;
    always @(posedge clk) if (tx_byte_stb) byte_stb_cnt = byte_stb_cnt + 1;

    // ---- Expected payload lengths, in send order ----
    integer exp_len [0:15];

    // ---- MII wire reconstruction (mii_clk) ----
    reg [7:0] wbuf [0:2047];
    integer   widx  = 0;
    reg       nsel  = 0;
    reg [3:0] lown  = 0;
    reg       en_d  = 0;
    integer   rx_fidx = 0;

    task check_frame;
        input integer wl;
        input integer fidx;
        integer plen, dplen, wexp, k;
        reg [31:0] c;
        reg bad;
        begin
            plen  = exp_len[fidx];
            dplen = (plen < 60) ? 60 : plen;   // data + pad
            wexp  = 8 + dplen + 4;             // preamble+SFD + data+pad + FCS
            bad = 0;
            for (k = 0; k < 7; k = k + 1) if (wbuf[k] !== 8'h55) bad = 1;
            if (wbuf[7] !== 8'hD5) bad = 1;
            for (k = 0; k < plen; k = k + 1)
                if (wbuf[8+k] !== k[7:0]) bad = 1;
            for (k = plen; k < 60; k = k + 1)
                if (wbuf[8+k] !== 8'h00) bad = 1;
            c = 32'hFFFFFFFF;
            for (k = 0; k < dplen; k = k + 1) c = crc_step(c, wbuf[8+k]);
            c = ~c;
            if (wbuf[8+dplen+0] !== c[7:0])   bad = 1;
            if (wbuf[8+dplen+1] !== c[15:8])  bad = 1;
            if (wbuf[8+dplen+2] !== c[23:16]) bad = 1;
            if (wbuf[8+dplen+3] !== c[31:24]) bad = 1;
            if (wl !== wexp) bad = 1;
            if (!bad) begin
                $display("PASS: frame %0d wire_len=%0d payload=%0d FCS ok", fidx, wl, plen);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: frame %0d wire_len=%0d (exp %0d) payload=%0d", fidx, wl, wexp, plen);
                $display("  pre=%02x %02x %02x %02x %02x %02x %02x sfd=%02x",
                         wbuf[0],wbuf[1],wbuf[2],wbuf[3],wbuf[4],wbuf[5],wbuf[6],wbuf[7]);
                $display("  pay=%02x %02x %02x %02x (exp 00 01 02 03)",
                         wbuf[8],wbuf[9],wbuf[10],wbuf[11]);
                $display("  fcs=%02x %02x %02x %02x  expfcs=%02x %02x %02x %02x",
                         wbuf[8+dplen],wbuf[8+dplen+1],wbuf[8+dplen+2],wbuf[8+dplen+3],
                         c[7:0],c[15:8],c[23:16],c[31:24]);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    always @(posedge mii_clk or negedge rst_n) begin
        if (!rst_n) begin
            widx <= 0; nsel <= 0; en_d <= 0; rx_fidx <= 0;
        end else begin
            en_d <= mii_tx_en;
            if (mii_tx_en) begin
                if (!nsel) begin
                    lown <= mii_txd; nsel <= 1;
                end else begin
                    wbuf[widx] <= {mii_txd, lown};
                    widx <= widx + 1;
                    nsel <= 0;
                end
            end else if (en_d) begin       // tx_en just fell -> frame complete
                check_frame(widx, rx_fidx);
                rx_fidx <= rx_fidx + 1;
                widx <= 0; nsel <= 0;
            end
        end
    end

    // ---- AXIS master with bubble injection ----
    // bub: 0 = continuous, 1 = 1-cycle gap before every byte,
    //      2 = 40-cycle stall at mid-frame (worst-case bubble)
    // Canonical AXIS master: present a byte, and only advance to the next once
    // the current one is accepted (tvalid && tready at a posedge). Race-free for
    // continuous streams and under backpressure. bub selects gap injection.
    task send_frame;
        input integer plen;
        input integer bub;
        integer k;
        begin
            k = 0;
            @(negedge clk);
            tvalid = 1; tdata = 8'h00; tlast = (plen == 1);
            while (k < plen) begin
                @(posedge clk);
                if (tvalid && tready) begin       // byte k accepted this edge
                    k = k + 1;
                    @(negedge clk);
                    if (k == plen) begin
                        tvalid = 0; tlast = 0;
                    end else begin
                        if (bub == 1) begin
                            tvalid = 0; @(negedge clk); tvalid = 1;
                        end else if (bub == 2 && k == plen/2) begin
                            tvalid = 0; repeat (40) @(negedge clk); tvalid = 1;
                        end
                        tdata = k[7:0]; tlast = (k == plen-1);
                    end
                end
            end
        end
    endtask

    integer wire_bytes_total;
    initial begin
        $dumpfile("tb_mii_tx_saf.vcd");
        $dumpvars(0, tb_mii_tx_saf);

        exp_len[0] = 60;   // continuous, exactly min data
        exp_len[1] = 64;   // per-byte bubbles
        exp_len[2] = 46;   // long mid-frame stall + needs padding
        exp_len[3] = 100;  // per-byte bubbles, longer

        #200 rst_n = 1;
        #200;

        send_frame(60,  0);
        send_frame(64,  1);
        send_frame(46,  2);
        send_frame(100, 1);

        #200000;   // let all frames drain out the 25 MHz MII side

        // wire bytes (data+pad+preamble+sfd+fcs) the stats strobe should have counted
        wire_bytes_total = (8+60+4) + (8+64+4) + (8+60+4) + (8+100+4);

        if (rx_fidx !== 4) begin
            $display("FAIL: got %0d frames, expected 4", rx_fidx);
            fail_cnt = fail_cnt + 1;
        end
        if (byte_stb_cnt !== wire_bytes_total) begin
            $display("FAIL: tx_byte_stb counted %0d, expected %0d",
                     byte_stb_cnt, wire_bytes_total);
            fail_cnt = fail_cnt + 1;
        end else begin
            $display("PASS: tx_byte_stb counted %0d wire bytes", byte_stb_cnt);
            pass_cnt = pass_cnt + 1;
        end

        if (fail_cnt == 0) begin
            $display("PASS: %0d checks passed", pass_cnt);
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        end
        $finish;
    end

endmodule
