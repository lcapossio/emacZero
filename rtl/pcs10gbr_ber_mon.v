// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// pcs10gbr_ber_mon.v - 10GBASE-R BER monitor (IEEE 802.3 clause 49.2.13.2.7)
//
// While block lock holds, counts invalid sync headers in windows of
// TIMER_CYCLES clocks (125 us; 20142 cycles at 161.13 MHz). hi_ber rises as
// soon as 16 are seen in one window and falls at the end of a window with
// fewer than 16. ber_cnt counts invalid headers seen since reset, saturating,
// for the status registers.
// Verilog 2001
// =============================================================================

module pcs10gbr_ber_mon #(
    parameter TIMER_CYCLES = 20142
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        valid,
    input  wire [1:0]  hdr,
    input  wire        block_lock,
    output reg         hi_ber,
    output reg  [15:0] ber_cnt
);

    reg [15:0] timer;
    // timer is 16 bits: a longer window would never end and hi_ber would
    // never clear. Unsupported values instantiate a module that does not exist.
    generate
        if ((TIMER_CYCLES < 1) || (TIMER_CYCLES > 65536)) begin : gen_timer_check
            EMACZERO_CONFIG_ERROR_pcs10gbr_ber_mon_timer_cycles_must_be_1_to_65536
                u_timer_cycles_out_of_range ();
        end
    endgenerate
    reg [4:0]  win_cnt;

    wire       bad     = valid && block_lock && !(hdr[0] ^ hdr[1]);
    // count including this cycle, saturating at 16
    wire [4:0] cnt_now = win_cnt + ((bad && win_cnt != 5'd16) ? 5'd1 : 5'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hi_ber  <= 1'b0;
            ber_cnt <= 16'd0;
            timer   <= 16'd0;
            win_cnt <= 5'd0;
        end else begin
            if (bad && ber_cnt != 16'hFFFF)
                ber_cnt <= ber_cnt + 16'd1;
            if (!block_lock) begin
                hi_ber  <= 1'b0;
                timer   <= 16'd0;
                win_cnt <= 5'd0;
            end else begin
                if (cnt_now == 5'd16)
                    hi_ber <= 1'b1;
                if (timer == TIMER_CYCLES - 1) begin
                    timer   <= 16'd0;
                    win_cnt <= 5'd0;
                    if (cnt_now != 5'd16)
                        hi_ber <= 1'b0;
                end else begin
                    timer   <= timer + 16'd1;
                    win_cnt <= cnt_now;
                end
            end
        end
    end

endmodule
