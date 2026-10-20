// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// xilinx_clk_prims_standin.v - Parity-only stand-ins for the Xilinx clocking
// primitives MMCME2_BASE and BUFG (7-series unisim), as used by
// fpga/arty_a7/rtl/gmii_lb_selftest.v. Read on the Verilog (golden) side;
// xilinx_clk_prims_standin.vhd is the line-for-line VHDL twin on the
// candidate side, where the local component declarations bind to it.
//
// Not a model of the MMCM. What the proof needs is that each output depends on
// the inputs and parameters it is wired to, so a wrong connection or a wrong
// generic value diverges:
//   - CLKOUT0 = CLKIN1 & CLKFBIN: the 125 MHz clock follows the input clock
//     (frequency is not modelled), and only when the feedback loop through
//     BUFG is closed;
//   - CLKFBOUT = CLKIN1;
//   - LOCKED is bit 0 of the register lk (clocked by CLKIN1, async reset by
//     RST), which rotates and XORs in PWRDWN and a fingerprint of the four
//     parameters gmii_lb_selftest sets. lk is paired by name (u_mmcm.lk), and
//     in the induction step LOCKED takes either value at any time.
// Parameters are the unisim names and types; the fingerprint takes each real
// in units of 1/8 (the MMCM's 0.125 step).
// =============================================================================

module MMCME2_BASE #(
    parameter real    CLKFBOUT_MULT_F  = 5.000,
    parameter real    CLKIN1_PERIOD    = 0.000,
    parameter real    CLKOUT0_DIVIDE_F = 1.000,
    parameter integer DIVCLK_DIVIDE    = 1
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

    localparam integer FP_FB  = CLKFBOUT_MULT_F * 8.0;
    localparam integer FP_IN  = CLKIN1_PERIOD * 8.0;
    localparam integer FP_O0  = CLKOUT0_DIVIDE_F * 8.0;
    localparam [7:0]   FP_FB8 = FP_FB;
    localparam [7:0]   FP_IN8 = FP_IN;
    localparam [7:0]   FP_O08 = FP_O0;
    localparam [7:0]   FP_DV8 = DIVCLK_DIVIDE;
    localparam [31:0]  GEN_FP = {FP_DV8, FP_O08, FP_IN8, FP_FB8};

    reg [31:0] lk;
    always @(posedge CLKIN1 or posedge RST) begin
        if (RST) lk <= 32'd0;
        else     lk <= {lk[30:0], lk[31]} ^ GEN_FP ^ {31'd0, PWRDWN};
    end

    assign CLKFBOUT  = CLKIN1;
    assign CLKFBOUTB = 1'b0;
    assign CLKOUT0   = CLKIN1 & CLKFBIN;
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
    assign LOCKED    = lk[0];

endmodule

module BUFG (
    output wire O,
    input  wire I
);
    assign O = I;
endmodule
