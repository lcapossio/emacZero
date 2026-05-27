// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// sync_fifo.v - Synchronous (single-clock) FIFO with BRAM storage and FWFT
// output register. Width and depth (power of 2) are parameterizable.
//
// FWFT semantics: when rd_valid=1, rd_data is the head of the FIFO. Pop
// happens when (rd_valid && rd_en). Read latency from non-empty to first
// rd_valid is 1 cycle (BRAM sync read). ram_style=block forces BRAM.
// Verilog 2001
// =============================================================================

module sync_fifo #(
    parameter DATA_WIDTH = 8,
    parameter ADDR_WIDTH = 8
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // Write side
    input  wire [DATA_WIDTH-1:0] wr_data,
    input  wire                  wr_en,
    output wire                  wr_full,

    // Read side (FWFT)
    output wire [DATA_WIDTH-1:0] rd_data,
    output wire                  rd_valid,
    input  wire                  rd_en,
    output wire                  rd_empty,

    // Occupancy (count of entries in BRAM, excludes the output register)
    output wire [ADDR_WIDTH:0]   count,

    // High for one cycle when a write was attempted but dropped (FIFO full).
    output wire                  wr_overflow
);

    localparam DEPTH = 1 << ADDR_WIDTH;

    (* ram_style = "block" *)
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    reg [ADDR_WIDTH:0] wr_ptr;
    reg [ADDR_WIDTH:0] rd_ptr;

    wire [ADDR_WIDTH:0] occ = wr_ptr - rd_ptr;
    wire                empty = (occ == {ADDR_WIDTH+1{1'b0}});
    wire                full  = (occ == DEPTH[ADDR_WIDTH:0]);

    // Output stage (BRAM dout register + valid bit)
    reg [DATA_WIDTH-1:0] dout_r;
    reg                  dout_valid_r;

    wire pop        = dout_valid_r && rd_en;
    wire issue_read = !empty && (!dout_valid_r || pop);

    // Push gating: accept the write if there is room, or if a slot is being
    // freed this cycle by issue_read.
    wire push_ok = wr_en && (!full || issue_read);

    always @(posedge clk) begin
        if (push_ok)
            mem[wr_ptr[ADDR_WIDTH-1:0]] <= wr_data;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= {ADDR_WIDTH+1{1'b0}};
        end else if (push_ok) begin
            wr_ptr <= wr_ptr + 1'b1;
        end
    end

    always @(posedge clk) begin
        if (issue_read)
            dout_r <= mem[rd_ptr[ADDR_WIDTH-1:0]];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr       <= {ADDR_WIDTH+1{1'b0}};
            dout_valid_r <= 1'b0;
        end else begin
            if (issue_read) begin
                rd_ptr       <= rd_ptr + 1'b1;
                dout_valid_r <= 1'b1;
            end else if (pop) begin
                dout_valid_r <= 1'b0;
            end
        end
    end

    assign rd_data     = dout_r;
    assign rd_valid    = dout_valid_r;
    assign rd_empty    = empty && !dout_valid_r;
    assign wr_full     = full;
    assign count       = occ;
    assign wr_overflow = wr_en && !push_ok;

endmodule
