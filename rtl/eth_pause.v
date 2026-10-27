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
//                good FCS, no rx_er after the SFD, and at least 64 bytes. Here
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
//                   tx_paused and goes out ahead of queued user frames.
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
    parameter [15:0] TICK_DIV_10M  = 16'd5120
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- Configuration / control ----
    input  wire [47:0] our_mac,
    input  wire [1:0]  cfg_speed,             // 00=1G, 01=100M, 10=10M
    input  wire        cfg_pause_rx_en,       // honor incoming PAUSE
    input  wire        cfg_pause_tx_send,     // 1-cycle pulse: emit a PAUSE frame
    input  wire [15:0] cfg_pause_tx_quanta,   // quanta value to send

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
    reg [15:0] pause_remaining;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pause_remaining <= 16'd0;
            pause_rx_cnt    <= 32'd0;
        end else begin
            if (pause_load)
                pause_remaining <= rx_pause_quanta;
            else if (pause_tick && pause_remaining != 16'd0)
                pause_remaining <= pause_remaining - 16'd1;

            if (stat_clr)
                pause_rx_cnt <= 32'd0;
            else if (prx_evt && pause_rx_cnt != 32'hFFFFFFFF)
                pause_rx_cnt <= pause_rx_cnt + 32'd1;
        end
    end

    assign tx_paused = (pause_remaining != 16'd0);

    // (our_mac is consumed by the TX generator below; tag the snoop input as
    //  used so lint stays clean even when the parser only verifies the dst.)
    /* verilator lint_off UNUSED */
    wire _unused_our_mac = |our_mac;
    /* verilator lint_on UNUSED */

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
    reg [15:0] tx_quanta_lat;
    reg [47:0] tx_src_lat;

    localparam [1:0]
        TX_IDLE = 2'd0,
        TX_RUN  = 2'd1,
        TX_DONE = 2'd2;

    reg [1:0] tx_state;

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
            pause_tx_cnt  <= 32'd0;
        end else begin
            case (tx_state)
                TX_IDLE: begin
                    if (cfg_pause_tx_send) begin
                        tx_quanta_lat <= cfg_pause_tx_quanta;
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

            if (stat_clr)
                pause_tx_cnt <= 32'd0;
        end
    end

endmodule
