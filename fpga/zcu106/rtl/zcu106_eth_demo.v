// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// zcu106_eth_demo.v - emacZero GMII MAC plus the demo L3 stack
//
//   GMII <-> eth_mac_sys (PHY_INTERFACE="GMII") <-> ARP responder
//                                               <-> net_rx -> ICMP echo
//                                                          -> UDP echo (port)
//
// Everything runs on one 125 MHz clock: the MAC system clock and both of its
// GMII clocks. On the ZCU106 that is the PCS/PMA userclk2. The CSRs stay at
// their reset values (TX/RX enabled, 1G, IP 192.168.137.200); OUR_MAC sets
// the address the ARP/ICMP/UDP responders answer with.
// Verilog 2001
// =============================================================================

module zcu106_eth_demo #(
    parameter [47:0] OUR_MAC       = 48'h02_00_00_00_00_01,
    parameter [15:0] UDP_ECHO_PORT = 16'd9999
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
    output wire       tx_frame
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

    wire [7:0]  mac_tx_tdata;
    wire        mac_tx_tvalid, mac_tx_tready, mac_tx_tlast;

    arty_tx_arbiter u_tx_arb (
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
        .stats_tdata   (8'd0),
        .stats_tvalid  (1'b0),
        .stats_tready  (),
        .stats_tlast   (1'b0),
        .udp_tdata     (udp_tx_tdata),
        .udp_tvalid    (udp_tx_tvalid),
        .udp_tready    (udp_tx_tready),
        .udp_tlast     (udp_tx_tlast),
        .blast_tdata   (8'd0),
        .blast_tvalid  (1'b0),
        .blast_tready  (),
        .blast_tlast   (1'b0),
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
        // AXI4-Lite unused
        .s_axi_awaddr   (8'd0),
        .s_axi_awvalid  (1'b0),
        .s_axi_awready  (),
        .s_axi_wdata    (32'd0),
        .s_axi_wstrb    (4'd0),
        .s_axi_wvalid   (1'b0),
        .s_axi_wready   (),
        .s_axi_bresp    (),
        .s_axi_bvalid   (),
        .s_axi_bready   (1'b1),
        .s_axi_araddr   (8'd0),
        .s_axi_arvalid  (1'b0),
        .s_axi_arready  (),
        .s_axi_rdata    (),
        .s_axi_rresp    (),
        .s_axi_rvalid   (),
        .s_axi_rready   (1'b1),
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

endmodule
