// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// crc32_d64.v - Ethernet CRC-32 over up to eight bytes per step
//
// Combinational. crc_out is crc_in advanced over data[8*i +: 8] for
// i = 0 .. nbytes-1, byte 0 first, with the same convention as the byte-wide
// TX MAC: reflected polynomial 0xEDB88320, the register starts at all ones,
// the FCS is ~crc sent least significant byte first (zlib.crc32). nbytes = 0
// passes crc_in through; values above 8 count as 8.
//
// Written as eight byte steps; synthesis flattens each output bit into one
// XOR of the inputs it depends on, so every length is a parallel transform
// and the eight lengths share logic.
// Verilog 2001
// =============================================================================

module crc32_d64 (
    input  wire [31:0] crc_in,
    input  wire [63:0] data,
    input  wire [3:0]  nbytes,
    output reg  [31:0] crc_out
);

    function [31:0] crc_step_byte;
        input [31:0] crc;
        input [7:0]  d;
        integer      b;
        reg   [31:0] c;
        begin
            c = crc ^ {24'd0, d};
            for (b = 0; b < 8; b = b + 1)
                c = c[0] ? ({1'b0, c[31:1]} ^ 32'hEDB88320) : {1'b0, c[31:1]};
            crc_step_byte = c;
        end
    endfunction

    integer      i;
    reg   [31:0] c;
    always @(*) begin
        c       = crc_in;
        crc_out = crc_in;
        for (i = 0; i < 8; i = i + 1) begin
            c = crc_step_byte(c, data[8*i +: 8]);
            if (nbytes > i) crc_out = c;
        end
    end

endmodule
