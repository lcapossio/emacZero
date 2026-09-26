// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// tb_gmii_cdc_rx_overflow.v - gmii_cdc RX CDC FIFO overflow handling
//
// Shrinks the RX FIFO to 64 words (RX_FIFO_ADDR_WIDTH=6) and drives the media
// RX side directly, slowing sys_clk to force overflow. Checks that:
//   - a frame larger than the FIFO is delivered truncated, with rx_er on its
//     final beat only (so the MAC terrors it), never silently short
//   - a frame arriving into a full FIFO is dropped whole, with no stray beats
//   - frame boundaries survive overflow: no two frames are merged, the
//     pending-frame count returns to zero and the reader goes idle
//   - a frame reduced to its EOF word by overflow is retired silently
//   - normal frames after an overflow come through intact
//   - under a small-frame burst every delivered frame is either exact and
//     clean, or a truncated prefix ending in an rx_er beat, in order
// Frames are preamble + SFD + payload; payload[i] = (id + i) & 0xFF so the
// checker identifies each delivered frame and detects merges.
// =============================================================================
`timescale 1ns / 1ps

module tb_gmii_cdc_rx_overflow;

    localparam AW = 6;                  // 64-word RX FIFO
    // Built twice by the regression: GMII-CDC-RX-OVERFLOW (block, the default)
    // and GMII-CDC-RX-OVERFLOW-DIST (-DGMII_CDC_DISTRIBUTED).
// KEPT = data words of an overflowing frame that fit: DEPTH-1 (one slot held
// for the EOF), plus the word the BLOCK FIFO's output stage has already
// pulled out of memory.
`ifdef GMII_CDC_DISTRIBUTED
    localparam RAM_STYLE = "DISTRIBUTED";
    localparam KEPT      = (1 << AW) - 1;
`else
    localparam RAM_STYLE = "BLOCK";
    localparam KEPT      = (1 << AW);
`endif

    // ---- Clocks ----
    reg     sys_clk, media_clk, sys_rst_n;
    integer sys_half;                   // variable-rate sys_clk
    initial begin sys_clk = 0; media_clk = 0; sys_half = 5; end
    always #(sys_half) sys_clk = ~sys_clk;
    always #4 media_clk = ~media_clk;   // 125 MHz

    reg  [7:0] m_rxd;
    reg        m_rx_dv, m_rx_er;
    wire [7:0] rx_data;
    wire       rx_dv, rx_er;

    gmii_cdc #(.RX_FIFO_ADDR_WIDTH(AW), .FIFO_RAM_STYLE(RAM_STYLE)) uut (
        .sys_clk        (sys_clk),
        .sys_rst_n      (sys_rst_n),
        .media_clk      (media_clk),
        .media_rx_clk   (media_clk),
        .cfg_speed      (2'b00),
        .gmii_txd_in    (8'd0),
        .gmii_tx_en_in  (1'b0),
        .gmii_tx_er_in  (1'b0),
        .gmii_rxd_out   (rx_data),
        .gmii_rx_dv_out (rx_dv),
        .gmii_rx_er_out (rx_er),
        .gmii_txd_out   (),
        .gmii_tx_en_out (),
        .gmii_tx_er_out (),
        .gmii_rxd_in    (m_rxd),
        .gmii_rx_dv_in  (m_rx_dv),
        .gmii_rx_er_in  (m_rx_er),
        .gmii_rx_ce_in  (1'b1),
        .tx_busy        (),
        .tx_fifo_level  ()
    );

    integer pass_cnt, fail_cnt;

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

    // =========================================================================
    // Media-side frame driver
    // =========================================================================
    task send_frame;
        input integer id;
        input integer payload_len;
        input integer ifg;
        integer k;
        begin
            @(negedge media_clk);
            for (k = 0; k < 8 + payload_len; k = k + 1) begin
                m_rx_dv = 1'b1;
                m_rx_er = 1'b0;
                m_rxd   = (k < 7) ? 8'h55 : (k == 7) ? 8'hD5 : ((id + k - 8) & 8'hFF);
                @(negedge media_clk);
            end
            m_rx_dv = 1'b0;
            m_rxd   = 8'h00;
            repeat (ifg) @(negedge media_clk);
        end
    endtask

    // =========================================================================
    // Sys-side capture + per-frame check
    // =========================================================================
    reg [7:0] cap_d  [0:255];
    reg       cap_er [0:255];
    integer   cap_len;
    reg       capturing;

    // Result of the most recent delivered frames, by delivery order.
    integer   n_frames;                 // frames delivered
    integer   fr_id    [0:63];          // frame id (payload[0])
    integer   fr_plen  [0:63];          // payload bytes delivered (excl. err beat)
    reg       fr_trunc [0:63];          // ended with an rx_er beat
    reg       fr_ok    [0:63];          // structure + content valid
    integer   stray_beats;              // dv beats not forming a valid frame

    integer j, p, pre;

    // Coverage probe: error-flagged EOF words committed to the FIFO.
    integer ovf_eofs;
    initial ovf_eofs = 0;
    always @(posedge media_clk)
        if (uut.rx_wr_accept && uut.rx_wr_is_eof && uut.rx_fifo_din[8])
            ovf_eofs = ovf_eofs + 1;
    reg     ok;

    always @(posedge sys_clk) begin
        if (!sys_rst_n) begin
            cap_len   <= 0;
            capturing <= 1'b0;
        end else if (rx_dv) begin
            if (cap_len < 256) begin
                cap_d[cap_len]  <= rx_data;
                cap_er[cap_len] <= rx_er;
            end
            cap_len   <= cap_len + 1;
            capturing <= 1'b1;
        end else if (capturing) begin
            capturing <= 1'b0;
            cap_len   <= 0;
            analyse(cap_len);
        end
    end

    // Strip leading preamble 0x55 (the reader may consume one on cold start),
    // require the SFD, then check payload[i] = payload[0] + i. A final beat with
    // rx_er set marks truncation; rx_er anywhere else is a failure.
    task analyse;
        input integer len;
        integer last;
        begin
            ok   = 1'b1;
            last = len;
            pre  = 0;
            if (len > 0 && cap_er[len-1]) last = len - 1;
            for (j = 0; j < last; j = j + 1)
                if (cap_er[j]) ok = 1'b0;
            while (pre < last && cap_d[pre] == 8'h55) pre = pre + 1;
            if (pre >= last || cap_d[pre] != 8'hD5 || pre < 6) ok = 1'b0;
            p = last - pre - 1;             // payload bytes delivered
            if (ok && p > 0)
                for (j = 1; j < p; j = j + 1)
                    if (cap_d[pre + 1 + j] != ((cap_d[pre + 1] + j) & 8'hFF))
                        ok = 1'b0;
            if (n_frames < 64) begin
                fr_id[n_frames]    = (ok && p > 0) ? cap_d[pre + 1] : -1;
                fr_plen[n_frames]  = p;
                fr_trunc[n_frames] = (last != len);
                fr_ok[n_frames]    = ok;
            end
            if (!ok) stray_beats = stray_beats + len;
            n_frames = n_frames + 1;
        end
    endtask

    task wait_idle;
        integer t;
        begin
            t = 0;
            while ((uut.rx_frames_pending != 0 || uut.rx_reading || !uut.rx_rd_empty
                    || capturing) && t < 20000) begin
                @(posedge media_clk);
                t = t + 1;
            end
            repeat (200) @(posedge media_clk);
        end
    endtask

    integer base, i, prev_id, bad, trunc_n, clean_n;

    initial begin
        $dumpfile("tb_gmii_cdc_rx_overflow.vcd");
        $dumpvars(0, tb_gmii_cdc_rx_overflow);

        pass_cnt = 0; fail_cnt = 0;
        n_frames = 0; stray_beats = 0;
        m_rxd = 0; m_rx_dv = 0; m_rx_er = 0;
        sys_rst_n = 0;
        #200;
        sys_rst_n = 1;
        #500;

        // ---- T1: a frame that fits is delivered exact and clean ----------
        send_frame(8'h10, 20, 12);
        wait_idle;
        check("T1 one frame delivered", n_frames == 1);
        check("T1 frame exact and clean",
              fr_ok[0] && !fr_trunc[0] && fr_id[0] == 8'h10 && fr_plen[0] == 20);

        // ---- T2: overflow with a slow sys side (10 MHz) --------------------
        // B (8 + 100 words) overruns the 64-word FIFO before the reader can
        // start: 63 data words are kept + an error-flagged EOF, filling it. C
        // and D then find it completely full and are lost without trace - their
        // EOFs are refused too, so the frame toggle never fires for them.
        i = ovf_eofs;
        sys_half = 50;
        repeat (4) @(posedge sys_clk);
        send_frame(8'h20, 100, 30);     // B
        send_frame(8'h40, 10, 30);      // C
        send_frame(8'h60, 10, 30);      // D
        wait_idle;
        sys_half = 5;
        repeat (20) @(posedge sys_clk);

        check("T2 only B's EOF was committed (C/D EOFs refused)", ovf_eofs == i + 1);
        check("T2 exactly one frame out of B/C/D", n_frames == 2);
        check("T2 B delivered as a valid truncated prefix", fr_ok[1] && fr_id[1] == 8'h20);
        check("T2 B ends with an rx_er beat", fr_trunc[1]);
        // KEPT data words: 7 preamble + SFD + (KEPT - 8) payload bytes.
        check("T2 B is short (KEPT words - 8 preamble/SFD)",
              fr_plen[1] == KEPT - 8);
        check("T2 no stray beats from the dropped frames", stray_beats == 0);
        check("T2 pending-frame count back to zero", uut.rx_frames_pending == 0);
        check("T2 reader idle", !uut.rx_reading);

        // ---- T3: normal traffic after overflow is intact --------------------
        send_frame(8'h80, 20, 12);
        send_frame(8'h90, 30, 12);
        wait_idle;
        check("T3 two frames delivered", n_frames == 4);
        check("T3 first frame exact and clean",
              fr_ok[2] && !fr_trunc[2] && fr_id[2] == 8'h80 && fr_plen[2] == 20);
        check("T3 second frame exact and clean",
              fr_ok[3] && !fr_trunc[3] && fr_id[3] == 8'h90 && fr_plen[3] == 30);

        // ---- T3b: exact fit, then an EOF-only frame -------------------------
        // E (KEPT - 1 data words + EOF) fills the FIFO without overflowing.
        // F then gets no data room but its EOF still fits: an EOF-only frame
        // the reader must retire silently (it used to be able to pop it as a
        // speculative read and wedge rx_frames_pending). G finds it full.
        base = n_frames;
        i    = ovf_eofs;
        sys_half = 50;
        repeat (4) @(posedge sys_clk);
        send_frame(8'hA0, KEPT - 9, 30);    // E
        send_frame(8'hC0, 10, 30);      // F
        send_frame(8'hE0, 10, 30);      // G
        wait_idle;
        sys_half = 5;
        repeat (20) @(posedge sys_clk);
        check("T3b exactly one frame out of E/F/G", n_frames == base + 1);
        check("T3b E exact and clean",
              fr_ok[base] && !fr_trunc[base] && fr_id[base] == 8'hA0 &&
              fr_plen[base] == KEPT - 9);
        check("T3b F reached the FIFO as an EOF-only frame", ovf_eofs == i + 1);
        check("T3b no stray beats", stray_beats == 0);
        check("T3b pending-frame count back to zero", uut.rx_frames_pending == 0);
        check("T3b reader idle", !uut.rx_reading);

        // ---- T4: burst of back-to-back frames at full rate ------------------
        // Writer 125 MHz vs reader 100 MHz, 55 words/frame into 64 words: some
        // frames overflow. Every delivered frame must be exact+clean or a valid
        // truncated prefix, in order, with no merges.
        base = n_frames;
        for (i = 0; i < 16; i = i + 1)
            send_frame(i * 8, 46, 12);
        wait_idle;

        bad = 0;
        prev_id = -1;
        for (i = base; i < n_frames && i < 64; i = i + 1) begin
            if (!fr_ok[i]) bad = bad + 1;
            else if (fr_id[i] <= prev_id) bad = bad + 1;          // order / dup
            else if (!fr_trunc[i] && fr_plen[i] != 46) bad = bad + 1;
            else if (fr_trunc[i] && fr_plen[i] >= 46) bad = bad + 1;
            prev_id = fr_id[i];
        end
        $display("INFO: T4 delivered %0d of 16 burst frames", n_frames - base);
        check("T4 delivered at least one burst frame", n_frames > base);
        check("T4 every delivered frame exact or truncated+rx_er, in order", bad == 0);
        check("T4 no stray beats", stray_beats == 0);
        check("T4 pending-frame count back to zero", uut.rx_frames_pending == 0);

        // ---- T5: overflowing burst ------------------------------------------
        // 62-word frames against a 64-word FIFO drained at 4/5 of the write
        // rate: the backlog grows until frames are truncated or dropped. Same
        // invariants as T4, and both outcomes must actually occur.
        base = n_frames;
        for (i = 0; i < 24; i = i + 1)
            send_frame(i * 8, 54, 12);
        wait_idle;

        bad = 0;
        prev_id = -1;
        trunc_n = 0;
        clean_n = 0;
        for (i = base; i < n_frames && i < 64; i = i + 1) begin
            if (!fr_ok[i]) bad = bad + 1;
            else if (fr_id[i] <= prev_id) bad = bad + 1;
            else if (!fr_trunc[i] && fr_plen[i] != 54) bad = bad + 1;
            else if (fr_trunc[i] && fr_plen[i] >= 54) bad = bad + 1;
            if (fr_trunc[i]) trunc_n = trunc_n + 1;
            else             clean_n = clean_n + 1;
            prev_id = fr_id[i];
        end
        $display("INFO: T5 delivered %0d of 24 (%0d clean, %0d truncated)",
                 n_frames - base, clean_n, trunc_n);
        check("T5 some frames delivered clean", clean_n > 0);
        check("T5 overflow actually exercised", trunc_n > 0 || n_frames - base < 24);
        check("T5 every delivered frame exact or truncated+rx_er, in order", bad == 0);
        check("T5 no stray beats", stray_beats == 0);
        check("T5 pending-frame count back to zero", uut.rx_frames_pending == 0);

        // ---- T6: recovery after the storm ------------------------------------
        base = n_frames;
        send_frame(8'h33, 40, 12);
        wait_idle;
        check("T6 frame after overflow exact and clean",
              n_frames == base + 1 && fr_ok[base] && !fr_trunc[base] &&
              fr_id[base] == 8'h33 && fr_plen[base] == 40);

        if (fail_cnt == 0) begin
            $display("PASS: %0d tests passed", pass_cnt);
            $display("ALL TESTS PASSED");
        end else begin
            $display("FAIL: %0d passed, %0d failed", pass_cnt, fail_cnt);
        end
        $finish;
    end

    initial begin
        #2000000;
        $display("FAIL: simulation timeout");
        $finish;
    end

endmodule
