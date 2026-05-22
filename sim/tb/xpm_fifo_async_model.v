// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// xpm_fifo_async_model.v - Small simulation model for Xilinx xpm_fifo_async
//
// This model is intentionally stricter than the repo's generic async_fifo for
// FWFT replay tests: after a read, data_valid drops for one rd_clk cycle before
// the next word is presented. RTL that consumes based only on !empty can replay
// stale data; RTL that waits for data_valid sees the fresh word.
// =============================================================================
`timescale 1ns / 1ps

module xpm_fifo_async #(
    parameter integer CDC_SYNC_STAGES      = 2,
    parameter         DOUT_RESET_VALUE     = "0",
    parameter integer FIFO_READ_LATENCY    = 0,
    parameter integer FIFO_WRITE_DEPTH     = 16,
    parameter integer FULL_RESET_VALUE     = 0,
    parameter integer PROG_EMPTY_THRESH    = 10,
    parameter integer PROG_FULL_THRESH     = 10,
    parameter integer RD_DATA_COUNT_WIDTH  = 5,
    parameter         READ_MODE            = "fwft",
    parameter integer READ_DATA_WIDTH      = 8,
    parameter         USE_ADV_FEATURES     = "0000",
    parameter integer WAKEUP_TIME          = 0,
    parameter integer WR_DATA_COUNT_WIDTH  = 5,
    parameter integer WRITE_DATA_WIDTH     = 8
)(
    input  wire                          wr_clk,
    input  wire                          wr_en,
    input  wire [WRITE_DATA_WIDTH-1:0]   din,
    output wire                          full,
    output wire                          wr_rst_busy,

    input  wire                          rd_clk,
    input  wire                          rd_en,
    output reg  [READ_DATA_WIDTH-1:0]    dout,
    output wire                          empty,
    output wire                          rd_rst_busy,

    input  wire                          rst,
    input  wire                          sleep,
    input  wire                          injectsbiterr,
    input  wire                          injectdbiterr,
    output wire                          sbiterr,
    output wire                          dbiterr,
    output reg                           overflow,
    output reg                           underflow,
    output wire                          prog_full,
    output wire                          prog_empty,
    output wire                          almost_full,
    output wire                          almost_empty,
    output wire [WR_DATA_COUNT_WIDTH-1:0] wr_data_count,
    output wire [RD_DATA_COUNT_WIDTH-1:0] rd_data_count,
    output reg                           data_valid,
    output reg                           wr_ack
);
    function integer clog2;
        input integer value;
        integer tmp;
        begin
            tmp = value - 1;
            for (clog2 = 0; tmp > 0; clog2 = clog2 + 1)
                tmp = tmp >> 1;
        end
    endfunction

    localparam integer ADDR_WIDTH = clog2(FIFO_WRITE_DEPTH);
    localparam integer COUNT_WIDTH = ADDR_WIDTH + 1;

    reg [WRITE_DATA_WIDTH-1:0] mem [0:FIFO_WRITE_DEPTH-1];
    reg [ADDR_WIDTH-1:0] wr_ptr;
    reg [ADDR_WIDTH-1:0] rd_ptr;
    reg [COUNT_WIDTH-1:0] wr_count_total;
    reg [COUNT_WIDTH-1:0] rd_count_total;
    reg                  present_bubble;

    wire [COUNT_WIDTH-1:0] count = wr_count_total - rd_count_total;
    wire can_write = wr_en && !full && !rst;
    wire can_read  = rd_en && !empty && !rst;
    wire [ADDR_WIDTH-1:0] rd_ptr_next =
        (rd_ptr == FIFO_WRITE_DEPTH-1) ? {ADDR_WIDTH{1'b0}} : rd_ptr + 1'b1;

    assign full = (count == FIFO_WRITE_DEPTH[COUNT_WIDTH-1:0]);
    assign empty = (count == {COUNT_WIDTH{1'b0}});
    assign wr_rst_busy = 1'b0;
    assign rd_rst_busy = 1'b0;
    assign sbiterr = 1'b0;
    assign dbiterr = 1'b0;
    assign prog_full = full;
    assign prog_empty = (count < PROG_EMPTY_THRESH[COUNT_WIDTH-1:0]);
    assign almost_full = full;
    assign almost_empty = prog_empty;
    assign wr_data_count = count[WR_DATA_COUNT_WIDTH-1:0];
    assign rd_data_count = count[RD_DATA_COUNT_WIDTH-1:0];

    always @(posedge wr_clk or posedge rst) begin
        if (rst) begin
            wr_ptr <= {ADDR_WIDTH{1'b0}};
            wr_count_total <= {COUNT_WIDTH{1'b0}};
            wr_ack <= 1'b0;
            overflow <= 1'b0;
        end else begin
            wr_ack <= 1'b0;
            overflow <= 1'b0;
            if (wr_en && full) begin
                overflow <= 1'b1;
            end else if (can_write) begin
                mem[wr_ptr] <= din;
                wr_ptr <= (wr_ptr == FIFO_WRITE_DEPTH-1) ?
                          {ADDR_WIDTH{1'b0}} : wr_ptr + 1'b1;
                wr_count_total <= wr_count_total + 1'b1;
                wr_ack <= 1'b1;
            end
        end
    end

    always @(posedge rd_clk or posedge rst) begin
        if (rst) begin
            rd_ptr <= {ADDR_WIDTH{1'b0}};
            rd_count_total <= {COUNT_WIDTH{1'b0}};
            dout <= {READ_DATA_WIDTH{1'b0}};
            data_valid <= 1'b0;
            underflow <= 1'b0;
            present_bubble <= 1'b0;
        end else begin
            underflow <= 1'b0;
            if (rd_en && empty) begin
                underflow <= 1'b1;
                data_valid <= 1'b0;
            end else if (can_read) begin
                rd_ptr <= rd_ptr_next;
                rd_count_total <= rd_count_total + 1'b1;
                data_valid <= 1'b0;
                present_bubble <= 1'b1;
            end else if (present_bubble) begin
                present_bubble <= 1'b0;
                if (count != {COUNT_WIDTH{1'b0}}) begin
                    dout <= mem[rd_ptr];
                    data_valid <= 1'b1;
                end else begin
                    data_valid <= 1'b0;
                end
            end else if (!empty) begin
                dout <= mem[rd_ptr];
                data_valid <= 1'b1;
            end else begin
                data_valid <= 1'b0;
            end
        end
    end

endmodule
