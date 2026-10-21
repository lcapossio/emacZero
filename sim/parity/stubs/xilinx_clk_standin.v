// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// xilinx_clk_standin.v - Parity-only stand-ins for MMCME2_BASE and BUFG (Verilog
// side; xilinx_clk_standin.vhd is the VHDL twin). Read identically by both
// sides of the clk_gen and gmii_lb_selftest proofs in place of unisim.
//
// MMCME2_BASE keeps a register `st` clocked by CLKIN1 (no reset, no initial
// value, so it pairs by name and starts free) whose next value is `st`
// rotated by one XOR {PWRDWN, RST, fingerprint}: the two pins sit above a
// fingerprint of every parameter at full width, so a pin can never cancel a
// parameter. In the fingerprint: each real parameter as round(value * 1000)
// in its own 32-bit field, each integer in its own 32-bit field, BANDWIDTH and
// the two booleans as one bit per value. Distinct legal values give distinct
// fingerprints, with two limits: reals are compared only to 0.001 (two values
// that round to the same thousandth share a field), and an illegal string sets
// no bit. A wrong value on either side diverges (`st` is a paired state
// point). Every output is its own bit of `st`; CLKOUT0 also XORs
// CLKFBIN, so the feedback connection is checked. The output clocks are
// therefore state, not the input clock: a process clocked from CLKOUT0 has
// different edges from one clocked from CLKIN1, and moving logic between the
// two domains diverges. Nothing about real MMCM behaviour is modelled.
// BUFG is a wire, as on silicon.
// Generated once by a script; keep the two files in step by hand.
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
    localparam [2:0]   F_BANDWIDTH = {BANDWIDTH == "HIGH", BANDWIDTH == "LOW", BANDWIDTH == "OPTIMIZED"};
    localparam integer I_CLKFBOUT_MULT_F = CLKFBOUT_MULT_F * 1000.0;
    localparam [31:0]  F_CLKFBOUT_MULT_F = I_CLKFBOUT_MULT_F;
    localparam integer I_CLKFBOUT_PHASE = CLKFBOUT_PHASE * 1000.0;
    localparam [31:0]  F_CLKFBOUT_PHASE = I_CLKFBOUT_PHASE;
    localparam integer I_CLKIN1_PERIOD = CLKIN1_PERIOD * 1000.0;
    localparam [31:0]  F_CLKIN1_PERIOD = I_CLKIN1_PERIOD;
    localparam integer I_CLKOUT0_DIVIDE_F = CLKOUT0_DIVIDE_F * 1000.0;
    localparam [31:0]  F_CLKOUT0_DIVIDE_F = I_CLKOUT0_DIVIDE_F;
    localparam integer I_CLKOUT0_DUTY_CYCLE = CLKOUT0_DUTY_CYCLE * 1000.0;
    localparam [31:0]  F_CLKOUT0_DUTY_CYCLE = I_CLKOUT0_DUTY_CYCLE;
    localparam integer I_CLKOUT0_PHASE = CLKOUT0_PHASE * 1000.0;
    localparam [31:0]  F_CLKOUT0_PHASE = I_CLKOUT0_PHASE;
    localparam [31:0]  F_CLKOUT1_DIVIDE = CLKOUT1_DIVIDE;
    localparam integer I_CLKOUT1_DUTY_CYCLE = CLKOUT1_DUTY_CYCLE * 1000.0;
    localparam [31:0]  F_CLKOUT1_DUTY_CYCLE = I_CLKOUT1_DUTY_CYCLE;
    localparam integer I_CLKOUT1_PHASE = CLKOUT1_PHASE * 1000.0;
    localparam [31:0]  F_CLKOUT1_PHASE = I_CLKOUT1_PHASE;
    localparam [31:0]  F_CLKOUT2_DIVIDE = CLKOUT2_DIVIDE;
    localparam integer I_CLKOUT2_DUTY_CYCLE = CLKOUT2_DUTY_CYCLE * 1000.0;
    localparam [31:0]  F_CLKOUT2_DUTY_CYCLE = I_CLKOUT2_DUTY_CYCLE;
    localparam integer I_CLKOUT2_PHASE = CLKOUT2_PHASE * 1000.0;
    localparam [31:0]  F_CLKOUT2_PHASE = I_CLKOUT2_PHASE;
    localparam [31:0]  F_CLKOUT3_DIVIDE = CLKOUT3_DIVIDE;
    localparam integer I_CLKOUT3_DUTY_CYCLE = CLKOUT3_DUTY_CYCLE * 1000.0;
    localparam [31:0]  F_CLKOUT3_DUTY_CYCLE = I_CLKOUT3_DUTY_CYCLE;
    localparam integer I_CLKOUT3_PHASE = CLKOUT3_PHASE * 1000.0;
    localparam [31:0]  F_CLKOUT3_PHASE = I_CLKOUT3_PHASE;
    localparam [0:0]   F_CLKOUT4_CASCADE = (CLKOUT4_CASCADE == "TRUE");
    localparam [31:0]  F_CLKOUT4_DIVIDE = CLKOUT4_DIVIDE;
    localparam integer I_CLKOUT4_DUTY_CYCLE = CLKOUT4_DUTY_CYCLE * 1000.0;
    localparam [31:0]  F_CLKOUT4_DUTY_CYCLE = I_CLKOUT4_DUTY_CYCLE;
    localparam integer I_CLKOUT4_PHASE = CLKOUT4_PHASE * 1000.0;
    localparam [31:0]  F_CLKOUT4_PHASE = I_CLKOUT4_PHASE;
    localparam [31:0]  F_CLKOUT5_DIVIDE = CLKOUT5_DIVIDE;
    localparam integer I_CLKOUT5_DUTY_CYCLE = CLKOUT5_DUTY_CYCLE * 1000.0;
    localparam [31:0]  F_CLKOUT5_DUTY_CYCLE = I_CLKOUT5_DUTY_CYCLE;
    localparam integer I_CLKOUT5_PHASE = CLKOUT5_PHASE * 1000.0;
    localparam [31:0]  F_CLKOUT5_PHASE = I_CLKOUT5_PHASE;
    localparam [31:0]  F_CLKOUT6_DIVIDE = CLKOUT6_DIVIDE;
    localparam integer I_CLKOUT6_DUTY_CYCLE = CLKOUT6_DUTY_CYCLE * 1000.0;
    localparam [31:0]  F_CLKOUT6_DUTY_CYCLE = I_CLKOUT6_DUTY_CYCLE;
    localparam integer I_CLKOUT6_PHASE = CLKOUT6_PHASE * 1000.0;
    localparam [31:0]  F_CLKOUT6_PHASE = I_CLKOUT6_PHASE;
    localparam [31:0]  F_DIVCLK_DIVIDE = DIVCLK_DIVIDE;
    localparam integer I_REF_JITTER1 = REF_JITTER1 * 1000.0;
    localparam [31:0]  F_REF_JITTER1 = I_REF_JITTER1;
    localparam [0:0]   F_STARTUP_WAIT = (STARTUP_WAIT == "TRUE");
    localparam [836:0] GEN_FP = {F_STARTUP_WAIT, F_REF_JITTER1, F_DIVCLK_DIVIDE, F_CLKOUT6_PHASE, F_CLKOUT6_DUTY_CYCLE, F_CLKOUT6_DIVIDE, F_CLKOUT5_PHASE, F_CLKOUT5_DUTY_CYCLE, F_CLKOUT5_DIVIDE, F_CLKOUT4_PHASE, F_CLKOUT4_DUTY_CYCLE, F_CLKOUT4_DIVIDE, F_CLKOUT4_CASCADE, F_CLKOUT3_PHASE, F_CLKOUT3_DUTY_CYCLE, F_CLKOUT3_DIVIDE, F_CLKOUT2_PHASE, F_CLKOUT2_DUTY_CYCLE, F_CLKOUT2_DIVIDE, F_CLKOUT1_PHASE, F_CLKOUT1_DUTY_CYCLE, F_CLKOUT1_DIVIDE, F_CLKOUT0_PHASE, F_CLKOUT0_DUTY_CYCLE, F_CLKOUT0_DIVIDE_F, F_CLKIN1_PERIOD, F_CLKFBOUT_PHASE, F_CLKFBOUT_MULT_F, F_BANDWIDTH};

    reg  [838:0] st;
    always @(posedge CLKIN1)
        st <= {st[837:0], st[838]} ^ {PWRDWN, RST, GEN_FP};

    assign CLKFBOUT  = st[0];
    assign CLKFBOUTB = st[1];
    assign CLKOUT0   = st[2] ^ CLKFBIN;
    assign CLKOUT0B  = st[3];
    assign CLKOUT1   = st[4];
    assign CLKOUT1B  = st[5];
    assign CLKOUT2   = st[6];
    assign CLKOUT2B  = st[7];
    assign CLKOUT3   = st[8];
    assign CLKOUT3B  = st[9];
    assign CLKOUT4   = st[10];
    assign CLKOUT5   = st[11];
    assign CLKOUT6   = st[12];
    assign LOCKED    = st[13];
endmodule

module BUFG (
    output wire O,
    input  wire I
);
    assign O = I;
endmodule
