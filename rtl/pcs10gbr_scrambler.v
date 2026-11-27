// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// pcs10gbr_scrambler.v - 10GBASE-R self-synchronizing scrambler and descrambler
//
// IEEE 802.3 clause 49.2.6: G(x) = 1 + x^39 + x^58, applied to the 64 payload
// bits of each 66-bit block (the 2-bit sync header is not scrambled). Bit 0 of
// the payload is the first bit on the wire.
//
//   DESCRAMBLE = 0 (TX): out[i] = in[i] ^ out[i-39] ^ out[i-58]
//   DESCRAMBLE = 1 (RX): out[i] = in[i] ^ in[i-39]  ^ in[i-58]
//
// The state is the last 58 bits of the scrambled stream (out for TX, in for
// RX), st[57] the most recent. One 64-bit block is processed per cycle in
// which en is high; the result is registered.
// Verilog 2001
// =============================================================================

module pcs10gbr_scrambler #(
    parameter DESCRAMBLE = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,
    input  wire [63:0] din,
    output reg  [63:0] dout
);

    reg  [57:0] st;
    reg  [63:0] res;
    reg  [57:0] st_n;

    // e[j] = st[j] for j < 58, else the scrambled-stream bit j-58 of this block
    integer i;
    reg [121:0] e;
    always @* begin
        e = {64'd0, st};
        for (i = 0; i < 64; i = i + 1) begin
            res[i] = din[i] ^ e[i] ^ e[i + 19];
            if (DESCRAMBLE != 0)
                e[58 + i] = din[i];
            else
                e[58 + i] = res[i];
        end
        st_n = e[121:64];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st   <= {58{1'b1}};
            dout <= 64'd0;
        end else if (en) begin
            st   <= st_n;
            dout <= res;
        end
    end

endmodule
