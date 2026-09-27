// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// async_fifo.v - Asynchronous FIFO with Gray-code pointer CDC
// Parameterizable width and depth (depth must be power of 2).
//
// Two storage implementations behind one first-word-fall-through interface
// (rd_data is valid whenever !rd_empty; rd_en && !rd_empty pops it):
//   RAM_STYLE = "DISTRIBUTED"  combinational read of the memory array. Maps to
//               LUTRAM on FPGAs; lowest latency. Right for shallow FIFOs - deep
//               ones cost ~DEPTH*WIDTH/64 LUTs plus a wide write decode that
//               will not close timing at 100+ MHz (16K words fails on Artix-7).
//   RAM_STYLE = "BLOCK"        registered read into a one-word output stage,
//               which is the FWFT head. Maps to block RAM. rd_empty deasserts
//               one rd_clk later than DISTRIBUTED after a write lands; pops
//               still sustain one word per rd_clk. The head word has left the
//               memory, so once it is loaded the FIFO holds DEPTH+1 words
//               before wr_full.
// Verilog 2001
// =============================================================================

module async_fifo #(
    parameter DATA_WIDTH = 9,
    parameter ADDR_WIDTH = 11,
    parameter RAM_STYLE  = "DISTRIBUTED"    // "DISTRIBUTED" | "BLOCK"
)(
    input  wire                  wr_clk,
    input  wire                  wr_rst_n,
    input  wire [DATA_WIDTH-1:0] wr_data,
    input  wire                  wr_en,
    output wire                  wr_full,

    input  wire                  rd_clk,
    input  wire                  rd_rst_n,
    output wire [DATA_WIDTH-1:0] rd_data,
    input  wire                  rd_en,
    output wire                  rd_empty,

    // Write-side occupancy of the memory array (wr_ptr - synced rd_ptr), in
    // the wr_clk domain. Lags reads by the pointer-sync latency, so it never
    // under-reports how full the memory is - safe for fill-level / "busy"
    // decisions. With RAM_STYLE="BLOCK" the word held in the output stage has
    // already left the memory and is not counted. Leave unconnected if unused.
    output wire [ADDR_WIDTH:0]   wr_data_count
);

    localparam DEPTH = 1 << ADDR_WIDTH;

    reg [ADDR_WIDTH:0] wr_ptr_bin;
    reg [ADDR_WIDTH:0] wr_ptr_gray;
    reg [ADDR_WIDTH:0] rd_ptr_bin;
    reg [ADDR_WIDTH:0] rd_ptr_gray;

    (* ASYNC_REG = "TRUE" *) reg [ADDR_WIDTH:0] wr_ptr_gray_sync1;
    (* ASYNC_REG = "TRUE" *) reg [ADDR_WIDTH:0] wr_ptr_gray_sync2;
    (* ASYNC_REG = "TRUE" *) reg [ADDR_WIDTH:0] rd_ptr_gray_sync1;
    (* ASYNC_REG = "TRUE" *) reg [ADDR_WIDTH:0] rd_ptr_gray_sync2;

    function [ADDR_WIDTH:0] bin2gray;
        input [ADDR_WIDTH:0] bin;
        begin
            bin2gray = bin ^ (bin >> 1);
        end
    endfunction

    wire wr_addr_valid = wr_en && !wr_full;

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_ptr_bin  <= {ADDR_WIDTH+1{1'b0}};
            wr_ptr_gray <= {ADDR_WIDTH+1{1'b0}};
        end else if (wr_addr_valid) begin
            wr_ptr_bin  <= wr_ptr_bin + 1'b1;
            wr_ptr_gray <= bin2gray(wr_ptr_bin + 1'b1);
        end
    end

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rd_ptr_gray_sync1 <= {ADDR_WIDTH+1{1'b0}};
            rd_ptr_gray_sync2 <= {ADDR_WIDTH+1{1'b0}};
        end else begin
            rd_ptr_gray_sync1 <= rd_ptr_gray;
            rd_ptr_gray_sync2 <= rd_ptr_gray_sync1;
        end
    end

    assign wr_full = (wr_ptr_gray == {~rd_ptr_gray_sync2[ADDR_WIDTH:ADDR_WIDTH-1],
                                      rd_ptr_gray_sync2[ADDR_WIDTH-2:0]});

    // Write-side occupancy from the already-synchronized read Gray pointer.
    function [ADDR_WIDTH:0] gray2bin;
        input [ADDR_WIDTH:0] gray;
        integer i;
        reg [ADDR_WIDTH:0] b;
        begin
            b = gray;
            for (i = 1; i <= ADDR_WIDTH; i = i + 1)
                b = b ^ (gray >> i);
            gray2bin = b;
        end
    endfunction
    assign wr_data_count = wr_ptr_bin - gray2bin(rd_ptr_gray_sync2);

    // rd_ptr_bin / rd_ptr_gray count words read out of the memory array.
    // mem_empty compares that pointer against the synced write pointer; what
    // the user sees as rd_empty depends on the storage style below.
    wire mem_empty = (rd_ptr_gray == wr_ptr_gray_sync2);
    wire mem_rd;                    // pop one word from the memory array

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_ptr_bin  <= {ADDR_WIDTH+1{1'b0}};
            rd_ptr_gray <= {ADDR_WIDTH+1{1'b0}};
        end else if (mem_rd) begin
            rd_ptr_bin  <= rd_ptr_bin + 1'b1;
            rd_ptr_gray <= bin2gray(rd_ptr_bin + 1'b1);
        end
    end

    generate
        if (RAM_STYLE == "BLOCK") begin : gen_block
            (* ram_style = "block" *) reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
            always @(posedge wr_clk) begin
                if (wr_addr_valid)
                    mem[wr_ptr_bin[ADDR_WIDTH-1:0]] <= wr_data;
            end

            // One-word output stage = the FWFT head. Refill it whenever it is
            // empty or being popped this cycle, so back-to-back pops run at
            // one word per clock. head_q is the block RAM's registered read
            // port: no reset, so the tool can absorb it into the RAM.
            reg [DATA_WIDTH-1:0] head_q;
            reg                  head_valid;
            wire                 pop  = rd_en && head_valid;
            assign mem_rd = !mem_empty && (!head_valid || pop);

            always @(posedge rd_clk) begin
                if (mem_rd)
                    head_q <= mem[rd_ptr_bin[ADDR_WIDTH-1:0]];
            end
            always @(posedge rd_clk or negedge rd_rst_n) begin
                if (!rd_rst_n)
                    head_valid <= 1'b0;
                else if (mem_rd)
                    head_valid <= 1'b1;
                else if (pop)
                    head_valid <= 1'b0;
            end

            assign rd_data  = head_q;
            assign rd_empty = !head_valid;
        end else begin : gen_distributed
            (* ram_style = "distributed" *) reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
            always @(posedge wr_clk) begin
                if (wr_addr_valid)
                    mem[wr_ptr_bin[ADDR_WIDTH-1:0]] <= wr_data;
            end

            assign mem_rd   = rd_en && !mem_empty;
            assign rd_data  = mem[rd_ptr_bin[ADDR_WIDTH-1:0]];
            assign rd_empty = mem_empty;
        end
    endgenerate

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            wr_ptr_gray_sync1 <= {ADDR_WIDTH+1{1'b0}};
            wr_ptr_gray_sync2 <= {ADDR_WIDTH+1{1'b0}};
        end else begin
            wr_ptr_gray_sync1 <= wr_ptr_gray;
            wr_ptr_gray_sync2 <= wr_ptr_gray_sync1;
        end
    end

endmodule
