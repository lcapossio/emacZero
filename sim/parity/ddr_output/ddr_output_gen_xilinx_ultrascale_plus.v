// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// Parity wrapper (golden side only): a pass-through ddr_output whose instance
// is named gen_xilinx_ultrascale_plus, like the VHDL generate that holds the
// XILINX_ULTRASCALE_PLUS branch. The flattened stub state then has the same
// name on both sides (gen_xilinx_ultrascale_plus.u_oddr.q1 vs GHDL's gen_xilinx_ultrascale_plus_u_oddr.q1).
module ddr_output_gen_xilinx_ultrascale_plus (
    input  wire clk,
    input  wire d1,
    input  wire d2,
    output wire q
);
    ddr_output gen_xilinx_ultrascale_plus (.clk(clk), .d1(d1), .d2(d2), .q(q));
endmodule
