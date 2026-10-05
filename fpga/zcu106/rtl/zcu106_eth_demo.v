// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// zcu106_eth_demo.v - emacZero GMII MAC plus the demo L3 stack
//
//   GMII <-> eth_mac_sys (PHY_INTERFACE="GMII") <-> ARP responder
//                                               <-> net_rx -> ICMP echo
//                                                          -> UDP echo (port)
//                                                          -> iperf2 sink, stats
//                                                          -> blast trigger
//                                          UDP blast generator -> TX
//
// Throughput test ports (as on the Arty demo, see fpga/zcu106/README.md):
//   UDP/5001  iperf2 UDP sink: counts packets, bytes and sequence gaps
//   UDP/9996  sink stats: "G" reads them, "C" reads and clears them
//   UDP/9997  blast trigger: a bounded line-rate burst of iperf2-format
//             datagrams back to the sender (payload: IFG delay, count, port,
//             payload size; see udp_blast_trigger.v)
//
// Everything runs on one 125 MHz clock: the MAC system clock and both of its
// GMII clocks. On the ZCU106 that is the PCS/PMA userclk2. The CSRs start at
// their reset values (TX/RX enabled, 1G, IP 192.168.137.200) and are on the
// s_axi port, for reading the MAC statistics; tie it off if unused. OUR_MAC
// sets the address the ARP/ICMP/UDP responders answer with.
// Verilog 2001
// =============================================================================

module zcu106_eth_demo #(
    parameter [47:0] OUR_MAC       = 48'h02_00_00_00_00_01,
    parameter [15:0] UDP_ECHO_PORT = 16'd9999,
    // Cycles from a blast trigger to the first frame. 1 s gives a plain
    // `iperf -u -s` time to start; 0 starts at once.
    parameter [31:0] BLAST_START_DELAY = 32'd125_000_000
) (
    input  wire       clk,            // 125 MHz
    input  wire       rst_n,

    // GMII to the PCS/PMA (clk domain)
    output wire [7:0] gmii_txd,
    output wire       gmii_tx_en,
    output wire       gmii_tx_er,
    input  wire [7:0] gmii_rxd,
    input  wire       gmii_rx_dv,
    input  wire       gmii_rx_er,

    // One-cycle pulses at the end of each received / transmitted frame
    output wire       rx_frame,
    output wire       tx_frame,

    // MAC CSRs (eth_mac_sys AXI4-Lite, clk domain)
    input  wire [7:0]  s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [7:0]  s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,

    // Blast frames generated since reset or the last blast_frames_clear, to
    // compare with the MAC's TX frame count
    input  wire        blast_frames_clear,
    output reg  [31:0] blast_frames
);

    // =========================================================================
    // AXI4-Stream TX mux: ARP / ICMP / UDP echo
    // =========================================================================
    wire [31:0] cfg_ip_addr;

    wire [7:0]  arp_tx_tdata;
    wire        arp_tx_tvalid, arp_tx_tready, arp_tx_tlast;
    wire [7:0]  icmp_tx_tdata;
    wire        icmp_tx_tvalid, icmp_tx_tready, icmp_tx_tlast;
    wire [7:0]  udp_tx_tdata;
    wire        udp_tx_tvalid, udp_tx_tready, udp_tx_tlast;
    wire [7:0]  stats_tx_tdata;
    wire        stats_tx_tvalid, stats_tx_tready, stats_tx_tlast;
    wire [7:0]  blast_tx_tdata;
    wire        blast_tx_tvalid, blast_tx_tready, blast_tx_tlast;

    wire [7:0]  mac_tx_tdata;
    wire        mac_tx_tvalid, mac_tx_tready, mac_tx_tlast;

    // The blast has the lowest priority, so a pending ARP / ping / stats
    // reply already wins at the next frame boundary of a line-rate blast.
    // The Arty's idle service window (0.3% of the line rate at 64-byte
    // frames) is turned off.
    arty_tx_arbiter #(
        .BLAST_SERVICE_INTERVAL    (8'd255),
        .BLAST_SERVICE_IDLE_CYCLES (12'd0)
    ) u_tx_arb (
        .clk           (clk),
        .rst_n         (rst_n),
        .arp_tx_active (1'b0),
        .seq_tdata     (8'd0),
        .seq_tvalid    (1'b0),
        .seq_tready    (),
        .seq_tlast     (1'b0),
        .arp_tdata     (arp_tx_tdata),
        .arp_tvalid    (arp_tx_tvalid),
        .arp_tready    (arp_tx_tready),
        .arp_tlast     (arp_tx_tlast),
        .icmp_tdata    (icmp_tx_tdata),
        .icmp_tvalid   (icmp_tx_tvalid),
        .icmp_tready   (icmp_tx_tready),
        .icmp_tlast    (icmp_tx_tlast),
        .stats_tdata   (stats_tx_tdata),
        .stats_tvalid  (stats_tx_tvalid),
        .stats_tready  (stats_tx_tready),
        .stats_tlast   (stats_tx_tlast),
        .udp_tdata     (udp_tx_tdata),
        .udp_tvalid    (udp_tx_tvalid),
        .udp_tready    (udp_tx_tready),
        .udp_tlast     (udp_tx_tlast),
        .blast_tdata   (blast_tx_tdata),
        .blast_tvalid  (blast_tx_tvalid),
        .blast_tready  (blast_tx_tready),
        .blast_tlast   (blast_tx_tlast),
        .m_axis_tdata  (mac_tx_tdata),
        .m_axis_tvalid (mac_tx_tvalid),
        .m_axis_tready (mac_tx_tready),
        .m_axis_tlast  (mac_tx_tlast)
    );

    // =========================================================================
    // Ethernet MAC (GMII mode)
    // =========================================================================
    wire [7:0]  mac_rx_tdata;
    wire        mac_rx_tvalid, mac_rx_tlast, mac_rx_terror, mac_rx_tsof;

    eth_mac_sys #(
        .PHY_INTERFACE ("GMII"),
        .CLK_FREQ_HZ   (125_000_000)
    ) u_mac_sys (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_axi_awaddr   (s_axi_awaddr),
        .s_axi_awvalid  (s_axi_awvalid),
        .s_axi_awready  (s_axi_awready),
        .s_axi_wdata    (s_axi_wdata),
        .s_axi_wstrb    (s_axi_wstrb),
        .s_axi_wvalid   (s_axi_wvalid),
        .s_axi_wready   (s_axi_wready),
        .s_axi_bresp    (s_axi_bresp),
        .s_axi_bvalid   (s_axi_bvalid),
        .s_axi_bready   (s_axi_bready),
        .s_axi_araddr   (s_axi_araddr),
        .s_axi_arvalid  (s_axi_arvalid),
        .s_axi_arready  (s_axi_arready),
        .s_axi_rdata    (s_axi_rdata),
        .s_axi_rresp    (s_axi_rresp),
        .s_axi_rvalid   (s_axi_rvalid),
        .s_axi_rready   (s_axi_rready),
        // AXI4-Stream
        .s_axis_tdata   (mac_tx_tdata),
        .s_axis_tvalid  (mac_tx_tvalid),
        .s_axis_tready  (mac_tx_tready),
        .s_axis_tlast   (mac_tx_tlast),
        .m_axis_tdata   (mac_rx_tdata),
        .m_axis_tvalid  (mac_rx_tvalid),
        .m_axis_tready  (1'b1),
        .m_axis_tlast   (mac_rx_tlast),
        .m_axis_terror  (mac_rx_terror),
        .m_axis_tsof    (mac_rx_tsof),
        // MII unused
        .mii_txd        (),
        .mii_tx_en      (),
        .mii_tx_clk     (1'b0),
        .mii_rxd        (4'd0),
        .mii_rx_dv      (1'b0),
        .mii_rx_er      (1'b0),
        .mii_rx_clk     (1'b0),
        .mii_col        (1'b0),
        .mii_crs        (1'b0),
        // GMII TX clock (the RGMII group's clk_125); other RGMII ports unused
        .clk_125        (clk),
        .clk_125_90     (1'b0),
        .clk_25         (1'b0),
        .clk_2_5        (1'b0),
        .rgmii_txd      (),
        .rgmii_tx_ctl   (),
        .rgmii_txc      (),
        .rgmii_rxd      (4'd0),
        .rgmii_rx_ctl   (1'b0),
        .rgmii_rxc      (1'b0),
        // GMII to the PCS/PMA. gmii_if registers both directions; the
        // forwarded TX clock is for an external PHY and is left open.
        .phy_gmii_txd    (gmii_txd),
        .phy_gmii_tx_en  (gmii_tx_en),
        .phy_gmii_tx_er  (gmii_tx_er),
        .phy_gmii_txc    (),
        .phy_gmii_rx_clk (clk),
        .phy_gmii_rxd    (gmii_rxd),
        .phy_gmii_rx_dv  (gmii_rx_dv),
        .phy_gmii_rx_er  (gmii_rx_er),
        // MDIO unused (1000BASE-X has no external PHY)
        .mdc            (),
        .mdio_i         (1'b1),
        .mdio_o         (),
        .mdio_oe        (),
        .cfg_ip_addr    (cfg_ip_addr),
        .irq            ()
    );

    assign rx_frame = mac_rx_tvalid && mac_rx_tlast;
    assign tx_frame = mac_tx_tvalid && mac_tx_tready && mac_tx_tlast;

    // =========================================================================
    // Demo L3 stack: ARP responder, IPv4/ICMP/UDP parser, ping, UDP echo
    // =========================================================================
    arp_responder u_arp (
        .clk            (clk),
        .rst_n          (rst_n),
        .enable         (1'b1),
        .rx_tdata       (mac_rx_tdata),
        .rx_tvalid      (mac_rx_tvalid),
        .rx_tlast       (mac_rx_tlast),
        .rx_terror      (mac_rx_terror),
        .rx_tsof        (mac_rx_tsof),
        .tx_tdata       (arp_tx_tdata),
        .tx_tvalid      (arp_tx_tvalid),
        .tx_tready      (arp_tx_tready),
        .tx_tlast       (arp_tx_tlast),
        .our_mac        (OUR_MAC),
        .our_ip         (cfg_ip_addr),
        .arp_reply_sent ()
    );

    wire [7:0]  netrx_icmp_data;
    wire        netrx_icmp_valid, netrx_icmp_last, netrx_icmp_err;
    wire [31:0] netrx_icmp_src_ip;
    wire [47:0] netrx_rx_src_mac;
    wire [7:0]  netrx_udp_data;
    wire        netrx_udp_valid, netrx_udp_last, netrx_udp_err;
    wire [31:0] netrx_udp_src_ip;
    wire [15:0] netrx_udp_src_port, netrx_udp_dst_port, netrx_udp_length;

    net_rx u_net_rx (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_axis_tdata   (mac_rx_tdata),
        .s_axis_tvalid  (mac_rx_tvalid),
        .s_axis_tlast   (mac_rx_tlast),
        .s_axis_tsof    (mac_rx_tsof),
        .s_axis_terror  (mac_rx_terror),
        .arp_data       (),
        .arp_valid      (),
        .arp_last       (),
        .icmp_data      (netrx_icmp_data),
        .icmp_valid     (netrx_icmp_valid),
        .icmp_last      (netrx_icmp_last),
        .icmp_err       (netrx_icmp_err),
        .icmp_src_ip    (netrx_icmp_src_ip),
        .udp_data       (netrx_udp_data),
        .udp_valid      (netrx_udp_valid),
        .udp_last       (netrx_udp_last),
        .udp_err        (netrx_udp_err),
        .udp_src_ip     (netrx_udp_src_ip),
        .udp_src_port   (netrx_udp_src_port),
        .udp_dst_port   (netrx_udp_dst_port),
        .udp_length     (netrx_udp_length),
        .rx_src_mac     (netrx_rx_src_mac),
        .our_ip         (cfg_ip_addr)
    );

    icmp_echo u_icmp (
        .clk            (clk),
        .rst_n          (rst_n),
        .our_mac        (OUR_MAC),
        .our_ip         (cfg_ip_addr),
        .icmp_rx_data   (netrx_icmp_data),
        .icmp_rx_valid  (netrx_icmp_valid),
        .icmp_rx_last   (netrx_icmp_last),
        .icmp_rx_err    (netrx_icmp_err),
        .icmp_rx_src_ip (netrx_icmp_src_ip),
        .rx_src_mac     (netrx_rx_src_mac),
        .tx_data        (icmp_tx_tdata),
        .tx_valid       (icmp_tx_tvalid),
        .tx_last        (icmp_tx_tlast),
        .tx_ready       (icmp_tx_tready),
        .tx_start       ()
    );

    udp_echo #(
        .BUF_SIZE    (1536),
        .LISTEN_PORT (UDP_ECHO_PORT)
    ) u_udp (
        .clk             (clk),
        .rst_n           (rst_n),
        .our_mac         (OUR_MAC),
        .our_ip          (cfg_ip_addr),
        .udp_rx_data     (netrx_udp_data),
        .udp_rx_valid    (netrx_udp_valid),
        .udp_rx_last     (netrx_udp_last),
        .udp_rx_err      (netrx_udp_err),
        .udp_rx_src_ip   (netrx_udp_src_ip),
        .udp_rx_src_port (netrx_udp_src_port),
        .udp_rx_dst_port (netrx_udp_dst_port),
        .udp_rx_length   (netrx_udp_length),
        .rx_src_mac      (netrx_rx_src_mac),
        .tx_data         (udp_tx_tdata),
        .tx_valid        (udp_tx_tvalid),
        .tx_last         (udp_tx_tlast),
        .tx_ready        (udp_tx_tready),
        .tx_start        ()
    );

    // =========================================================================
    // Throughput test: iperf2 UDP sink with stats on UDP/9996, and the
    // line-rate UDP blast generator triggered from UDP/9997
    // =========================================================================
    localparam [15:0] IPERF_SINK_PORT    = 16'd5001;
    localparam [15:0] IPERF_STATS_PORT   = 16'd9996;
    localparam [15:0] BLAST_TRIGGER_PORT = 16'd9997;

    wire [31:0] iperf_stat_packets, iperf_stat_bytes;
    wire [31:0] iperf_stat_first_seq, iperf_stat_last_seq;
    wire [31:0] iperf_stat_seq_gaps, iperf_stat_out_of_order;
    wire [31:0] iperf_stat_final_packets, iperf_stat_last_src_ip;
    wire [15:0] iperf_stat_last_src_port;
    wire        iperf_stats_clear;

    udp_iperf_sink #(
        .LISTEN_PORT (IPERF_SINK_PORT)
    ) u_iperf_sink (
        .clk                (clk),
        .rst_n              (rst_n),
        .udp_rx_data        (netrx_udp_data),
        .udp_rx_valid       (netrx_udp_valid),
        .udp_rx_last        (netrx_udp_last),
        .udp_rx_err         (netrx_udp_err),
        .udp_rx_src_ip      (netrx_udp_src_ip),
        .udp_rx_src_port    (netrx_udp_src_port),
        .udp_rx_dst_port    (netrx_udp_dst_port),
        .udp_rx_length      (netrx_udp_length),
        .clear_stats        (iperf_stats_clear),
        .stat_packets       (iperf_stat_packets),
        .stat_bytes         (iperf_stat_bytes),
        .stat_first_seq     (iperf_stat_first_seq),
        .stat_last_seq      (iperf_stat_last_seq),
        .stat_seq_gaps      (iperf_stat_seq_gaps),
        .stat_out_of_order  (iperf_stat_out_of_order),
        .stat_final_packets (iperf_stat_final_packets),
        .stat_last_src_ip   (iperf_stat_last_src_ip),
        .stat_last_src_port (iperf_stat_last_src_port)
    );

    udp_stats_reply u_iperf_stats (
        .clk                (clk),
        .rst_n              (rst_n),
        .our_mac            (OUR_MAC),
        .our_ip             (cfg_ip_addr),
        .stats_port         (IPERF_STATS_PORT),
        .udp_rx_data        (netrx_udp_data),
        .udp_rx_valid       (netrx_udp_valid),
        .udp_rx_last        (netrx_udp_last),
        .udp_rx_err         (netrx_udp_err),
        .udp_rx_src_ip      (netrx_udp_src_ip),
        .udp_rx_src_port    (netrx_udp_src_port),
        .udp_rx_dst_port    (netrx_udp_dst_port),
        .rx_src_mac         (netrx_rx_src_mac),
        .stat_packets       (iperf_stat_packets),
        .stat_bytes         (iperf_stat_bytes),
        .stat_first_seq     (iperf_stat_first_seq),
        .stat_last_seq      (iperf_stat_last_seq),
        .stat_seq_gaps      (iperf_stat_seq_gaps),
        .stat_out_of_order  (iperf_stat_out_of_order),
        .stat_final_packets (iperf_stat_final_packets),
        .stat_last_src_ip   (iperf_stat_last_src_ip),
        .stat_last_src_port (iperf_stat_last_src_port),
        .clear_stats        (iperf_stats_clear),
        .tx_data            (stats_tx_tdata),
        .tx_valid           (stats_tx_tvalid),
        .tx_last            (stats_tx_tlast),
        .tx_ready           (stats_tx_tready),
        .tx_start           ()
    );

    wire        trig_start;
    wire [47:0] trig_dst_mac;
    wire [31:0] trig_dst_ip;
    wire [15:0] trig_dst_port, trig_src_port, trig_payload;
    wire [23:0] trig_ifg_delay;
    wire [31:0] trig_count;

    reg  [47:0] blast_dst_mac;
    reg  [31:0] blast_dst_ip;
    reg  [15:0] blast_dst_port, blast_src_port;
    reg  [13:0] blast_payload;
    reg  [23:0] blast_ifg_delay;
    reg  [31:0] blast_remaining;
    reg         blast_tx_start_d;
    reg         blast_in_frame;
    wire        blast_tx_start;
    wire        blast_frame_done;
    wire        blast_enable = (blast_remaining != 32'd0);
    // The count reaches 0 when the last frame starts, but that frame still
    // uses the latched destination and sequence. Stay busy until it is done.
    wire        blast_busy   = blast_enable || blast_in_frame;

    udp_blast_trigger #(
        .TRIGGER_PORT    (BLAST_TRIGGER_PORT),
        .IGNORE_SRC_PORT (IPERF_SINK_PORT),
        .DEFAULT_COUNT   (32'd1000000),
        .DEFAULT_PAYLOAD (16'd1472)
    ) u_blast_trigger (
        .clk             (clk),
        .rst_n           (rst_n),
        .udp_rx_data     (netrx_udp_data),
        .udp_rx_valid    (netrx_udp_valid),
        .udp_rx_last     (netrx_udp_last),
        .udp_rx_err      (netrx_udp_err),
        .udp_rx_src_mac  (netrx_rx_src_mac),
        .udp_rx_src_ip   (netrx_udp_src_ip),
        .udp_rx_src_port (netrx_udp_src_port),
        .udp_rx_dst_port (netrx_udp_dst_port),
        .busy            (blast_busy),
        .start           (trig_start),
        .dst_mac         (trig_dst_mac),
        .dst_ip          (trig_dst_ip),
        .dst_port        (trig_dst_port),
        .src_port        (trig_src_port),
        .ifg_delay       (trig_ifg_delay),
        .packet_count    (trig_count),
        .payload_size    (trig_payload)
    );

    // Latch a trigger while idle and count frames down as each one starts.
    // The burst mirrors the trigger's 4-tuple so the host sees a reply flow.
    // A payload size outside 18..1472 (a 60..1514-byte frame: no padding,
    // standard MTU) falls back to 1472.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blast_dst_mac    <= 48'd0;
            blast_dst_ip     <= 32'd0;
            blast_dst_port   <= 16'd0;
            blast_src_port   <= 16'd0;
            blast_payload    <= 14'd1472;
            blast_ifg_delay  <= 24'd0;
            blast_remaining  <= 32'd0;
            blast_tx_start_d <= 1'b0;
            blast_in_frame   <= 1'b0;
            blast_frames     <= 32'd0;
        end else begin
            if (blast_frames_clear)
                blast_frames <= 32'd0;
            else if (blast_frame_done)
                blast_frames <= blast_frames + 32'd1;
            blast_tx_start_d <= blast_tx_start;
            if (blast_tx_start && !blast_tx_start_d)
                blast_in_frame <= 1'b1;
            else if (blast_frame_done)
                blast_in_frame <= 1'b0;
            if (trig_start && !blast_busy) begin
                blast_dst_mac   <= trig_dst_mac;
                blast_dst_ip    <= trig_dst_ip;
                blast_dst_port  <= trig_dst_port;
                blast_src_port  <= trig_src_port;
                blast_ifg_delay <= trig_ifg_delay;
                blast_remaining <= trig_count;
                blast_payload   <= (trig_payload >= 16'd18 && trig_payload <= 16'd1472) ?
                                   trig_payload[13:0] : 14'd1472;
            end else if (blast_tx_start && !blast_tx_start_d && blast_enable) begin
                blast_remaining <= blast_remaining - 32'd1;
            end
        end
    end

    udp_blast #(
        .START_DELAY_CYCLES (BLAST_START_DELAY),
        .USEC_TICK_CYCLES   (7'd125)            // iperf2 timestamps at 125 MHz
    ) u_blast (
        .clk               (clk),
        .rst_n             (rst_n),
        .our_mac           (OUR_MAC),
        .our_ip            (cfg_ip_addr),
        .dst_mac           (blast_dst_mac),
        .dst_ip            (blast_dst_ip),
        .dst_port          (blast_dst_port),
        .src_port          (blast_src_port),
        .payload_size      (blast_payload),
        .enable            (blast_enable),
        .inter_frame_delay (blast_ifg_delay),
        .pkts_sent         (),
        .pkt_done_pulse    (blast_frame_done),
        .tx_data           (blast_tx_tdata),
        .tx_valid          (blast_tx_tvalid),
        .tx_last           (blast_tx_tlast),
        .tx_ready          (blast_tx_tready),
        .tx_start          (blast_tx_start)
    );

endmodule
