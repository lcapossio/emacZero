// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// async_fifo.v - Asynchronous FIFO with Gray-code pointer CDC
// Parameterizable width and depth (depth must be power of 2).
// Verilog 2001
// =============================================================================

module async_fifo #(
    parameter DATA_WIDTH = 9,
    parameter ADDR_WIDTH = 11
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

    // Exact write-side occupancy (wr_ptr - synced rd_ptr), in the wr_clk
    // domain. Lags true occupancy by the pointer-sync latency, so it never
    // under-reports fullness - safe for fill-level / "busy" decisions. Leave
    // unconnected if not needed.
    output wire [ADDR_WIDTH:0]   wr_data_count
);

    localparam DEPTH = 1 << ADDR_WIDTH;

    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

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

    always @(posedge wr_clk) begin
        if (wr_addr_valid)
            mem[wr_ptr_bin[ADDR_WIDTH-1:0]] <= wr_data;
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

    assign rd_data = mem[rd_ptr_bin[ADDR_WIDTH-1:0]];

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_ptr_bin  <= {ADDR_WIDTH+1{1'b0}};
            rd_ptr_gray <= {ADDR_WIDTH+1{1'b0}};
        end else if (rd_en && !rd_empty) begin
            rd_ptr_bin  <= rd_ptr_bin + 1'b1;
            rd_ptr_gray <= bin2gray(rd_ptr_bin + 1'b1);
        end
    end

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            wr_ptr_gray_sync1 <= {ADDR_WIDTH+1{1'b0}};
            wr_ptr_gray_sync2 <= {ADDR_WIDTH+1{1'b0}};
        end else begin
            wr_ptr_gray_sync1 <= wr_ptr_gray;
            wr_ptr_gray_sync2 <= wr_ptr_gray_sync1;
        end
    end

    assign rd_empty = (rd_ptr_gray == wr_ptr_gray_sync2);

endmodule
