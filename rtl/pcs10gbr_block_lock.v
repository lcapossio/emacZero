// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// pcs10gbr_block_lock.v - 10GBASE-R block lock (IEEE 802.3 clause 49.2.13.2.6)
//
// Tests the sync header of each block (valid when the two bits differ).
//   - Out of lock: the first invalid header slips the gearbox one bit; 64
//     valid headers in a row give block lock.
//   - In lock: headers are counted in windows of 64; 16 invalid headers in a
//     window drop lock and slip. A window with fewer resets the counts.
// After a slip, SLIP_WAIT blocks are ignored while the gearbox pipeline
// refills at the new boundary.
// Verilog 2001
// =============================================================================

module pcs10gbr_block_lock #(
    parameter SLIP_WAIT = 4
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       valid,       // a block on hdr
    input  wire [1:0] hdr,
    output reg        block_lock,
    output reg        slip         // one-cycle pulse to the gearbox
);

    reg [6:0] sh_cnt;              // headers tested in this window, 0..64
    reg [4:0] inv_cnt;             // invalid headers in this window, 0..16
    reg [3:0] wait_cnt;

    wire sh_valid = hdr[0] ^ hdr[1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            block_lock <= 1'b0;
            slip       <= 1'b0;
            sh_cnt     <= 7'd0;
            inv_cnt    <= 5'd0;
            wait_cnt   <= 4'd0;
        end else begin
            slip <= 1'b0;
            if (valid) begin
                if (wait_cnt != 4'd0) begin
                    wait_cnt <= wait_cnt - 4'd1;
                end else if (!block_lock) begin
                    if (sh_valid) begin
                        if (sh_cnt == 7'd63) begin
                            block_lock <= 1'b1;
                            sh_cnt     <= 7'd0;
                            inv_cnt    <= 5'd0;
                        end else
                            sh_cnt <= sh_cnt + 7'd1;
                    end else begin
                        slip     <= 1'b1;
                        sh_cnt   <= 7'd0;
                        inv_cnt  <= 5'd0;
                        wait_cnt <= SLIP_WAIT;
                    end
                end else begin
                    if (!sh_valid && inv_cnt == 5'd15) begin
                        block_lock <= 1'b0;
                        slip       <= 1'b1;
                        sh_cnt     <= 7'd0;
                        inv_cnt    <= 5'd0;
                        wait_cnt   <= SLIP_WAIT;
                    end else if (sh_cnt == 7'd63) begin
                        sh_cnt  <= 7'd0;
                        inv_cnt <= 5'd0;
                    end else begin
                        sh_cnt <= sh_cnt + 7'd1;
                        if (!sh_valid) inv_cnt <= inv_cnt + 5'd1;
                    end
                end
            end
        end
    end

endmodule
