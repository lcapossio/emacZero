// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_eth_mac_tx_pad.v - minimum-frame padding in both TX framers
// Sends 14/58/59/60/61-byte frames through eth_mac_tx (GMII/RGMII path) and
// mii_tx_saf (MII path) and checks, on the wire after the SFD: exactly
// max(len, 60) data+pad bytes plus the 4-byte FCS, pad bytes all zero, and a
// valid FCS. A 59-byte frame is the edge case: one pad byte completes it
// (eth_mac_tx used to send two).
// Verilog 2001
// =============================================================================
`timescale 1ns / 1ps

module tb_eth_mac_tx_pad;

    reg clk = 1'b0, mclk = 1'b0, rst_n = 1'b0;
    always #4  clk  = ~clk;     // 125 MHz
    always #20 mclk = ~mclk;    // 25 MHz MII TX clock

    reg  [7:0] s_tdata  = 8'd0;
    reg        s_tvalid = 1'b0;
    reg        s_tlast  = 1'b0;
    reg        sel_gmii = 1'b1;  // 1 = eth_mac_tx, 0 = mii_tx_saf
    wire       rdy_g, rdy_m;
    wire       s_tready = sel_gmii ? rdy_g : rdy_m;

    wire [7:0] gmii_txd;
    wire       gmii_tx_en, gmii_tx_er;

    eth_mac_tx u_gmii (
        .clk           (clk),
        .rst_n         (rst_n),
        .tx_start_ok   (1'b1),
        .gmii_txd      (gmii_txd),
        .gmii_tx_en    (gmii_tx_en),
        .gmii_tx_er    (gmii_tx_er),
        .s_axis_tdata  (s_tdata),
        .s_axis_tvalid (s_tvalid && sel_gmii),
        .s_axis_tready (rdy_g),
        .s_axis_tlast  (s_tlast),
        .s_axis_tkeep  (1'b1),
        .tx_active     (),
        .dbg_state     (),
        .dbg_stall_cnt ()
    );

    wire [3:0] mii_txd;
    wire       mii_tx_en;

    mii_tx_saf u_mii (
        .clk           (clk),
        .rst_n         (rst_n),
        .s_axis_tdata  (s_tdata),
        .s_axis_tvalid (s_tvalid && !sel_gmii),
        .s_axis_tready (rdy_m),
        .s_axis_tlast  (s_tlast),
        .tx_start_ok   (1'b1),
        .mii_tx_clk    (mclk),
        .mii_txd       (mii_txd),
        .mii_tx_en     (mii_tx_en),
        .tx_busy       (),
        .tx_fifo_level (),
        .tx_active     (),
        .tx_byte_stb   (),
        .tx_frame_done (),
        .dbg_saf       ()
    );

    // ---- Wire capture: bytes after the SFD, into a shared buffer ----
    reg  [7:0] wire_buf [0:127];
    integer    wire_len;        // bytes captured after the SFD
    integer    wire_frames;     // completed bursts
    reg        seen_sfd;

    function [31:0] crc_byte;
        input [31:0] c;
        input [7:0]  b;
        integer i;
        reg [31:0] t;
        begin
            t = c ^ {24'd0, b};
            for (i = 0; i < 8; i = i + 1)
                t = t[0] ? ((t >> 1) ^ 32'hEDB88320) : (t >> 1);
            crc_byte = t;
        end
    endfunction

    task wire_byte;
        input [7:0] b;
        begin
            if (seen_sfd) begin
                if (wire_len < 128) wire_buf[wire_len] = b;
                wire_len = wire_len + 1;
            end else if (b == 8'hD5) begin
                seen_sfd = 1'b1;
            end
        end
    endtask

    reg g_en_d = 1'b0;
    always @(posedge clk) begin
        if (sel_gmii) begin
            if (gmii_tx_en) wire_byte(gmii_txd);
            if (g_en_d && !gmii_tx_en) wire_frames = wire_frames + 1;
        end
        g_en_d <= gmii_tx_en;
    end

    // MII: low nibble first
    reg       m_en_d = 1'b0;
    reg       m_hi   = 1'b0;
    reg [3:0] m_lo;
    always @(posedge mclk) begin
        if (!sel_gmii) begin
            if (mii_tx_en) begin
                if (!m_hi) m_lo = mii_txd;
                else       wire_byte({mii_txd, m_lo});
                m_hi = !m_hi;
            end else begin
                m_hi = 1'b0;
            end
            if (m_en_d && !mii_tx_en) wire_frames = wire_frames + 1;
        end
        m_en_d <= mii_tx_en;
    end

    integer pass_cnt = 0, fail_cnt = 0;

    task check;
        input [511:0] name;
        input         cond;
        begin
            if (cond) begin $display("PASS: %0s", name); pass_cnt = pass_cnt + 1; end
            else      begin $display("FAIL: %0s", name); fail_cnt = fail_cnt + 1; end
        end
    endtask

    task send_and_check;
        input         gmii;
        input integer n;
        integer k, exp_len, frames0, t, pad_bad;
        reg [31:0] c;
        begin
            sel_gmii = gmii;
            wire_len = 0;
            seen_sfd = 1'b0;
            frames0  = wire_frames;
            for (k = 0; k < n; k = k + 1) begin
                @(negedge clk);
                s_tdata  = 8'hA0 + k[7:0];     // no zero bytes in the data
                s_tvalid = 1'b1;
                s_tlast  = (k == n - 1);
                @(posedge clk);
                while (!s_tready) @(posedge clk);
            end
            @(negedge clk);
            s_tvalid = 1'b0;
            s_tlast  = 1'b0;
            t = 0;
            while (wire_frames == frames0 && t < 200000) begin
                @(negedge clk);
                t = t + 1;
            end
            repeat (50) @(negedge clk);

            exp_len = ((n < 60) ? 60 : n) + 4;
            c = 32'hFFFFFFFF;
            pad_bad = 0;
            for (k = 0; k < wire_len && k < 128; k = k + 1) begin
                c = crc_byte(c, wire_buf[k]);
                if (k >= n && k < exp_len - 4 && wire_buf[k] != 8'h00)
                    pad_bad = pad_bad + 1;
            end
            $display("INFO: %0s %0d bytes in -> %0d after SFD (expect %0d)",
                     gmii ? "eth_mac_tx" : "mii_tx_saf", n, wire_len, exp_len);
            check(gmii ? "eth_mac_tx: wire length" : "mii_tx_saf: wire length",
                  wire_len == exp_len);
            check(gmii ? "eth_mac_tx: pad bytes zero" : "mii_tx_saf: pad bytes zero",
                  pad_bad == 0);
            check(gmii ? "eth_mac_tx: FCS valid" : "mii_tx_saf: FCS valid",
                  c == 32'hDEBB20E3);
        end
    endtask

    integer i;
    reg [31:0] lens [0:4];

    initial begin
        wire_frames = 0;
        wire_len    = 0;
        seen_sfd    = 1'b0;
        lens[0] = 14; lens[1] = 58; lens[2] = 59; lens[3] = 60; lens[4] = 61;
        #100 rst_n = 1'b1;
        #200;
        for (i = 0; i < 5; i = i + 1) send_and_check(1'b1, lens[i]);
        for (i = 0; i < 5; i = i + 1) send_and_check(1'b0, lens[i]);

        if (fail_cnt == 0) begin
            $display("PASS: %0d tests passed", pass_cnt);
            $display("ALL TESTS PASSED");
        end else
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        $finish;
    end

    initial begin #20000000; $display("FAIL: simulation timeout"); $finish; end

endmodule
