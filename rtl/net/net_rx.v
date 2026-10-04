// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// net_rx.v - Network Receive Path
// Parses Ethernet headers, routes by ethertype (ARP/IPv4)
// Parses IP header, routes ICMP payload to icmp_echo
//
// IPv4 checks: version 4, IHL >= 5, header checksum, total length covering
// the header plus 8 bytes, destination = our IP or broadcast. Frames that
// fail are dropped before any ICMP/UDP byte is passed on. The header
// checksum is judged one cycle after the last header byte, from the
// registered sum: nothing has been passed on by then (the first ICMP byte is
// only held, UDP is still in its 8-byte header), and folding the running sum
// with the incoming byte in one cycle does not fit 100 MHz on a 7-series part.
//
// The ICMP / UDP payload ends at the IPv4 total length; Ethernet padding
// after it is not passed on. The last payload byte is held back until the
// end of the frame, then passed on with icmp_last / udp_last and an error
// flag (icmp_err / udp_err) that tells the consumer to discard the message:
// the MAC flagged the frame (terror: bad FCS, rx_er, overflow), the frame
// ended before the IPv4 total length, or (ICMP) the ICMP checksum is wrong.
// The last byte therefore comes out on the cycle after the frame's tlast.
// Verilog 2001
// =============================================================================

module net_rx (
    input  wire        clk,
    input  wire        rst_n,

    // AXI4-Stream slave from MAC RX
    input  wire [7:0]  s_axis_tdata,
    input  wire        s_axis_tvalid,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tsof,
    input  wire        s_axis_terror,

    // ARP output (payload after ethertype)
    output reg  [7:0]  arp_data,
    output reg         arp_valid,
    output reg         arp_last,

    // ICMP output (payload after IP header)
    output reg  [7:0]  icmp_data,
    output reg         icmp_valid,
    output reg         icmp_last,
    output reg         icmp_err,       // with icmp_last: discard this message
    output reg  [31:0] icmp_src_ip,

    // UDP output (payload after UDP header — 8 bytes of UDP header are
    // consumed inside this module; only payload bytes appear on udp_data).
    output reg  [7:0]  udp_data,
    output reg         udp_valid,
    output reg         udp_last,
    output reg         udp_err,        // with udp_last: discard this message
    output reg  [31:0] udp_src_ip,
    output reg  [15:0] udp_src_port,
    output reg  [15:0] udp_dst_port,
    output reg  [15:0] udp_length,

    // Parsed metadata (available during frame)
    output reg  [47:0] rx_src_mac,

    // Our IP address for destination filtering
    input  wire [31:0] our_ip
);

    // Parser states
    localparam [3:0]
        P_ETH_DST     = 4'd0,
        P_ETH_SRC     = 4'd1,
        P_ETH_TYPE    = 4'd2,
        P_ARP_PAYLOAD = 4'd3,
        P_IP_HDR      = 4'd4,
        P_ICMP_DATA   = 4'd5,
        P_UDP_HDR     = 4'd6,
        P_UDP_DATA    = 4'd7,
        P_DROP        = 4'd8;

    reg [3:0]  state;
    reg [13:0] byte_cnt;
    reg [15:0] ethertype;
    reg [7:0]  ip_protocol;
    reg [3:0]  ip_ihl;
    reg [13:0] ip_hdr_bytes;
    reg [15:0] ip_tot_len;

    // Stored addresses
    reg [47:0] dst_mac_buf;
    reg [47:0] src_mac_buf;
    reg [31:0] src_ip_buf;
    reg [31:0] dst_ip_buf;

    // Checksums (one's-complement sums of 16-bit words, folded when checked)
    reg [31:0] hdr_sum;                // IPv4 header
    reg        hdr_chk;                // judge hdr_sum this cycle
    reg [31:0] pl_sum;                 // IPv4 payload (ICMP message)
    reg        pl_odd;                 // next payload byte is a low byte

    // Payload tracking
    reg [15:0] rem;                    // IPv4 payload bytes still to come
    reg        terr_seen;              // terror on any beat of this frame
    reg        hold_v;                 // last payload byte held back
    reg [7:0]  hold_d;
    reg        fin;                    // frame ended: release the held byte
    reg        fin_err;
    reg        fin_icmp;

    function [15:0] fold;
        input [31:0] s;
        reg   [31:0] t;
        begin
            t    = {16'd0, s[15:0]} + {16'd0, s[31:16]};
            t    = {16'd0, t[15:0]} + {16'd0, t[31:16]};
            fold = t[15:0];
        end
    endfunction

    // Header byte at byte_cnt as a 16-bit word contribution
    wire [31:0] hdr_word  = byte_cnt[0] ? {24'd0, s_axis_tdata}
                                        : {16'd0, s_axis_tdata, 8'd0};
    wire [31:0] hdr_sum_now = hdr_sum + hdr_word;
    wire [31:0] pl_word   = pl_odd ? {24'd0, s_axis_tdata}
                                   : {16'd0, s_axis_tdata, 8'd0};
    wire        in_payload = (state == P_ICMP_DATA) || (state == P_UDP_HDR) ||
                             (state == P_UDP_DATA);
    wire [15:0] rem_next  = (rem != 16'd0) ? rem - 16'd1 : 16'd0;

    // =========================================================================
    // Main parser
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= P_ETH_DST;
            byte_cnt     <= 14'd0;
            ethertype    <= 16'd0;
            ip_protocol  <= 8'd0;
            ip_ihl       <= 4'd0;
            ip_hdr_bytes <= 14'd0;
            ip_tot_len   <= 16'd0;
            dst_mac_buf  <= 48'd0;
            src_mac_buf  <= 48'd0;
            src_ip_buf   <= 32'd0;
            dst_ip_buf   <= 32'd0;
            hdr_sum      <= 32'd0;
            hdr_chk      <= 1'b0;
            pl_sum       <= 32'd0;
            pl_odd       <= 1'b0;
            rem          <= 16'd0;
            terr_seen    <= 1'b0;
            hold_v       <= 1'b0;
            hold_d       <= 8'd0;
            fin          <= 1'b0;
            fin_err      <= 1'b0;
            fin_icmp     <= 1'b0;

            arp_data   <= 8'd0; arp_valid   <= 1'b0; arp_last   <= 1'b0;
            icmp_data  <= 8'd0; icmp_valid  <= 1'b0; icmp_last  <= 1'b0;
            icmp_err   <= 1'b0;
            icmp_src_ip <= 32'd0;
            udp_data    <= 8'd0; udp_valid  <= 1'b0; udp_last   <= 1'b0;
            udp_err     <= 1'b0;
            udp_src_ip  <= 32'd0;
            udp_src_port <= 16'd0; udp_dst_port <= 16'd0;
            udp_length  <= 16'd0;
            rx_src_mac  <= 48'd0;
        end else begin
            // Default: clear output valids
            arp_valid  <= 1'b0;
            arp_last   <= 1'b0;
            icmp_valid <= 1'b0;
            icmp_last  <= 1'b0;
            icmp_err   <= 1'b0;
            udp_valid  <= 1'b0;
            udp_last   <= 1'b0;
            udp_err    <= 1'b0;

            // Release the held last payload byte, one cycle after tlast. The
            // next frame is still in its Ethernet header, so nothing else is
            // driving the outputs this cycle.
            if (fin) begin
                fin <= 1'b0;
                if (hold_v) begin
                    hold_v <= 1'b0;
                    if (fin_icmp) begin
                        icmp_data  <= hold_d;
                        icmp_valid <= 1'b1;
                        icmp_last  <= 1'b1;
                        icmp_err   <= fin_err || (fold(pl_sum) != 16'hFFFF);
                    end else begin
                        udp_data   <= hold_d;
                        udp_valid  <= 1'b1;
                        udp_last   <= 1'b1;
                        udp_err    <= fin_err;
                    end
                end
            end

            if (s_axis_tvalid) begin
                if (s_axis_terror)
                    terr_seen <= 1'b1;

                // IPv4 payload bytes (up to the total length) in the ICMP /
                // UDP states: count and sum them; padding after is ignored.
                if (in_payload && rem != 16'd0) begin
                    rem    <= rem - 16'd1;
                    pl_sum <= pl_sum + pl_word;
                    pl_odd <= ~pl_odd;
                end

                case (state)
                    // ----- Ethernet destination MAC (6 bytes) -----
                    P_ETH_DST: begin
                        dst_mac_buf <= {dst_mac_buf[39:0], s_axis_tdata};
                        byte_cnt    <= byte_cnt + 14'd1;
                        if (byte_cnt == 14'd5) begin
                            state    <= P_ETH_SRC;
                            byte_cnt <= 14'd0;
                        end
                    end

                    // ----- Ethernet source MAC (6 bytes) -----
                    P_ETH_SRC: begin
                        src_mac_buf <= {src_mac_buf[39:0], s_axis_tdata};
                        byte_cnt    <= byte_cnt + 14'd1;
                        if (byte_cnt == 14'd5) begin
                            state    <= P_ETH_TYPE;
                            byte_cnt <= 14'd0;
                            rx_src_mac <= {src_mac_buf[39:0], s_axis_tdata};
                        end
                    end

                    // ----- Ethertype (2 bytes) -----
                    P_ETH_TYPE: begin
                        hdr_sum <= 32'd0;
                        pl_sum  <= 32'd0;
                        pl_odd  <= 1'b0;
                        hold_v  <= 1'b0;
                        if (byte_cnt == 14'd0) begin
                            ethertype[15:8] <= s_axis_tdata;
                            byte_cnt <= 14'd1;
                        end else begin
                            ethertype[7:0] <= s_axis_tdata;
                            byte_cnt       <= 14'd0;
                            if ({ethertype[15:8], s_axis_tdata} == 16'h0806)
                                state <= P_ARP_PAYLOAD;
                            else if ({ethertype[15:8], s_axis_tdata} == 16'h0800)
                                state <= P_IP_HDR;
                            else
                                state <= P_DROP;
                        end
                    end

                    // ----- ARP payload (pass through) -----
                    P_ARP_PAYLOAD: begin
                        arp_data  <= s_axis_tdata;
                        arp_valid <= 1'b1;
                        if (s_axis_tlast)
                            arp_last <= 1'b1;
                    end

                    // ----- IP header parsing -----
                    P_IP_HDR: begin
                        byte_cnt <= byte_cnt + 14'd1;
                        hdr_sum  <= hdr_sum_now;

                        case (byte_cnt)
                            14'd0: begin
                                if (s_axis_tdata[7:4] != 4'd4 ||
                                    s_axis_tdata[3:0] < 4'd5)
                                    state <= P_DROP;
                                else begin
                                    ip_ihl       <= s_axis_tdata[3:0];
                                    ip_hdr_bytes <= {10'd0, s_axis_tdata[3:0]} << 2;
                                end
                            end
                            14'd2:  ip_tot_len[15:8]  <= s_axis_tdata;
                            14'd3:  ip_tot_len[7:0]   <= s_axis_tdata;
                            14'd9:  ip_protocol <= s_axis_tdata;
                            14'd12: src_ip_buf[31:24] <= s_axis_tdata;
                            14'd13: src_ip_buf[23:16] <= s_axis_tdata;
                            14'd14: src_ip_buf[15:8]  <= s_axis_tdata;
                            14'd15: src_ip_buf[7:0]   <= s_axis_tdata;
                            14'd16: dst_ip_buf[31:24] <= s_axis_tdata;
                            14'd17: dst_ip_buf[23:16] <= s_axis_tdata;
                            14'd18: dst_ip_buf[15:8]  <= s_axis_tdata;
                            14'd19: dst_ip_buf[7:0]   <= s_axis_tdata;
                            default: ;
                        endcase

                        // End of IP header
                        if (byte_cnt == ip_hdr_bytes - 14'd1) begin
                            byte_cnt <= 14'd0;
                            rem      <= ip_tot_len - {2'd0, ip_hdr_bytes};
                            // Destination filter: our IP or broadcast
                            if ({dst_ip_buf[31:8], s_axis_tdata} != our_ip &&
                                {dst_ip_buf[31:8], s_axis_tdata} != 32'hFFFFFFFF)
                                state <= P_DROP;
                            else if (ip_tot_len < {2'd0, ip_hdr_bytes} + 16'd8)
                                state <= P_DROP;           // no room for ICMP/UDP header
                            else if (ip_protocol == 8'd1) begin
                                state       <= P_ICMP_DATA;
                                hdr_chk     <= 1'b1;
                                icmp_src_ip <= {src_ip_buf[31:8],
                                    (byte_cnt == 14'd15) ? s_axis_tdata : src_ip_buf[7:0]};
                            end else if (ip_protocol == 8'd17) begin
                                state      <= P_UDP_HDR;
                                hdr_chk    <= 1'b1;
                                udp_src_ip <= {src_ip_buf[31:8],
                                    (byte_cnt == 14'd15) ? s_axis_tdata : src_ip_buf[7:0]};
                            end else
                                state <= P_DROP;
                        end
                    end

                    // ----- ICMP data (last byte held back) -----
                    P_ICMP_DATA: begin
                        if (rem != 16'd0) begin
                            if (hold_v) begin
                                icmp_data  <= hold_d;
                                icmp_valid <= 1'b1;
                            end
                            hold_d <= s_axis_tdata;
                            hold_v <= 1'b1;
                        end
                    end

                    // ----- UDP header (8 bytes) -----
                    P_UDP_HDR: begin
                        byte_cnt <= byte_cnt + 14'd1;
                        case (byte_cnt)
                            14'd0: udp_src_port[15:8] <= s_axis_tdata;
                            14'd1: udp_src_port[7:0]  <= s_axis_tdata;
                            14'd2: udp_dst_port[15:8] <= s_axis_tdata;
                            14'd3: udp_dst_port[7:0]  <= s_axis_tdata;
                            14'd4: udp_length[15:8]   <= s_axis_tdata;
                            14'd5: udp_length[7:0]    <= s_axis_tdata;
                            // bytes 6,7 = checksum (ignored, payload follows)
                            default: ;
                        endcase
                        if (byte_cnt == 14'd7) begin
                            byte_cnt <= 14'd0;
                            state    <= P_UDP_DATA;
                        end
                    end

                    // ----- UDP payload (last byte held back) -----
                    P_UDP_DATA: begin
                        if (rem != 16'd0) begin
                            if (hold_v) begin
                                udp_data  <= hold_d;
                                udp_valid <= 1'b1;
                            end
                            hold_d <= s_axis_tdata;
                            hold_v <= 1'b1;
                        end
                    end

                    // ----- Drop frame -----
                    P_DROP: begin
                        // Consume until end of frame
                    end

                    default: state <= P_DROP;
                endcase

                // End of frame: reset the parser; in the ICMP / UDP states,
                // release the held byte next cycle with the frame's verdict.
                if (s_axis_tlast) begin
                    state     <= P_ETH_DST;
                    byte_cnt  <= 14'd0;
                    terr_seen <= 1'b0;
                    if (in_payload) begin
                        fin      <= 1'b1;
                        fin_err  <= terr_seen || s_axis_terror ||
                                    (rem_next != 16'd0);
                        fin_icmp <= (state == P_ICMP_DATA);
                    end
                end
            end

            // Header checksum verdict (hdr_sum now includes the last header
            // byte). On a mismatch, drop the frame and anything held for it;
            // if the frame also ended this cycle the parser is already back at
            // P_ETH_DST, so only the pending release is cancelled.
            if (hdr_chk) begin
                hdr_chk <= 1'b0;
                if (fold(hdr_sum) != 16'hFFFF) begin
                    hold_v <= 1'b0;
                    fin    <= 1'b0;
                    if (!(s_axis_tvalid && s_axis_tlast))
                        state <= P_DROP;
                end
            end
        end
    end

endmodule
