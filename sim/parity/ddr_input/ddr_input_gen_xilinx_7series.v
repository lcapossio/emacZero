// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// Parity wrapper (golden side only): a pass-through ddr_input whose instance
// is named gen_xilinx_7series, like the VHDL generate that holds the
// XILINX_7SERIES branch. The flattened stub state then has the same
// name on both sides (gen_xilinx_7series.u_iddr.q1p vs GHDL's gen_xilinx_7series_u_iddr.q1p).
module ddr_input_gen_xilinx_7series (
    input  wire clk,
    input  wire d,
    output wire q1,
    output wire q2
);
    ddr_input gen_xilinx_7series (.clk(clk), .d(d), .q1(q1), .q2(q2));
endmodule
