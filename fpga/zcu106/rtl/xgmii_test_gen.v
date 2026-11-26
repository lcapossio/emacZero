// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// xgmii_test_gen.v - 64-bit XGMII test frame generator for the 10GBASE-R
// bring-up (pairs with xgmii_test_chk.v). Not Ethernet frames: there is no
// FCS, so a switch drops them; they exercise the PCS and the GT at line rate.
//
// Frame: start word (FB 55 55 55 55 55 55 D5, lane 0 first), a header word
// {32'h5A3C_0F96, seq}, len_words - 1 payload words from a 64-bit xorshift
// generator seeded from seq, a terminate word (FD 07 07 07 07 07 07 07),
// then ipg_words idle words. seq counts frames from 0. inj_err (a pulse)
// flips bit 0 of the next payload word, once.
//
// The PCS takes a word when xgmii_tx_ready is high (32 of 33 cycles); the
// generator only advances on those cycles.
// Verilog 2001
// =============================================================================

module xgmii_test_gen (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,            // finishes the current frame when cleared
    input  wire [7:0]  len_words,         // header + payload words, >= 1
    input  wire [7:0]  ipg_words,         // idle words after the terminate word
    input  wire        inj_err,
    input  wire        xgmii_tx_ready,
    output reg  [63:0] xgmii_txd,
    output reg  [7:0]  xgmii_txc,
    output reg  [31:0] frames
);

    localparam [63:0] IDLE_D  = 64'h0707070707070707;
    localparam [63:0] START_D = 64'hD5555555555555FB;
    localparam [63:0] TERM_D  = 64'h07070707070707FD;
    localparam [31:0] HDR_TAG = 32'h5A3C0F96;

    // xorshift64 step; seeds are never zero (see seed below)
    function [63:0] xs;
        input [63:0] s;
        reg   [63:0] t;
        begin
            t  = s ^ (s << 13);
            t  = t ^ (t >> 7);
            xs = t ^ (t << 17);
        end
    endfunction

    localparam S_IDLE = 3'd0, S_START = 3'd1, S_HDR = 3'd2, S_DATA = 3'd3,
               S_TERM = 3'd4, S_IPG = 3'd5;

    reg [2:0]  st;
    reg [7:0]  cnt;
    reg [31:0] seq;
    reg [63:0] lfsr;
    reg        inj_pend;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= S_IDLE;
            cnt       <= 8'd0;
            seq       <= 32'd0;
            lfsr      <= 64'd1;
            inj_pend  <= 1'b0;
            frames    <= 32'd0;
            xgmii_txd <= IDLE_D;
            xgmii_txc <= 8'hFF;
        end else begin
            if (inj_err) inj_pend <= 1'b1;
            if (xgmii_tx_ready) begin
                case (st)
                    S_IDLE: begin
                        xgmii_txd <= IDLE_D;
                        xgmii_txc <= 8'hFF;
                        if (enable) st <= S_START;
                    end
                    S_START: begin
                        xgmii_txd <= START_D;
                        xgmii_txc <= 8'h01;
                        st        <= S_HDR;
                    end
                    S_HDR: begin
                        xgmii_txd <= {seq, HDR_TAG};
                        xgmii_txc <= 8'h00;
                        lfsr      <= {seq, ~seq};
                        cnt       <= 8'd1;
                        st        <= (len_words > 8'd1) ? S_DATA : S_TERM;
                    end
                    S_DATA: begin
                        xgmii_txd <= {lfsr[63:1], lfsr[0] ^ inj_pend};
                        xgmii_txc <= 8'h00;
                        inj_pend  <= inj_err;   // a pulse now hits the next word
                        lfsr      <= xs(lfsr);
                        cnt       <= cnt + 8'd1;
                        if (cnt + 8'd1 >= len_words) st <= S_TERM;
                    end
                    S_TERM: begin
                        xgmii_txd <= TERM_D;
                        xgmii_txc <= 8'hFF;
                        seq       <= seq + 32'd1;
                        frames    <= frames + 32'd1;
                        cnt       <= 8'd0;
                        st        <= (ipg_words == 8'd0) ? (enable ? S_START : S_IDLE)
                                                         : S_IPG;
                    end
                    default: begin   // S_IPG
                        xgmii_txd <= IDLE_D;
                        xgmii_txc <= 8'hFF;
                        cnt       <= cnt + 8'd1;
                        if (cnt + 8'd1 >= ipg_words) st <= enable ? S_START : S_IDLE;
                    end
                endcase
            end
        end
    end

endmodule
