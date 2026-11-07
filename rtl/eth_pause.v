// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// eth_pause.v - 802.3x PAUSE flow control
//
// Two cooperating units:
//
//   * RX: eth_pause_rx (instantiated next to the PHY interface, in the PHY
//                receive clock domain, ahead of the RX FIFO) recognizes PAUSE
//                frames (dst=01:80:C2:00:00:01, EtherType=0x8808,
//                opcode=0x0001) and flips rx_pause_tgl for each valid one:
//                good FCS, no rx_er while rx_dv is high, and at least 64
//                bytes. Here
//                each flip counts, and its 16-bit quanta is loaded into
//                pause_remaining, which decrements at one tick per "pause
//                quantum" of the current line rate. While pause_remaining != 0,
//                tx_paused is asserted to hold data frames that have not yet
//                started on the medium. A quanta of 0 cancels the pause
//                immediately.
//
//   * TX generator: when cfg_pause_tx_send pulses, enqueues a single 60-byte
//                   MAC-Control PAUSE frame on its own AXIS-byte master. The
//                   wrapper sends it on a control path that is not held by
//                   tx_paused and goes out ahead of queued user frames that
//                   have not started. A tx_send that arrives while a frame
//                   is being generated waits in a one-deep slot (a later one
//                   replaces it).
//
//   * Automatic PAUSE: with cfg_auto_en, the RX FIFO occupancy (rx_level)
//                   drives the generator. Crossing XOFF sends a PAUSE with
//                   the quanta latched at enable, repeated every refresh
//                   interval while the level stays at or above XON; falling
//                   below XON (or clearing cfg_auto_en) sends one quanta-0
//                   PAUSE. The thresholds, quanta and refresh are latched when
//                   cfg_auto_en rises; an invalid set raises auto_cfg_err and
//                   leaves the feature off until cfg_auto_en is cleared and set
//                   again. Automatic frames come first, but a waiting tx_send
//                   never waits behind more than one of them.
//
// Pause-quantum tick period, in clk cycles (defaults are for clk = 100 MHz;
// eth_mac_sys derives them from its CLK_FREQ_HZ):
//     1G   : 512 bit-times = 512 ns       =   52 clk cycles (rounded up)
//     100M :                = 5.12 us     =  512 cycles
//     10M  :                = 51.2 us     = 5120 cycles
//
// Verilog 2001
// =============================================================================

module eth_pause #(
    parameter [15:0] TICK_DIV_1G   = 16'd52,
    parameter [15:0] TICK_DIV_100M = 16'd512,
    parameter [15:0] TICK_DIV_10M  = 16'd5120,
    // Automatic PAUSE: width of rx_level (at most 20) and the largest XOFF
    // threshold it can reach (eth_mac_sys passes the RX FIFO's admission
    // watermark, depth - 4).
    parameter        LEVEL_W       = 12,
    parameter [19:0] LEVEL_MAX     = 20'd2044
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- Configuration / control ----
    input  wire [47:0] our_mac,
    input  wire [1:0]  cfg_speed,             // 00=1G, 01=100M, 10=10M
    input  wire        cfg_pause_rx_en,       // honor incoming PAUSE
    input  wire        cfg_pause_tx_send,     // 1-cycle pulse: emit a PAUSE frame
    input  wire [15:0] cfg_pause_tx_quanta,   // quanta value to send

    // ---- Automatic PAUSE from RX FIFO occupancy ----
    input  wire [LEVEL_W-1:0] rx_level,       // RX FIFO occupancy, bytes
    input  wire        cfg_auto_en,           // level: enable (config latched on 0->1)
    input  wire [19:0] cfg_auto_xoff,         // send XOFF at rx_level >= this
    input  wire [19:0] cfg_auto_xon,          // send XON at rx_level < this
    input  wire [15:0] cfg_auto_refresh,      // XOFF repeat interval, quanta (0 = quanta/2)
    output reg         auto_active,           // between XOFF and XON thresholds
    output reg         auto_cfg_err,          // auto_en set with an invalid config
    output wire        tx_pending,            // a tx_send is waiting for the generator

    // ---- From eth_pause_rx, in the PHY receive clock domain (asynchronous) ----
    input  wire        rx_pause_tgl,          // flips once per valid PAUSE frame
    input  wire [15:0] rx_pause_quanta,       // its pause_time; stable between flips

    // ---- TX gate to eth_mac_tx ----
    output wire        tx_paused,             // 1 = block new frame starts

    // ---- AXIS-byte master output (PAUSE frame source) ----
    output reg  [7:0]  pause_tdata,
    output wire        pause_tvalid,
    input  wire        pause_tready,
    output wire        pause_tlast,

    // ---- Status counters (32-bit saturating) ----
    input  wire        stat_clr,              // 1-cycle pulse: clear both counters
    output reg  [31:0] pause_rx_cnt,
    output reg  [31:0] pause_tx_cnt
);

    // ============================================================
    // RX PAUSE events from eth_pause_rx
    // ============================================================
    // Toggle synchronizer into clk. rx_pause_quanta settles at least 46 byte
    // times before its toggle and holds for at least 24 byte times after it
    // (see eth_pause_rx), so it is sampled directly on the cycle the toggle
    // edge is seen here.
    (* ASYNC_REG = "TRUE" *) reg prx_tgl_s1, prx_tgl_s2;
    reg  prx_tgl_s3;
    wire prx_evt = prx_tgl_s2 ^ prx_tgl_s3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prx_tgl_s1 <= 1'b0;
            prx_tgl_s2 <= 1'b0;
            prx_tgl_s3 <= 1'b0;
        end else begin
            prx_tgl_s1 <= rx_pause_tgl;
            prx_tgl_s2 <= prx_tgl_s1;
            prx_tgl_s3 <= prx_tgl_s2;
        end
    end

    wire pause_load = prx_evt && cfg_pause_rx_en;

    // ============================================================
    // Pause-quantum tick prescaler (speed-dependent). It restarts when a
    // PAUSE frame loads the timer, so N quanta always last N full quanta.
    // ============================================================
    reg  [15:0] tick_cnt;
    wire [15:0] tick_div = (cfg_speed == 2'b00) ? TICK_DIV_1G   :
                           (cfg_speed == 2'b01) ? TICK_DIV_100M :
                                                  TICK_DIV_10M;
    reg pause_tick;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_cnt   <= 16'd0;
            pause_tick <= 1'b0;
        end else begin
            if (pause_load) begin
                tick_cnt   <= 16'd0;
                pause_tick <= 1'b0;
            end else if (tick_cnt >= tick_div - 16'd1) begin
                tick_cnt   <= 16'd0;
                pause_tick <= 1'b1;
            end else begin
                tick_cnt   <= tick_cnt + 16'd1;
                pause_tick <= 1'b0;
            end
        end
    end

    // ============================================================
    // Pause timer and PAUSE_RX counter
    // ============================================================
    // tx_paused_r is (pause_remaining != 0), kept in a flop of its own:
    // gmii_cdc and mii_tx_saf synchronize tx_paused into the TX clock domain,
    // so it must not glitch.
    reg [15:0] pause_remaining;
    reg        tx_paused_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pause_remaining <= 16'd0;
            tx_paused_r     <= 1'b0;
            pause_rx_cnt    <= 32'd0;
        end else begin
            if (pause_load) begin
                pause_remaining <= rx_pause_quanta;
                tx_paused_r     <= (rx_pause_quanta != 16'd0);
            end else if (pause_tick && pause_remaining != 16'd0) begin
                pause_remaining <= pause_remaining - 16'd1;
                if (pause_remaining == 16'd1)
                    tx_paused_r <= 1'b0;
            end

            if (stat_clr)
                pause_rx_cnt <= 32'd0;
            else if (prx_evt && pause_rx_cnt != 32'hFFFFFFFF)
                pause_rx_cnt <= pause_rx_cnt + 32'd1;
        end
    end

    assign tx_paused = tx_paused_r;

    // (our_mac is consumed by the TX generator below; tag the snoop input as
    //  used so lint stays clean even when the parser only verifies the dst.)
    /* verilator lint_off UNUSED */
    wire _unused_our_mac = |our_mac;
    /* verilator lint_on UNUSED */

    // ============================================================
    // Automatic PAUSE from RX FIFO occupancy
    // ============================================================
    // The configuration is latched when cfg_auto_en rises, so software can
    // change PAUSE_QUANTA or the thresholds without disturbing a running
    // loop. Valid: quanta != 0, 0 < XON <= XOFF <= LEVEL_MAX, and an explicit
    // refresh shorter than the quanta (or else the partner resumes between
    // repeats).
    reg        auto_en_d;
    reg        auto_run;          // enabled with a valid latched config
    reg [19:0] a_xoff;
    reg [19:0] a_xon;
    reg [15:0] a_quanta;
    reg [15:0] a_refresh;
    reg        partner_paused;    // the last automatic PAUSE sent was an XOFF

    wire [19:0] level = rx_level;
    wire auto_cfg_ok = (cfg_pause_tx_quanta != 16'd0) &&
                       (cfg_auto_xon != 20'd0) &&
                       (cfg_auto_xon <= cfg_auto_xoff) &&
                       (cfg_auto_xoff <= LEVEL_MAX) &&
                       ((cfg_auto_refresh == 16'd0) ||
                        (cfg_auto_refresh < cfg_pause_tx_quanta));
    wire [15:0] auto_refresh_dflt = (cfg_pause_tx_quanta[15:1] != 15'd0) ?
                                    {1'b0, cfg_pause_tx_quanta[15:1]} : 16'd1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            auto_en_d    <= 1'b0;
            auto_run     <= 1'b0;
            auto_cfg_err <= 1'b0;
            a_xoff       <= 20'd0;
            a_xon        <= 20'd0;
            a_quanta     <= 16'd0;
            a_refresh    <= 16'd0;
            auto_active  <= 1'b0;
        end else begin
            auto_en_d <= cfg_auto_en;
            if (!cfg_auto_en) begin
                auto_run     <= 1'b0;
                auto_cfg_err <= 1'b0;
            end else if (!auto_en_d) begin
                if (auto_cfg_ok) begin
                    auto_run  <= 1'b1;
                    a_xoff    <= cfg_auto_xoff;
                    a_xon     <= cfg_auto_xon;
                    a_quanta  <= cfg_pause_tx_quanta;
                    a_refresh <= (cfg_auto_refresh != 16'd0) ? cfg_auto_refresh
                                                             : auto_refresh_dflt;
                end else begin
                    auto_cfg_err <= 1'b1;
                end
            end

            // Congestion state with hysteresis.
            if (!auto_run)
                auto_active <= 1'b0;
            else if (level >= a_xoff)
                auto_active <= 1'b1;
            else if (level < a_xon)
                auto_active <= 1'b0;
        end
    end

    // Refresh timer: quanta since the last automatic XOFF left the generator,
    // on a prescaler of its own (the receive-side one restarts on every
    // received PAUSE, which would stretch the interval).
    reg  [15:0] rtick_cnt;
    reg         rtick;
    reg  [15:0] refresh_cnt;
    wire        refresh_due = (refresh_cnt >= a_refresh);

    // Generator state the requests below depend on (driven further down).
    localparam [1:0]
        TX_IDLE = 2'd0,
        TX_RUN  = 2'd1,
        TX_DONE = 2'd2;

    reg  [1:0]  tx_state;
    reg  [15:0] tx_quanta_lat;
    reg         tx_auto;          // the frame being generated is automatic
    wire        auto_done = (tx_state == TX_DONE) && tx_auto;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rtick_cnt      <= 16'd0;
            rtick          <= 1'b0;
            refresh_cnt    <= 16'd0;
            partner_paused <= 1'b0;
        end else begin
            if (auto_done && tx_quanta_lat != 16'd0) begin
                rtick_cnt   <= 16'd0;
                rtick       <= 1'b0;
                refresh_cnt <= 16'd0;
            end else begin
                if (rtick_cnt >= tick_div - 16'd1) begin
                    rtick_cnt <= 16'd0;
                    rtick     <= 1'b1;
                end else begin
                    rtick_cnt <= rtick_cnt + 16'd1;
                    rtick     <= 1'b0;
                end
                if (rtick && refresh_cnt != 16'hFFFF)
                    refresh_cnt <= refresh_cnt + 16'd1;
            end

            if (auto_done)
                partner_paused <= (tx_quanta_lat != 16'd0);
        end
    end

    // What the automatic side wants sent next, from its state alone: a
    // request that is no longer wanted before it starts simply goes away.
    wire xoff_need = auto_active && (!partner_paused || refresh_due);
    wire xon_need  = partner_paused && !auto_active;
    wire auto_need = xoff_need || xon_need;

    // ============================================================
    // TX generator: emits a 60-byte 802.3x PAUSE frame on AXIS.
    // Frame layout (no preamble/SFD/FCS — those are added by eth_mac_tx):
    //   [0..5]   dst MAC      = 01:80:C2:00:00:01
    //   [6..11]  src MAC      = our_mac (byte 0 = our_mac[47:40])
    //   [12]     ethertype hi = 0x88
    //   [13]     ethertype lo = 0x08
    //   [14]     opcode hi    = 0x00
    //   [15]     opcode lo    = 0x01
    //   [16]     quanta hi    = cfg_pause_tx_quanta[15:8]
    //   [17]     quanta lo    = cfg_pause_tx_quanta[7:0]
    //   [18..59] pad bytes    = 0x00 (ensures min frame size before FCS)
    // ============================================================
    reg [5:0]  tx_idx;        // 0..59
    reg [47:0] tx_src_lat;

    // A tx_send is served at once when the generator is idle, else it waits
    // in man_pend. Automatic frames go first, except that a waiting tx_send
    // goes next after an automatic frame (last_auto).
    reg        man_pend;
    reg [15:0] man_q;
    reg        last_auto;
    wire        man_now   = cfg_pause_tx_send || man_pend;
    wire [15:0] man_now_q = cfg_pause_tx_send ? cfg_pause_tx_quanta : man_q;
    wire        serve_man = man_now && (!auto_need || last_auto);
    wire        start_man = (tx_state == TX_IDLE) && serve_man;

    assign tx_pending = man_pend;

    always @* begin
        // Default: drive the byte for the current tx_idx
        case (tx_idx)
            6'd0:  pause_tdata = 8'h01;
            6'd1:  pause_tdata = 8'h80;
            6'd2:  pause_tdata = 8'hC2;
            6'd3:  pause_tdata = 8'h00;
            6'd4:  pause_tdata = 8'h00;
            6'd5:  pause_tdata = 8'h01;
            6'd6:  pause_tdata = tx_src_lat[47:40];
            6'd7:  pause_tdata = tx_src_lat[39:32];
            6'd8:  pause_tdata = tx_src_lat[31:24];
            6'd9:  pause_tdata = tx_src_lat[23:16];
            6'd10: pause_tdata = tx_src_lat[15:8];
            6'd11: pause_tdata = tx_src_lat[7:0];
            6'd12: pause_tdata = 8'h88;
            6'd13: pause_tdata = 8'h08;
            6'd14: pause_tdata = 8'h00;
            6'd15: pause_tdata = 8'h01;
            6'd16: pause_tdata = tx_quanta_lat[15:8];
            6'd17: pause_tdata = tx_quanta_lat[7:0];
            default: pause_tdata = 8'h00;
        endcase
    end

    // tvalid and tlast follow the state and index directly, like tdata, so
    // the 60th byte carries tlast whether or not tready stalls before it.
    assign pause_tvalid = (tx_state == TX_RUN);
    assign pause_tlast  = (tx_state == TX_RUN) && (tx_idx == 6'd59);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state      <= TX_IDLE;
            tx_idx        <= 6'd0;
            tx_quanta_lat <= 16'd0;
            tx_src_lat    <= 48'd0;
            tx_auto       <= 1'b0;
            last_auto     <= 1'b0;
            man_pend      <= 1'b0;
            man_q         <= 16'd0;
            pause_tx_cnt  <= 32'd0;
        end else begin
            case (tx_state)
                TX_IDLE: begin
                    if (serve_man) begin
                        tx_quanta_lat <= man_now_q;
                        tx_auto       <= 1'b0;
                        last_auto     <= 1'b0;
                        tx_src_lat    <= our_mac;
                        tx_idx        <= 6'd0;
                        tx_state      <= TX_RUN;
                    end else if (auto_need) begin
                        tx_quanta_lat <= xoff_need ? a_quanta : 16'd0;
                        tx_auto       <= 1'b1;
                        last_auto     <= 1'b1;
                        tx_src_lat    <= our_mac;
                        tx_idx        <= 6'd0;
                        tx_state      <= TX_RUN;
                    end
                end

                TX_RUN: begin
                    if (pause_tready) begin
                        if (tx_idx == 6'd59)
                            tx_state <= TX_DONE;
                        else
                            tx_idx <= tx_idx + 6'd1;
                    end
                end

                TX_DONE: begin
                    pause_tx_cnt <= (pause_tx_cnt == 32'hFFFFFFFF)
                                    ? pause_tx_cnt : pause_tx_cnt + 32'd1;
                    tx_state <= TX_IDLE;
                end

                default: tx_state <= TX_IDLE;
            endcase

            if (start_man)
                man_pend <= 1'b0;
            else if (cfg_pause_tx_send) begin
                man_pend <= 1'b1;
                man_q    <= cfg_pause_tx_quanta;
            end

            if (stat_clr)
                pause_tx_cnt <= 32'd0;
        end
    end

endmodule
