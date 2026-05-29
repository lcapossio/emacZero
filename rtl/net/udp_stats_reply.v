// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// udp_stats_reply.v - Fixed binary UDP stats responder
//
// Query payload:
//   "G" -> reply with current stats
//   "C" -> clear stats and reply with the pre-clear snapshot
//
// Reply payload is 44 bytes:
//   0..3   "IPS0"
//   4..7   packets
//   8..11  bytes
//   12..15 first_seq
//   16..19 last_seq
//   20..23 seq_gaps
//   24..27 out_of_order
//   28..31 final_packets
//   32..35 last_src_ip
//   36..37 last_src_port
//   38..39 flags/reserved
//   40..43 magic "DONE"
// Verilog 2001
// =============================================================================

module udp_stats_reply (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [47:0] our_mac,
    input  wire [31:0] our_ip,
    input  wire [15:0] stats_port,

    input  wire [7:0]  udp_rx_data,
    input  wire        udp_rx_valid,
    input  wire        udp_rx_last,
    input  wire [31:0] udp_rx_src_ip,
    input  wire [15:0] udp_rx_src_port,
    input  wire [15:0] udp_rx_dst_port,
    input  wire [47:0] rx_src_mac,

    input  wire [31:0] stat_packets,
    input  wire [31:0] stat_bytes,
    input  wire [31:0] stat_first_seq,
    input  wire [31:0] stat_last_seq,
    input  wire [31:0] stat_seq_gaps,
    input  wire [31:0] stat_out_of_order,
    input  wire [31:0] stat_final_packets,
    input  wire [31:0] stat_last_src_ip,
    input  wire [15:0] stat_last_src_port,

    output reg         clear_stats,

    output wire [7:0]  tx_data,
    output wire        tx_valid,
    output wire        tx_last,
    input  wire        tx_ready,
    output reg         tx_start
);

    localparam [15:0] PAYLOAD_LEN = 16'd44;
    localparam [15:0] IP_TOTAL_LEN = 16'd28 + PAYLOAD_LEN;
    localparam [15:0] UDP_TOTAL_LEN = 16'd8 + PAYLOAD_LEN;

    reg pkt_ready;
    reg reply_active;
    reg query_is_clear;
    reg [31:0] reply_dst_ip;
    reg [47:0] reply_dst_mac;
    reg [15:0] reply_dst_port;

    reg [31:0] lat_packets;
    reg [31:0] lat_bytes;
    reg [31:0] lat_first_seq;
    reg [31:0] lat_last_seq;
    reg [31:0] lat_seq_gaps;
    reg [31:0] lat_out_of_order;
    reg [31:0] lat_final_packets;
    reg [31:0] lat_last_src_ip;
    reg [15:0] lat_last_src_port;

    localparam [1:0]
        RX_IDLE    = 2'd0,
        RX_DRAIN   = 2'd1,
        RX_CAPTURE = 2'd2;

    reg [1:0] rx_state;
    wire reply_take;
    wire query_clear_next = (rx_state == RX_IDLE) ?
                            (udp_rx_data == 8'h43) : query_is_clear;
    wire do_latch_query =
        udp_rx_valid &&
        ((rx_state == RX_IDLE && udp_rx_dst_port == stats_port && udp_rx_last) ||
         (rx_state == RX_CAPTURE && udp_rx_last));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pkt_ready        <= 1'b0;
            query_is_clear   <= 1'b0;
            reply_dst_ip     <= 32'd0;
            reply_dst_mac    <= 48'd0;
            reply_dst_port   <= 16'd0;
            rx_state         <= RX_IDLE;
            clear_stats      <= 1'b0;
            lat_packets      <= 32'd0;
            lat_bytes        <= 32'd0;
            lat_first_seq    <= 32'd0;
            lat_last_seq     <= 32'd0;
            lat_seq_gaps     <= 32'd0;
            lat_out_of_order <= 32'd0;
            lat_final_packets <= 32'd0;
            lat_last_src_ip  <= 32'd0;
            lat_last_src_port <= 16'd0;
        end else begin
            clear_stats <= 1'b0;
            if (reply_take) begin
                pkt_ready <= 1'b0;
            end else if (udp_rx_valid && !reply_active && !pkt_ready) begin
                if (do_latch_query) begin
                    pkt_ready         <= 1'b1;
                    reply_dst_ip      <= udp_rx_src_ip;
                    reply_dst_mac     <= rx_src_mac;
                    reply_dst_port    <= udp_rx_src_port;
                    lat_packets       <= stat_packets;
                    lat_bytes         <= stat_bytes;
                    lat_first_seq     <= stat_first_seq;
                    lat_last_seq      <= stat_last_seq;
                    lat_seq_gaps      <= stat_seq_gaps;
                    lat_out_of_order  <= stat_out_of_order;
                    lat_final_packets <= stat_final_packets;
                    lat_last_src_ip   <= stat_last_src_ip;
                    lat_last_src_port <= stat_last_src_port;
                    clear_stats       <= query_clear_next;
                    query_is_clear    <= 1'b0;
                    rx_state          <= RX_IDLE;
                end else begin
                    case (rx_state)
                        RX_IDLE: begin
                            if (udp_rx_dst_port == stats_port) begin
                                query_is_clear <= (udp_rx_data == 8'h43); // "C"
                                rx_state       <= RX_CAPTURE;
                            end else begin
                                rx_state <= udp_rx_last ? RX_IDLE : RX_DRAIN;
                            end
                        end

                        RX_CAPTURE: begin
                            // Payload bytes after byte 0 are ignored; the final
                            // byte is handled by do_latch_query above.
                        end

                        RX_DRAIN: begin
                            if (udp_rx_last)
                                rx_state <= RX_IDLE;
                        end

                        default: rx_state <= RX_IDLE;
                    endcase
                end
            end else if (udp_rx_valid && udp_rx_last) begin
                // Drop arrivals that complete while a reply is active/pending.
                rx_state       <= RX_IDLE;
                query_is_clear <= 1'b0;
            end
        end
    end

    localparam [1:0]
        TX_IDLE    = 2'd0,
        TX_ETH_HDR = 2'd1,
        TX_IP_HDR  = 2'd2,
        TX_UDP     = 2'd3;

    reg [1:0]  tx_state;
    reg [5:0]  tx_cnt;
    reg        src_valid;
    reg        src_last;
    reg [15:0] ip_id_cnt;

    reg [31:0] ip_csum_acc;
    wire [16:0] ip_fold1 = ip_csum_acc[15:0] + ip_csum_acc[31:16];
    wire [15:0] ip_fold2 = ip_fold1[15:0] + {15'd0, ip_fold1[16]};
    wire [15:0] ip_checksum = ~ip_fold2;
    assign reply_take = (tx_state == TX_IDLE) && pkt_ready && !reply_active;

    // 1-deep AXIS register-slice signals + combinational mux, declared ahead of
    // the TX FSM that references src_ready and tx_data_mux (logic is below).
    reg [7:0] r_data;
    reg       r_valid;
    reg       r_last;
    reg [7:0] tx_data_mux;
    wire      src_ready = !r_valid || tx_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state     <= TX_IDLE;
            tx_cnt       <= 6'd0;
            reply_active <= 1'b0;
            src_valid    <= 1'b0;
            src_last     <= 1'b0;
            tx_start     <= 1'b0;
            ip_id_cnt    <= 16'd5000;
            ip_csum_acc  <= 32'd0;
        end else begin
            if (tx_ready && tx_valid)
                tx_start <= 1'b0;
            src_last <= 1'b0;

            case (tx_state)
                TX_IDLE: begin
                    src_valid <= 1'b0;
                    if (reply_take) begin
                        tx_state     <= TX_ETH_HDR;
                        tx_cnt       <= 6'd0;
                        reply_active <= 1'b1;
                        src_valid    <= 1'b1;
                        tx_start     <= 1'b1;
                        ip_id_cnt    <= ip_id_cnt + 16'd1;
                        ip_csum_acc  <= {16'd0, 16'h4500}
                                      + {16'd0, IP_TOTAL_LEN}
                                      + {16'd0, ip_id_cnt + 16'd1}
                                      + {16'd0, 16'h4000}
                                      + {16'd0, 16'h4011}
                                      + {16'd0, our_ip[31:16]}
                                      + {16'd0, our_ip[15:0]}
                                      + {16'd0, reply_dst_ip[31:16]}
                                      + {16'd0, reply_dst_ip[15:0]};
                    end
                end

                TX_ETH_HDR: begin
                    src_valid <= 1'b1;
                    if (src_ready && src_valid) begin
                        tx_cnt <= tx_cnt + 6'd1;
                        if (tx_cnt == 6'd13) begin
                            tx_state <= TX_IP_HDR;
                            tx_cnt   <= 6'd0;
                        end
                    end
                end

                TX_IP_HDR: begin
                    src_valid <= 1'b1;
                    if (src_ready && src_valid) begin
                        tx_cnt <= tx_cnt + 6'd1;
                        if (tx_cnt == 6'd19) begin
                            tx_state <= TX_UDP;
                            tx_cnt   <= 6'd0;
                        end
                    end
                end

                TX_UDP: begin
                    src_valid <= 1'b1;
                    if (src_ready && src_valid) begin
                        tx_cnt <= tx_cnt + 6'd1;
                        if (tx_cnt == 6'd50)
                            src_last <= 1'b1;
                        if (tx_cnt == 6'd51) begin
                            tx_state     <= TX_IDLE;
                            reply_active <= 1'b0;
                            src_valid    <= 1'b0;
                        end
                    end
                end

                default: tx_state <= TX_IDLE;
            endcase
        end
    end

    // r_data/r_valid/r_last and src_ready are declared above (ahead of the FSM).
    assign tx_data  = r_data;
    assign tx_valid = r_valid;
    assign tx_last  = r_last;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_data  <= 8'd0;
            r_valid <= 1'b0;
            r_last  <= 1'b0;
        end else if (src_ready) begin
            r_data  <= tx_data_mux;
            r_valid <= src_valid;
            r_last  <= src_last;
        end
    end

    // tx_data_mux is declared above.
    always @(*) begin
        tx_data_mux = 8'h00;
        case (tx_state)
            TX_ETH_HDR: case (tx_cnt)
                6'd0:  tx_data_mux = reply_dst_mac[47:40];
                6'd1:  tx_data_mux = reply_dst_mac[39:32];
                6'd2:  tx_data_mux = reply_dst_mac[31:24];
                6'd3:  tx_data_mux = reply_dst_mac[23:16];
                6'd4:  tx_data_mux = reply_dst_mac[15:8];
                6'd5:  tx_data_mux = reply_dst_mac[7:0];
                6'd6:  tx_data_mux = our_mac[47:40];
                6'd7:  tx_data_mux = our_mac[39:32];
                6'd8:  tx_data_mux = our_mac[31:24];
                6'd9:  tx_data_mux = our_mac[23:16];
                6'd10: tx_data_mux = our_mac[15:8];
                6'd11: tx_data_mux = our_mac[7:0];
                6'd12: tx_data_mux = 8'h08;
                6'd13: tx_data_mux = 8'h00;
                default: tx_data_mux = 8'h00;
            endcase

            TX_IP_HDR: case (tx_cnt)
                6'd0:  tx_data_mux = 8'h45;
                6'd1:  tx_data_mux = 8'h00;
                6'd2:  tx_data_mux = IP_TOTAL_LEN[15:8];
                6'd3:  tx_data_mux = IP_TOTAL_LEN[7:0];
                6'd4:  tx_data_mux = ip_id_cnt[15:8];
                6'd5:  tx_data_mux = ip_id_cnt[7:0];
                6'd6:  tx_data_mux = 8'h40;
                6'd7:  tx_data_mux = 8'h00;
                6'd8:  tx_data_mux = 8'h40;
                6'd9:  tx_data_mux = 8'h11;
                6'd10: tx_data_mux = ip_checksum[15:8];
                6'd11: tx_data_mux = ip_checksum[7:0];
                6'd12: tx_data_mux = our_ip[31:24];
                6'd13: tx_data_mux = our_ip[23:16];
                6'd14: tx_data_mux = our_ip[15:8];
                6'd15: tx_data_mux = our_ip[7:0];
                6'd16: tx_data_mux = reply_dst_ip[31:24];
                6'd17: tx_data_mux = reply_dst_ip[23:16];
                6'd18: tx_data_mux = reply_dst_ip[15:8];
                6'd19: tx_data_mux = reply_dst_ip[7:0];
                default: tx_data_mux = 8'h00;
            endcase

            TX_UDP: case (tx_cnt)
                6'd0:  tx_data_mux = stats_port[15:8];
                6'd1:  tx_data_mux = stats_port[7:0];
                6'd2:  tx_data_mux = reply_dst_port[15:8];
                6'd3:  tx_data_mux = reply_dst_port[7:0];
                6'd4:  tx_data_mux = UDP_TOTAL_LEN[15:8];
                6'd5:  tx_data_mux = UDP_TOTAL_LEN[7:0];
                6'd6:  tx_data_mux = 8'h00;
                6'd7:  tx_data_mux = 8'h00;
                6'd8:  tx_data_mux = 8'h49; // I
                6'd9:  tx_data_mux = 8'h50; // P
                6'd10: tx_data_mux = 8'h53; // S
                6'd11: tx_data_mux = 8'h30; // 0
                6'd12: tx_data_mux = lat_packets[31:24];
                6'd13: tx_data_mux = lat_packets[23:16];
                6'd14: tx_data_mux = lat_packets[15:8];
                6'd15: tx_data_mux = lat_packets[7:0];
                6'd16: tx_data_mux = lat_bytes[31:24];
                6'd17: tx_data_mux = lat_bytes[23:16];
                6'd18: tx_data_mux = lat_bytes[15:8];
                6'd19: tx_data_mux = lat_bytes[7:0];
                6'd20: tx_data_mux = lat_first_seq[31:24];
                6'd21: tx_data_mux = lat_first_seq[23:16];
                6'd22: tx_data_mux = lat_first_seq[15:8];
                6'd23: tx_data_mux = lat_first_seq[7:0];
                6'd24: tx_data_mux = lat_last_seq[31:24];
                6'd25: tx_data_mux = lat_last_seq[23:16];
                6'd26: tx_data_mux = lat_last_seq[15:8];
                6'd27: tx_data_mux = lat_last_seq[7:0];
                6'd28: tx_data_mux = lat_seq_gaps[31:24];
                6'd29: tx_data_mux = lat_seq_gaps[23:16];
                6'd30: tx_data_mux = lat_seq_gaps[15:8];
                6'd31: tx_data_mux = lat_seq_gaps[7:0];
                6'd32: tx_data_mux = lat_out_of_order[31:24];
                6'd33: tx_data_mux = lat_out_of_order[23:16];
                6'd34: tx_data_mux = lat_out_of_order[15:8];
                6'd35: tx_data_mux = lat_out_of_order[7:0];
                6'd36: tx_data_mux = lat_final_packets[31:24];
                6'd37: tx_data_mux = lat_final_packets[23:16];
                6'd38: tx_data_mux = lat_final_packets[15:8];
                6'd39: tx_data_mux = lat_final_packets[7:0];
                6'd40: tx_data_mux = lat_last_src_ip[31:24];
                6'd41: tx_data_mux = lat_last_src_ip[23:16];
                6'd42: tx_data_mux = lat_last_src_ip[15:8];
                6'd43: tx_data_mux = lat_last_src_ip[7:0];
                6'd44: tx_data_mux = lat_last_src_port[15:8];
                6'd45: tx_data_mux = lat_last_src_port[7:0];
                6'd46: tx_data_mux = 8'h00;
                6'd47: tx_data_mux = 8'h00;
                6'd48: tx_data_mux = 8'h44; // D
                6'd49: tx_data_mux = 8'h4f; // O
                6'd50: tx_data_mux = 8'h4e; // N
                6'd51: tx_data_mux = 8'h45; // E
                default: tx_data_mux = 8'h00;
            endcase

            default: tx_data_mux = 8'h00;
        endcase
    end

endmodule
