// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// pcs10gbr_enc.v - 10GBASE-R 64b/66b encoder (IEEE 802.3 clause 49.2.4)
//
// Encodes one 64-bit XGMII transfer (8 lanes, lane 0 in bits [7:0] and first
// on the wire) into a 66-bit block: a 2-bit sync header and a 64-bit payload,
// both LSB first. hdr = 2'b10 (bit 0 = 0, bit 1 = 1, "01" in wire order) for
// a data block, 2'b01 for a control block. The payload is NOT scrambled here.
//
// Control block formats (block type in payload[7:0]):
//   0x1E C0..C7      0x2D C0..C3 O4 D5..D7   0x33 C0..C3 S4 D5..D7
//   0x66 O0 D1..D3 S4 D5..D7   0x55 O0 D1..D3 O4 D5..D7
//   0x78 S0 D1..D7   0x4B O0 D1..D3 C4..C7
//   0x87 T0 C1..C7   0x99 D0 T1 C2..C7   0xAA D0 D1 T2 C3..C7
//   0xB4 D0..D2 T3 C4..C7   0xCC D0..D3 T4 C5..C7   0xD2 D0..D4 T5 C6 C7
//   0xE1 D0..D5 T6 C7       0xFF D0..D6 T7
// The 7-bit control code of lane j is always at payload[8+7j +: 7]; the data
// octets of a terminate block start at payload[8]; an ordered-set O code is a
// 4-bit field at [35:32] (lane 0) or [39:36] (lane 4). Unused bits are 0.
//
// A transfer that matches none of the formats is sent as an error block
// (0x1E, every lane /E/). The output is registered and advances when en is
// high (the gearbox's ready).
// Verilog 2001
// =============================================================================

module pcs10gbr_enc (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,
    input  wire [63:0] xgmii_d,
    input  wire [7:0]  xgmii_c,
    output reg  [1:0]  hdr,
    output reg  [63:0] pay
);

    localparam [1:0] SYNC_DATA = 2'b10;
    localparam [1:0] SYNC_CTRL = 2'b01;

    localparam [7:0] X_S = 8'hFB;
    localparam [7:0] X_T = 8'hFD;

    // XGMII control character -> 7-bit 10GBASE-R control code
    function cc_ok;
        input [7:0] x;
        begin
            case (x)
                8'h07, 8'h06, 8'hFE, 8'h1C, 8'h3C, 8'h7C, 8'hBC, 8'hDC, 8'hF7:
                    cc_ok = 1'b1;
                default: cc_ok = 1'b0;
            endcase
        end
    endfunction

    function [6:0] cc7;
        input [7:0] x;
        begin
            case (x)
                8'h07:   cc7 = 7'h00;   // /I/ idle
                8'h06:   cc7 = 7'h06;   // LPI
                8'h1C:   cc7 = 7'h2D;   // reserved 0
                8'h3C:   cc7 = 7'h33;   // reserved 1
                8'h7C:   cc7 = 7'h4B;   // reserved 2
                8'hBC:   cc7 = 7'h55;   // reserved 3
                8'hDC:   cc7 = 7'h66;   // reserved 4
                8'hF7:   cc7 = 7'h78;   // reserved 5
                default: cc7 = 7'h1E;   // /E/ error
            endcase
        end
    endfunction

    // Ordered-set control character -> 4-bit O code
    function o_ok;
        input [7:0] x;
        o_ok = (x == 8'h9C) || (x == 8'h5C);
    endfunction

    function [3:0] o4;
        input [7:0] x;
        o4 = (x == 8'h5C) ? 4'hF : 4'h0;
    endfunction

    wire [7:0] l0 = xgmii_d[ 7: 0];
    wire [7:0] l1 = xgmii_d[15: 8];
    wire [7:0] l2 = xgmii_d[23:16];
    wire [7:0] l3 = xgmii_d[31:24];
    wire [7:0] l4 = xgmii_d[39:32];
    wire [7:0] l5 = xgmii_d[47:40];
    wire [7:0] l6 = xgmii_d[55:48];
    wire [7:0] l7 = xgmii_d[63:56];

    // ok[j]: lane j is a control character with a 7-bit code
    wire [7:0] ok = {xgmii_c[7] & cc_ok(l7), xgmii_c[6] & cc_ok(l6),
                     xgmii_c[5] & cc_ok(l5), xgmii_c[4] & cc_ok(l4),
                     xgmii_c[3] & cc_ok(l3), xgmii_c[2] & cc_ok(l2),
                     xgmii_c[1] & cc_ok(l1), xgmii_c[0] & cc_ok(l0)};

    // Control codes of all lanes at their block positions
    wire [55:0] codes = {cc7(l7), cc7(l6), cc7(l5), cc7(l4),
                         cc7(l3), cc7(l2), cc7(l1), cc7(l0)};

    // Terminate in lane k: lanes 0..k-1 data, lane k /T/, lanes k+1..7 coded
    // control. term[k] is set when that pattern matches.
    reg  [7:0]  term;
    integer k;
    always @* begin
        for (k = 0; k < 8; k = k + 1)
            term[k] = (xgmii_c == ((8'hFF << k) & 8'hFF)) &&
                      (xgmii_d[8*k +: 8] == X_T) &&
                      ((ok | ~((8'hFF << (k + 1)) & 8'hFF)) == 8'hFF);
    end

    // Mask of payload bits [63:8] holding control codes for lanes > k
    function [55:0] code_mask;
        input [2:0] kk;
        integer j;
        begin
            code_mask = 56'd0;
            for (j = 0; j < 8; j = j + 1)
                if (j > kk) code_mask[7*j +: 7] = 7'h7F;
        end
    endfunction

    reg [1:0]  h_n;
    reg [63:0] p_n;
    reg [55:0] dterm;
    integer t;

    always @* begin
        h_n   = SYNC_CTRL;
        p_n   = {{8{7'h1E}}, 8'h1E};   // error block
        dterm = 56'd0;
        if (xgmii_c == 8'h00) begin
            h_n = SYNC_DATA;
            p_n = xgmii_d;
        end else if (ok == 8'hFF) begin
            p_n = {codes, 8'h1E};
        end else if (xgmii_c == 8'h01 && l0 == X_S) begin
            p_n = {xgmii_d[63:8], 8'h78};
        end else if (xgmii_c == 8'h1F && ok[3:0] == 4'hF && l4 == X_S) begin
            p_n = {xgmii_d[63:40], 4'h0, codes[27:0], 8'h33};
        end else if (xgmii_c == 8'h1F && ok[3:0] == 4'hF && o_ok(l4)) begin
            p_n = {xgmii_d[63:40], o4(l4), codes[27:0], 8'h2D};
        end else if (xgmii_c == 8'h11 && o_ok(l0) && l4 == X_S) begin
            p_n = {xgmii_d[63:40], 4'h0, o4(l0), xgmii_d[31:8], 8'h66};
        end else if (xgmii_c == 8'h11 && o_ok(l0) && o_ok(l4)) begin
            p_n = {xgmii_d[63:40], o4(l4), o4(l0), xgmii_d[31:8], 8'h55};
        end else if (xgmii_c == 8'hF1 && o_ok(l0) && ok[7:4] == 4'hF) begin
            p_n = {codes[55:28], o4(l0), xgmii_d[31:8], 8'h4B};
        end else begin
            for (t = 0; t < 8; t = t + 1) begin
                if (term[t]) begin
                    // data octets 0..t-1 move up one byte, behind the type
                    dterm = xgmii_d[55:0] & ~({56{1'b1}} << (8 * t));
                    p_n[63:8] = dterm | (codes & code_mask(t[2:0]));
                    case (t)
                        0: p_n[7:0] = 8'h87;
                        1: p_n[7:0] = 8'h99;
                        2: p_n[7:0] = 8'hAA;
                        3: p_n[7:0] = 8'hB4;
                        4: p_n[7:0] = 8'hCC;
                        5: p_n[7:0] = 8'hD2;
                        6: p_n[7:0] = 8'hE1;
                        default: p_n[7:0] = 8'hFF;
                    endcase
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hdr <= SYNC_CTRL;
            pay <= {{8{7'h00}}, 8'h1E};   // idle block
        end else if (en) begin
            hdr <= h_n;
            pay <= p_n;
        end
    end

endmodule
