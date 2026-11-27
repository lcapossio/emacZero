// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// pcs10gbr_dec.v - 10GBASE-R 64b/66b decoder and receive state machine
//
// IEEE 802.3 clause 49.2.11 / 49.2.13. Takes descrambled 66-bit blocks
// (hdr, payload; formats as in pcs10gbr_enc.v) and produces 64-bit XGMII
// transfers (lane 0 in bits [7:0]).
//
// Each block is classified as C (control or ordered set: 0x1E, 0x2D, 0x4B,
// 0x55), S (start: 0x33, 0x66, 0x78), T (terminate: 0x87..0xFF), D (data) or
// E (anything else, including an invalid sync header, an unknown block type
// or an invalid control code). The receive state machine then checks the
// sequence:
//   INIT, C, T: C -> C, S -> D, else E
//   D:          D -> D, T followed by S or C -> T, else E
//   E:          C -> C, D -> D, T followed by S or C -> T, else E
// A block that breaks the sequence is replaced by an error block (every
// lane /E/). Without block lock, or with hi_ber, the output is a local fault
// ordered set in both halves and the machine returns to INIT.
//
// The T check needs the following block, so the decoder holds one block:
// a block is decoded and output when the next one arrives (en high).
// Verilog 2001
// =============================================================================

module pcs10gbr_dec (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,          // a new block on hdr / pay
    input  wire        block_lock,
    input  wire        hi_ber,
    input  wire [1:0]  hdr,
    input  wire [63:0] pay,
    output reg  [63:0] xgmii_d,
    output reg  [7:0]  xgmii_c,
    output reg         valid        // one cycle per output transfer
);

    localparam [1:0] SYNC_DATA = 2'b10;
    localparam [1:0] SYNC_CTRL = 2'b01;

    localparam [2:0] R_C = 3'd0, R_S = 3'd1, R_T = 3'd2, R_D = 3'd3, R_E = 3'd4;
    localparam [2:0] S_INIT = 3'd0, S_C = 3'd1, S_D = 3'd2, S_T = 3'd3, S_E = 3'd4;

    localparam [63:0] E_D = {8{8'hFE}};
    localparam [63:0] LF_D = 64'h0100_009C_0100_009C;   // local fault, both halves
    localparam [7:0]  LF_C = 8'h11;

    // 7-bit control code -> XGMII control character
    function code_ok;
        input [6:0] x;
        begin
            case (x)
                7'h00, 7'h06, 7'h1E, 7'h2D, 7'h33, 7'h4B, 7'h55, 7'h66, 7'h78:
                    code_ok = 1'b1;
                default: code_ok = 1'b0;
            endcase
        end
    endfunction

    function [7:0] xc;
        input [6:0] x;
        begin
            case (x)
                7'h00:   xc = 8'h07;
                7'h06:   xc = 8'h06;
                7'h2D:   xc = 8'h1C;
                7'h33:   xc = 8'h3C;
                7'h4B:   xc = 8'h7C;
                7'h55:   xc = 8'hBC;
                7'h66:   xc = 8'hDC;
                7'h78:   xc = 8'hF7;
                default: xc = 8'hFE;
            endcase
        end
    endfunction

    function o_valid;
        input [3:0] o;
        o_valid = (o == 4'h0) || (o == 4'hF);
    endfunction

    function [7:0] ox;
        input [3:0] o;
        ox = (o == 4'hF) ? 8'h5C : 8'h9C;
    endfunction

    // ---- Combinational decode of the incoming block ----
    reg  [63:0] d_n;
    reg  [7:0]  c_n;
    reg  [2:0]  r_n;
    reg  [7:0]  vok;        // control code of lane j valid
    reg  [63:0] xcs;        // XGMII characters for all 8 code positions
    integer j;
    wire [7:0] bt = pay[7:0];

    // lanes > k valid codes
    function hi_ok;
        input [7:0] v;
        input [3:0] kk;
        hi_ok = ((v | ~((8'hFF << kk) & 8'hFF)) == 8'hFF);
    endfunction

    always @* begin
        for (j = 0; j < 8; j = j + 1) begin
            vok[j]       = code_ok(pay[8 + 7*j +: 7]);
            xcs[8*j +: 8] = xc(pay[8 + 7*j +: 7]);
        end
        d_n = E_D;
        c_n = 8'hFF;
        r_n = R_E;
        if (hdr == SYNC_DATA) begin
            d_n = pay;
            c_n = 8'h00;
            r_n = R_D;
        end else if (hdr == SYNC_CTRL) begin
            case (bt)
                8'h1E: if (vok == 8'hFF) begin
                    d_n = xcs; c_n = 8'hFF; r_n = R_C;
                end
                8'h2D: if (vok[3:0] == 4'hF && o_valid(pay[39:36])) begin
                    d_n = {pay[63:40], ox(pay[39:36]), xcs[31:0]};
                    c_n = 8'h1F; r_n = R_C;
                end
                8'h33: if (vok[3:0] == 4'hF) begin
                    d_n = {pay[63:40], 8'hFB, xcs[31:0]};
                    c_n = 8'h1F; r_n = R_S;
                end
                8'h66: if (o_valid(pay[35:32])) begin
                    d_n = {pay[63:40], 8'hFB, pay[31:8], ox(pay[35:32])};
                    c_n = 8'h11; r_n = R_S;
                end
                8'h55: if (o_valid(pay[35:32]) && o_valid(pay[39:36])) begin
                    d_n = {pay[63:40], ox(pay[39:36]), pay[31:8], ox(pay[35:32])};
                    c_n = 8'h11; r_n = R_C;
                end
                8'h78: begin
                    d_n = {pay[63:8], 8'hFB};
                    c_n = 8'h01; r_n = R_S;
                end
                8'h4B: if (o_valid(pay[35:32]) && vok[7:4] == 4'hF) begin
                    d_n = {xcs[63:32], pay[31:8], ox(pay[35:32])};
                    c_n = 8'hF1; r_n = R_C;
                end
                8'h87: if (hi_ok(vok, 4'd1)) begin
                    d_n = {xcs[63:8], 8'hFD};
                    c_n = 8'hFF; r_n = R_T;
                end
                8'h99: if (hi_ok(vok, 4'd2)) begin
                    d_n = {xcs[63:16], 8'hFD, pay[15:8]};
                    c_n = 8'hFE; r_n = R_T;
                end
                8'hAA: if (hi_ok(vok, 4'd3)) begin
                    d_n = {xcs[63:24], 8'hFD, pay[23:8]};
                    c_n = 8'hFC; r_n = R_T;
                end
                8'hB4: if (hi_ok(vok, 4'd4)) begin
                    d_n = {xcs[63:32], 8'hFD, pay[31:8]};
                    c_n = 8'hF8; r_n = R_T;
                end
                8'hCC: if (hi_ok(vok, 4'd5)) begin
                    d_n = {xcs[63:40], 8'hFD, pay[39:8]};
                    c_n = 8'hF0; r_n = R_T;
                end
                8'hD2: if (hi_ok(vok, 4'd6)) begin
                    d_n = {xcs[63:48], 8'hFD, pay[47:8]};
                    c_n = 8'hE0; r_n = R_T;
                end
                8'hE1: if (hi_ok(vok, 4'd7)) begin
                    d_n = {xcs[63:56], 8'hFD, pay[55:8]};
                    c_n = 8'hC0; r_n = R_T;
                end
                8'hFF: begin
                    d_n = {8'hFD, pay[63:8]};
                    c_n = 8'h80; r_n = R_T;
                end
                default: ;
            endcase
            if (r_n == R_E) begin
                d_n = E_D;
                c_n = 8'hFF;
            end
        end
    end

    // ---- Held block and receive state machine ----
    reg [63:0] cur_d;
    reg [7:0]  cur_c;
    reg [2:0]  cur_r;
    reg        cur_v;
    reg [2:0]  st;

    wire nxt_sc = (r_n == R_S) || (r_n == R_C);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cur_d   <= LF_D;
            cur_c   <= LF_C;
            cur_r   <= R_E;
            cur_v   <= 1'b0;
            st      <= S_INIT;
            xgmii_d <= LF_D;
            xgmii_c <= LF_C;
            valid   <= 1'b0;
        end else begin
            valid <= 1'b0;
            if (!block_lock || hi_ber) begin
                st      <= S_INIT;
                cur_v   <= 1'b0;
                if (en) begin
                    xgmii_d <= LF_D;
                    xgmii_c <= LF_C;
                    valid   <= 1'b1;
                end
            end else if (en) begin
                cur_d <= d_n;
                cur_c <= c_n;
                cur_r <= r_n;
                cur_v <= 1'b1;
                valid <= 1'b1;
                if (!cur_v) begin
                    // first block after lock: nothing held yet
                    xgmii_d <= LF_D;
                    xgmii_c <= LF_C;
                end else begin
                    xgmii_d <= E_D;
                    xgmii_c <= 8'hFF;
                    case (st)
                        S_D: begin
                            if (cur_r == R_D) begin
                                xgmii_d <= cur_d; xgmii_c <= cur_c; st <= S_D;
                            end else if (cur_r == R_T && nxt_sc) begin
                                xgmii_d <= cur_d; xgmii_c <= cur_c; st <= S_T;
                            end else
                                st <= S_E;
                        end
                        S_E: begin
                            if (cur_r == R_C) begin
                                xgmii_d <= cur_d; xgmii_c <= cur_c; st <= S_C;
                            end else if (cur_r == R_D) begin
                                xgmii_d <= cur_d; xgmii_c <= cur_c; st <= S_D;
                            end else if (cur_r == R_T && nxt_sc) begin
                                xgmii_d <= cur_d; xgmii_c <= cur_c; st <= S_T;
                            end else
                                st <= S_E;
                        end
                        default: begin   // INIT, C, T
                            if (cur_r == R_C) begin
                                xgmii_d <= cur_d; xgmii_c <= cur_c; st <= S_C;
                            end else if (cur_r == R_S) begin
                                xgmii_d <= cur_d; xgmii_c <= cur_c; st <= S_D;
                            end else
                                st <= S_E;
                        end
                    endcase
                end
            end
        end
    end

endmodule
