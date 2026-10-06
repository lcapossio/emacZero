// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// icmp_echo.v - ICMP Echo (Ping) Responder
// Buffers incoming echo request, swaps addresses, replies with correct
// IP header checksum and incremental ICMP checksum adjustment.
//
// One request is buffered at a time. A request is answered only if it fits
// the buffer (MAX_LEN bytes of ICMP) and arrives while the responder is idle;
// anything else is dropped without touching the buffer, so a reply is never
// sent truncated, padded with stale bytes, or overwritten while it goes out.
// Verilog 2001
// =============================================================================
// ICMP echo request: Type(1)=0x08 | Code(1)=0x00 | Csum(2) | Id(2) | Seq(2) | Data(N)
// ICMP echo reply:   Type(1)=0x00 | Code(1)=0x00 | Csum(2) | Id(2) | Seq(2) | Data(N)
// =============================================================================

module icmp_echo #(
    // Largest ICMP message answered, header included. 1480 is a full
    // 1500-byte IPv4 packet; longer (jumbo) requests get no reply.
    parameter integer MAX_LEN = 1480
) (
    input  wire        clk,
    input  wire        rst_n,

    // Our identity
    input  wire [47:0] our_mac,
    input  wire [31:0] our_ip,

    // ICMP RX (from net_rx - ICMP payload after IP header)
    input  wire [7:0]  icmp_rx_data,
    input  wire        icmp_rx_valid,
    input  wire        icmp_rx_last,
    input  wire        icmp_rx_err,     // with last: discard (net_rx verdict)
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
    // Buffer incoming ICMP packet (max MAX_LEN bytes)
    // =========================================================================
    localparam integer LEN_W = $clog2(MAX_LEN + 1);
    localparam [LEN_W-1:0] LEN_MAX = MAX_LEN;
    localparam [LEN_W-1:0] LEN_1   = 1;
    localparam [LEN_W-1:0] LEN_2   = 2;
    localparam [LEN_W-1:0] LEN_3   = 3;
    localparam [LEN_W-1:0] LEN_8   = 8;
    reg [7:0]       icmp_buf [0:MAX_LEN-1];
    reg [LEN_W-1:0] icmp_len;       // length of the buffered request
    reg [LEN_W-1:0] rx_cnt;         // bytes stored of the packet arriving
    reg             rx_ovf;         // it has more than MAX_LEN bytes
    reg             rx_in_pkt;      // a packet is arriving (first byte seen)
    reg             rx_drop;        // it arrived busy: ignore it to its end
    reg             is_echo_req;
    reg             pkt_ready;
    reg             reply_active;   // driven by the TX FSM below

    // Busy from the request being handed over until its reply is sent. A
    // packet whose first byte arrives while busy is dropped whole.
    wire rx_busy  = pkt_ready || reply_active;
    wire rx_sop   = icmp_rx_valid && !rx_in_pkt;
    wire rx_skip  = rx_sop ? rx_busy : rx_drop;
    wire rx_store = icmp_rx_valid && !rx_skip && (rx_cnt != LEN_MAX);
    // The byte that would be number MAX_LEN+1 makes the packet too long.
    wire rx_ovf_now = rx_ovf || (icmp_rx_valid && !rx_skip && (rx_cnt == LEN_MAX));

    // Captured source info for reply
    reg [31:0] reply_dst_ip;
    reg [47:0] reply_dst_mac;

    // =========================================================================
    // RX: buffer incoming ICMP data
    // =========================================================================
    // The buffer has no reset and one read port (the TX byte), so it maps to
    // distributed RAM. The checksum bytes are also kept in orig_csum, so
    // nothing else reads the buffer: two more fixed-index reads would build
    // it from flip-flops.
    reg [15:0] orig_csum;
    always @(posedge clk) begin
        if (rx_store) begin
            icmp_buf[rx_cnt] <= icmp_rx_data;
            if (rx_cnt == LEN_2) orig_csum[15:8] <= icmp_rx_data;
            if (rx_cnt == LEN_3) orig_csum[7:0]  <= icmp_rx_data;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_cnt        <= {LEN_W{1'b0}};
            rx_ovf        <= 1'b0;
            rx_in_pkt     <= 1'b0;
            rx_drop       <= 1'b0;
            icmp_len      <= {LEN_W{1'b0}};
            is_echo_req   <= 1'b0;
            pkt_ready     <= 1'b0;
            reply_dst_ip  <= 32'd0;
            reply_dst_mac <= 48'd0;
        end else begin
            pkt_ready <= 1'b0;

            if (icmp_rx_valid) begin
                if (rx_sop)
                    rx_drop <= rx_busy;
                rx_in_pkt <= !icmp_rx_last;

                if (rx_store) begin
                    rx_cnt <= rx_cnt + LEN_1;
                    // Check ICMP type (byte 0) and code (byte 1)
                    if (rx_cnt == {LEN_W{1'b0}})
                        is_echo_req <= (icmp_rx_data == 8'h08);
                    if (rx_cnt == LEN_1)
                        is_echo_req <= is_echo_req && (icmp_rx_data == 8'h00);
                end
                if (rx_ovf_now)
                    rx_ovf <= 1'b1;

                if (icmp_rx_last) begin
                    rx_cnt <= {LEN_W{1'b0}};
                    rx_ovf <= 1'b0;
                    // icmp_len changes only with an accepted request, so it
                    // holds still while that request's reply goes out.
                    if (!rx_skip && !rx_ovf_now && is_echo_req && !icmp_rx_err &&
                        (rx_cnt + LEN_1) >= LEN_8) begin
                        icmp_len      <= rx_cnt + LEN_1;
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

    reg [2:0]       tx_state;
    reg [5:0]       tx_cnt;
    reg [LEN_W-1:0] icmp_tx_cnt;

    // IP header fields
    wire [15:0] ip_total_len = 16'd20 + icmp_len;
    reg  [15:0] ip_id_cnt;

    // IP header checksum
    reg  [31:0] ip_csum_acc;
    wire [16:0] ip_fold1 = ip_csum_acc[15:0] + ip_csum_acc[31:16];
    wire [15:0] ip_fold2 = ip_fold1[15:0] + {15'd0, ip_fold1[16]};
    wire [15:0] ip_checksum = ~ip_fold2;

    // ICMP checksum: incremental update (type 0x08 -> 0x00 = add 0x0800)
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
            icmp_tx_cnt  <= {LEN_W{1'b0}};
            reply_active <= 1'b0;
            src_valid    <= 1'b0;
            src_last     <= 1'b0;
            tx_start     <= 1'b0;
            ip_id_cnt    <= 16'd1000;
            ip_csum_acc  <= 32'd0;
        end else begin
            if (tx_ready && tx_valid)
                tx_start <= 1'b0;
            // Hold tlast until the output slice captures it: the slice samples
            // src_* only while src_ready is high, so an unconditional clear drops
            // tlast when the sink stalls on that beat and merges two frames.
            if (src_ready)
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
                            icmp_tx_cnt <= {LEN_W{1'b0}};
                        end
                    end
                end

                TX_ICMP: begin
                    src_valid <= 1'b1;
                    if (src_ready && src_valid) begin
                        icmp_tx_cnt <= icmp_tx_cnt + LEN_1;
                        // Arm src_last one cycle ahead so it lands with the
                        // last data byte (registers update next clock).
                        if (icmp_tx_cnt == icmp_len - LEN_2)
                            src_last <= 1'b1;
                        if (icmp_tx_cnt == icmp_len - LEN_1) begin
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
                if (icmp_tx_cnt == {LEN_W{1'b0}} || icmp_tx_cnt == LEN_1)
                    tx_data_mux = 8'h00;                 // Type = Echo Reply, Code = 0
                else if (icmp_tx_cnt == LEN_2)
                    tx_data_mux = new_csum[15:8];        // Adjusted checksum
                else if (icmp_tx_cnt == LEN_3)
                    tx_data_mux = new_csum[7:0];
                else
                    tx_data_mux = icmp_buf[icmp_tx_cnt];
            end
            default: tx_data_mux = 8'h00;
        endcase
    end

endmodule
