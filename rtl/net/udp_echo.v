// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// udp_echo.v - UDP Echo Responder
// Buffers incoming UDP payload, swaps src/dst MAC + IP + UDP ports, recomputes
// IP header checksum, sets UDP checksum to 0 (allowed by RFC 768) and replies
// with a full Ethernet frame.
//
// Layout of an outbound echo:
//   [0..5]   Dst MAC      (= rx_src_mac)
//   [6..11]  Src MAC      (= our_mac)
//   [12..13] EtherType    = 0x0800
//   [14..33] IPv4 header  (20 bytes, protocol = 17 = UDP)
//   [34..35] UDP src port (= incoming dst port)
//   [36..37] UDP dst port (= incoming src port)
//   [38..39] UDP length   (= 8 + payload length)
//   [40..41] UDP checksum (= 0x0000, optional per RFC 768)
//   [42..]   payload      (echoed back)
//
// Buffer size limits the largest echoed payload. 1472 = max UDP/IP MTU at 1500
// Ethernet payload size, but we buffer 1024 here to keep BRAM use small. UDP
// packets larger than the buffer are simply dropped (RX state machine stops
// pushing once full; the TX FSM uses captured length to bound transmission).
// Verilog 2001
// =============================================================================

module udp_echo #(
    parameter BUF_SIZE = 1024,    // bytes of payload buffer
    parameter [15:0] LISTEN_PORT = 16'd0 // 0 = echo every UDP payload
)(
    input  wire        clk,
    input  wire        rst_n,

    // Our identity
    input  wire [47:0] our_mac,
    input  wire [31:0] our_ip,

    // UDP RX (from net_rx, payload only — UDP header already parsed)
    input  wire [7:0]  udp_rx_data,
    input  wire        udp_rx_valid,
    input  wire        udp_rx_last,
    input  wire [31:0] udp_rx_src_ip,
    input  wire [15:0] udp_rx_src_port,
    input  wire [15:0] udp_rx_dst_port,
    input  wire [15:0] udp_rx_length,    // UDP total length (header + payload)

    // Source MAC captured by net_rx
    input  wire [47:0] rx_src_mac,

    // TX output - full Ethernet frame
    output wire [7:0]  tx_data,
    output wire        tx_valid,
    output wire        tx_last,
    input  wire        tx_ready,
    output reg         tx_start
);

    // FSM-side AXIS handshake (gated by the 1-deep register slice below).
    reg src_valid;
    reg src_last;
    reg reply_active;   // TX reply in progress; read by the RX block to drop input

    // =========================================================================
    // RX: buffer incoming UDP payload
    // =========================================================================
    localparam ADDR_W = $clog2(BUF_SIZE);

    reg [7:0]            udp_buf [0:BUF_SIZE-1];
    reg [ADDR_W:0]       payload_len;
    reg [ADDR_W:0]       rx_cnt;
    reg                  pkt_ready;
    reg                  rx_accept;

    reg [31:0]           reply_dst_ip;
    reg [47:0]           reply_dst_mac;
    reg [15:0]           reply_dst_port;   // = original src port
    reg [15:0]           reply_src_port;   // = original dst port

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_cnt         <= {(ADDR_W+1){1'b0}};
            payload_len    <= {(ADDR_W+1){1'b0}};
            pkt_ready      <= 1'b0;
            rx_accept      <= 1'b0;
            reply_dst_ip   <= 32'd0;
            reply_dst_mac  <= 48'd0;
            reply_dst_port <= 16'd0;
            reply_src_port <= 16'd0;
        end else begin
            pkt_ready <= 1'b0;

            // While the TX FSM is replying, drop incoming UDP — the single
            // buffer would otherwise be clobbered mid-transmit. Drains the
            // input by counting bytes and then advancing on tlast.
            if (udp_rx_valid) begin
                if (rx_cnt == {(ADDR_W+1){1'b0}})
                    rx_accept <= (LISTEN_PORT == 16'd0) ||
                                 (udp_rx_dst_port == LISTEN_PORT);

                if (reply_active || pkt_ready ||
                    ((rx_cnt == {(ADDR_W+1){1'b0}}) &&
                     (LISTEN_PORT != 16'd0) &&
                     (udp_rx_dst_port != LISTEN_PORT)) ||
                    ((rx_cnt != {(ADDR_W+1){1'b0}}) && !rx_accept)) begin
                    if (udp_rx_last) begin
                        rx_cnt <= {(ADDR_W+1){1'b0}};
                        rx_accept <= 1'b0;
                    end
                end else begin
                    if (rx_cnt < BUF_SIZE[ADDR_W:0])
                        udp_buf[rx_cnt[ADDR_W-1:0]] <= udp_rx_data;
                    rx_cnt <= rx_cnt + 1'b1;

                    if (udp_rx_last) begin
                        payload_len    <= rx_cnt + 1'b1;
                        rx_cnt         <= {(ADDR_W+1){1'b0}};
                        if ((rx_cnt + 1'b1) <= BUF_SIZE[ADDR_W:0]) begin
                            pkt_ready      <= 1'b1;
                            reply_dst_ip   <= udp_rx_src_ip;
                            reply_dst_mac  <= rx_src_mac;
                            reply_dst_port <= udp_rx_src_port;
                            reply_src_port <= udp_rx_dst_port;
                        end
                        rx_accept <= 1'b0;
                    end
                end
            end
        end
    end

    // =========================================================================
    // TX: build echo reply frame
    // =========================================================================
    localparam [2:0]
        TX_IDLE     = 3'd0,
        TX_ETH_HDR  = 3'd1,
        TX_IP_HDR   = 3'd2,
        TX_UDP_HDR  = 3'd3,
        TX_PAYLOAD  = 3'd4;

    reg [2:0]            tx_state;
    reg [5:0]            tx_cnt;
    reg [ADDR_W:0]       payload_tx_cnt;

    // IP totals: 20 (IP header) + 8 (UDP header) + payload
    wire [15:0] ip_total_len  = 16'd28 + {6'd0, payload_len[ADDR_W:0]};
    wire [15:0] udp_total_len = 16'd8  + {6'd0, payload_len[ADDR_W:0]};
    reg  [15:0] ip_id_cnt;

    // IP header checksum (one-pass accumulator, fold at TX)
    reg  [31:0] ip_csum_acc;
    wire [16:0] ip_fold1   = ip_csum_acc[15:0] + ip_csum_acc[31:16];
    wire [15:0] ip_fold2   = ip_fold1[15:0] + {15'd0, ip_fold1[16]};
    wire [15:0] ip_checksum = ~ip_fold2;

    // 1-deep AXIS register-slice signals + combinational mux, declared ahead of
    // the TX FSM that references src_ready and tx_data_mux (logic is below).
    reg [7:0] r_data;
    reg       r_valid;
    reg       r_last;
    reg [7:0] tx_data_mux;
    wire      src_ready = !r_valid || tx_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state       <= TX_IDLE;
            tx_cnt         <= 6'd0;
            payload_tx_cnt <= {(ADDR_W+1){1'b0}};
            reply_active   <= 1'b0;
            src_valid      <= 1'b0;
            src_last       <= 1'b0;
            tx_start       <= 1'b0;
            ip_id_cnt      <= 16'd2000;
            ip_csum_acc    <= 32'd0;
        end else begin
            if (tx_ready && tx_valid)
                tx_start <= 1'b0;
            src_last <= 1'b0;

            case (tx_state)
                TX_IDLE: begin
                    src_valid <= 1'b0;
                    if (pkt_ready && !reply_active) begin
                        tx_state     <= TX_ETH_HDR;
                        tx_cnt       <= 6'd0;
                        reply_active <= 1'b1;
                        tx_start     <= 1'b1;
                        src_valid    <= 1'b1;
                        ip_id_cnt    <= ip_id_cnt + 16'd1;
                        // Pre-compute IP-header pseudo-sum.
                        // IP header is fixed 0x4500 / total_len / id / 0x4000 /
                        // 0x4011 (TTL=64, proto=UDP) / our_ip / dst_ip.
                        ip_csum_acc  <=
                            {16'd0, 16'h4500} +
                            {16'd0, ip_total_len} +
                            {16'd0, ip_id_cnt + 16'd1} +
                            {16'd0, 16'h4000} +
                            {16'd0, 16'h4011} +
                            {16'd0, our_ip[31:16]} +
                            {16'd0, our_ip[15:0]} +
                            {16'd0, reply_dst_ip[31:16]} +
                            {16'd0, reply_dst_ip[15:0]};
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
                            tx_state <= TX_UDP_HDR;
                            tx_cnt   <= 6'd0;
                        end
                    end
                end

                TX_UDP_HDR: begin
                    src_valid <= 1'b1;
                    if (src_ready && src_valid) begin
                        tx_cnt <= tx_cnt + 6'd1;
                        if (tx_cnt == 6'd7) begin
                            tx_state       <= TX_PAYLOAD;
                            tx_cnt         <= 6'd0;
                            payload_tx_cnt <= {(ADDR_W+1){1'b0}};
                        end
                    end
                end

                TX_PAYLOAD: begin
                    src_valid <= 1'b1;
                    if (src_ready && src_valid) begin
                        payload_tx_cnt <= payload_tx_cnt + 1'b1;
                        // Arm src_last one cycle ahead so it lands with the
                        // last data byte (registers update next clock).
                        if (payload_tx_cnt == payload_len - 2)
                            src_last <= 1'b1;
                        if (payload_tx_cnt == payload_len - 1) begin
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

    // =========================================================================
    // 1-deep AXIS register slice — same pattern as icmp_echo.v to keep the
    // wide tx_data_mux off the eth_mac_tx CRC critical path. r_data/r_valid/
    // r_last and src_ready are declared above (ahead of the FSM).
    // =========================================================================
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

    // =========================================================================
    // TX data mux (combinational). tx_data_mux is declared above.
    // =========================================================================
    always @(*) begin
        tx_data_mux = 8'h00;
        case (tx_state)
            TX_ETH_HDR: begin
                case (tx_cnt)
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
            end
            TX_IP_HDR: begin
                case (tx_cnt)
                    6'd0:  tx_data_mux = 8'h45;
                    6'd1:  tx_data_mux = 8'h00;
                    6'd2:  tx_data_mux = ip_total_len[15:8];
                    6'd3:  tx_data_mux = ip_total_len[7:0];
                    6'd4:  tx_data_mux = ip_id_cnt[15:8];
                    6'd5:  tx_data_mux = ip_id_cnt[7:0];
                    6'd6:  tx_data_mux = 8'h40;          // DF flag
                    6'd7:  tx_data_mux = 8'h00;
                    6'd8:  tx_data_mux = 8'h40;          // TTL = 64
                    6'd9:  tx_data_mux = 8'h11;          // Protocol = 17 (UDP)
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
            end
            TX_UDP_HDR: begin
                case (tx_cnt)
                    6'd0: tx_data_mux = reply_src_port[15:8];
                    6'd1: tx_data_mux = reply_src_port[7:0];
                    6'd2: tx_data_mux = reply_dst_port[15:8];
                    6'd3: tx_data_mux = reply_dst_port[7:0];
                    6'd4: tx_data_mux = udp_total_len[15:8];
                    6'd5: tx_data_mux = udp_total_len[7:0];
                    6'd6: tx_data_mux = 8'h00;          // checksum hi (0 = no check)
                    6'd7: tx_data_mux = 8'h00;          // checksum lo
                    default: tx_data_mux = 8'h00;
                endcase
            end
            TX_PAYLOAD: tx_data_mux = udp_buf[payload_tx_cnt[ADDR_W-1:0]];
            default:    tx_data_mux = 8'h00;
        endcase
    end

    // udp_rx_length / udp_rx_dst_port aren't strictly needed once the reply
    // ports are captured into reply_*; tag them used for clean lint.
    /* verilator lint_off UNUSED */
    wire _unused = |udp_rx_length | |udp_rx_dst_port;
    /* verilator lint_on UNUSED */

endmodule
