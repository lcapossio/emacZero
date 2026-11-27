// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// net_service64.v - the demo L3 stack (ARP responder, ping, UDP echo) behind
// a 64-bit AXI4-Stream MAC such as eth_mac_sys_10g, so a 10G port can be
// reached from a PC through a switch.
//
//   s_axis (64-bit RX frames) -> 64:8 unpacker -> arp_responder
//                                              -> net_rx -> icmp_echo
//                                                        -> udp_echo
//   arty_tx_arbiter (ARP > ICMP > UDP) -> 8:64 packer -> m_axis (64-bit TX)
//
// The stack runs one byte per clock, so at a 200 MHz clock it takes up to
// 1.6 Gb/s; s_axis is held off meanwhile (the MAC's RX FIFO drops whole
// frames when it fills). Frames are whole, FCS stripped, as eth_mac_sys_10g
// delivers them; tuser marks a bad one (passed on as terror with the last
// byte, so the stack ignores it). Replies leave without an FCS, and the MAC
// pads and appends it. our_mac must be the MAC's station address.
// Verilog 2001
// =============================================================================

module net_service64 #(
    parameter [15:0] UDP_ECHO_PORT = 16'd9999
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [47:0] our_mac,
    input  wire [31:0] our_ip,

    // RX frames from the MAC
    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tuser,

    // TX frames to the MAC
    output reg  [63:0] m_axis_tdata,
    output reg  [7:0]  m_axis_tkeep,
    output reg         m_axis_tvalid,
    input  wire        m_axis_tready,
    output reg         m_axis_tlast,

    // one-cycle pulses: a frame taken in, a reply sent out
    output wire        rx_frame,
    output wire        tx_frame
);

    // =========================================================================
    // RX: 64 -> 8, one byte per clock, no gap between beats of a frame
    // =========================================================================
    reg  [63:0] u_data;
    reg  [7:0]  u_keep;
    reg         u_last, u_user, u_full, u_first;
    reg  [2:0]  u_idx;
    // the byte out now is the beat's last one: tkeep is contiguous from bit
    // 0, so that is the top set bit
    wire        u_end = !u_keep[u_idx + 3'd1] || (u_idx == 3'd7);
    assign s_axis_tready = !u_full || u_end;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            u_full  <= 1'b0;
            u_first <= 1'b1;
            u_idx   <= 3'd0;
            u_data  <= 64'd0;
            u_keep  <= 8'd0;
            u_last  <= 1'b0;
            u_user  <= 1'b0;
        end else begin
            if (u_full) begin
                u_idx <= u_idx + 3'd1;
                if (u_idx == 3'd0)
                    u_first <= 1'b0;
                if (u_end) begin
                    u_full <= 1'b0;
                    u_idx  <= 3'd0;
                    if (u_last)     // after the clear above: a 1-byte beat
                        u_first <= 1'b1;
                end
            end
            if (s_axis_tvalid && s_axis_tready) begin
                u_data <= s_axis_tdata;
                u_keep <= s_axis_tkeep;
                u_last <= s_axis_tlast;
                u_user <= s_axis_tuser;
                u_full <= 1'b1;
                u_idx  <= 3'd0;
            end
        end
    end

    wire [7:0] rx_tdata  = u_data[{u_idx, 3'b000} +: 8];
    wire       rx_tvalid = u_full;
    wire       rx_tlast  = u_full && u_end && u_last;
    wire       rx_tsof   = u_full && u_first && (u_idx == 3'd0);
    wire       rx_terror = rx_tlast && u_user;
    assign rx_frame = rx_tlast;

    // =========================================================================
    // L3 stack
    // =========================================================================
    wire [7:0]  arp_tdata, icmp_tdata, udp_tdata, tx_tdata;
    wire        arp_tvalid, arp_tready, arp_tlast;
    wire        icmp_tvalid, icmp_tready, icmp_tlast;
    wire        udp_tvalid, udp_tready, udp_tlast;
    wire        tx_tvalid, tx_tready, tx_tlast;

    arp_responder u_arp (
        .clk            (clk),
        .rst_n          (rst_n),
        .enable         (1'b1),
        .rx_tdata       (rx_tdata),
        .rx_tvalid      (rx_tvalid),
        .rx_tlast       (rx_tlast),
        .rx_terror      (rx_terror),
        .rx_tsof        (rx_tsof),
        .tx_tdata       (arp_tdata),
        .tx_tvalid      (arp_tvalid),
        .tx_tready      (arp_tready),
        .tx_tlast       (arp_tlast),
        .our_mac        (our_mac),
        .our_ip         (our_ip),
        .arp_reply_sent ()
    );

    wire [7:0]  icmp_rx_data, udp_rx_data;
    wire        icmp_rx_valid, icmp_rx_last, icmp_rx_err;
    wire        udp_rx_valid, udp_rx_last, udp_rx_err;
    wire [31:0] icmp_src_ip, udp_src_ip;
    wire [47:0] rx_src_mac;
    wire [15:0] udp_src_port, udp_dst_port, udp_length;

    net_rx u_net_rx (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_axis_tdata   (rx_tdata),
        .s_axis_tvalid  (rx_tvalid),
        .s_axis_tlast   (rx_tlast),
        .s_axis_tsof    (rx_tsof),
        .s_axis_terror  (rx_terror),
        .arp_data       (),
        .arp_valid      (),
        .arp_last       (),
        .icmp_data      (icmp_rx_data),
        .icmp_valid     (icmp_rx_valid),
        .icmp_last      (icmp_rx_last),
        .icmp_err       (icmp_rx_err),
        .icmp_src_ip    (icmp_src_ip),
        .udp_data       (udp_rx_data),
        .udp_valid      (udp_rx_valid),
        .udp_last       (udp_rx_last),
        .udp_err        (udp_rx_err),
        .udp_src_ip     (udp_src_ip),
        .udp_src_port   (udp_src_port),
        .udp_dst_port   (udp_dst_port),
        .udp_length     (udp_length),
        .rx_src_mac     (rx_src_mac),
        .our_ip         (our_ip)
    );

    icmp_echo u_icmp (
        .clk            (clk),
        .rst_n          (rst_n),
        .our_mac        (our_mac),
        .our_ip         (our_ip),
        .icmp_rx_data   (icmp_rx_data),
        .icmp_rx_valid  (icmp_rx_valid),
        .icmp_rx_last   (icmp_rx_last),
        .icmp_rx_err    (icmp_rx_err),
        .icmp_rx_src_ip (icmp_src_ip),
        .rx_src_mac     (rx_src_mac),
        .tx_data        (icmp_tdata),
        .tx_valid       (icmp_tvalid),
        .tx_last        (icmp_tlast),
        .tx_ready       (icmp_tready),
        .tx_start       ()
    );

    udp_echo #(
        .BUF_SIZE    (1536),
        .LISTEN_PORT (UDP_ECHO_PORT)
    ) u_udp (
        .clk             (clk),
        .rst_n           (rst_n),
        .our_mac         (our_mac),
        .our_ip          (our_ip),
        .udp_rx_data     (udp_rx_data),
        .udp_rx_valid    (udp_rx_valid),
        .udp_rx_last     (udp_rx_last),
        .udp_rx_err      (udp_rx_err),
        .udp_rx_src_ip   (udp_src_ip),
        .udp_rx_src_port (udp_src_port),
        .udp_rx_dst_port (udp_dst_port),
        .udp_rx_length   (udp_length),
        .rx_src_mac      (rx_src_mac),
        .tx_data         (udp_tdata),
        .tx_valid        (udp_tvalid),
        .tx_last         (udp_tlast),
        .tx_ready        (udp_tready),
        .tx_start        ()
    );

    arty_tx_arbiter #(
        .BLAST_SERVICE_INTERVAL    (8'd255),
        .BLAST_SERVICE_IDLE_CYCLES (12'd0)
    ) u_arb (
        .clk           (clk),
        .rst_n         (rst_n),
        .arp_tx_active (1'b0),
        .seq_tdata     (8'd0),
        .seq_tvalid    (1'b0),
        .seq_tready    (),
        .seq_tlast     (1'b0),
        .arp_tdata     (arp_tdata),
        .arp_tvalid    (arp_tvalid),
        .arp_tready    (arp_tready),
        .arp_tlast     (arp_tlast),
        .icmp_tdata    (icmp_tdata),
        .icmp_tvalid   (icmp_tvalid),
        .icmp_tready   (icmp_tready),
        .icmp_tlast    (icmp_tlast),
        .stats_tdata   (8'd0),
        .stats_tvalid  (1'b0),
        .stats_tready  (),
        .stats_tlast   (1'b0),
        .udp_tdata     (udp_tdata),
        .udp_tvalid    (udp_tvalid),
        .udp_tready    (udp_tready),
        .udp_tlast     (udp_tlast),
        .blast_tdata   (8'd0),
        .blast_tvalid  (1'b0),
        .blast_tready  (),
        .blast_tlast   (1'b0),
        .m_axis_tdata  (tx_tdata),
        .m_axis_tvalid (tx_tvalid),
        .m_axis_tready (tx_tready),
        .m_axis_tlast  (tx_tlast)
    );

    // =========================================================================
    // TX: 8 -> 64. A beat goes out when it has 8 bytes or the frame's last;
    // the byte side waits while a beat is waiting to go.
    // =========================================================================
    reg [2:0] p_cnt;
    assign tx_tready = !m_axis_tvalid;
    assign tx_frame  = m_axis_tvalid && m_axis_tready && m_axis_tlast;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p_cnt         <= 3'd0;
            m_axis_tdata  <= 64'd0;
            m_axis_tkeep  <= 8'd0;
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
        end else begin
            if (m_axis_tvalid && m_axis_tready)
                m_axis_tvalid <= 1'b0;
            if (tx_tvalid && tx_tready) begin
                if (p_cnt == 3'd0) begin
                    m_axis_tdata <= {56'd0, tx_tdata};
                    m_axis_tkeep <= 8'h01;
                end else begin
                    m_axis_tdata[{p_cnt, 3'b000} +: 8] <= tx_tdata;
                    m_axis_tkeep[p_cnt] <= 1'b1;
                end
                p_cnt <= p_cnt + 3'd1;
                if (tx_tlast || p_cnt == 3'd7) begin
                    m_axis_tvalid <= 1'b1;
                    m_axis_tlast  <= tx_tlast;
                    p_cnt         <= 3'd0;
                end
            end
        end
    end

endmodule
