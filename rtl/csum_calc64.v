// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// csum_calc64.v - IPv4 / IPv6 / TCP / UDP / ICMP checksum engine, 8 bytes per
// clock (64-bit frame stream, tdata[7:0] = the first byte)
// Verilog 2001
// =============================================================================
// Watches Ethernet frames as 64-bit beats (beat 0 = frame bytes 0..7, no
// preamble, tkeep all ones except on the last beat) and computes the Internet
// checksums they carry. The 10G counterpart of rtl/net/csum_calc.v, shared by
// the TX inserter (tx_csum_off64) and the RX checker in eth_mac_sys_10g:
//
//   zero_fields = 1 (TX): the IPv4 header and L4 checksum fields are summed
//     as zero, so ~res_ip_sum / ~res_l4_sum are the values to insert.
//   zero_fields = 0 (RX): the fields are summed as received, so a correct
//     header / datagram folds to 16'hFFFF.
//
// Scope, as csum_calc.v:
//   - Ethernet II, optionally with one 802.1Q (0x8100) or 802.1ad (0x88A8)
//     tag; IPv4 with any IHL (header checksum); the IPv6 fixed header.
//   - L4 checksum for TCP (6), UDP (17) and ICMP (1) over IPv4, and TCP, UDP
//     and ICMPv6 (58) over IPv6, with the pseudo-header for all but ICMPv4.
//   - Sums cover the IP datagram only, [l3, l3_end) from the IPv4 total
//     length or the IPv6 payload length; UDP covers only its Length field's
//     bytes (RFC 768), which also go in its pseudo-header.
//   - No L4 checksum (res_l4_ok = 0) for IPv4 fragments, UDP whose Length is
//     below 8 or beyond the IP payload, IPv6 with extension headers, other
//     protocols, and IPv4 whose options hold a byte 0x83 or 0x89 anywhere.
//     The last differs from csum_calc.v, which walks the options for a loose
//     or strict source route (types 0x83 / 0x89) or a malformed length: eight
//     bytes a clock leave no time for the walk, so any such byte, option type
//     or not, leaves the L4 checksum to software. That covers every source
//     route, whatever the list around it; a list that cannot be walked but
//     holds neither byte is summed with the header's own destination.
// Every header start (14 or 18, plus IHL*4 or 40) is even, so a byte's weight
// in the 16-bit sum follows the parity of its frame offset, and every 16-bit
// field of interest lies within one beat.
//
// Results: one per frame, res_valid for one cycle LATENCY (6) cycles after
// the cycle in which the frame's last beat was presented, whatever the frame
// holds, in frame order, with in_tag as it was on that last beat. A new frame
// may start the cycle after a last beat.
//   res_done   an IP datagram in scope, whole within the frame
//   res_ip4    IPv4 header checksum applies and the header is within the frame
//   res_l4_ok  L4 checksum applies (implies res_done)
// Frames up to 2048 beats (16384 bytes); a longer frame gets no result flags.
//
// Pipeline: the header fields are parsed from each beat as it arrives (P);
// the beat is masked one cycle later (S1), against the fields parsed up to
// and including it, summed into the frame's accumulators (S2), and the
// accumulators are folded (F1..F4).
// =============================================================================

module csum_calc64 #(
    parameter TAG_W = 2
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire             zero_fields,  // static: 1 = TX, 0 = RX

    input  wire             in_valid,
    input  wire [63:0]      in_data,
    input  wire [7:0]       in_keep,
    input  wire             in_last,
    input  wire [TAG_W-1:0] in_tag,       // taken with the last beat

    output reg              res_valid,
    output reg  [TAG_W-1:0] res_tag,
    output reg              res_done,
    output reg              res_ip4,
    output reg  [15:0]      res_ip_sum,   // folded IPv4 header sum
    output reg  [13:0]      res_ip_pos,   // frame offset of the IPv4 csum MSB
    output reg              res_l4_ok,
    output reg              res_l4_udp,
    output reg  [15:0]      res_l4_sum,   // folded L4 sum incl. pseudo-header
    output reg  [13:0]      res_l4_pos,   // frame offset of the L4 csum MSB
    output reg  [15:0]      res_l4_field  // L4 checksum field as received
);

    // ---- helpers -------------------------------------------------------------
    // lanes of beat b at or past frame offset x
    function [7:0] ge8;
        input [10:0] b;
        input [14:0] x;
        integer      j;
        begin
            for (j = 0; j < 8; j = j + 1)
                ge8[j] = ({1'b0, b} > x[14:3]) || (({1'b0, b} == x[14:3]) && (j >= x[2:0]));
        end
    endfunction

    function [63:0] bytes_of;            // lane mask to byte mask
        input [7:0] m;
        integer     j;
        begin
            for (j = 0; j < 8; j = j + 1)
                bytes_of[8*j +: 8] = {8{m[j]}};
        end
    endfunction

    function [17:0] sum4;                // the beat's four 16-bit words
        input [63:0] x;
        begin
            sum4 = {2'b00, x[7:0],   x[15:8]}  + {2'b00, x[23:16], x[31:24]} +
                   {2'b00, x[39:32], x[47:40]} + {2'b00, x[55:48], x[63:56]};
        end
    endfunction

    function [3:0] ones8;
        input [7:0] k;
        integer     j;
        begin
            ones8 = 4'd0;
            for (j = 0; j < 8; j = j + 1)
                ones8 = ones8 + {3'd0, k[j]};
        end
    endfunction

    wire [7:0] B0 = in_data[7:0],   B1 = in_data[15:8],  B2 = in_data[23:16];
    wire [7:0] B3 = in_data[31:24], B4 = in_data[39:32], B5 = in_data[47:40];
    wire [7:0] B6 = in_data[55:48], B7 = in_data[63:56];

    // =========================================================================
    // P: header fields, parsed from the beats as they arrive
    // =========================================================================
    reg  [10:0] ib;                 // index of the next beat in its frame
    reg         ib_ovf;             // the frame is past 2048 beats
    wire        in_first = (ib == 11'd0) && !ib_ovf;

    reg         vlan;               // one tag seen; EtherType at 16-17
    reg         l3k;                // l3o known
    reg  [4:0]  l3o;                // 14 or 18
    reg         f4, f6;             // IPv4 / IPv6 (EtherType and version)
    reg  [5:0]  hlen;               // IPv4 IHL*4
    reg  [15:0] iplen;              // IPv4 total length / IPv6 payload length
    reg         frag;               // IPv4 MF or fragment offset != 0
    reg  [7:0]  proto;
    reg         l4p_ok;             // proto has an L4 checksum here
    reg         udp;
    reg  [4:0]  l4off;              // L4 checksum offset in the L4 header
    reg         lenok;              // l3e within the 2048 beats
    reg  [14:0] l3e;                // one past the datagram
    reg  [13:0] l4s;                // L4 header (one past the IPv4 header)
    reg  [14:0] l4e;                // one past the L4 bytes summed
    reg  [13:0] l4cp;               // L4 checksum field
    reg  [13:0] udpp;               // UDP Length field (l4s + 4)
    reg  [15:0] l4len;              // IP payload length
    reg  [15:0] udplen;

    // beat 1: EtherType at lanes 4-5; untagged, the IP header starts at lane 6
    wire [15:0] et1   = {B4, B5};
    wire        tag1  = (et1 == 16'h8100) || (et1 == 16'h88A8);
    // beat 2, tagged: EtherType at lanes 0-1, the IP header at lane 2
    wire [15:0] et2   = {B0, B1};
    wire        v4t   = (et2 == 16'h0800) && (B2[7:4] == 4'd4);
    wire        v6t   = (et2 == 16'h86DD) && (B2[7:4] == 4'd6);
    // beat 2: the length fields (the IHL too when tagged)
    wire        l_v4  = vlan ? v4t : f4;
    wire [4:0]  l_l3o = vlan ? 5'd18 : 5'd14;
    wire [5:0]  l_hl  = vlan ? {B2[3:0], 2'b00} : hlen;
    wire [15:0] l_il  = l_v4 ? (vlan ? {B4, B5} : {B0, B1})
                             : (vlan ? {B6, B7} : {B2, B3});
    wire [16:0] l_end = l_v4 ? {12'd0, l_l3o} + {1'b0, l_il}
                             : {12'd0, l_l3o} + 17'd40 + {1'b0, l_il};
    wire        l_cap = (ib == 11'd2) && !ib_ovf && (vlan || l3k);

    // the protocol: beat 2 untagged, beat 3 tagged
    wire        p_cap = !ib_ovf && (vlan ? (ib == 11'd3) : (ib == 11'd2)) &&
                        l3k && (f4 || f6);
    wire [7:0]  p_now = f4 ? (vlan ? B3 : B7) : (vlan ? B0 : B4);
    wire [7:0]  p_frg = vlan ? B0 : B4;          // IPv4 flags / offset bytes
    wire [7:0]  p_fr2 = vlan ? B1 : B5;
    reg  [4:0]  p_off;
    reg         p_ok;
    always @* begin
        p_ok = 1'b1;
        case (p_now)
            8'd6:    p_off = 5'd16;                  // TCP
            8'd17:   p_off = 5'd6;                   // UDP
            8'd1:    begin p_off = 5'd2; p_ok = f4; end   // ICMP
            8'd58:   begin p_off = 5'd2; p_ok = f6; end   // ICMPv6
            default: begin p_off = 5'd0; p_ok = 1'b0; end
        endcase
    end

    // the UDP Length: at l4s + 4, lane 2 or 6 of its beat
    wire        u_cap = !ib_ovf && udp && lenok && l3k && (f4 || f6) &&
                        (ib == udpp[13:3]);
    wire [15:0] u_now = udpp[2] ? {B6, B7} : {B2, B3};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ib     <= 11'd0;
            ib_ovf <= 1'b0;
            vlan   <= 1'b0;
            l3k    <= 1'b0;
            l3o    <= 5'd14;
            f4     <= 1'b0;
            f6     <= 1'b0;
            hlen   <= 6'd20;
            iplen  <= 16'd0;
            frag   <= 1'b0;
            proto  <= 8'd0;
            l4p_ok <= 1'b0;
            udp    <= 1'b0;
            l4off  <= 5'd0;
            lenok  <= 1'b0;
            l3e    <= 15'd0;
            l4s    <= 14'h3FFF;
            l4e    <= 15'd0;
            l4cp   <= 14'h3FFF;
            udpp   <= 14'h3FFF;
            l4len  <= 16'd0;
            udplen <= 16'd0;
        end else if (in_valid) begin
            if (in_last) begin
                ib     <= 11'd0;
                ib_ovf <= 1'b0;
            end else if (ib == 11'h7FF) begin
                ib_ovf <= 1'b1;
            end else begin
                ib <= ib + 11'd1;
            end

            if (in_first) begin
                // beat 0 is addresses only: start the frame afresh
                vlan   <= 1'b0;
                l3k    <= 1'b0;
                l3o    <= 5'd14;
                f4     <= 1'b0;
                f6     <= 1'b0;
                hlen   <= 6'd20;
                iplen  <= 16'd0;
                frag   <= 1'b0;
                proto  <= 8'd0;
                l4p_ok <= 1'b0;
                udp    <= 1'b0;
                l4off  <= 5'd0;
                lenok  <= 1'b0;
                l3e    <= 15'd0;
                l4s    <= 14'h3FFF;
                l4e    <= 15'd0;
                l4cp   <= 14'h3FFF;
                udpp   <= 14'h3FFF;
                l4len  <= 16'd0;
                udplen <= 16'd0;
            end

            if (ib == 11'd1 && !ib_ovf) begin
                if (tag1) begin
                    vlan <= 1'b1;
                end else begin
                    l3k  <= 1'b1;
                    l3o  <= 5'd14;
                    f4   <= (et1 == 16'h0800) && (B6[7:4] == 4'd4);
                    f6   <= (et1 == 16'h86DD) && (B6[7:4] == 4'd6);
                    hlen <= {B6[3:0], 2'b00};
                    l4s  <= (et1 == 16'h86DD) ? 14'd54 : 14'd14 + {8'd0, B6[3:0], 2'b00};
                    udpp <= (et1 == 16'h86DD) ? 14'd58 : 14'd18 + {8'd0, B6[3:0], 2'b00};
                end
            end

            if (ib == 11'd2 && !ib_ovf && vlan) begin
                l3k  <= 1'b1;
                l3o  <= 5'd18;
                f4   <= v4t;
                f6   <= v6t;
                hlen <= {B2[3:0], 2'b00};
                l4s  <= v6t ? 14'd58 : 14'd18 + {8'd0, B2[3:0], 2'b00};
                udpp <= v6t ? 14'd62 : 14'd22 + {8'd0, B2[3:0], 2'b00};
            end

            if (l_cap) begin
                iplen <= l_il;
                lenok <= (l_end <= 17'h04000);
                l3e   <= l_end[14:0];
                l4e   <= l_end[14:0];
                l4len <= l_v4 ? l_il - {10'd0, l_hl} : l_il;
            end

            if (p_cap) begin
                proto  <= p_now;
                l4p_ok <= p_ok;
                udp    <= (p_now == 8'd17);
                l4off  <= p_off;
                l4cp   <= l4s + {9'd0, p_off};
                if (f4)
                    frag <= p_frg[5] || (p_frg[4:0] != 5'd0) || (p_fr2 != 8'd0);
            end

            if (u_cap) begin
                udplen <= u_now;
                if (u_now >= 16'd8 && u_now <= l4len)
                    l4e <= {1'b0, l4s} + u_now[14:0];
            end
        end
    end

    // =========================================================================
    // S1: mask the beat against the fields parsed up to and including it
    // =========================================================================
    reg              s1_v, s1_last, s1_first, s1_ovf;
    reg  [10:0]      s1_b;
    reg  [63:0]      s1_d;
    reg  [7:0]       s1_k;
    reg  [TAG_W-1:0] s1_tag;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_v     <= 1'b0;
            s1_last  <= 1'b0;
            s1_first <= 1'b0;
            s1_ovf   <= 1'b0;
            s1_b     <= 11'd0;
            s1_d     <= 64'd0;
            s1_k     <= 8'd0;
            s1_tag   <= {TAG_W{1'b0}};
        end else begin
            s1_v <= in_valid;
            if (in_valid) begin
                s1_last  <= in_last;
                s1_first <= in_first;
                s1_ovf   <= ib_ovf;
                s1_b     <= ib;
                s1_d     <= in_data;
                s1_k     <= in_keep;
                s1_tag   <= in_tag;
            end
        end
    end

    wire        l3ok  = l3k && (f4 || f6);
    wire [13:0] l3o14 = {9'd0, l3o};
    wire [13:0] ph_lo = f4 ? l3o14 + 14'd12 : l3o14 + 14'd8;
    wire [13:0] ph_hi = f4 ? l3o14 + 14'd20 : l3o14 + 14'd40;

    wire [7:0] m_ip  = (l3k && f4) ? (ge8(s1_b, l3o14) & ~ge8(s1_b, l4s)) : 8'h00;
    wire [7:0] m_ipf = (zero_fields && l3k && f4)
                       ? (ge8(s1_b, l3o14 + 14'd10) & ~ge8(s1_b, l3o14 + 14'd12)) : 8'h00;
    wire [7:0] m_ph  = l3ok ? (ge8(s1_b, ph_lo) & ~ge8(s1_b, ph_hi)) : 8'h00;
    wire [7:0] m_l4  = (l3ok && lenok) ? (ge8(s1_b, l4s) & ~ge8(s1_b, l4e)) : 8'h00;
    wire [7:0] m_l4f = zero_fields ? (ge8(s1_b, l4cp) & ~ge8(s1_b, l4cp + 14'd2)) : 8'h00;
    wire [7:0] m_opt = (l3k && f4) ? (ge8(s1_b, l3o14 + 14'd20) & ~ge8(s1_b, l4s)) : 8'h00;

    // an option byte 0x83 / 0x89 (see header)
    reg [7:0] opt_lane;
    integer   oj;
    always @* begin
        for (oj = 0; oj < 8; oj = oj + 1)
            opt_lane[oj] = m_opt[oj] && (s1_d[8*oj +: 8] == 8'h83 ||
                                         s1_d[8*oj +: 8] == 8'h89);
    end
    wire        opt_now = |opt_lane;

    // the L4 checksum field as received (an even lane)
    wire        fld_hit = (s1_b == l4cp[13:3]);
    wire [15:0] fld_now = (l4cp[2:1] == 2'd0) ? {s1_d[7:0],   s1_d[15:8]}  :
                          (l4cp[2:1] == 2'd1) ? {s1_d[23:16], s1_d[31:24]} :
                          (l4cp[2:1] == 2'd2) ? {s1_d[39:32], s1_d[47:40]} :
                                                {s1_d[55:48], s1_d[63:56]};

    // per-frame flags gathered at S1
    reg         opt_r, ovf_r;
    reg  [15:0] fld_r;
    wire        opt_all = (s1_first ? 1'b0 : opt_r) || opt_now;
    wire        ovf_all = (s1_first ? 1'b0 : ovf_r) || s1_ovf;
    wire [15:0] fld_all = fld_hit ? fld_now : (s1_first ? 16'd0 : fld_r);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            opt_r <= 1'b0;
            ovf_r <= 1'b0;
            fld_r <= 16'd0;
        end else if (s1_v) begin
            opt_r <= opt_all;
            ovf_r <= ovf_all;
            fld_r <= fld_all;
        end
    end

    // frame verdicts, taken with the last beat (P still holds this frame:
    // a next frame's first beat changes it only at the end of this cycle)
    wire [14:0] flen      = {s1_b, 3'b000} + {11'd0, ones8(s1_k)};
    wire        struct4   = f4 && l3k && (hlen >= 6'd20) && (iplen >= {10'd0, hlen});
    wire        struct_ok = lenok && (struct4 || (f6 && l3k));
    wire        udp_ok    = (udplen >= 16'd8) && (udplen <= l4len);
    wire        l4_able   = struct_ok && l4p_ok && !(f4 && (frag || opt_all)) &&
                            (l4len >= {11'd0, l4off} + 16'd2) && (!udp || udp_ok);
    wire        v_done    = struct_ok && (l3e <= flen) && !ovf_all;
    wire        v_ip4     = struct4 && ({1'b0, l4s} <= flen) && !ovf_all;

    // =========================================================================
    // S2: sum the masked beat into the frame's accumulators
    // =========================================================================
    reg              s2_v, s2_first, s2_last;
    reg  [63:0]      s2_ip, s2_ph, s2_l4;
    // frame context, from the last beat at S1
    reg              c2_done, c2_ip4, c2_l4ok, c2_udp, c2_useph;
    reg  [7:0]       c2_proto;
    reg  [15:0]      c2_phlen, c2_fld;
    reg  [13:0]      c2_ippos, c2_l4pos;
    reg  [TAG_W-1:0] c2_tag;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_v     <= 1'b0;
            s2_first <= 1'b0;
            s2_last  <= 1'b0;
            s2_ip    <= 64'd0;
            s2_ph    <= 64'd0;
            s2_l4    <= 64'd0;
            c2_done  <= 1'b0;
            c2_ip4   <= 1'b0;
            c2_l4ok  <= 1'b0;
            c2_udp   <= 1'b0;
            c2_useph <= 1'b0;
            c2_proto <= 8'd0;
            c2_phlen <= 16'd0;
            c2_fld   <= 16'd0;
            c2_ippos <= 14'd0;
            c2_l4pos <= 14'd0;
            c2_tag   <= {TAG_W{1'b0}};
        end else begin
            s2_v <= s1_v;
            if (s1_v) begin
                s2_first <= s1_first;
                s2_last  <= s1_last;
                s2_ip    <= s1_d & bytes_of(m_ip & ~m_ipf);
                s2_ph    <= s1_d & bytes_of(m_ph);
                s2_l4    <= s1_d & bytes_of(m_l4 & ~m_l4f);
            end
            if (s1_v && s1_last) begin
                c2_done  <= v_done;
                c2_ip4   <= v_ip4;
                c2_l4ok  <= v_done && l4_able;
                c2_udp   <= udp;
                c2_useph <= f6 || (proto != 8'd1);
                c2_proto <= proto;
                c2_phlen <= udp ? udplen : l4len;
                c2_fld   <= fld_all;
                c2_ippos <= l3o14 + 14'd10;
                c2_l4pos <= l4cp;
                c2_tag   <= s1_tag;
            end
        end
    end

    wire [17:0] w_ip = sum4(s2_ip);
    wire [17:0] w_ph = sum4(s2_ph);
    wire [17:0] w_l4 = sum4(s2_l4);
    reg  [23:0] ip_acc, ph_acc;
    reg  [31:0] l4_acc;
    wire [23:0] ip_new = (s2_first ? 24'd0 : ip_acc) + {6'd0, w_ip};
    wire [23:0] ph_new = (s2_first ? 24'd0 : ph_acc) + {6'd0, w_ph};
    wire [31:0] l4_new = (s2_first ? 32'd0 : l4_acc) + {14'd0, w_l4};

    // =========================================================================
    // F1..F4: totals, pseudo-header, folds
    // =========================================================================
    reg              f1_v, f2_v, f3_v;
    reg  [23:0]      f1_ip, f1_ph;
    reg  [31:0]      f1_l4, f2_l4;
    reg  [16:0]      f2_ip, f3_l4;
    reg  [15:0]      f3_ip;
    reg              c3_done, c3_ip4, c3_l4ok, c3_udp, c3_useph;
    reg  [7:0]       c3_proto;
    reg  [15:0]      c3_phlen, c3_fld;
    reg  [13:0]      c3_ippos, c3_l4pos;
    reg  [TAG_W-1:0] c3_tag;
    reg              c4_done, c4_ip4, c4_l4ok, c4_udp;
    reg  [15:0]      c4_fld;
    reg  [13:0]      c4_ippos, c4_l4pos;
    reg  [TAG_W-1:0] c4_tag;
    reg              c5_done, c5_ip4, c5_l4ok, c5_udp;
    reg  [15:0]      c5_fld;
    reg  [13:0]      c5_ippos, c5_l4pos;
    reg  [TAG_W-1:0] c5_tag;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ip_acc <= 24'd0;
            ph_acc <= 24'd0;
            l4_acc <= 32'd0;
            f1_v   <= 1'b0;
            f2_v   <= 1'b0;
            f3_v   <= 1'b0;
            f1_ip  <= 24'd0;
            f1_ph  <= 24'd0;
            f1_l4  <= 32'd0;
            f2_l4  <= 32'd0;
            f2_ip  <= 17'd0;
            f3_l4  <= 17'd0;
            f3_ip  <= 16'd0;
            c3_done <= 1'b0; c3_ip4 <= 1'b0; c3_l4ok <= 1'b0; c3_udp <= 1'b0;
            c3_useph <= 1'b0; c3_proto <= 8'd0; c3_phlen <= 16'd0; c3_fld <= 16'd0;
            c3_ippos <= 14'd0; c3_l4pos <= 14'd0; c3_tag <= {TAG_W{1'b0}};
            c4_done <= 1'b0; c4_ip4 <= 1'b0; c4_l4ok <= 1'b0; c4_udp <= 1'b0;
            c4_fld <= 16'd0; c4_ippos <= 14'd0; c4_l4pos <= 14'd0;
            c4_tag <= {TAG_W{1'b0}};
            c5_done <= 1'b0; c5_ip4 <= 1'b0; c5_l4ok <= 1'b0; c5_udp <= 1'b0;
            c5_fld <= 16'd0; c5_ippos <= 14'd0; c5_l4pos <= 14'd0;
            c5_tag <= {TAG_W{1'b0}};
            res_valid    <= 1'b0;
            res_tag      <= {TAG_W{1'b0}};
            res_done     <= 1'b0;
            res_ip4      <= 1'b0;
            res_ip_sum   <= 16'd0;
            res_ip_pos   <= 14'd0;
            res_l4_ok    <= 1'b0;
            res_l4_udp   <= 1'b0;
            res_l4_sum   <= 16'd0;
            res_l4_pos   <= 14'd0;
            res_l4_field <= 16'd0;
        end else begin
            if (s2_v) begin
                ip_acc <= ip_new;
                ph_acc <= ph_new;
                l4_acc <= l4_new;
            end

            // F1: the frame's totals
            f1_v <= s2_v && s2_last;
            if (s2_v && s2_last) begin
                f1_ip    <= ip_new;
                f1_ph    <= ph_new;
                f1_l4    <= l4_new;
                c3_done  <= c2_done;
                c3_ip4   <= c2_ip4;
                c3_l4ok  <= c2_l4ok;
                c3_udp   <= c2_udp;
                c3_useph <= c2_useph;
                c3_proto <= c2_proto;
                c3_phlen <= c2_phlen;
                c3_fld   <= c2_fld;
                c3_ippos <= c2_ippos;
                c3_l4pos <= c2_l4pos;
                c3_tag   <= c2_tag;
            end

            // F2: add the pseudo-header; first fold of the IPv4 sum
            f2_v <= f1_v;
            if (f1_v) begin
                f2_l4    <= f1_l4 + (c3_useph ? {8'd0, f1_ph} + {24'd0, c3_proto} +
                                                {16'd0, c3_phlen}
                                              : 32'd0);
                f2_ip    <= {1'b0, f1_ip[15:0]} + {9'd0, f1_ip[23:16]};
                c4_done  <= c3_done;
                c4_ip4   <= c3_ip4;
                c4_l4ok  <= c3_l4ok;
                c4_udp   <= c3_udp;
                c4_fld   <= c3_fld;
                c4_ippos <= c3_ippos;
                c4_l4pos <= c3_l4pos;
                c4_tag   <= c3_tag;
            end

            // F3: first fold of the L4 sum; final fold of the IPv4 sum
            f3_v <= f2_v;
            if (f2_v) begin
                f3_l4    <= {1'b0, f2_l4[15:0]} + {1'b0, f2_l4[31:16]};
                f3_ip    <= f2_ip[15:0] + {15'd0, f2_ip[16]};
                c5_done  <= c4_done;
                c5_ip4   <= c4_ip4;
                c5_l4ok  <= c4_l4ok;
                c5_udp   <= c4_udp;
                c5_fld   <= c4_fld;
                c5_ippos <= c4_ippos;
                c5_l4pos <= c4_l4pos;
                c5_tag   <= c4_tag;
            end

            // F4: final fold of the L4 sum; results
            res_valid <= f3_v;
            if (f3_v) begin
                res_l4_sum   <= f3_l4[15:0] + {15'd0, f3_l4[16]};
                res_ip_sum   <= f3_ip;
                res_done     <= c5_done;
                res_ip4      <= c5_ip4;
                res_l4_ok    <= c5_l4ok;
                res_l4_udp   <= c5_udp;
                res_l4_field <= c5_fld;
                res_ip_pos   <= c5_ippos;
                res_l4_pos   <= c5_l4pos;
                res_tag      <= c5_tag;
            end
        end
    end

endmodule
