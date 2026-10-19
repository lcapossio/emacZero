// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// Parity wrapper (golden side only): a pass-through ddr_output whose instance
// is named gen_xilinx_7series, like the VHDL generate that holds the
// XILINX_7SERIES branch. The flattened stub state then has the same
// name on both sides (gen_xilinx_7series.u_oddr.q1 vs GHDL's gen_xilinx_7series_u_oddr.q1).
module ddr_output_gen_xilinx_7series (
    input  wire clk,
    input  wire d1,
    input  wire d2,
    output wire q
);
    ddr_output gen_xilinx_7series (.clk(clk), .d1(d1), .d2(d2), .q(q));
endmodule
