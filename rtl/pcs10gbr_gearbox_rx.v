// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// pcs10gbr_gearbox_rx.v - 64-bit transceiver word to 66-bit block gearbox
//
// Runs on the transceiver RX user clock. A 64-bit word (bit 0 first off the
// wire) comes in every cycle; a 66-bit block comes out, with valid, in 32 of
// every 33 cycles. A slip pulse drops one bit from the stream, moving the
// block boundary by one bit; the block-lock machine slips until the sync
// headers line up.
//
// The buffer holds cnt bits (0..65) after each cycle, so at most 129 bits are
// in it while a word is appended.
// Verilog 2001
// =============================================================================

module pcs10gbr_gearbox_rx (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [63:0] din,
    input  wire        slip,
    output reg  [65:0] blk,        // {payload, hdr}
    output reg         valid
);

    reg [129:0] buf_q;
    reg [6:0]   cnt;

    reg [129:0] tmp;
    reg [7:0]   n;
    reg         v;

    always @* begin
        tmp = buf_q | ({66'd0, din} << cnt);
        n   = cnt + 8'd64;
        if (slip) begin
            tmp = tmp >> 1;
            n   = n - 8'd1;
        end
        v = (n >= 8'd66);
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buf_q <= 130'd0;
            cnt   <= 7'd0;
            blk   <= 66'd0;
            valid <= 1'b0;
        end else begin
            valid <= v;
            if (v) begin
                blk   <= tmp[65:0];
                buf_q <= tmp >> 66;
                cnt   <= n[6:0] - 7'd66;   // n - 66 < 64, so mod 128 is exact
            end else begin
                buf_q <= tmp;
                cnt   <= n[6:0];
            end
        end
    end

endmodule
