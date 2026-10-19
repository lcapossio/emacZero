// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// ddr_standin.v - Parity-only stateless stand-ins for ddr_output / ddr_input.
// Read on the Verilog (golden) side of a proof of a module that instantiates
// DDR cells inside a for-generate (rgmii_if); ddr_standin.vhd is the
// line-for-line VHDL twin on the candidate side. The real cells are proven
// per target on their own (sim/parity/ddr_output, sim/parity/ddr_input).
//
// Why stateless: Yosys names a for-generate instance gen_txd[0].u_txd and GHDL
// names it gen_txd_n1_u_txd, so state inside those cells cannot pair by name
// and starts from independent values on each side. A stand-in without state
// has nothing to pair, and every output depends on every input, so the proof
// still checks each cell's clock and data connections.
// =============================================================================

module ddr_output (
    input  wire clk,
    input  wire d1,
    input  wire d2,
    output wire q
);
    assign q = clk ? d1 : d2;
endmodule

module ddr_input (
    input  wire clk,
    input  wire d,
    output wire q1,
    output wire q2
);
    assign q1 = d;
    assign q2 = d ^ clk;
endmodule
