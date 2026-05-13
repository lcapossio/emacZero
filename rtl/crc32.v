// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio � bard0 design
// =============================================================================
// crc32.v — Ethernet CRC-32 (IEEE 802.3), byte-at-a-time
// Polynomial: 0x04C11DB7 (reflected: 0xEDB88320)
// Verilog 2001
// =============================================================================

module crc32 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  data_in,
    input  wire        data_valid,
    input  wire        crc_init,    // pulse to reset CRC to 0xFFFFFFFF
    output wire [31:0] crc_out,     // current CRC (bit-reversed, inverted)
    output wire [31:0] crc_raw      // raw CRC register value
);

    reg [31:0] crc_reg;
    wire [31:0] crc_next;

    // Byte-at-a-time CRC calculation (LSB-first / reflected)
    // Processes one byte per clock, XORing bit-by-bit through the polynomial
    function [31:0] crc_step;
        input [31:0] crc_in;
        input [7:0]  data;
        integer i;
        reg [31:0] c;
        begin
            c = crc_in ^ {24'd0, data};
            for (i = 0; i < 8; i = i + 1) begin
                if (c[0])
                    c = {1'b0, c[31:1]} ^ 32'hEDB88320;
                else
                    c = {1'b0, c[31:1]};
            end
            crc_step = c;
        end
    endfunction

    assign crc_next = crc_step(crc_reg, data_in);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            crc_reg <= 32'hFFFFFFFF;
        else if (crc_init)
            crc_reg <= 32'hFFFFFFFF;
        else if (data_valid)
            crc_reg <= crc_next;
    end

    // Final CRC: invert (complement) the register
    // Bit order: transmitted LSB-first, so we bit-reverse each byte
    assign crc_raw = crc_reg;
    assign crc_out = ~crc_reg;

endmodule
