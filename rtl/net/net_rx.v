// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// net_rx.v - Network Receive Path
// Parses Ethernet headers, routes by ethertype (ARP/IPv4)
// Parses IP header, routes ICMP payload to icmp_echo
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
    output reg  [31:0] icmp_src_ip,

    // UDP output (payload after UDP header — 8 bytes of UDP header are
    // consumed inside this module; only payload bytes appear on udp_data).
    output reg  [7:0]  udp_data,
    output reg         udp_valid,
    output reg         udp_last,
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

    // Stored addresses
    reg [47:0] dst_mac_buf;
    reg [47:0] src_mac_buf;
    reg [31:0] src_ip_buf;
    reg [31:0] dst_ip_buf;

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
            dst_mac_buf  <= 48'd0;
            src_mac_buf  <= 48'd0;
            src_ip_buf   <= 32'd0;
            dst_ip_buf   <= 32'd0;

            arp_data   <= 8'd0; arp_valid   <= 1'b0; arp_last   <= 1'b0;
            icmp_data  <= 8'd0; icmp_valid  <= 1'b0; icmp_last  <= 1'b0;
            icmp_src_ip <= 32'd0;
            udp_data    <= 8'd0; udp_valid  <= 1'b0; udp_last   <= 1'b0;
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
            udp_valid  <= 1'b0;
            udp_last   <= 1'b0;

            // Error — abort frame
            if (s_axis_terror) begin
                state    <= P_ETH_DST;
                byte_cnt <= 14'd0;
            end

            if (s_axis_tvalid) begin
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

                        case (byte_cnt)
                            14'd0: begin
                                if (s_axis_tdata[3:0] < 4'd5)
                                    state <= P_DROP;
                                else begin
                                    ip_ihl       <= s_axis_tdata[3:0];
                                    ip_hdr_bytes <= {10'd0, s_axis_tdata[3:0]} << 2;
                                end
                            end
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
                            // Destination filter: our IP or broadcast
                            if ({dst_ip_buf[31:8], s_axis_tdata} != our_ip &&
                                {dst_ip_buf[31:8], s_axis_tdata} != 32'hFFFFFFFF)
                                state <= P_DROP;
                            else if (ip_protocol == 8'd1) begin
                                state       <= P_ICMP_DATA;
                                icmp_src_ip <= {src_ip_buf[31:8],
                                    (byte_cnt == 14'd15) ? s_axis_tdata : src_ip_buf[7:0]};
                            end else if (ip_protocol == 8'd17) begin
                                state      <= P_UDP_HDR;
                                udp_src_ip <= {src_ip_buf[31:8],
                                    (byte_cnt == 14'd15) ? s_axis_tdata : src_ip_buf[7:0]};
                            end else
                                state <= P_DROP;
                        end
                    end

                    // ----- ICMP data (pass through) -----
                    P_ICMP_DATA: begin
                        icmp_data  <= s_axis_tdata;
                        icmp_valid <= 1'b1;
                        if (s_axis_tlast)
                            icmp_last <= 1'b1;
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

                    // ----- UDP payload (pass through) -----
                    P_UDP_DATA: begin
                        udp_data  <= s_axis_tdata;
                        udp_valid <= 1'b1;
                        if (s_axis_tlast)
                            udp_last <= 1'b1;
                    end

                    // ----- Drop frame -----
                    P_DROP: begin
                        // Consume until end of frame
                    end

                    default: state <= P_DROP;
                endcase

                // Reset on end of frame
                if (s_axis_tlast) begin
                    state    <= P_ETH_DST;
                    byte_cnt <= 14'd0;
                end
            end
        end
    end

endmodule
