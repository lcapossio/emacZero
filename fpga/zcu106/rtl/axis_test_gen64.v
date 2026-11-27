// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// axis_test_gen64.v - 64-bit AXIS test frame source for the 10G MAC
//
// Frame (len bytes, no FCS; the MAC adds it), udp = 0:
//   bytes 0-5   destination 02:00:00:00:00:01 (locally administered)
//   bytes 6-11  source      02:00:00:00:00:02
//   bytes 12-13 EtherType 0x88B5 (local experimental)
//   bytes 14-15 len, big endian
//   bytes 16-23 seq, ~seq (little endian); seq counts frames from 0
//   bytes 24-   64-bit xorshift words seeded from {seq, ~seq}, one per beat
// udp = 1, an IPv4 / UDP datagram between the same addresses:
//   bytes 0-11  as above, then EtherType 0x0800
//   bytes 14-33 IPv4 header: version 4, IHL 5, total length len - 14,
//               identification seq[15:0], DF, TTL 64, protocol 17, header
//               checksum, source 10.0.0.2, destination 10.0.0.1
//   bytes 34-41 UDP header: ports 5001 -> 5001, length len - 34, checksum 0
//               (none, as RFC 768 allows over IPv4)
//   bytes 42-47 seq (little endian), ~seq[31:16] (seq[15:0] is checked
//               against the identification, the rest against this)
//   bytes 48-   the xorshift words as above, one per beat
// The UDP payload is len - 42 bytes. len is clamped to 60..16000. With sweep
// set, the length steps by one byte per frame from 60 up to len and wraps,
// so every tkeep pattern and the whole range are exercised. ipg = idle
// cycles between frames (0 = back to back; the MAC still adds the line gap).
// udp and len are taken at the start of each frame. inj_err (a pulse) flips
// bit 0 of the next payload word, once: the MAC sends it with a good FCS,
// so only the checker's payload compare can catch it.
// Verilog 2001
// =============================================================================

module axis_test_gen64 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire [15:0] len,
    input  wire        sweep,
    input  wire        udp,
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

    // IPv4 header checksum: the constant words (0x4500, 0x4000, 0x4011,
    // 10.0.0.2, 10.0.0.1) sum to 0xD914; add total length and identification
    function [15:0] ip_csum;
        input [15:0] tl;
        input [15:0] id;
        reg   [17:0] s;
        reg   [16:0] f;
        begin
            s       = 18'h0D914 + {2'b00, tl} + {2'b00, id};
            f       = {1'b0, s[15:0]} + {15'd0, s[17:16]};
            ip_csum = ~(f[15:0] + {15'd0, f[16]});
        end
    endfunction

    wire [15:0] len_c = (len < 16'd60) ? 16'd60 : (len > 16'd16000) ? 16'd16000 : len;

    reg [15:0] flen;                 // this frame's length
    reg        fudp;                 // this frame is a UDP datagram
    reg [15:0] csum;                 // this frame's IPv4 header checksum
    reg [15:0] swp;                  // sweep length for the next frame
    reg [12:0] beat;                 // beat index of m_axis_* in this frame
    reg [12:0] nbeats;
    reg [31:0] seq;
    reg [63:0] prbs;
    reg        busy;
    reg [7:0]  gap;
    reg        inj_pend;

    wire take = m_axis_tvalid && m_axis_tready;

    // beat b (b <= the seq beat) of a frame of length l with sequence s
    function [63:0] beat_data;
        input [12:0] b;
        input [15:0] l;
        input [31:0] s;
        input        u;
        input [15:0] c;
        reg   [15:0] tl, ul;
        begin
            tl = l - 16'd14;
            ul = l - 16'd34;
            if (!u)
                case (b)
                    13'd0:   beat_data = {8'h00, 8'h02, 8'h01, 8'h00, 8'h00, 8'h00, 8'h00, 8'h02};
                    13'd1:   beat_data = {l[7:0], l[15:8], 8'hB5, 8'h88, 8'h02, 8'h00, 8'h00, 8'h00};
                    default: beat_data = {~s, s};
                endcase
            else
                case (b)
                    13'd0:   beat_data = {8'h00, 8'h02, 8'h01, 8'h00, 8'h00, 8'h00, 8'h00, 8'h02};
                    13'd1:   beat_data = {8'h00, 8'h45, 8'h00, 8'h08, 8'h02, 8'h00, 8'h00, 8'h00};
                    13'd2:   beat_data = {8'h11, 8'h40, 8'h00, 8'h40, s[7:0], s[15:8], tl[7:0], tl[15:8]};
                    13'd3:   beat_data = {8'h00, 8'h0A, 8'h02, 8'h00, 8'h00, 8'h0A, c[7:0], c[15:8]};
                    13'd4:   beat_data = {ul[7:0], ul[15:8], 8'h89, 8'h13, 8'h89, 8'h13, 8'h01, 8'h00};
                    default: beat_data = {~s[31:16], s, 16'h0000};
                endcase
        end
    endfunction

    // a sweep value above a lowered len restarts at 60, before it is used
    wire [15:0] swp_n    = (swp > len_c) ? 16'd60 : swp;
    wire [15:0] next_len = sweep ? swp_n : len_c;
    wire [12:0] next_nb  = next_len[15:3] + {12'd0, |next_len[2:0]};
    wire [12:0] seq_beat = fudp ? 13'd5 : 13'd2;   // last header beat
    wire [12:0] nxt      = beat + 13'd1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axis_tdata  <= 64'd0;
            m_axis_tkeep  <= 8'd0;
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
            frames        <= 32'd0;
            flen          <= 16'd60;
            fudp          <= 1'b0;
            csum          <= 16'd0;
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
                    fudp          <= udp;
                    csum          <= ip_csum(next_len - 16'd14, seq[15:0]);
                    nbeats        <= next_nb;
                    beat          <= 13'd0;
                    m_axis_tdata  <= beat_data(13'd0, next_len, seq, udp, 16'd0);
                    m_axis_tkeep  <= 8'hFF;
                    m_axis_tlast  <= 1'b0;
                    m_axis_tvalid <= 1'b1;
                    // each sweep starts at 60; fixed-length frames hold it there
                    swp           <= (!sweep || swp_n >= len_c) ? 16'd60 : swp_n + 16'd1;
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
                    beat         <= nxt;
                    m_axis_tlast <= (beat + 13'd2 == nbeats);
                    m_axis_tkeep <= (beat + 13'd2 == nbeats) ? keep_of(flen[2:0]) : 8'hFF;
                    if (nxt <= seq_beat) begin
                        m_axis_tdata <= beat_data(nxt, flen, seq, fudp, csum);
                        if (nxt == seq_beat)
                            prbs <= xs({seq, ~seq});
                    end else begin       // payload words
                        m_axis_tdata <= prbs ^ {63'd0, inj_pend};
                        prbs         <= xs(prbs);
                        if (inj_pend) inj_pend <= inj_err;
                    end
                end
            end
        end
    end

endmodule
