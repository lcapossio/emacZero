// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// axis_test_gen64.v - 64-bit AXIS test frame source for the 10G MAC
//
// Frame (len bytes, no FCS; the MAC adds it):
//   bytes 0-5   destination 02:00:00:00:00:01 (locally administered)
//   bytes 6-11  source      02:00:00:00:00:02
//   bytes 12-13 EtherType 0x88B5 (local experimental)
//   bytes 14-15 len, big endian
//   bytes 16-23 seq, ~seq (little endian); seq counts frames from 0
//   bytes 24-   64-bit xorshift words seeded from {seq, ~seq}, one per beat
// len is clamped to 60..16000. With sweep set, the length steps by one byte
// per frame from 60 up to len and wraps, so every tkeep pattern and the
// whole range are exercised. ipg = idle cycles between frames (0 = back to
// back; the MAC still adds the line gap). inj_err (a pulse) flips bit 0 of
// the next payload word, once: the MAC sends it with a good FCS, so only the
// checker's payload compare can catch it.
// Verilog 2001
// =============================================================================

module axis_test_gen64 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire [15:0] len,
    input  wire        sweep,
    input  wire [7:0]  ipg,
    input  wire        inj_err,

    output reg  [63:0] m_axis_tdata,
    output reg  [7:0]  m_axis_tkeep,
    output reg         m_axis_tvalid,
    output reg         m_axis_tlast,
    input  wire        m_axis_tready,

    output reg  [31:0] frames
);

    function [63:0] xs;
        input [63:0] s;
        reg   [63:0] t;
        begin
            t  = s ^ (s << 13);
            t  = t ^ (t >> 7);
            xs = t ^ (t << 17);
        end
    endfunction

    function [7:0] keep_of;          // tkeep of the last beat of n bytes
        input [2:0] r;               // n mod 8
        begin
            keep_of = (r == 3'd0) ? 8'hFF : ((8'h01 << r) - 8'h01);
        end
    endfunction

    wire [15:0] len_c = (len < 16'd60) ? 16'd60 : (len > 16'd16000) ? 16'd16000 : len;

    reg [15:0] flen;                 // this frame's length
    reg [15:0] swp;                  // sweep length for the next frame
    reg [12:0] beat;                 // beat index of m_axis_* in this frame
    reg [12:0] nbeats;
    reg [31:0] seq;
    reg [63:0] prbs;
    reg        busy;
    reg [7:0]  gap;
    reg        inj_pend;

    wire take = m_axis_tvalid && m_axis_tready;

    // beat b of a frame of length l with sequence s and payload word p
    function [63:0] beat_data;
        input [12:0] b;
        input [15:0] l;
        input [31:0] s;
        input [63:0] p;
        begin
            case (b)
                13'd0:   beat_data = {8'h00, 8'h02, 8'h01, 8'h00, 8'h00, 8'h00, 8'h00, 8'h02};
                13'd1:   beat_data = {l[7:0], l[15:8], 8'hB5, 8'h88, 8'h02, 8'h00, 8'h00, 8'h00};
                13'd2:   beat_data = {~s, s};
                default: beat_data = p;
            endcase
        end
    endfunction

    wire [15:0] next_len = sweep ? swp : len_c;
    wire [12:0] next_nb  = next_len[15:3] + {12'd0, |next_len[2:0]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axis_tdata  <= 64'd0;
            m_axis_tkeep  <= 8'd0;
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
            frames        <= 32'd0;
            flen          <= 16'd60;
            swp           <= 16'd60;
            beat          <= 13'd0;
            nbeats        <= 13'd0;
            seq           <= 32'd0;
            prbs          <= 64'd0;
            busy          <= 1'b0;
            gap           <= 8'd0;
            inj_pend      <= 1'b0;
        end else begin
            if (inj_err) inj_pend <= 1'b1;

            if (!busy) begin
                if (gap != 8'd0) begin
                    gap <= gap - 8'd1;
                end else if (enable) begin
                    // first beat of a new frame
                    busy          <= 1'b1;
                    flen          <= next_len;
                    nbeats        <= next_nb;
                    beat          <= 13'd0;
                    m_axis_tdata  <= beat_data(13'd0, next_len, seq, 64'd0);
                    m_axis_tkeep  <= 8'hFF;
                    m_axis_tlast  <= 1'b0;
                    m_axis_tvalid <= 1'b1;
                    swp           <= (swp >= len_c) ? 16'd60 : swp + 16'd1;
                end
            end else if (take) begin
                if (m_axis_tlast) begin
                    busy          <= 1'b0;
                    m_axis_tvalid <= 1'b0;
                    m_axis_tlast  <= 1'b0;
                    frames        <= frames + 32'd1;
                    seq           <= seq + 32'd1;
                    gap           <= ipg;
                end else begin
                    beat         <= beat + 13'd1;
                    m_axis_tlast <= (beat + 13'd2 == nbeats);
                    m_axis_tkeep <= (beat + 13'd2 == nbeats) ? keep_of(flen[2:0]) : 8'hFF;
                    case (beat)
                        13'd0: m_axis_tdata <= beat_data(13'd1, flen, seq, 64'd0);
                        13'd1: begin
                            m_axis_tdata <= beat_data(13'd2, flen, seq, 64'd0);
                            prbs         <= xs({seq, ~seq});
                        end
                        default: begin   // payload words
                            m_axis_tdata <= prbs ^ {63'd0, inj_pend};
                            prbs         <= xs(prbs);
                            if (inj_pend) inj_pend <= inj_err;
                        end
                    endcase
                end
            end
        end
    end

endmodule
