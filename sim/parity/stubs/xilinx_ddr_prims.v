// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// xilinx_ddr_prims.v - Parity-only behavioural stubs of the Xilinx DDR I/O
// primitives ODDR, IDDR (7-series) and ODDRE1, IDDRE1 (UltraScale+).
// Read on the Verilog (golden) side of a translateHDL proof in place of the
// unisim models; xilinx_ddr_prims.vhd is the line-for-line VHDL twin read on
// the candidate side. Ports and parameters match unisim, so the proof checks
// every connection and parameter value the wrapper passes.
//
// NOT the vendor models. Modelled: DDR_CLK_EDGE (OPPOSITE_EDGE, SAME_EDGE,
// SAME_EDGE_PIPELINED), INIT / INIT_Q1 / INIT_Q2 / SRVAL as power-up values,
// IS_*_INVERTED, CE, and R / S / SR (synchronous to the edge that loads each
// register). Not modelled: SRTYPE (R / S / SR are tied off by every emacZero
// instance, so ASYNC and SYNC give the same waveforms), SIM_DEVICE, and timing.
// =============================================================================

module ODDR #(
    parameter       DDR_CLK_EDGE   = "OPPOSITE_EDGE",
    parameter [0:0] INIT           = 1'b0,
    parameter [0:0] IS_C_INVERTED  = 1'b0,
    parameter [0:0] IS_D1_INVERTED = 1'b0,
    parameter [0:0] IS_D2_INVERTED = 1'b0,
    parameter       SRTYPE         = "SYNC"
)(
    output wire Q,
    input  wire C,
    input  wire CE,
    input  wire D1,
    input  wire D2,
    input  wire R,
    input  wire S
);
    localparam SAME = (DDR_CLK_EDGE == "SAME_EDGE");
    wire c_i  = C  ^ IS_C_INVERTED;
    wire d1_i = D1 ^ IS_D1_INVERTED;
    wire d2_i = D2 ^ IS_D2_INVERTED;
    reg  q1 = INIT, q2s = INIT, q2 = INIT;
    // Rising edge: D1 (and D2 for SAME_EDGE).
    always @(posedge c_i) begin
        if (R)       begin q1 <= 1'b0; q2s <= 1'b0; end
        else if (S)  begin q1 <= 1'b1; q2s <= 1'b1; end
        else if (CE) begin q1 <= d1_i; q2s <= d2_i; end
    end
    // Falling edge: D2 (OPPOSITE_EDGE) or the D2 taken on the rising edge.
    always @(negedge c_i) begin
        if (R)       q2 <= 1'b0;
        else if (S)  q2 <= 1'b1;
        else if (CE) q2 <= SAME ? q2s : d2_i;
    end
    assign Q = c_i ? q1 : q2;
endmodule

module ODDRE1 #(
    parameter [0:0] IS_C_INVERTED  = 1'b0,
    parameter [0:0] IS_D1_INVERTED = 1'b0,
    parameter [0:0] IS_D2_INVERTED = 1'b0,
    parameter       SIM_DEVICE     = "ULTRASCALE",
    parameter [0:0] SRVAL          = 1'b0
)(
    output wire Q,
    input  wire C,
    input  wire D1,
    input  wire D2,
    input  wire SR
);
    wire c_i  = C  ^ IS_C_INVERTED;
    wire d1_i = D1 ^ IS_D1_INVERTED;
    wire d2_i = D2 ^ IS_D2_INVERTED;
    reg  q1 = SRVAL, q2s = SRVAL, q2 = SRVAL;
    // D1 and D2 both sampled on the rising edge; D2 driven in the low half.
    always @(posedge c_i) begin
        if (SR) begin q1 <= SRVAL; q2s <= SRVAL; end
        else    begin q1 <= d1_i;  q2s <= d2_i;  end
    end
    always @(negedge c_i) begin
        if (SR) q2 <= SRVAL;
        else    q2 <= q2s;
    end
    assign Q = c_i ? q1 : q2;
endmodule

module IDDR #(
    parameter       DDR_CLK_EDGE  = "OPPOSITE_EDGE",
    parameter [0:0] INIT_Q1       = 1'b0,
    parameter [0:0] INIT_Q2       = 1'b0,
    parameter [0:0] IS_C_INVERTED = 1'b0,
    parameter [0:0] IS_D_INVERTED = 1'b0,
    parameter       SRTYPE        = "SYNC"
)(
    output wire Q1,
    output wire Q2,
    input  wire C,
    input  wire CE,
    input  wire D,
    input  wire R,
    input  wire S
);
    localparam OPP  = (DDR_CLK_EDGE == "OPPOSITE_EDGE");
    localparam PIPE = (DDR_CLK_EDGE == "SAME_EDGE_PIPELINED");
    wire c_i = C ^ IS_C_INVERTED;
    wire d_i = D ^ IS_D_INVERTED;
    reg  q1p = INIT_Q1, q1r = INIT_Q1, q2p = INIT_Q2, q2r = INIT_Q2;
    // Rising edge: D into q1p; Q1 takes D (OPPOSITE/SAME_EDGE) or q1p
    // (SAME_EDGE_PIPELINED); Q2 re-times the falling-edge capture.
    always @(posedge c_i) begin
        if (R)       begin q1p <= 1'b0; q1r <= 1'b0; q2r <= 1'b0; end
        else if (S)  begin q1p <= 1'b1; q1r <= 1'b1; q2r <= 1'b1; end
        else if (CE) begin
            q1p <= d_i;
            q1r <= PIPE ? q1p : d_i;
            q2r <= q2p;
        end
    end
    // Falling edge: D into q2p (Q2 directly for OPPOSITE_EDGE).
    always @(negedge c_i) begin
        if (R)       q2p <= 1'b0;
        else if (S)  q2p <= 1'b1;
        else if (CE) q2p <= d_i;
    end
    assign Q1 = q1r;
    assign Q2 = OPP ? q2p : q2r;
endmodule

module IDDRE1 #(
    parameter       DDR_CLK_EDGE   = "OPPOSITE_EDGE",
    parameter [0:0] IS_CB_INVERTED = 1'b0,
    parameter [0:0] IS_C_INVERTED  = 1'b0
)(
    output wire Q1,
    output wire Q2,
    input  wire C,
    input  wire CB,
    input  wire D,
    input  wire R
);
    localparam OPP  = (DDR_CLK_EDGE == "OPPOSITE_EDGE");
    localparam PIPE = (DDR_CLK_EDGE == "SAME_EDGE_PIPELINED");
    wire c_i  = C  ^ IS_C_INVERTED;
    wire cb_i = CB ^ IS_CB_INVERTED;
    reg  q1p = 1'b0, q1r = 1'b0, q2p = 1'b0, q2r = 1'b0;
    // Rising C: as IDDR's rising edge.
    always @(posedge c_i) begin
        if (R) begin q1p <= 1'b0; q1r <= 1'b0; q2r <= 1'b0; end
        else begin
            q1p <= D;
            q1r <= PIPE ? q1p : D;
            q2r <= q2p;
        end
    end
    // Rising CB (after IS_CB_INVERTED): the second-half capture.
    always @(posedge cb_i) begin
        if (R) q2p <= 1'b0;
        else   q2p <= D;
    end
    assign Q1 = q1r;
    assign Q2 = OPP ? q2p : q2r;
endmodule
