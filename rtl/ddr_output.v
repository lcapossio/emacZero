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
    // -------------------------------------------------------------------------
    // STUB - NOT a real Intel DDR output. ALTDDIO_OUT / DDIO atoms are NOT
    // instantiated here; this is only a behavioral mux so an Intel-target
    // elaboration completes. It will NOT meet DDR output timing on real
    // silicon. Replace with a true ALTDDIO_OUT instance before targeting Intel.
    // -------------------------------------------------------------------------
    reg q1_r, q2_r;
    always @(posedge clk) q1_r <= d1;
    always @(negedge clk) q2_r <= d2;
    assign q = clk ? q1_r : q2_r;
`elsif SIM
    // Simulation-only behavioral DDR model (not for synthesis). Two single-edge
    // registers muxed by clk - never drives one register from two clock edges.
    reg q1_r, q2_r;
    always @(posedge clk) q1_r <= d1;
    always @(negedge clk) q2_r <= d2;
    assign q = clk ? q1_r : q2_r;
`else
    // No DDR primitive selected. Define XILINX_7SERIES (or INTEL_CYCLONE) for
    // synthesis, or SIM for simulation. `q` is intentionally left undriven so an
    // accidental synthesis of this file fails loudly instead of silently
    // inferring a non-DDR soft register.
`endif

endmodule
