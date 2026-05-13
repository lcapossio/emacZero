// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// eth_pause.v - 802.3x PAUSE flow control
//
// Two cooperating units:
//
//   * RX parser: snoops the GMII RX byte stream looking for PAUSE frames
//                (dst=01:80:C2:00:00:01, EtherType=0x8808, opcode=0x0001).
//                On match, latches the 16-bit quanta value into pause_remaining,
//                which then decrements at one tick per "pause quantum" of the
//                current line rate. While pause_remaining != 0, tx_paused is
//                asserted to gate eth_mac_tx from starting a new frame. A
//                quanta of 0 cancels the pause immediately.
//
//   * TX generator: when cfg_pause_tx_send pulses, enqueues a single 60-byte
//                   MAC-Control PAUSE frame on its own AXIS-byte master. The
//                   wrapper is responsible for priority-muxing this source
//                   into eth_mac_tx ahead of normal user traffic.
//
// Pause-quantum tick period (sys_clk = 100 MHz):
//     1G   : 512 bit-times = 512 ns       =   52 sys_clk cycles (round)
//     100M :                = 5.12 us     =  512 cycles
//     10M  :                = 51.2 us     = 5120 cycles
//
// Verilog 2001
// =============================================================================

module eth_pause #(
    parameter [12:0] TICK_DIV_1G   = 13'd52,
    parameter [12:0] TICK_DIV_100M = 13'd512,
    parameter [12:0] TICK_DIV_10M  = 13'd5120
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- Configuration / control ----
    input  wire [47:0] our_mac,
    input  wire [1:0]  cfg_speed,             // 00=1G, 01=100M, 10=10M
    input  wire        cfg_pause_rx_en,       // honor incoming PAUSE
    input  wire        cfg_pause_tx_send,     // 1-cycle pulse: emit a PAUSE frame
    input  wire [15:0] cfg_pause_tx_quanta,   // quanta value to send

    // ---- Snoop GMII RX ----
    input  wire [7:0]  gmii_rxd,
    input  wire        gmii_rx_dv,

    // ---- TX gate to eth_mac_tx ----
    output wire        tx_paused,             // 1 = block new frame starts

    // ---- AXIS-byte master output (PAUSE frame source) ----
    output reg  [7:0]  pause_tdata,
    output reg         pause_tvalid,
    input  wire        pause_tready,
    output reg         pause_tlast,

    // ---- Status counters (32-bit saturating) ----
    output reg  [31:0] pause_rx_cnt,
    output reg  [31:0] pause_tx_cnt
);

    // ============================================================
    // Pause-quantum tick prescaler (speed-dependent)
    // ============================================================
    reg  [12:0] tick_cnt;
    wire [12:0] tick_div = (cfg_speed == 2'b00) ? TICK_DIV_1G   :
                           (cfg_speed == 2'b01) ? TICK_DIV_100M :
                                                  TICK_DIV_10M;
    reg pause_tick;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_cnt   <= 13'd0;
            pause_tick <= 1'b0;
        end else begin
            if (tick_cnt >= tick_div - 13'd1) begin
                tick_cnt   <= 13'd0;
                pause_tick <= 1'b1;
            end else begin
                tick_cnt   <= tick_cnt + 13'd1;
                pause_tick <= 1'b0;
            end
        end
    end

    // ============================================================
    // RX parser FSM
    // Looks for 802.3x PAUSE frame after preamble/SFD (handled upstream by the
    // PHY interface so gmii_rx_dv first goes high on byte 0 of dst-MAC).
    // ============================================================
    localparam [3:0]
        RX_IDLE     = 4'd0,
        RX_DST      = 4'd1,
        RX_SRC      = 4'd2,
        RX_TYPE_HI  = 4'd3,
        RX_TYPE_LO  = 4'd4,
        RX_OP_HI    = 4'd5,
        RX_OP_LO    = 4'd6,
        RX_QUANTA_HI= 4'd7,
        RX_QUANTA_LO= 4'd8,
        RX_LATCH    = 4'd9,
        RX_DRAIN    = 4'd10;

    reg [3:0]  rx_state;
    reg [2:0]  rx_idx;       // 0..5 within DST/SRC fields
    reg [15:0] rx_quanta;
    reg [15:0] pause_remaining;

    // Constant: 802.3x reserved multicast address for MAC Control frames.
    // Wire-byte order: 01 80 C2 00 00 01.
    function automatic dst_byte_match;
        input [2:0] idx;
        input [7:0] b;
        begin
            case (idx)
                3'd0: dst_byte_match = (b == 8'h01);
                3'd1: dst_byte_match = (b == 8'h80);
                3'd2: dst_byte_match = (b == 8'hC2);
                3'd3: dst_byte_match = (b == 8'h00);
                3'd4: dst_byte_match = (b == 8'h00);
                3'd5: dst_byte_match = (b == 8'h01);
                default: dst_byte_match = 1'b0;
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_state         <= RX_IDLE;
            rx_idx           <= 3'd0;
            rx_quanta        <= 16'd0;
            pause_remaining  <= 16'd0;
            pause_rx_cnt     <= 32'd0;
        end else begin
            // Pause counter decrements on each tick (clamped at 0).
            if (pause_tick && pause_remaining != 16'd0)
                pause_remaining <= pause_remaining - 16'd1;

            if (gmii_rx_dv) begin
                case (rx_state)
                    RX_IDLE: begin
                        rx_idx <= 3'd1;
                        if (dst_byte_match(3'd0, gmii_rxd))
                            rx_state <= RX_DST;
                        else
                            rx_state <= RX_DRAIN;
                    end

                    RX_DST: begin
                        if (!dst_byte_match(rx_idx, gmii_rxd)) begin
                            rx_state <= RX_DRAIN;
                        end else if (rx_idx == 3'd5) begin
                            rx_state <= RX_SRC;
                            rx_idx   <= 3'd0;
                        end else begin
                            rx_idx <= rx_idx + 3'd1;
                        end
                    end

                    RX_SRC: begin
                        // Skip 6 source-MAC bytes
                        if (rx_idx == 3'd5) begin
                            rx_state <= RX_TYPE_HI;
                            rx_idx   <= 3'd0;
                        end else begin
                            rx_idx <= rx_idx + 3'd1;
                        end
                    end

                    RX_TYPE_HI: rx_state <= (gmii_rxd == 8'h88) ? RX_TYPE_LO : RX_DRAIN;
                    RX_TYPE_LO: rx_state <= (gmii_rxd == 8'h08) ? RX_OP_HI   : RX_DRAIN;
                    RX_OP_HI:   rx_state <= (gmii_rxd == 8'h00) ? RX_OP_LO   : RX_DRAIN;
                    RX_OP_LO:   rx_state <= (gmii_rxd == 8'h01) ? RX_QUANTA_HI : RX_DRAIN;

                    RX_QUANTA_HI: begin
                        rx_quanta[15:8] <= gmii_rxd;
                        rx_state <= RX_QUANTA_LO;
                    end
                    RX_QUANTA_LO: begin
                        rx_quanta[7:0] <= gmii_rxd;
                        rx_state <= RX_LATCH;
                    end

                    RX_LATCH, RX_DRAIN: ;  // wait for end of frame
                    default:    rx_state <= RX_IDLE;
                endcase
            end else if (rx_state != RX_IDLE) begin
                // gmii_rx_dv low: end of frame.  Commit if PAUSE was matched.
                if (rx_state == RX_LATCH) begin
                    pause_rx_cnt <= (pause_rx_cnt == 32'hFFFFFFFF)
                                    ? pause_rx_cnt : pause_rx_cnt + 32'd1;
                    if (cfg_pause_rx_en)
                        pause_remaining <= rx_quanta;
                end
                rx_state <= RX_IDLE;
                rx_idx   <= 3'd0;
            end
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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state      <= TX_IDLE;
            tx_idx        <= 6'd0;
            tx_quanta_lat <= 16'd0;
            tx_src_lat    <= 48'd0;
            pause_tvalid  <= 1'b0;
            pause_tlast   <= 1'b0;
            pause_tx_cnt  <= 32'd0;
        end else begin
            case (tx_state)
                TX_IDLE: begin
                    pause_tvalid <= 1'b0;
                    pause_tlast  <= 1'b0;
                    if (cfg_pause_tx_send) begin
                        tx_quanta_lat <= cfg_pause_tx_quanta;
                        tx_src_lat    <= our_mac;
                        tx_idx        <= 6'd0;
                        tx_state      <= TX_RUN;
                        pause_tvalid  <= 1'b1;
                        pause_tlast   <= 1'b0;
                    end
                end

                TX_RUN: begin
                    pause_tvalid <= 1'b1;
                    pause_tlast  <= (tx_idx == 6'd59);
                    if (pause_tready) begin
                        if (tx_idx == 6'd59) begin
                            tx_state     <= TX_DONE;
                            pause_tvalid <= 1'b0;
                            pause_tlast  <= 1'b0;
                        end else begin
                            tx_idx <= tx_idx + 6'd1;
                        end
                    end
                end

                TX_DONE: begin
                    pause_tx_cnt <= (pause_tx_cnt == 32'hFFFFFFFF)
                                    ? pause_tx_cnt : pause_tx_cnt + 32'd1;
                    tx_state <= TX_IDLE;
                end

                default: tx_state <= TX_IDLE;
            endcase
        end
    end

endmodule
