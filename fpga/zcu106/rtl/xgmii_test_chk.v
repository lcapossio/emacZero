// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// xgmii_test_chk.v - Checker for the xgmii_test_gen.v frames on a 64-bit
// XGMII receive stream (PCS RX output, a word per cycle with xgmii_rx_valid).
//
// A frame is good when it starts with the start word, carries the header tag,
// every payload word matches the generator sequence seeded from the header's
// seq, and it ends with the terminate word after exactly len_words header +
// payload words. Anything else after a start word (a wrong word, an error
// character, a control character in the payload, a missing terminate) makes
// it bad. seq_gaps counts headers whose seq is not the previous header's
// seq + 1: frames lost entirely (start or header destroyed) before it.
// bad_words counts payload words that differ.
// lf_words counts local fault ordered-set words (the PCS sends them while it
// has no block lock). Counters wrap; clear resets them.
// Verilog 2001
// =============================================================================

module xgmii_test_chk (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clear,
    input  wire [7:0]  len_words,
    input  wire [63:0] xgmii_rxd,
    input  wire [7:0]  xgmii_rxc,
    input  wire        xgmii_rx_valid,
    output reg  [31:0] good_frames,
    output reg  [31:0] bad_frames,
    output reg  [31:0] seq_gaps,
    output reg  [31:0] bad_words,
    output reg  [31:0] lf_words,
    output reg         good_pulse,
    output reg         bad_pulse
);

    localparam [63:0] START_D = 64'hD5555555555555FB;
    localparam [63:0] TERM_D  = 64'h07070707070707FD;
    localparam [63:0] LF_D    = 64'h0100009C0100009C;
    localparam [31:0] HDR_TAG = 32'h5A3C0F96;

    function [63:0] xs;
        input [63:0] s;
        reg   [63:0] t;
        begin
            t  = s ^ (s << 13);
            t  = t ^ (t >> 7);
            xs = t ^ (t << 17);
        end
    endfunction

    localparam S_IDLE = 2'd0, S_HDR = 2'd1, S_DATA = 2'd2;

    reg [1:0]  st;
    reg [7:0]  cnt;
    reg [63:0] lfsr;
    reg [31:0] last_seq;
    reg        have_last, frame_bad;

    wire is_start = (xgmii_rxc == 8'h01) && (xgmii_rxd == START_D);
    wire is_term  = (xgmii_rxc == 8'hFF) && (xgmii_rxd == TERM_D);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st          <= S_IDLE;
            cnt         <= 8'd0;
            lfsr        <= 64'd1;
            last_seq    <= 32'd0;
            have_last   <= 1'b0;
            frame_bad   <= 1'b0;
            good_frames <= 32'd0;
            bad_frames  <= 32'd0;
            seq_gaps    <= 32'd0;
            bad_words   <= 32'd0;
            lf_words    <= 32'd0;
            good_pulse  <= 1'b0;
            bad_pulse   <= 1'b0;
        end else begin
            good_pulse <= 1'b0;
            bad_pulse  <= 1'b0;
            if (clear) begin
                good_frames <= 32'd0;
                bad_frames  <= 32'd0;
                seq_gaps    <= 32'd0;
                bad_words   <= 32'd0;
                lf_words    <= 32'd0;
                have_last   <= 1'b0;
            end
            if (xgmii_rx_valid) begin
                if (xgmii_rxc == 8'h11 && xgmii_rxd == LF_D && !clear)
                    lf_words <= lf_words + 32'd1;
                case (st)
                    S_IDLE: if (is_start) st <= S_HDR;
                    S_HDR: begin
                        if (xgmii_rxc == 8'h00 && xgmii_rxd[31:0] == HDR_TAG) begin
                            if (have_last && xgmii_rxd[63:32] != last_seq + 32'd1 && !clear)
                                seq_gaps <= seq_gaps + 32'd1;
                            last_seq  <= xgmii_rxd[63:32];
                            have_last <= !clear;
                            lfsr      <= {xgmii_rxd[63:32], ~xgmii_rxd[63:32]};
                            cnt       <= 8'd1;
                            frame_bad <= 1'b0;
                            st        <= S_DATA;
                        end else begin
                            if (!clear) bad_frames <= bad_frames + 32'd1;
                            bad_pulse <= 1'b1;
                            st        <= is_start ? S_HDR : S_IDLE;
                        end
                    end
                    default: begin   // S_DATA
                        if (xgmii_rxc == 8'h00) begin
                            if (xgmii_rxd != lfsr) begin
                                frame_bad <= 1'b1;
                                if (!clear) bad_words <= bad_words + 32'd1;
                            end
                            lfsr <= xs(lfsr);
                            cnt  <= cnt + 8'd1;
                            // runaway frame: give up once it is longer than any frame
                            if (cnt == 8'hFF) begin
                                if (!clear) bad_frames <= bad_frames + 32'd1;
                                bad_pulse <= 1'b1;
                                st        <= S_IDLE;
                            end
                        end else begin
                            if (is_term && !frame_bad && cnt == len_words) begin
                                if (!clear) good_frames <= good_frames + 32'd1;
                                good_pulse <= 1'b1;
                            end else begin
                                if (!clear) bad_frames <= bad_frames + 32'd1;
                                bad_pulse <= 1'b1;
                            end
                            st <= is_start ? S_HDR : S_IDLE;
                        end
                    end
                endcase
            end
        end
    end

endmodule
