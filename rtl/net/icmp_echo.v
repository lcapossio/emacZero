// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// icmp_echo.v - ICMP Echo (Ping) Responder
// Buffers incoming echo request, swaps addresses, replies with correct
// IP header checksum and incremental ICMP checksum adjustment.
// Verilog 2001
// =============================================================================
// ICMP echo request: Type(1)=0x08 | Code(1)=0x00 | Csum(2) | Id(2) | Seq(2) | Data(N)
// ICMP echo reply:   Type(1)=0x00 | Code(1)=0x00 | Csum(2) | Id(2) | Seq(2) | Data(N)
// =============================================================================

module icmp_echo (
    input  wire        clk,
    input  wire        rst_n,

    // Our identity
    input  wire [47:0] our_mac,
    input  wire [31:0] our_ip,

    // ICMP RX (from net_rx - ICMP payload after IP header)
    input  wire [7:0]  icmp_rx_data,
    input  wire        icmp_rx_valid,
    input  wire        icmp_rx_last,
    input  wire [31:0] icmp_rx_src_ip,

    // Source MAC (captured by net_rx before IP parsing)
    input  wire [47:0] rx_src_mac,

    // TX output - full Ethernet frame (dst+src+type+IP+ICMP)
    output wire [7:0]  tx_data,
    output wire        tx_valid,
    output wire        tx_last,
    input  wire        tx_ready,
    output reg         tx_start
);

    // FSM-side AXIS handshake (internal). The external tx_data / tx_valid /
    // tx_last go through a 1-deep register slice below — this breaks the
    // long combinational path tx_data_mux -> eth_mac_tx.crc_saved that was
    // the design's worst sys_clk path.
    reg       src_valid;
    reg       src_last;

    // =========================================================================
    // Buffer incoming ICMP packet (max 256 bytes)
    // =========================================================================
    localparam BUF_SIZE = 256;
    reg [7:0]  icmp_buf [0:BUF_SIZE-1];
    reg [8:0]  icmp_len;
    reg [8:0]  rx_cnt;
    reg        is_echo_req;
    reg        pkt_ready;

    // Captured source info for reply
    reg [31:0] reply_dst_ip;
    reg [47:0] reply_dst_mac;

    // =========================================================================
    // RX: buffer incoming ICMP data
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_cnt        <= 9'd0;
            icmp_len      <= 9'd0;
            is_echo_req   <= 1'b0;
            pkt_ready     <= 1'b0;
            reply_dst_ip  <= 32'd0;
            reply_dst_mac <= 48'd0;
        end else begin
            pkt_ready <= 1'b0;

            if (icmp_rx_valid) begin
                if (rx_cnt < BUF_SIZE)
                    icmp_buf[rx_cnt] <= icmp_rx_data;
                rx_cnt <= rx_cnt + 9'd1;

                // Check ICMP type (byte 0) and code (byte 1)
                if (rx_cnt == 9'd0)
                    is_echo_req <= (icmp_rx_data == 8'h08);
                if (rx_cnt == 9'd1)
                    is_echo_req <= is_echo_req && (icmp_rx_data == 8'h00);

                if (icmp_rx_last) begin
                    icmp_len <= rx_cnt + 9'd1;
                    rx_cnt   <= 9'd0;
                    if (is_echo_req && (rx_cnt + 9'd1) >= 9'd8) begin
                        pkt_ready     <= 1'b1;
                        reply_dst_ip  <= icmp_rx_src_ip;
                        reply_dst_mac <= rx_src_mac;
                    end
                end
            end
        end
    end

    // =========================================================================
    // TX: generate echo reply
    // =========================================================================
    // Frame layout:
    //   [0:5]   Dst MAC
    //   [6:11]  Src MAC (ours)
    //   [12:13] Ethertype 0x0800 (IPv4)
    //   [14:33] IP header (20 bytes)
    //   [34+]   ICMP payload (type=0x00, checksum adjusted)

    localparam [2:0]
        TX_IDLE     = 3'd0,
        TX_ETH_HDR  = 3'd1,
        TX_IP_HDR   = 3'd2,
        TX_ICMP     = 3'd3;

    reg [2:0]  tx_state;
    reg [5:0]  tx_cnt;
    reg [8:0]  icmp_tx_cnt;
    reg        reply_active;

    // IP header fields
    wire [15:0] ip_total_len = 16'd20 + icmp_len;
    reg  [15:0] ip_id_cnt;

    // IP header checksum
    reg  [31:0] ip_csum_acc;
    wire [16:0] ip_fold1 = ip_csum_acc[15:0] + ip_csum_acc[31:16];
    wire [15:0] ip_fold2 = ip_fold1[15:0] + {15'd0, ip_fold1[16]};
    wire [15:0] ip_checksum = ~ip_fold2;

    // ICMP checksum: incremental update (type 0x08 -> 0x00 = add 0x0800)
    wire [15:0] orig_csum = {icmp_buf[2], icmp_buf[3]};
    wire [16:0] new_csum_raw = {1'b0, orig_csum} + 17'h0800;
    wire [15:0] new_csum = new_csum_raw[15:0] + {15'd0, new_csum_raw[16]};

    // AXIS register-slice signals (1-deep), declared ahead of the TX FSM that
    // references them. src_ready is the slice "can accept" handshake; the slice
    // registers and the combinational tx_data_mux are driven further below.
    reg [7:0]  r_data;
    reg        r_valid;
    reg        r_last;
    reg [7:0]  tx_data_mux;
    wire       src_ready = !r_valid || tx_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state     <= TX_IDLE;
            tx_cnt       <= 6'd0;
            icmp_tx_cnt  <= 9'd0;
            reply_active <= 1'b0;
            src_valid    <= 1'b0;
            src_last     <= 1'b0;
            tx_start     <= 1'b0;
            ip_id_cnt    <= 16'd1000;
            ip_csum_acc  <= 32'd0;
        end else begin
            if (tx_ready && tx_valid)
                tx_start <= 1'b0;
            src_last  <= 1'b0;

            case (tx_state)
                TX_IDLE: begin
                    src_valid <= 1'b0;
                    if (pkt_ready && !reply_active) begin
                        tx_state     <= TX_ETH_HDR;
                        tx_cnt       <= 6'd0;
                        reply_active <= 1'b1;
                        tx_start     <= 1'b1;
                        src_valid    <= 1'b1;  // assert immediately so byte 0 lands
                        ip_id_cnt    <= ip_id_cnt + 16'd1;
                        ip_csum_acc  <=
                            {16'd0, 16'h4500} +
                            {16'd0, ip_total_len} +
                            {16'd0, ip_id_cnt + 16'd1} +
                            {16'd0, 16'h4000} +
                            {16'd0, 16'h4001} +
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
                            tx_state    <= TX_ICMP;
                            tx_cnt      <= 6'd0;
                            icmp_tx_cnt <= 9'd0;
                        end
                    end
                end

                TX_ICMP: begin
                    src_valid <= 1'b1;
                    if (src_ready && src_valid) begin
                        icmp_tx_cnt <= icmp_tx_cnt + 9'd1;
                        // Arm src_last one cycle ahead so it lands with the
                        // last data byte (registers update next clock).
                        if (icmp_tx_cnt == icmp_len - 9'd2)
                            src_last <= 1'b1;
                        if (icmp_tx_cnt == icmp_len - 9'd1) begin
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
    // AXIS register slice (1-deep). Breaks the long combinational path from
    // tx_data_mux into eth_mac_tx's CRC pipeline. The FSM produces src_*;
    // tx_* are registered outputs driven by r_*. r_data/r_valid/r_last and
    // src_ready are declared above (ahead of the FSM that references them).
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
                    6'd0:  tx_data_mux = 8'h45;          // Version=4, IHL=5
                    6'd1:  tx_data_mux = 8'h00;          // DSCP/ECN
                    6'd2:  tx_data_mux = ip_total_len[15:8];
                    6'd3:  tx_data_mux = ip_total_len[7:0];
                    6'd4:  tx_data_mux = ip_id_cnt[15:8];
                    6'd5:  tx_data_mux = ip_id_cnt[7:0];
                    6'd6:  tx_data_mux = 8'h40;          // Don't Fragment
                    6'd7:  tx_data_mux = 8'h00;
                    6'd8:  tx_data_mux = 8'h40;          // TTL=64
                    6'd9:  tx_data_mux = 8'h01;          // Protocol=ICMP
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
            TX_ICMP: begin
                case (icmp_tx_cnt)
                    9'd0: tx_data_mux = 8'h00;           // Type = Echo Reply
                    9'd1: tx_data_mux = 8'h00;           // Code = 0
                    9'd2: tx_data_mux = new_csum[15:8];  // Adjusted checksum
                    9'd3: tx_data_mux = new_csum[7:0];
                    default: tx_data_mux = icmp_buf[icmp_tx_cnt];
                endcase
            end
            default: tx_data_mux = 8'h00;
        endcase
    end

endmodule
