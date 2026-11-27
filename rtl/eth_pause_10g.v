// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// eth_pause_10g.v - 802.3x PAUSE flow control for eth_mac_sys_10g (IEEE 802.3
// clause 31 and Annex 31B), on three clocks:
//
//   rx_clk (the RX MAC's): received PAUSE frames are recognized on the RX
//       MAC's output stream, ahead of the address filter and the RX FIFO: dst
//       01:80:C2:00:00:01, EtherType 0x8808, opcode 0x0001, and a good frame
//       (no tuser: good FCS, at least 64 bytes, no control or error
//       character). rx_pause_evt pulses for each; its pause_time and a toggle
//       go to tx_clk. The automatic PAUSE congestion state is kept here too,
//       from the RX FIFO level.
//   tx_clk (the TX MAC's, with tx_ce): the pause timer and the TX side of
//       the PAUSE frame generator. A pause quantum is 512 bit times, 64
//       bytes, exactly 8 XGMII words, so the timer counts 8 tx_ce per
//       quantum. tx_paused holds data frames that have not started (the
//       system's TX arbiter closes on it between frames). The frames already
//       committed when a nonzero PAUSE arrives (started: from f_start, a
//       first beat taken by the MAC, to f_end, its terminate sent; or with a
//       first beat offered to the MAC and not yet taken, f_wait, which the
//       arbiter cannot take back) finish first, and the countdown starts
//       after the last of them ends (802.3 Figure 31B-2,
//       transmission_in_progress), so the pause is never shortened. Our own
//       PAUSE frames started later do not hold it. A quanta of 0 cancels the
//       pause at once, also while the countdown waits. With cfg_rx_en low,
//       received PAUSE frames are counted but do not pause.
//       The generator offers 64-bit PAUSE frames (p_*: 18 bytes, the MAC pads
//       them to 60) to the arbiter, which sends them ahead of data frames
//       that have not started and does not hold them while paused.
//   clk (the CSRs'): cfg_tx_send asks for one PAUSE frame with cfg_quanta
//       (latched with the request); one more request can wait (a later one
//       replaces it), and tx_pending reads 1 until the generator has started
//       the frame. The automatic PAUSE configuration is checked and latched
//       here when cfg_auto_en rises.
//
// Automatic PAUSE (as eth_pause on the 1G core): with cfg_auto_en, reaching
// cfg_auto_xoff bytes in the RX FIFO sends a PAUSE with cfg_quanta, repeated
// every refresh interval while the level stays at or above cfg_auto_xon;
// falling below cfg_auto_xon, or clearing cfg_auto_en, sends one quanta-0
// PAUSE. cfg_quanta, the thresholds and the refresh (0: half of cfg_quanta,
// at least 1) are latched when cfg_auto_en rises; an invalid set (quanta 0,
// not 0 < xon <= xoff <= LEVEL_MAX, or a refresh not under the quanta) raises
// auto_cfg_err and leaves the feature off until cfg_auto_en is cleared and
// set again. Automatic frames go first, but a waiting cfg_tx_send never waits
// behind more than one of them. The refresh interval counts tx_ce quanta
// from the moment an automatic XOFF left the generator.
//
// Clock crossings. clk -> rx_clk / tx_clk: the latched automatic settings
// are static while auto_run is high, and auto_run rises and falls AUTO_SETTLE
// clk cycles away from any change of them; the station address and
// cfg_rx_en are quasi-static (two-flop synchronizers, as the system's other
// settings). The tx_send request is a toggle with its quanta held until the
// tx_clk side toggles an acknowledge back. rx_clk -> tx_clk: a toggle with
// the pause_time, which holds from that toggle until the next valid PAUSE
// frame ends, at least 8 words later; the tx_clk side reads it two cycles
// after the toggle arrives. Like the FIFO crossings between clk and the
// transceiver clocks, these multi-bit crossings need their paths bounded
// (set_max_delay -datapath_only under a destination clock period), not cut.
// Resets: the clk side of the request handshake resets with the TX crossing
// (c_tx_rst_n with tx_rst_n, as eth_mac_sys_10g resets each crossing
// whole). rx_clk and tx_clk reset on their own; the tx_clk side ignores the
// PAUSE toggle for its first cycles after a reset (a PAUSE frame received
// then is lost), and an RX reset alone (the toggle returns to 0, the
// pause_time to 0) at most cancels a pause.
// Verilog 2001
// =============================================================================

module eth_pause_10g #(
    parameter        LEVEL_W   = 12,           // rx_level width (FIFO words, <= 17)
    parameter [19:0] LEVEL_MAX = 20'd16384     // largest XOFF, bytes
) (
    // ---- clk: CSR side
    input  wire        clk,
    input  wire        c_rst_n,             // configuration and status
    input  wire        c_tx_rst_n,          // the TX crossing, clk side
    input  wire        cfg_tx_send,         // 1-cycle pulse
    input  wire [15:0] cfg_quanta,
    input  wire        cfg_rx_en,
    input  wire        cfg_auto_en,
    input  wire [19:0] cfg_auto_xoff,
    input  wire [19:0] cfg_auto_xon,
    input  wire [15:0] cfg_auto_refresh,
    input  wire [47:0] our_mac,
    output wire        tx_pending,
    output reg         auto_cfg_err,
    output wire        auto_active,         // synchronized into clk
    output wire        paused_sts,          // tx_paused synchronized into clk

    // ---- rx_clk: the RX MAC's output stream and the RX FIFO level
    input  wire        rx_clk,
    input  wire        rx_rst_n,
    input  wire [63:0] rx_tdata,
    input  wire        rx_tvalid,
    input  wire        rx_tlast,
    input  wire        rx_tuser,
    input  wire [LEVEL_W-1:0] rx_level,     // RX FIFO words held
    output reg         rx_pause_evt,        // a valid PAUSE frame was received

    // ---- tx_clk: timer, generator
    input  wire        tx_clk,
    input  wire        tx_rst_n,
    input  wire        tx_ce,
    input  wire        f_start,             // the MAC took a frame's first beat
    input  wire        f_wait,              // a first beat is offered, not taken
    input  wire        f_end,               // the MAC sent a frame's terminate
    output reg         tx_paused,
    output reg  [63:0] p_tdata,
    output wire [7:0]  p_tkeep,
    output wire        p_tvalid,
    input  wire        p_tready,
    output wire        p_tlast,
    output reg         tx_pause_evt         // a PAUSE frame left the generator
);

    localparam AUTO_SETTLE = 8;

    // =========================================================================
    // clk: automatic PAUSE configuration, latched when cfg_auto_en rises
    // =========================================================================
    reg        auto_en_d;
    reg        auto_run;            // to rx_clk / tx_clk
    reg [19:0] a_xoff, a_xon;       // applied settings (cross to rx / tx)
    reg [15:0] a_quanta, a_refresh;
    reg [19:0] s_xoff, s_xon;       // taken at the enable edge
    reg [15:0] s_quanta, s_refresh;
    reg        have;                // a valid snapshot waits to be applied
    reg [3:0]  settle;              // clk cycles since the last change
    reg        run_want;            // applied, run once settled

    wire auto_cfg_ok = (cfg_quanta != 16'd0) &&
                       (cfg_auto_xon != 20'd0) &&
                       (cfg_auto_xon <= cfg_auto_xoff) &&
                       (cfg_auto_xoff <= LEVEL_MAX) &&
                       ((cfg_auto_refresh == 16'd0) ||
                        (cfg_auto_refresh < cfg_quanta));
    wire [15:0] refresh_dflt = (cfg_quanta[15:1] != 15'd0) ?
                               {1'b0, cfg_quanta[15:1]} : 16'd1;
    wire settled = (settle == AUTO_SETTLE[3:0]);

    always @(posedge clk or negedge c_rst_n) begin
        if (!c_rst_n) begin
            auto_en_d    <= 1'b0;
            auto_run     <= 1'b0;
            run_want     <= 1'b0;
            have         <= 1'b0;
            auto_cfg_err <= 1'b0;
            a_xoff       <= 20'd0;
            a_xon        <= 20'd0;
            a_quanta     <= 16'd0;
            a_refresh    <= 16'd0;
            s_xoff       <= 20'd0;
            s_xon        <= 20'd0;
            s_quanta     <= 16'd0;
            s_refresh    <= 16'd0;
            settle       <= AUTO_SETTLE[3:0];
        end else begin
            if (!settled)
                settle <= settle + 4'd1;
            if (!cfg_auto_en) begin
                auto_en_d    <= 1'b0;
                auto_cfg_err <= 1'b0;
                run_want     <= 1'b0;
                have         <= 1'b0;
                if (auto_run) begin
                    auto_run <= 1'b0;
                    settle   <= 4'd0;
                end
            end else if (!auto_en_d) begin
                // the rising edge: the settings are taken and checked now;
                // later writes wait for the next enable
                auto_en_d <= 1'b1;
                if (auto_cfg_ok) begin
                    s_xoff    <= cfg_auto_xoff;
                    s_xon     <= cfg_auto_xon;
                    s_quanta  <= cfg_quanta;
                    s_refresh <= (cfg_auto_refresh != 16'd0) ? cfg_auto_refresh
                                                             : refresh_dflt;
                    have      <= 1'b1;
                end else begin
                    auto_cfg_err <= 1'b1;
                end
            end else if (have && settled) begin
                // applied once auto_run has been low for AUTO_SETTLE, so the
                // applied settings never change within AUTO_SETTLE of it
                a_xoff    <= s_xoff;
                a_xon     <= s_xon;
                a_quanta  <= s_quanta;
                a_refresh <= s_refresh;
                have      <= 1'b0;
                run_want  <= 1'b1;
                settle    <= 4'd0;
            end else if (run_want && settled) begin
                auto_run <= 1'b1;
                run_want <= 1'b0;
            end
        end
    end

    // =========================================================================
    // clk: tx_send request to tx_clk (toggle, quanta held until acknowledged)
    // =========================================================================
    reg        req, busy, wait_v;
    reg [15:0] req_q, wait_q;
    wire       ack;                 // tx_clk: the request was received
    wire       t_pend;              // tx_clk: a received request waits
    (* ASYNC_REG = "TRUE" *) reg ack_s1, ack_s2, pend_s1, pend_s2;
    wire       acked = busy && (ack_s2 == req);

    always @(posedge clk or negedge c_tx_rst_n) begin
        if (!c_tx_rst_n) begin
            ack_s1  <= 1'b0;
            ack_s2  <= 1'b0;
            pend_s1 <= 1'b0;
            pend_s2 <= 1'b0;
            req    <= 1'b0;
            busy   <= 1'b0;
            wait_v <= 1'b0;
            req_q  <= 16'd0;
            wait_q <= 16'd0;
        end else begin
            ack_s1  <= ack;
            ack_s2  <= ack_s1;
            pend_s1 <= t_pend;
            pend_s2 <= pend_s1;
            if (!busy || acked) begin
                // free: send the request at hand, the new one first
                if (cfg_tx_send || wait_v) begin
                    req    <= ~req;
                    req_q  <= cfg_tx_send ? cfg_quanta : wait_q;
                    busy   <= 1'b1;
                    wait_v <= 1'b0;
                end else begin
                    busy <= 1'b0;
                end
            end else if (cfg_tx_send) begin
                wait_v <= 1'b1;
                wait_q <= cfg_quanta;
            end
        end
    end
    // the acknowledge and the tx_clk side's pending flag change in the same
    // tx_clk cycle and cross through equal synchronizers, so tx_pending has
    // no gap between the two
    assign tx_pending = busy || wait_v || pend_s2;

    // =========================================================================
    // rx_clk: PAUSE frame recognition
    // =========================================================================
    // beats 0 and 1: destination, source, EtherType, opcode; beat 2: the
    // pause_time in bytes 16 and 17
    reg [1:0]  r_beat;              // beat of the frame (3 = past the third)
    reg        r_match;
    reg [15:0] r_q;                 // pause_time of the frame being received
    reg [15:0] r_hold;              // pause_time of the last valid PAUSE
    reg        r_tgl;
    wire [15:0] r_q_now = (r_beat == 2'd2) ? {rx_tdata[7:0], rx_tdata[15:8]} : r_q;

    always @(posedge rx_clk or negedge rx_rst_n) begin
        if (!rx_rst_n) begin
            r_beat       <= 2'd0;
            r_match      <= 1'b0;
            r_q          <= 16'd0;
            r_hold       <= 16'd0;
            r_tgl        <= 1'b0;
            rx_pause_evt <= 1'b0;
        end else begin
            rx_pause_evt <= 1'b0;
            if (rx_tvalid) begin
                case (r_beat)
                    2'd0: r_match <= (rx_tdata[47:0] == 48'h01_00_00_C2_80_01);
                    2'd1: r_match <= r_match &&
                                     (rx_tdata[63:32] == 32'h01_00_08_88);
                    default: ;
                endcase
                if (r_beat == 2'd2)
                    r_q <= r_q_now;
                if (r_beat != 2'd3)
                    r_beat <= r_beat + 2'd1;
                if (rx_tlast) begin
                    r_beat  <= 2'd0;
                    r_match <= 1'b0;
                    if (r_match && r_beat[1] && !rx_tuser) begin
                        r_hold       <= r_q_now;
                        r_tgl        <= ~r_tgl;
                        rx_pause_evt <= 1'b1;
                    end
                end
            end
        end
    end

    // =========================================================================
    // rx_clk: automatic PAUSE congestion state, from the RX FIFO level
    // =========================================================================
    (* ASYNC_REG = "TRUE" *) reg [40:0] ra_s1;
    (* ASYNC_REG = "TRUE" *) reg [40:0] ra_s2;
    reg r_active;
    wire        r_run  = ra_s2[40];
    wire [19:0] r_xoff = ra_s2[39:20];
    wire [19:0] r_xon  = ra_s2[19:0];
    wire [19:0] level_b = {{(17-LEVEL_W){1'b0}}, rx_level, 3'b000};  // bytes

    always @(posedge rx_clk or negedge rx_rst_n) begin
        if (!rx_rst_n) begin
            ra_s1    <= 41'd0;
            ra_s2    <= 41'd0;
            r_active <= 1'b0;
        end else begin
            ra_s1 <= {auto_run, a_xoff, a_xon};
            ra_s2 <= ra_s1;
            if (!r_run)
                r_active <= 1'b0;
            else if (level_b >= r_xoff)
                r_active <= 1'b1;
            else if (level_b < r_xon)
                r_active <= 1'b0;
        end
    end

    // =========================================================================
    // tx_clk: settings, the PAUSE toggle and the tx_send request
    // =========================================================================
    (* ASYNC_REG = "TRUE" *) reg [81:0] tc_s1;
    (* ASYNC_REG = "TRUE" *) reg [81:0] tc_s2;
    (* ASYNC_REG = "TRUE" *) reg [2:0]  ts1;   // {req, r_tgl, r_active}
    (* ASYNC_REG = "TRUE" *) reg [2:0]  ts2;
    reg [1:0]  ts3;                            // {req, r_tgl} one cycle on
    reg [1:0]  warm;                           // toggles ignored until 3

    always @(posedge tx_clk or negedge tx_rst_n) begin
        if (!tx_rst_n) begin
            tc_s1 <= 82'd0;
            tc_s2 <= 82'd0;
            ts1   <= 3'd0;
            ts2   <= 3'd0;
            ts3   <= 2'd0;
            warm  <= 2'd0;
        end else begin
            tc_s1 <= {cfg_rx_en, auto_run, a_quanta, a_refresh, our_mac};
            tc_s2 <= tc_s1;
            ts1   <= {req, r_tgl, r_active};
            ts2   <= ts1;
            ts3   <= ts2[2:1];
            if (warm != 2'd3)
                warm <= warm + 2'd1;
        end
    end
    wire        t_rx_en   = tc_s2[81];
    wire        t_run     = tc_s2[80];
    wire [15:0] t_quanta  = tc_s2[79:64];
    wire [15:0] t_refresh = tc_s2[63:48];
    wire [47:0] t_mac     = tc_s2[47:0];
    wire        t_active  = ts2[0] && t_run;
    wire        warmed    = (warm == 2'd3);
    wire        rx_evt    = warmed && (ts2[1] != ts3[0]);
    // the request's two ends always reset together (the TX crossing), so a
    // toggle made before the tx_clk side left reset is still a request
    wire        req_evt   = (ts2[2] != ts3[1]);

    // the pause_time is read two cycles after its toggle arrived
    reg  [1:0] load_d;
    wire       pause_load = load_d[1] && t_rx_en;
    always @(posedge tx_clk or negedge tx_rst_n)
        if (!tx_rst_n) load_d <= 2'b00;
        else           load_d <= {load_d[0], rx_evt};
    wire [15:0] load_q = r_hold;

    // =========================================================================
    // tx_clk: pause timer
    // =========================================================================
    reg  [2:0]  inflight;           // frames started and not yet ended
    reg  [2:0]  hold_n;             // of those, the ones the countdown waits for
    reg  [15:0] remaining;
    reg  [2:0]  qcnt;               // tx_ce within the current quantum
    wire [2:0]  inflight_now = inflight + {2'd0, f_start} - {2'd0, f_end};
    wire        counting = (remaining != 16'd0) && (hold_n == 3'd0);

    always @(posedge tx_clk or negedge tx_rst_n) begin
        if (!tx_rst_n) begin
            inflight  <= 3'd0;
            hold_n    <= 3'd0;
            remaining <= 16'd0;
            qcnt      <= 3'd0;
            tx_paused <= 1'b0;
        end else begin
            inflight <= inflight_now;
            if (pause_load) begin
                remaining <= load_q;
                tx_paused <= (load_q != 16'd0);
                hold_n    <= (load_q != 16'd0) ? inflight_now + {2'd0, f_wait}
                                                   : 3'd0;
                qcnt      <= 3'd0;
            end else begin
                if (f_end && hold_n != 3'd0)
                    hold_n <= hold_n - 3'd1;
                if (counting && tx_ce) begin
                    qcnt <= qcnt + 3'd1;
                    if (qcnt == 3'd7) begin
                        remaining <= remaining - 16'd1;
                        if (remaining == 16'd1)
                            tx_paused <= 1'b0;
                    end
                end
            end
        end
    end

    // =========================================================================
    // tx_clk: automatic PAUSE policy and the PAUSE frame generator
    // =========================================================================
    localparam [1:0] G_IDLE = 2'd0, G_RUN = 2'd1, G_DONE = 2'd2;
    reg  [1:0]  g_st;
    reg  [1:0]  g_idx;              // beat 0..2
    reg  [15:0] g_q;                // quanta of the frame being generated
    reg  [47:0] g_mac;
    reg         g_auto;             // the frame being generated is automatic
    reg         last_auto;
    reg         man_pend;           // a tx_send request is waiting here
    reg  [15:0] man_q;
    reg         ack_r;
    assign ack    = ack_r;
    assign t_pend = man_pend;

    reg         run_d;
    reg         partner_paused;     // the last automatic PAUSE sent was an XOFF
    reg  [2:0]  rq_cnt;             // tx_ce within the refresh quantum
    reg  [15:0] refresh_cnt;        // quanta since the last automatic XOFF
    wire        auto_done   = (g_st == G_DONE) && g_auto;
    wire        refresh_due = (refresh_cnt >= t_refresh);
    wire        xoff_need   = t_active && (!partner_paused || refresh_due);
    wire        xon_need    = partner_paused && !t_active;
    wire        auto_need   = xoff_need || xon_need;
    wire        serve_man   = man_pend && (!auto_need || last_auto);

    always @(posedge tx_clk or negedge tx_rst_n) begin
        if (!tx_rst_n) begin
            run_d          <= 1'b0;
            partner_paused <= 1'b0;
            rq_cnt         <= 3'd0;
            refresh_cnt    <= 16'd0;
        end else begin
            run_d <= t_run;
            if (t_run && !run_d) begin
                // a new configuration: an XOFF already sent carries the old
                // quanta; refresh at once (it only goes out while active)
                refresh_cnt <= 16'hFFFF;
            end else if (auto_done && g_q != 16'd0) begin
                rq_cnt      <= 3'd0;
                refresh_cnt <= (g_q == t_quanta) ? 16'd0 : 16'hFFFF;
            end else if (tx_ce) begin
                rq_cnt <= rq_cnt + 3'd1;
                if (rq_cnt == 3'd7 && refresh_cnt != 16'hFFFF)
                    refresh_cnt <= refresh_cnt + 16'd1;
            end
            if (auto_done)
                partner_paused <= (g_q != 16'd0);
        end
    end

    assign p_tvalid = (g_st == G_RUN);
    assign p_tlast  = (g_st == G_RUN) && (g_idx == 2'd2);
    assign p_tkeep  = (g_idx == 2'd2) ? 8'h03 : 8'hFF;
    always @* begin
        case (g_idx)
            2'd0:    p_tdata = {g_mac[39:32], g_mac[47:40], 48'h01_00_00_C2_80_01};
            2'd1:    p_tdata = {32'h01_00_08_88, g_mac[7:0], g_mac[15:8],
                                g_mac[23:16], g_mac[31:24]};
            default: p_tdata = {48'd0, g_q[7:0], g_q[15:8]};
        endcase
    end

    always @(posedge tx_clk or negedge tx_rst_n) begin
        if (!tx_rst_n) begin
            g_st         <= G_IDLE;
            g_idx        <= 2'd0;
            g_q          <= 16'd0;
            g_mac        <= 48'd0;
            g_auto       <= 1'b0;
            last_auto    <= 1'b0;
            man_pend     <= 1'b0;
            man_q        <= 16'd0;
            ack_r        <= 1'b0;
            tx_pause_evt <= 1'b0;
        end else begin
            tx_pause_evt <= 1'b0;
            if (req_evt) begin
                // the clk side holds req_q from its toggle until this
                // acknowledge; it has been stable for the synchronizer's
                // two cycles. A request still waiting here is replaced.
                man_pend <= 1'b1;
                man_q    <= req_q;
                ack_r    <= ~ack_r;
            end
            case (g_st)
                G_IDLE: begin
                    g_idx <= 2'd0;
                    g_mac <= t_mac;
                    if (serve_man) begin
                        g_q       <= man_q;
                        g_auto    <= 1'b0;
                        last_auto <= 1'b0;
                        man_pend  <= req_evt;   // a request arriving now stays
                        g_st      <= G_RUN;
                    end else if (auto_need) begin
                        g_q       <= xoff_need ? t_quanta : 16'd0;
                        g_auto    <= 1'b1;
                        last_auto <= 1'b1;
                        g_st      <= G_RUN;
                    end
                end
                G_RUN: begin
                    if (p_tready) begin
                        if (g_idx == 2'd2)
                            g_st <= G_DONE;
                        else
                            g_idx <= g_idx + 2'd1;
                    end
                end
                default: begin
                    tx_pause_evt <= 1'b1;
                    g_st         <= G_IDLE;
                end
            endcase
        end
    end

    // =========================================================================
    // Status into clk
    // =========================================================================
    (* ASYNC_REG = "TRUE" *) reg [1:0] st_s1;
    (* ASYNC_REG = "TRUE" *) reg [1:0] st_s2;
    always @(posedge clk or negedge c_rst_n) begin
        if (!c_rst_n) begin
            st_s1 <= 2'b00;
            st_s2 <= 2'b00;
        end else begin
            st_s1 <= {tx_paused, r_active};
            st_s2 <= st_s1;
        end
    end
    assign paused_sts  = st_s2[1];
    assign auto_active = st_s2[0];

endmodule
