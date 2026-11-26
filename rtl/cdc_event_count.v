// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// cdc_event_count.v - count single-cycle events in one clock domain, read the
// count in another
//
// The source counts inc pulses (at most one per src_clk, any rate) and holds
// the count in Gray code, so it changes by one bit at a time and crosses
// through a two-flop synchronizer whole. The destination converts it back to
// binary. The count wraps: a reader adds its growth since the last look to a
// counter of its own (eth_mac_sys_10g does this every cycle, so WIDTH only
// has to cover the events of a few dst_clk cycles). count lags the source by
// about three dst_clk cycles. Reset both ends together (and the reader's
// last look with them), or the count jumps.
// Verilog 2001
// =============================================================================

module cdc_event_count #(
    parameter WIDTH = 32
) (
    input  wire             src_clk,
    input  wire             src_rst_n,
    input  wire             inc,

    input  wire             dst_clk,
    input  wire             dst_rst_n,
    output reg  [WIDTH-1:0] count
);

    reg [WIDTH-1:0] bin;
    reg [WIDTH-1:0] gray;

    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            bin  <= {WIDTH{1'b0}};
            gray <= {WIDTH{1'b0}};
        end else if (inc) begin
            bin  <= bin + 1'b1;
            gray <= (bin + 1'b1) ^ ((bin + 1'b1) >> 1);
        end
    end

    (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] g_s1;
    (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] g_s2;

    function [WIDTH-1:0] gray2bin;
        input [WIDTH-1:0] g;
        integer           i;
        reg   [WIDTH-1:0] b;
        begin
            b = g;
            for (i = 1; i < WIDTH; i = i + 1)
                b = b ^ (g >> i);
            gray2bin = b;
        end
    endfunction

    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            g_s1  <= {WIDTH{1'b0}};
            g_s2  <= {WIDTH{1'b0}};
            count <= {WIDTH{1'b0}};
        end else begin
            g_s1  <= gray;
            g_s2  <= g_s1;
            count <= gray2bin(g_s2);
        end
    end

endmodule
