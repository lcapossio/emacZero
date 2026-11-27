// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// pcs10gbr_gearbox_tx.v - 66-bit block to 64-bit transceiver word gearbox
//
// Runs on the transceiver TX user clock (line rate / 64, 161.13 MHz at
// 10.3125 Gb/s). A 64-bit word goes out every cycle (bit 0 first on the
// wire); a 66-bit block (bit 0 = sync header bit 0) is taken in 32 of every
// 33 cycles. ready is high in the cycles that take a block, and the encode
// pipeline advances only then.
//
// The buffer holds cnt bits (an even number, 0..64). With fewer than 64 bits
// held a block is appended; 64 bits leave every cycle.
// Verilog 2001
// =============================================================================

module pcs10gbr_gearbox_tx (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [65:0] blk,        // {payload, hdr}
    output wire        ready,      // blk is taken this cycle
    output reg  [63:0] dout
);

    reg [129:0] buf_q;
    reg [6:0]   cnt;               // bits held, 0..64

    assign ready = (cnt < 7'd64);

    reg [129:0] tmp;
    reg [7:0]   n;

    always @* begin
        tmp = buf_q;
        n   = {1'b0, cnt};
        if (ready) begin
            tmp = buf_q | ({64'd0, blk} << cnt);
            n   = cnt + 8'd66;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buf_q <= 130'd0;
            cnt   <= 7'd0;
            dout  <= 64'd0;
        end else begin
            dout  <= tmp[63:0];
            buf_q <= tmp >> 64;
            cnt   <= n[6:0] - 7'd64;     // n - 64 < 128, so mod 128 is exact
        end
    end

endmodule
