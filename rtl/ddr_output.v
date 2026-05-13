// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// ddr_output.v - Vendor-agnostic DDR output primitive wrapper
// Outputs d1 on rising edge, d2 on falling edge.
// Vendor selection via `define: XILINX_7SERIES, INTEL_CYCLONE
// Default: behavioral model (simulation-compatible)
// Verilog 2001
// =============================================================================

module ddr_output (
    input  wire clk,
    input  wire d1,      // data captured on rising edge
    input  wire d2,      // data captured on falling edge
    output wire q        // DDR output
);

`ifdef XILINX_7SERIES
    ODDR #(
        .DDR_CLK_EDGE("SAME_EDGE"),
        .INIT(1'b0),
        .SRTYPE("ASYNC")
    ) u_oddr (
        .Q  (q),
        .C  (clk),
        .CE (1'b1),
        .D1 (d1),
        .D2 (d2),
        .R  (1'b0),
        .S  (1'b0)
    );
`elsif INTEL_CYCLONE
    // Intel/Altera DDR output using ALTDDIO_OUT
    // Directly instantiate the atom or use altddio_out megafunction
    reg q_r;
    always @(posedge clk) q_r <= d1;
    always @(negedge clk) q_r <= d2;
    assign q = q_r;
`else
    // Behavioral model for simulation
    reg q_r;
    always @(posedge clk) q_r <= d1;
    always @(negedge clk) q_r <= d2;
    assign q = q_r;
`endif

endmodule
