// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// csum_calc.v - IPv4 / IPv6 / TCP / UDP / ICMP checksum engine (byte stream)
// Verilog 2001
// =============================================================================
// Watches one Ethernet frame as a byte stream (frame byte 0 = first dst-MAC
// byte, no preamble) and computes the Internet checksums it carries. Shared by
// the TX inserter (tx_csum_off) and the RX checker (eth_mac_rx):
//
//   zero_fields = 1 (TX): the IPv4 header checksum and L4 checksum fields are
//     summed as zero, so ~ip_sum / ~l4_sum are the values to insert.
//   zero_fields = 0 (RX): the fields are summed as received, so a correct
//     header / segment folds to 16'hFFFF.
//
// Recognised frames:
//   - Ethernet II, optionally with one 802.1Q (0x8100) or 802.1ad (0x88A8) tag.
//   - IPv4 with any IHL (options included): header checksum.
//   - IPv6 fixed header (no header checksum exists).
//   - L4 checksum for TCP (6), UDP (17) and ICMP (1) over IPv4, and TCP, UDP
//     and ICMPv6 (58) over IPv6, with the pseudo-header for all but ICMPv4.
//
// Not covered (done = 1, l4_ok = 0, so callers leave the L4 field alone):
//   - IPv4 fragments (MF set or offset != 0): the L4 checksum spans the whole
//     reassembled datagram.
//   - IPv4 with a loose or strict source route option (LSRR 0x83, SSRR 0x89)
//     or a malformed option (length < 2): the pseudo-header destination may
//     be the route's final hop, not the header's destination field.
//   - UDP whose Length field is below 8 or beyond the IP payload.
//   - IPv6 with extension headers (next header not 6/17/58 directly).
//   - Other L4 protocols.
// Frames that are not IP, are malformed (IHL < 5, total length shorter than
// the header) or carry a second VLAN tag never raise done.
//
// Sums cover the IP datagram only: [l3, l3_end), where l3_end comes from the
// IPv4 total length or IPv6 payload length. Ethernet padding and the FCS are
// ignored. UDP covers only its Length field's bytes (RFC 768), which may be
// fewer than the IP payload, and that length goes in its pseudo-header; the
// other protocols use the IP-derived L4 length. Every header start (14 or 18,
// plus IHL*4 or 40) is even, so a byte's weight in the 16-bit sum follows the
// parity of its frame offset.
//
// Timing:
//   - ip4 / ip_sum are final 2 cycles after the IPv4 header's last byte, at
//     frame offset hdr_end - 1, whether or not the rest of the datagram
//     arrives. A caller that also feeds trailing bytes (RX feeds the FCS)
//     must check that hdr_end is inside the real data.
//   - Everything else is final, and done rises, 3 cycles after the
//     datagram's last byte. done stays high until the next frame
//     (in_idx == 0). An incomplete datagram never raises done.
// =============================================================================

module csum_calc (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        in_valid,      // one frame byte this cycle
    input  wire [13:0] in_idx,        // its frame offset; 0 starts a new frame
    input  wire [7:0]  in_data,
    input  wire        zero_fields,   // 1 = sum checksum fields as zero (TX)

    output reg         done,          // results below are valid
    output reg  [13:0] l3_end,        // frame offset one past the datagram
    output reg         ip4,           // IPv4 header checksum applies (see Timing)
    output reg  [15:0] ip_sum,        // folded IPv4 header sum
    output wire [13:0] hdr_end,       // frame offset one past the IPv4 header
    output reg  [13:0] ip_csum_pos,   // frame offset of the IPv4 csum MSB
    output reg         l4_ok,         // L4 checksum applies
    output reg         l4_udp,        // ... and the L4 protocol is UDP
    output reg  [15:0] l4_sum,        // folded L4 sum incl. pseudo-header
    output reg  [13:0] l4_csum_pos,   // frame offset of the L4 csum MSB
    output reg  [15:0] l4_field       // L4 checksum field as received
);

    // ---- Per-frame parse state ---------------------------------------------
    reg  [7:0]  etype_hi;        // byte 12 (or 16 after a tag)
    reg         vlan;            // one tag seen; real EtherType at 16-17
    reg         l3_known;        // l3_off valid
    reg  [4:0]  l3_off;          // 14 or 18
    reg         fam4;            // EtherType 0x0800 and version 4
    reg         fam6;            // EtherType 0x86DD and version 6
    reg  [5:0]  hdr_len;         // IPv4: IHL*4 (20 until byte 0 is seen)
    reg  [15:0] ip_len;          // IPv4 total length / IPv6 payload length
    reg         frag;            // IPv4 MF or fragment offset != 0
    reg  [7:0]  proto;           // IPv4 protocol / IPv6 next header
    reg         len_ok;          // l3_end computed and within 14 bits
    reg  [13:0] l4_start;        // also one past the IPv4 header
    reg  [15:0] l4_len;          // IP payload length
    reg  [13:0] l4_end;          // one past the L4 bytes summed
    reg  [7:0]  udp_len_hi;
    reg  [15:0] udp_len;         // UDP Length field

    // IPv4 option walk (RFC 791): EOL ends the list, NOP is one byte, every
    // other option is type, length, data.
    reg  [8:0]  opt_pos;         // header offset of the next option type
    reg         opt_len_nx;      // this byte is an option's length
    reg         opt_end;         // EOL or malformed: stop walking
    reg         opt_skip;        // source route or malformed: no L4 checksum

    reg  [23:0] ip_acc;          // IPv4 header
    reg  [23:0] ph_acc;          // pseudo-header addresses
    reg  [31:0] l4_acc;          // L4 header + payload

    // Offset of this byte within the L3 header (valid once l3_known)
    wire [13:0] r = in_idx - {9'd0, l3_off};

    // 16-bit word weight of this byte: even frame offsets are the MSB
    wire [15:0] w = in_idx[0] ? {8'h00, in_data} : {in_data, 8'h00};

    // L4 checksum field offset within the L4 header for this protocol
    reg  [4:0]  l4_off;
    reg         l4_proto_ok;
    always @* begin
        l4_proto_ok = 1'b1;
        case (proto)
            8'd6:    l4_off = 5'd16;                 // TCP
            8'd17:   l4_off = 5'd6;                  // UDP
            8'd1:    begin l4_off = 5'd2;            // ICMP (IPv4 only)
                           l4_proto_ok = fam4; end
            8'd58:   begin l4_off = 5'd2;            // ICMPv6 (IPv6 only)
                           l4_proto_ok = fam6; end
            default: begin l4_off = 5'd0; l4_proto_ok = 1'b0; end
        endcase
    end

    wire in_l3   = l3_known && (fam4 || fam6);
    wire in_ip4h = in_l3 && fam4 && (r < {8'd0, hdr_len});
    wire in_ph   = in_l3 && (fam4 ? (r >= 14'd12 && r < 14'd20)
                                  : (r >= 14'd8  && r < 14'd40));
    wire in_l4   = in_l3 && len_ok && (in_idx >= l4_start) &&
                   (in_idx < l4_end) && (in_idx < l3_end);
    wire is_ipf  = fam4 && (r == 14'd10 || r == 14'd11);
    wire is_l4f  = (in_idx == l4_csum_pos) || (in_idx == l4_csum_pos + 14'd1);
    wire last    = in_l3 && len_ok && (in_idx == l3_end - 14'd1);
    wire hdr_last = in_ip4h && (r == {8'd0, hdr_len} - 14'd1);
    wire in_opt  = in_ip4h && (r >= 14'd20) && !opt_end;
    wire is_udp  = (proto == 8'd17);
    wire [15:0] udp_len_now = {udp_len_hi, in_data};

    assign hdr_end = l4_start;

    // ---- IPv4 header sum pipeline (2 stages after the header's last byte) --
    reg         h1, h2;
    reg  [16:0] ip_f1_r;

    // ---- Final sum pipeline (3 stages after the last datagram byte) --------
    reg         p1, p2, p3;
    reg  [31:0] l4_tot_r;
    reg  [16:0] l4_f1_r;
    reg         struct_ok_r;     // datagram structure valid at p1
    reg         l4_ok_r;

    wire [16:0] ip_f1 = {1'b0, ip_acc[15:0]} + {9'd0, ip_acc[23:16]};
    wire        use_ph = fam6 || (proto != 8'd1);

    wire        struct4 = fam4 && (hdr_len >= 6'd20) && (ip_len >= {10'd0, hdr_len});
    wire        struct_ok = len_ok && (struct4 || fam6);
    wire        udp_ok  = (udp_len >= 16'd8) && (udp_len <= l4_len);
    wire [15:0] ph_len  = is_udp ? udp_len : l4_len;
    wire        l4_able = struct_ok && l4_proto_ok && !(fam4 && (frag || opt_skip)) &&
                          (l4_len >= {11'd0, l4_off} + 16'd2) &&
                          (!is_udp || udp_ok);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            etype_hi    <= 8'd0;
            vlan        <= 1'b0;
            l3_known    <= 1'b0;
            l3_off      <= 5'd14;
            fam4        <= 1'b0;
            fam6        <= 1'b0;
            hdr_len     <= 6'd20;
            ip_len      <= 16'd0;
            frag        <= 1'b0;
            proto       <= 8'd0;
            len_ok      <= 1'b0;
            l4_start    <= 14'd0;
            l4_len      <= 16'd0;
            l4_end      <= 14'd0;
            udp_len_hi  <= 8'd0;
            udp_len     <= 16'd0;
            opt_pos     <= 9'd20;
            opt_len_nx  <= 1'b0;
            opt_end     <= 1'b0;
            opt_skip    <= 1'b0;
            l3_end      <= 14'd0;
            ip_csum_pos <= 14'd0;
            l4_csum_pos <= 14'h3FFF;
            l4_field    <= 16'd0;
            ip_acc      <= 24'd0;
            ph_acc      <= 24'd0;
            l4_acc      <= 32'd0;
            h1          <= 1'b0;
            h2          <= 1'b0;
            p1          <= 1'b0;
            p2          <= 1'b0;
            p3          <= 1'b0;
            l4_tot_r    <= 32'd0;
            l4_f1_r     <= 17'd0;
            ip_f1_r     <= 17'd0;
            struct_ok_r <= 1'b0;
            l4_ok_r     <= 1'b0;
            done        <= 1'b0;
            ip4         <= 1'b0;
            ip_sum      <= 16'd0;
            l4_ok       <= 1'b0;
            l4_udp      <= 1'b0;
            l4_sum      <= 16'd0;
        end else begin
            h1 <= 1'b0;
            h2 <= 1'b0;
            p1 <= 1'b0;
            p2 <= 1'b0;

            if (in_valid && in_idx == 14'd0) begin
                // New frame: clear everything (byte 0 is a dst-MAC byte)
                vlan        <= 1'b0;
                l3_known    <= 1'b0;
                l3_off      <= 5'd14;
                fam4        <= 1'b0;
                fam6        <= 1'b0;
                hdr_len     <= 6'd20;
                ip_len      <= 16'd0;
                frag        <= 1'b0;
                proto       <= 8'd0;
                len_ok      <= 1'b0;
                l4_start    <= 14'd0;
                l4_len      <= 16'd0;
                l4_end      <= 14'd0;
                udp_len     <= 16'd0;
                opt_pos     <= 9'd20;
                opt_len_nx  <= 1'b0;
                opt_end     <= 1'b0;
                opt_skip    <= 1'b0;
                l3_end      <= 14'd0;
                l4_csum_pos <= 14'h3FFF;
                l4_field    <= 16'd0;
                ip_acc      <= 24'd0;
                ph_acc      <= 24'd0;
                l4_acc      <= 32'd0;
                done        <= 1'b0;
                ip4         <= 1'b0;
                l4_ok       <= 1'b0;
                l4_udp      <= 1'b0;
            end else if (in_valid) begin
                // ---- EtherType / VLAN ----------------------------------------
                if (!l3_known) begin
                    if (in_idx == 14'd12 || (vlan && in_idx == 14'd16))
                        etype_hi <= in_data;
                    if (in_idx == 14'd13 || (vlan && in_idx == 14'd17)) begin
                        if (!vlan && ({etype_hi, in_data} == 16'h8100 ||
                                      {etype_hi, in_data} == 16'h88A8)) begin
                            vlan <= 1'b1;
                        end else begin
                            l3_known <= 1'b1;
                            l3_off   <= vlan ? 5'd18 : 5'd14;
                            fam4     <= ({etype_hi, in_data} == 16'h0800);
                            fam6     <= ({etype_hi, in_data} == 16'h86DD);
                        end
                    end
                end

                // ---- L3 header fields ----------------------------------------
                if (in_l3) begin
                    if (r == 14'd0) begin
                        if (fam4) begin
                            hdr_len <= {in_data[3:0], 2'b00};
                            if (in_data[7:4] != 4'd4) fam4 <= 1'b0;
                        end
                        if (fam6 && in_data[7:4] != 4'd6) fam6 <= 1'b0;
                    end
                    if (fam4) begin
                        if (r == 14'd2) ip_len[15:8] <= in_data;
                        if (r == 14'd3) ip_len[7:0]  <= in_data;
                        if (r == 14'd6) frag <= in_data[5] || (in_data[4:0] != 5'd0);
                        if (r == 14'd7 && in_data != 8'd0) frag <= 1'b1;
                        if (r == 14'd9) proto <= in_data;
                    end else begin
                        if (r == 14'd4) ip_len[15:8] <= in_data;
                        if (r == 14'd5) ip_len[7:0]  <= in_data;
                        if (r == 14'd6) proto <= in_data;
                    end

                    // Once the length is in, work out where things end. IPv4:
                    // total length covers the header; IPv6: payload length
                    // follows the fixed 40-byte header.
                    if ((fam4 && r == 14'd4) || (fam6 && r == 14'd6)) begin : lengths
                        reg [16:0] end_off;
                        reg [16:0] l4s;
                        end_off = fam4 ? {12'd0, l3_off} + {1'b0, ip_len}
                                       : {12'd0, l3_off} + 17'd40 + {1'b0, ip_len};
                        l4s     = fam4 ? {12'd0, l3_off} + {11'd0, hdr_len}
                                       : {12'd0, l3_off} + 17'd40;
                        len_ok   <= (end_off <= 17'h3FFF);
                        l3_end   <= end_off[13:0];
                        l4_end   <= end_off[13:0];
                        l4_start <= l4s[13:0];
                        l4_len   <= fam4 ? ip_len - {10'd0, hdr_len} : ip_len;
                        ip_csum_pos <= {9'd0, l3_off} + 14'd10;
                    end
                    // Protocol is known by IPv4 byte 9 / IPv6 byte 6.
                    if ((fam4 && r == 14'd10) || (fam6 && r == 14'd7))
                        l4_csum_pos <= l4_start + {9'd0, l4_off};

                    // IPv4 options: look for a source route (or a length
                    // that cannot be walked past).
                    if (fam4 && in_opt) begin
                        if (opt_len_nx) begin
                            opt_len_nx <= 1'b0;
                            if (in_data < 8'd2) begin
                                opt_end  <= 1'b1;
                                opt_skip <= 1'b1;
                            end else begin
                                opt_pos <= opt_pos + {1'b0, in_data};
                            end
                        end else if (r == {5'd0, opt_pos}) begin
                            case (in_data)
                                8'h00:   opt_end <= 1'b1;                 // EOL
                                8'h01:   opt_pos <= opt_pos + 9'd1;       // NOP
                                default: begin
                                    opt_len_nx <= 1'b1;
                                    if (in_data == 8'h83 || in_data == 8'h89)
                                        opt_skip <= 1'b1;                 // LSRR / SSRR
                                end
                            endcase
                        end
                    end

                    // UDP Length (L4 bytes 4-5). Bytes 0-5 are always
                    // covered, so the end only needs to move from byte 6 on.
                    if (is_udp && len_ok && in_idx == l4_start + 14'd4)
                        udp_len_hi <= in_data;
                    if (is_udp && len_ok && in_idx == l4_start + 14'd5) begin
                        udp_len <= udp_len_now;
                        if (udp_len_now >= 16'd8 && udp_len_now <= l4_len)
                            l4_end <= l4_start + udp_len_now[13:0];
                    end
                end

                // ---- Sums ----------------------------------------------------
                if (in_ip4h && !(zero_fields && is_ipf))
                    ip_acc <= ip_acc + {8'd0, w};
                if (in_ph)
                    ph_acc <= ph_acc + {8'd0, w};
                if (in_l4) begin
                    if (!(zero_fields && is_l4f))
                        l4_acc <= l4_acc + {16'd0, w};
                    if (in_idx == l4_csum_pos)          l4_field[15:8] <= in_data;
                    if (in_idx == l4_csum_pos + 14'd1)  l4_field[7:0]  <= in_data;
                end

                if (hdr_last)
                    h1 <= 1'b1;
                if (last)
                    p1 <= 1'b1;
            end

            // IPv4 header: two folds; valid whether or not the datagram ends
            if (h1) begin
                h2      <= 1'b1;
                ip_f1_r <= ip_f1;
            end
            if (h2) begin
                ip_sum <= ip_f1_r[15:0] + {15'd0, ip_f1_r[16]};
                ip4    <= struct4;
            end

            // Stage 1: add the pseudo-header
            if (p1) begin
                p2          <= 1'b1;
                struct_ok_r <= struct_ok;
                l4_ok_r     <= l4_able;
                l4_udp      <= is_udp;
                l4_tot_r    <= l4_acc +
                               (use_ph ? {8'd0, ph_acc} + {24'd0, proto} +
                                         {16'd0, ph_len}
                                       : 32'd0);
            end

            // Stage 2: first fold of the L4 sum
            if (p2)
                l4_f1_r <= {1'b0, l4_tot_r[15:0]} + {1'b0, l4_tot_r[31:16]};

            // Stage 3: final fold of the L4 sum; results valid
            p3 <= p2;
            if (p3) begin
                l4_sum <= l4_f1_r[15:0] + {15'd0, l4_f1_r[16]};
                done   <= struct_ok_r;
                l4_ok  <= struct_ok_r && l4_ok_r;
            end
        end
    end

endmodule
