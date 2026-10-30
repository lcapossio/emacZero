// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// xilinx_io_standin.v - Parity-only stand-ins for IOBUF, IDELAYE2 and
// IDELAYCTRL (Verilog side; xilinx_io_standin.vhd is the VHDL twin). Read
// identically by both sides of the rgmii_lb_selftest proof in place of unisim.
//
// IDELAYE2 keeps a register `st` clocked by C, and IDELAYCTRL one clocked by
// REFCLK (no reset, no initial value, so each pairs by name and starts free).
// The next value is `st` rotated by one XOR {inputs, fingerprint}: every
// input pin sits above a fingerprint of every parameter at full width, so a
// pin can never cancel a parameter. In the fingerprint: each integer in its
// own 32-bit field, REFCLK_FREQUENCY as round(value * 1000) in 32 bits, each
// IS_*_INVERTED bit as itself, and each string parameter as one bit per legal
// value. Distinct legal values give distinct fingerprints, with two limits:
// the real is compared only to 0.001, and an illegal string sets no bit.
// Every output is its own bit of `st`. Nothing about real IDELAY behaviour is
// modelled: DATAOUT is not IDATAIN delayed, only a register that IDATAIN and
// every other input feed.
//
// IOBUF is a plain tri-state buffer, as on silicon (O reads the pad). The
// proof's L2 runs on a split model with no IOBUF (translateHDL does not model
// inout ports; see sim/parity/rgmii_lb_selftest/gen_split.py); L0, L1 and L4
// read this one.
// Keep the two files in step by hand.
// =============================================================================

module IOBUF (
    output wire O,
    inout  wire IO,
    input  wire I,
    input  wire T
);
    assign IO = T ? 1'bz : I;
    assign O  = IO;
endmodule

module IDELAYE2 #(
    parameter       CINVCTRL_SEL          = "FALSE",
    parameter       DELAY_SRC             = "IDATAIN",
    parameter       HIGH_PERFORMANCE_MODE = "FALSE",
    parameter       IDELAY_TYPE           = "FIXED",
    parameter       IDELAY_VALUE          = 0,
    parameter [0:0] IS_C_INVERTED         = 1'b0,
    parameter [0:0] IS_DATAIN_INVERTED    = 1'b0,
    parameter [0:0] IS_IDATAIN_INVERTED   = 1'b0,
    parameter       PIPE_SEL              = "FALSE",
    parameter       REFCLK_FREQUENCY      = 200.0,
    parameter       SIGNAL_PATTERN        = "DATA",
    parameter       SIM_DELAY_D           = 0
)(
    output wire [4:0] CNTVALUEOUT,
    output wire       DATAOUT,
    input  wire       C,
    input  wire       CE,
    input  wire       CINVCTRL,
    input  wire [4:0] CNTVALUEIN,
    input  wire       DATAIN,
    input  wire       IDATAIN,
    input  wire       INC,
    input  wire       LD,
    input  wire       LDPIPEEN,
    input  wire       REGRST
);
    localparam [1:0]   F_CINVCTRL_SEL = {CINVCTRL_SEL == "TRUE", CINVCTRL_SEL == "FALSE"};
    localparam [1:0]   F_DELAY_SRC    = {DELAY_SRC == "DATAIN", DELAY_SRC == "IDATAIN"};
    localparam [1:0]   F_HPM          = {HIGH_PERFORMANCE_MODE == "TRUE",
                                         HIGH_PERFORMANCE_MODE == "FALSE"};
    localparam [3:0]   F_IDELAY_TYPE  = {IDELAY_TYPE == "VAR_LOAD_PIPE", IDELAY_TYPE == "VAR_LOAD",
                                         IDELAY_TYPE == "VARIABLE", IDELAY_TYPE == "FIXED"};
    localparam [31:0]  F_IDELAY_VALUE = IDELAY_VALUE;
    localparam [2:0]   F_IS_INV       = {IS_IDATAIN_INVERTED, IS_DATAIN_INVERTED, IS_C_INVERTED};
    localparam [1:0]   F_PIPE_SEL     = {PIPE_SEL == "TRUE", PIPE_SEL == "FALSE"};
    localparam integer I_REFCLK       = REFCLK_FREQUENCY * 1000.0;
    localparam [31:0]  F_REFCLK       = I_REFCLK;
    localparam [1:0]   F_SIGNAL       = {SIGNAL_PATTERN == "CLOCK", SIGNAL_PATTERN == "DATA"};
    localparam [31:0]  F_SIM_DELAY_D  = SIM_DELAY_D;
    localparam [112:0] GEN_FP = {F_SIM_DELAY_D, F_SIGNAL, F_REFCLK, F_PIPE_SEL, F_IS_INV,
                                 F_IDELAY_VALUE, F_IDELAY_TYPE, F_HPM, F_DELAY_SRC,
                                 F_CINVCTRL_SEL};

    reg  [125:0] st;
    always @(posedge C)
        st <= {st[124:0], st[125]} ^ {REGRST, LDPIPEEN, LD, INC, IDATAIN, DATAIN,
                                      CNTVALUEIN, CINVCTRL, CE, GEN_FP};

    assign DATAOUT     = st[0];
    assign CNTVALUEOUT = st[5:1];
endmodule

module IDELAYCTRL #(
    parameter SIM_DEVICE = "7SERIES"
)(
    output wire RDY,
    input  wire REFCLK,
    input  wire RST
);
    localparam [1:0] GEN_FP = {SIM_DEVICE == "ULTRASCALE", SIM_DEVICE == "7SERIES"};

    reg  [2:0] st;
    always @(posedge REFCLK)
        st <= {st[1:0], st[2]} ^ {RST, GEN_FP};

    assign RDY = st[0];
endmodule
