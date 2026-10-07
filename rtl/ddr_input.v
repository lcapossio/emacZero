// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// ddr_input.v - Vendor-agnostic DDR input primitive wrapper
// Captures data on both edges: q1 from rising, q2 from falling.
// Vendor selection via `define: XILINX_7SERIES, XILINX_ULTRASCALE_PLUS,
// INTEL_CYCLONE
// Default: behavioral model (simulation-compatible)
// Verilog 2001
// =============================================================================

module ddr_input (
    input  wire clk,
    input  wire d,       // DDR input
    output wire q1,      // data captured on rising edge
    output wire q2       // data captured on falling edge
);

`ifdef XILINX_7SERIES
    IDDR #(
        .DDR_CLK_EDGE("SAME_EDGE_PIPELINED"),
        .INIT_Q1(1'b0),
        .INIT_Q2(1'b0),
        .SRTYPE("ASYNC")
    ) u_iddr (
        .Q1 (q1),
        .Q2 (q2),
        .C  (clk),
        .CE (1'b1),
        .D  (d),
        .R  (1'b0),
        .S  (1'b0)
    );
`elsif XILINX_ULTRASCALE_PLUS
    // IDDRE1 SAME_EDGE_PIPELINED matches the 7-series IDDR mode above. CB
    // takes the same clock, inverted inside the cell.
    IDDRE1 #(
        .DDR_CLK_EDGE  ("SAME_EDGE_PIPELINED"),
        .IS_CB_INVERTED(1'b1),
        .IS_C_INVERTED (1'b0)
    ) u_iddr (
        .Q1 (q1),
        .Q2 (q2),
        .C  (clk),
        .CB (clk),
        .D  (d),
        .R  (1'b0)
    );
`elsif INTEL_CYCLONE
    // -------------------------------------------------------------------------
    // STUB - NOT a real Intel DDR input. ALTDDIO_IN / DDIO atoms are NOT
    // instantiated here; this is only a behavioral model so an Intel-target
    // elaboration completes. It will NOT meet DDR input setup/hold on real
    // silicon. Replace with a true ALTDDIO_IN instance before targeting Intel.
    // -------------------------------------------------------------------------
    reg q1_pipe, q1_r, q2_pipe, q2_r;
    always @(posedge clk) begin
        q1_pipe <= d;
        q1_r    <= q1_pipe;
        q2_r    <= q2_pipe;
    end
    always @(negedge clk) q2_pipe <= d;
    assign q1 = q1_r;
    assign q2 = q2_r;
`elsif SIM
    // Simulation-only behavioral model (SAME_EDGE_PIPELINED equivalent, not for
    // synthesis). Xilinx IDDR SAME_EDGE_PIPELINED: at posedge N+1, q1 = data
    // from posedge N, q2 = data from negedge N. Both from the same DDR cycle.
    reg q1_pipe, q1_r, q2_pipe, q2_r;
    always @(posedge clk) begin
        q1_pipe <= d;        // capture rising-edge data
        q1_r    <= q1_pipe;  // pipeline to align with q2
        q2_r    <= q2_pipe;  // pipeline falling-edge data
    end
    always @(negedge clk) q2_pipe <= d;  // capture falling-edge data
    assign q1 = q1_r;
    assign q2 = q2_r;
`else
    // No DDR primitive selected. Define XILINX_7SERIES, XILINX_ULTRASCALE_PLUS
    // (or INTEL_CYCLONE) for synthesis, or SIM for simulation. q1/q2 are
    // intentionally left undriven so an accidental synthesis of this file
    // fails loudly instead of silently inferring a soft model.
`endif

endmodule
