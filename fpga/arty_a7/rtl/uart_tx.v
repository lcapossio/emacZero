// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// uart_tx.v - Simple UART transmitter (115200 baud, 8N1)
// Verilog 2001
// =============================================================================

module uart_tx #(
    parameter CLK_FREQ = 100_000_000,
    parameter BAUD     = 115200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] data,
    input  wire       data_valid,
    output reg        busy,
    output reg        txd
);

    localparam DIVISOR = CLK_FREQ / BAUD;  // 868 for 100MHz/115200

    reg [9:0]  shift_reg;  // start(0) + 8 data + stop(1)
    reg [3:0]  bit_cnt;
    reg [15:0] clk_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shift_reg <= 10'h3FF;
            bit_cnt   <= 4'd0;
            clk_cnt   <= 16'd0;
            busy      <= 1'b0;
            txd       <= 1'b1;
        end else begin
            if (!busy) begin
                txd <= 1'b1;
                if (data_valid) begin
                    shift_reg <= {1'b1, data, 1'b0};  // stop + data + start
                    bit_cnt   <= 4'd10;
                    clk_cnt   <= 16'd0;
                    busy      <= 1'b1;
                    txd       <= 1'b0;  // start bit immediately
                end
            end else begin
                if (clk_cnt == DIVISOR - 1) begin
                    clk_cnt <= 16'd0;
                    if (bit_cnt == 4'd1) begin
                        // Done
                        busy <= 1'b0;
                        txd  <= 1'b1;
                    end else begin
                        shift_reg <= {1'b1, shift_reg[9:1]};
                        txd       <= shift_reg[1];
                        bit_cnt   <= bit_cnt - 4'd1;
                    end
                end else begin
                    clk_cnt <= clk_cnt + 16'd1;
                end
            end
        end
    end

endmodule
