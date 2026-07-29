`timescale 1ns/1ps
// Trivial DFF - toolchain smoke DUT for the cocotb flow (Icarus VPI on Windows).
module dff (
    input  wire clk,
    input  wire rst_n,
    input  wire d,
    output reg  q
);
    always @(posedge clk or negedge rst_n)
        if (!rst_n) q <= 1'b0;
        else        q <= d;
endmodule
