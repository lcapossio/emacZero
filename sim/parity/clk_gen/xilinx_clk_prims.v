// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// xilinx_clk_prims.v - Parity-only stand-ins for the Xilinx clocking
// primitives MMCME2_BASE and BUFG (7-series).
// Read on the Verilog (golden) side of the clk_gen proof in place of the
// unisim models; xilinx_clk_prims.vhd is the line-for-line VHDL twin read on
// the candidate side. Ports and parameter names match unisim, so both sides
// elaborate the same instances.
//
// NOT the vendor models: no PLL, no clock synthesis, no lock timing, and the
// parameter values are accepted but not modelled. Each stand-in is stateless
// combinational logic in which every connected output depends on the inputs
// clk_gen drives, so the proof checks the connections (which net goes to which
// pin, the tie-offs of PWRDWN and RST, the feedback BUFG and the output BUFG),
// not the primitive and not the parameter values. CLKFBOUT does not depend on
// CLKFBIN, so the feedback path through the BUFG is not a combinational loop.
// Composed inside clk_gen (feedback through the BUFG, PWRDWN = RST = 0) the
// outputs are clk_25 = ~clk_in and locked = clk_in: distinct and non-constant,
// so a swapped, opened or re-tied connection changes an output.
// =============================================================================

module MMCME2_BASE #(
    parameter BANDWIDTH          = "OPTIMIZED",
    parameter CLKFBOUT_MULT_F    = 5.000,
    parameter CLKFBOUT_PHASE     = 0.000,
    parameter CLKIN1_PERIOD      = 0.000,
    parameter CLKOUT0_DIVIDE_F   = 1.000,
    parameter CLKOUT0_DUTY_CYCLE = 0.500,
    parameter CLKOUT0_PHASE      = 0.000,
    parameter CLKOUT1_DIVIDE     = 1,
    parameter CLKOUT1_DUTY_CYCLE = 0.500,
    parameter CLKOUT1_PHASE      = 0.000,
    parameter CLKOUT2_DIVIDE     = 1,
    parameter CLKOUT2_DUTY_CYCLE = 0.500,
    parameter CLKOUT2_PHASE      = 0.000,
    parameter CLKOUT3_DIVIDE     = 1,
    parameter CLKOUT3_DUTY_CYCLE = 0.500,
    parameter CLKOUT3_PHASE      = 0.000,
    parameter CLKOUT4_CASCADE    = "FALSE",
    parameter CLKOUT4_DIVIDE     = 1,
    parameter CLKOUT4_DUTY_CYCLE = 0.500,
    parameter CLKOUT4_PHASE      = 0.000,
    parameter CLKOUT5_DIVIDE     = 1,
    parameter CLKOUT5_DUTY_CYCLE = 0.500,
    parameter CLKOUT5_PHASE      = 0.000,
    parameter CLKOUT6_DIVIDE     = 1,
    parameter CLKOUT6_DUTY_CYCLE = 0.500,
    parameter CLKOUT6_PHASE      = 0.000,
    parameter DIVCLK_DIVIDE      = 1,
    parameter REF_JITTER1        = 0.010,
    parameter STARTUP_WAIT       = "FALSE"
)(
    output wire CLKFBOUT,
    output wire CLKFBOUTB,
    output wire CLKOUT0,
    output wire CLKOUT0B,
    output wire CLKOUT1,
    output wire CLKOUT1B,
    output wire CLKOUT2,
    output wire CLKOUT2B,
    output wire CLKOUT3,
    output wire CLKOUT3B,
    output wire CLKOUT4,
    output wire CLKOUT5,
    output wire CLKOUT6,
    output wire LOCKED,
    input  wire CLKFBIN,
    input  wire CLKIN1,
    input  wire PWRDWN,
    input  wire RST
);
    assign CLKFBOUT  = CLKIN1 ^ RST;
    assign CLKOUT0   = ~(CLKFBIN ^ PWRDWN);
    assign LOCKED    = CLKFBIN ^ PWRDWN ^ RST;
    assign CLKFBOUTB = 1'b0;
    assign CLKOUT0B  = 1'b0;
    assign CLKOUT1   = 1'b0;
    assign CLKOUT1B  = 1'b0;
    assign CLKOUT2   = 1'b0;
    assign CLKOUT2B  = 1'b0;
    assign CLKOUT3   = 1'b0;
    assign CLKOUT3B  = 1'b0;
    assign CLKOUT4   = 1'b0;
    assign CLKOUT5   = 1'b0;
    assign CLKOUT6   = 1'b0;
endmodule

module BUFG (
    output wire O,
    input  wire I
);
    assign O = I;
endmodule
