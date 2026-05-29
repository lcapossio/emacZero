// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// udp_blast.v - Line-rate UDP traffic generator
//
// While `enable` is high, continuously emits well-formed UDP/IPv4/Ethernet
// frames to {dst_mac, dst_ip, dst_port} from {our_mac, our_ip, src_port}.
// Frames are sent back-to-back; eth_mac_tx adds preamble/SFD/FCS/IFG. The
// generator is the AXIS master; eth_mac_tx accepts one byte per cycle so
// throughput is wire-rate (8128 fps with 1518-byte frames at 100 Mbps).
//
// Each datagram carries the 12-byte iperf2 UDP_datagram header
// (id + tv_sec + tv_usec) so an iperf2 -u -s server on the receiver can
// parse and count packets natively. The default timestamp tick assumes the
// Arty 100 MHz system clock: 100 cycles per microsecond.
//
// IP header checksum is computed once at start (all fields except total_len
// are constant; total_len is constant within a blast, so the IP csum is
// constant too). UDP checksum = 0 (skipped per RFC 768).
//
// Verilog 2001
// =============================================================================

module udp_blast #(
    parameter [31:0] START_DELAY_CYCLES = 32'd0,
    parameter [6:0]  USEC_TICK_CYCLES   = 7'd100
)(
    input  wire        clk,
    input  wire        rst_n,

    // Identity
    input  wire [47:0] our_mac,
    input  wire [31:0] our_ip,

    // Target (typically captured from a host trigger packet)
    input  wire [47:0] dst_mac,
    input  wire [31:0] dst_ip,
    input  wire [15:0] dst_port,
    input  wire [15:0] src_port,

    // Configuration
    input  wire [13:0] payload_size,   // total UDP payload bytes (incl. 12B iperf2 hdr)
    input  wire        enable,         // 1 = blast continuously while held high
    input  wire [23:0] inter_frame_delay, // sys_clk cycles to wait between frames (0 = back-to-back)

    // Status
    output reg  [31:0] pkts_sent,
    output reg         pkt_done_pulse,    // 1-cycle pulse after each TX frame

    // AXIS TX (master). Uses 1-deep skid the same way as udp_echo / icmp_echo
    // so the wide tx_data_mux stays off the eth_mac_tx CRC critical path.
    output wire [7:0]  tx_data,
    output wire        tx_valid,
    output wire        tx_last,
    input  wire        tx_ready,
    output reg         tx_start
);

    // FSM-side AXIS handshake
    reg src_valid;
    reg src_last;

    // ============================================================
    // Frame layout
    //   [0..5]    dst MAC
    //   [6..11]   src MAC (= our_mac)
    //   [12..13]  ethertype 0x0800
    //   [14..33]  IPv4 header (20 bytes, proto=UDP)
    //   [34..41]  UDP header (8 bytes, csum=0)
    //   [42..53]  iperf2 header (id + tv_sec + tv_usec)
    //   [54..]    filler bytes
    // ============================================================
    localparam [3:0]
        TX_IDLE      = 4'd0,
        TX_ETH_HDR   = 4'd1,
        TX_IP_HDR    = 4'd2,
        TX_UDP_HDR   = 4'd3,
        TX_IPERF_HDR = 4'd4,
        TX_PAYLOAD   = 4'd5;

    reg [3:0]  tx_state;
    reg [5:0]  hdr_cnt;
    reg [13:0] body_cnt;
    reg [13:0] payload_lat;     // latched at frame start
    reg [23:0] gap_cnt;         // counts down inter_frame_delay between frames
    reg [31:0] start_delay_cnt;  // optional delay before the first frame of a burst
    reg        enable_d;

    // Pre-computed frame fields. ip_total_len = 20 (IP) + 8 (UDP) + payload_size.
    wire [15:0] ip_total_len  = 16'd28 + {2'd0, payload_lat};
    wire [15:0] udp_total_len = 16'd8  + {2'd0, payload_lat};

    // IP id increments each frame so the receiver can correlate
    reg [15:0] ip_id_cnt;
    reg [15:0] ip_id_lat;

    // IP header checksum: latched at packet start so the long 9-term carry
    // chain doesn't sit on the tx_data_mux -> r_data path. The fold is two
    // small adders done combinationally on the registered accumulator.
    reg [31:0] ip_csum_acc;
    wire [16:0] ip_fold1    = ip_csum_acc[15:0] + ip_csum_acc[31:16];
    wire [15:0] ip_fold2    = ip_fold1[15:0] + {15'd0, ip_fold1[16]};
    wire [15:0] ip_checksum = ~ip_fold2;

    // iperf2 sequence number (32-bit, wraps)
    reg [31:0] seq_cnt;
    reg [6:0]  usec_tick_cnt;
    reg [31:0] ts_sec_cnt;
    reg [31:0] ts_usec_cnt;
    reg [31:0] ts_sec_lat;
    reg [31:0] ts_usec_lat;

    // 1-deep AXIS register-slice signals + combinational mux, declared ahead of
    // the TX FSM that references src_ready and tx_data_mux (logic is below).
    reg [7:0] r_data;
    reg       r_valid;
    reg       r_last;
    reg [7:0] tx_data_mux;
    wire      src_ready = !r_valid || tx_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state    <= TX_IDLE;
            hdr_cnt     <= 6'd0;
            body_cnt    <= 14'd0;
            payload_lat <= 14'd0;
            gap_cnt     <= 24'd0;
            start_delay_cnt <= 32'd0;
            enable_d    <= 1'b0;
            ip_id_cnt   <= 16'd1;
            ip_id_lat   <= 16'd1;
            seq_cnt     <= 32'd0;
            usec_tick_cnt <= 7'd0;
            ts_sec_cnt  <= 32'd0;
            ts_usec_cnt <= 32'd0;
            ts_sec_lat  <= 32'd0;
            ts_usec_lat <= 32'd0;
            pkts_sent   <= 32'd0;
            pkt_done_pulse <= 1'b0;
            ip_csum_acc <= 32'd0;
            src_valid   <= 1'b0;
            src_last    <= 1'b0;
            tx_start    <= 1'b0;
        end else begin
            if (usec_tick_cnt == USEC_TICK_CYCLES - 7'd1) begin
                usec_tick_cnt <= 7'd0;
                if (ts_usec_cnt == 32'd999999) begin
                    ts_usec_cnt <= 32'd0;
                    ts_sec_cnt  <= ts_sec_cnt + 32'd1;
                end else begin
                    ts_usec_cnt <= ts_usec_cnt + 32'd1;
                end
            end else begin
                usec_tick_cnt <= usec_tick_cnt + 7'd1;
            end
            enable_d <= enable;
            pkt_done_pulse <= 1'b0;
            if (tx_ready && tx_valid)
                tx_start <= 1'b0;
            src_last <= 1'b0;

            if (!enable) begin
                start_delay_cnt <= 32'd0;
            end else if (!enable_d) begin
                start_delay_cnt <= START_DELAY_CYCLES;
                seq_cnt         <= 32'd0;
                pkts_sent       <= 32'd0;
            end

            case (tx_state)
                TX_IDLE: begin
                    src_valid <= 1'b0;
                    if (gap_cnt != 24'd0) begin
                        gap_cnt <= gap_cnt - 24'd1;
                    end else if (enable && !enable_d && START_DELAY_CYCLES != 32'd0) begin
                        // Latch the new-burst delay above; start after it expires.
                    end else if (start_delay_cnt != 32'd0) begin
                        start_delay_cnt <= start_delay_cnt - 32'd1;
                    end else if (enable) begin
                        tx_state    <= TX_ETH_HDR;
                        hdr_cnt     <= 6'd0;
                        payload_lat <= payload_size;
                        ip_id_lat   <= ip_id_cnt;
                        ip_id_cnt   <= ip_id_cnt + 16'd1;
                        ts_sec_lat  <= ts_sec_cnt;
                        ts_usec_lat <= ts_usec_cnt;
                        // Register the long sum once per frame.
                        ip_csum_acc <= {16'd0, 16'h4500}
                                     + {16'd0, 16'd28 + {2'd0, payload_size}}
                                     + {16'd0, ip_id_cnt}
                                     + {16'd0, 16'h4000}
                                     + {16'd0, 16'h4011}
                                     + {16'd0, our_ip[31:16]}
                                     + {16'd0, our_ip[15:0]}
                                     + {16'd0, dst_ip[31:16]}
                                     + {16'd0, dst_ip[15:0]};
                        tx_start    <= 1'b1;
                        src_valid   <= 1'b1;
                    end
                end

                TX_ETH_HDR: begin
                    src_valid <= 1'b1;
                    if (src_ready && src_valid) begin
                        hdr_cnt <= hdr_cnt + 6'd1;
                        if (hdr_cnt == 6'd13) begin
                            tx_state <= TX_IP_HDR;
                            hdr_cnt  <= 6'd0;
                        end
                    end
                end

                TX_IP_HDR: begin
                    src_valid <= 1'b1;
                    if (src_ready && src_valid) begin
                        hdr_cnt <= hdr_cnt + 6'd1;
                        if (hdr_cnt == 6'd19) begin
                            tx_state <= TX_UDP_HDR;
                            hdr_cnt  <= 6'd0;
                        end
                    end
                end

                TX_UDP_HDR: begin
                    src_valid <= 1'b1;
                    if (src_ready && src_valid) begin
                        hdr_cnt <= hdr_cnt + 6'd1;
                        if (hdr_cnt == 6'd7) begin
                            tx_state <= TX_IPERF_HDR;
                            hdr_cnt  <= 6'd0;
                        end
                    end
                end

                TX_IPERF_HDR: begin
                    src_valid <= 1'b1;
                    if (src_ready && src_valid) begin
                        hdr_cnt <= hdr_cnt + 6'd1;
                        if (hdr_cnt == 6'd11) begin
                            tx_state <= TX_PAYLOAD;
                            body_cnt <= 14'd12;  // 12 bytes already counted as iperf hdr
                        end
                    end
                end

                TX_PAYLOAD: begin
                    src_valid <= 1'b1;
                    if (src_ready && src_valid) begin
                        body_cnt <= body_cnt + 14'd1;
                        // Arm src_last one cycle ahead so it lands with the
                        // last data byte (registers update next clock).
                        if (body_cnt == payload_lat - 14'd2)
                            src_last <= 1'b1;
                        if (body_cnt == payload_lat - 14'd1) begin
                            // Frame done. Always return through TX_IDLE for one
                            // cycle so src_valid drops; otherwise the 1-deep
                            // skid would latch the last payload byte as byte 0
                            // of the next frame (verified at wire level: byte
                            // 0 = last_payload_byte, dst-MAC shifted by 1).
                            pkts_sent      <= pkts_sent + 32'd1;
                            seq_cnt        <= seq_cnt   + 32'd1;
                            pkt_done_pulse <= 1'b1;
                            tx_state       <= TX_IDLE;
                            gap_cnt        <= inter_frame_delay;
                            src_valid      <= 1'b0;
                        end
                    end
                end

                default: tx_state <= TX_IDLE;
            endcase
        end
    end

    // ============================================================
    // 1-deep AXIS register slice. r_data/r_valid/r_last and src_ready are
    // declared above (ahead of the FSM that references them).
    // ============================================================
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

    // ============================================================
    // Combinational byte mux. tx_data_mux is declared above.
    // ============================================================
    always @* begin
        tx_data_mux = 8'h00;
        case (tx_state)
            TX_ETH_HDR: case (hdr_cnt)
                6'd0:  tx_data_mux = dst_mac[47:40];
                6'd1:  tx_data_mux = dst_mac[39:32];
                6'd2:  tx_data_mux = dst_mac[31:24];
                6'd3:  tx_data_mux = dst_mac[23:16];
                6'd4:  tx_data_mux = dst_mac[15:8];
                6'd5:  tx_data_mux = dst_mac[7:0];
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

            TX_IP_HDR: case (hdr_cnt)
                6'd0:  tx_data_mux = 8'h45;
                6'd1:  tx_data_mux = 8'h00;
                6'd2:  tx_data_mux = ip_total_len[15:8];
                6'd3:  tx_data_mux = ip_total_len[7:0];
                6'd4:  tx_data_mux = ip_id_lat[15:8];
                6'd5:  tx_data_mux = ip_id_lat[7:0];
                6'd6:  tx_data_mux = 8'h40;
                6'd7:  tx_data_mux = 8'h00;
                6'd8:  tx_data_mux = 8'h40;             // TTL = 64
                6'd9:  tx_data_mux = 8'h11;             // protocol = UDP
                6'd10: tx_data_mux = ip_checksum[15:8];
                6'd11: tx_data_mux = ip_checksum[7:0];
                6'd12: tx_data_mux = our_ip[31:24];
                6'd13: tx_data_mux = our_ip[23:16];
                6'd14: tx_data_mux = our_ip[15:8];
                6'd15: tx_data_mux = our_ip[7:0];
                6'd16: tx_data_mux = dst_ip[31:24];
                6'd17: tx_data_mux = dst_ip[23:16];
                6'd18: tx_data_mux = dst_ip[15:8];
                6'd19: tx_data_mux = dst_ip[7:0];
                default: tx_data_mux = 8'h00;
            endcase

            TX_UDP_HDR: case (hdr_cnt)
                6'd0: tx_data_mux = src_port[15:8];
                6'd1: tx_data_mux = src_port[7:0];
                6'd2: tx_data_mux = dst_port[15:8];
                6'd3: tx_data_mux = dst_port[7:0];
                6'd4: tx_data_mux = udp_total_len[15:8];
                6'd5: tx_data_mux = udp_total_len[7:0];
                6'd6: tx_data_mux = 8'h00;     // UDP csum = 0 (skipped)
                6'd7: tx_data_mux = 8'h00;
                default: tx_data_mux = 8'h00;
            endcase

            TX_IPERF_HDR: case (hdr_cnt)
                // iperf2 UDP_datagram: { int32 id (BE); uint32 tv_sec (BE);
                //                        uint32 tv_usec (BE) }
                6'd0:  tx_data_mux = seq_cnt[31:24];
                6'd1:  tx_data_mux = seq_cnt[23:16];
                6'd2:  tx_data_mux = seq_cnt[15:8];
                6'd3:  tx_data_mux = seq_cnt[7:0];
                6'd4:  tx_data_mux = ts_sec_lat[31:24];
                6'd5:  tx_data_mux = ts_sec_lat[23:16];
                6'd6:  tx_data_mux = ts_sec_lat[15:8];
                6'd7:  tx_data_mux = ts_sec_lat[7:0];
                6'd8:  tx_data_mux = ts_usec_lat[31:24];
                6'd9:  tx_data_mux = ts_usec_lat[23:16];
                6'd10: tx_data_mux = ts_usec_lat[15:8];
                6'd11: tx_data_mux = ts_usec_lat[7:0];
                default: tx_data_mux = 8'h00;
            endcase

            // Filler payload: simple ramp so iperf2 packet captures look sane.
            TX_PAYLOAD: tx_data_mux = body_cnt[7:0];

            default: tx_data_mux = 8'h00;
        endcase
    end

endmodule
