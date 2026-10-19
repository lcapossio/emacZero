// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// Parity wrapper: async_fifo with RAM_STYLE pinned to "BLOCK", so the
// integer-only translateHDL param sets can reach that generate branch.
module async_fifo_block #(
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
    output wire [ADDR_WIDTH:0]   wr_data_count
);
    async_fifo #(
        .DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH), .RAM_STYLE("BLOCK")
    ) u_fifo (
        .wr_clk(wr_clk), .wr_rst_n(wr_rst_n), .wr_data(wr_data), .wr_en(wr_en),
        .wr_full(wr_full), .rd_clk(rd_clk), .rd_rst_n(rd_rst_n), .rd_data(rd_data),
        .rd_en(rd_en), .rd_empty(rd_empty), .wr_data_count(wr_data_count)
    );
endmodule
