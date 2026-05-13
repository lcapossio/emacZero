// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// arty_a7_top.v - Top-level for emacZero hardware test on Arty A7-100T
// Instantiates eth_mac_sys (MII), test sequencer, ARP responder, UART TX.
// Verilog 2001
// =============================================================================

module arty_a7_top (
    input  wire        CLK100MHZ,
    input  wire        BTN0,           // active-high reset

    // ---- Ethernet MII ----
    output wire [3:0]  ETH_TXD,
    output wire        ETH_TX_EN,
    input  wire        ETH_TX_CLK,
    input  wire [3:0]  ETH_RXD,
    input  wire        ETH_RX_DV,
    input  wire        ETH_RXERR,
    input  wire        ETH_RX_CLK,
    input  wire        ETH_CRS,
    input  wire        ETH_COL,
    output wire        ETH_MDC,
    inout  wire        ETH_MDIO,
    output wire        ETH_REF_CLK,
    output wire        ETH_RSTN,

    // ---- UART ----
    output wire        UART_TXD,

    // ---- LEDs ----
    output wire [3:0]  LED
);

    // =========================================================================
    // Reset and clock
    // =========================================================================
    wire sys_clk = CLK100MHZ;
    wire sys_rst_n = ~BTN0;
    localparam [47:0] OUR_MAC = 48'h02_00_00_00_00_01;
    localparam [31:0] OUR_IP  = 32'hC0_A8_89_C8; // 192.168.137.200

    // 25 MHz reference clock for PHY
    wire clk_25;
    wire mmcm_locked;

    clk_gen u_clk_gen (
        .clk_in (sys_clk),
        .clk_25 (clk_25),
        .locked (mmcm_locked)
    );

    // Drive ETH_REF_CLK via ODDR for clean pad timing
    ddr_output u_ref_clk (
        .clk (clk_25),
        .d1  (1'b1),
        .d2  (1'b0),
        .q   (ETH_REF_CLK)
    );

    // =========================================================================
    // PHY reset sequencing: hold low for 200ms after MMCM lock
    // =========================================================================
    reg [24:0] phy_rst_cnt;
    reg        phy_rst_done_r;
    localparam PHY_RST_CYCLES = 25'd20_000_000; // 200ms at 100 MHz

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            phy_rst_cnt    <= 25'd0;
            phy_rst_done_r <= 1'b0;
        end else if (mmcm_locked) begin
            if (phy_rst_cnt < PHY_RST_CYCLES)
                phy_rst_cnt <= phy_rst_cnt + 25'd1;
            else
                phy_rst_done_r <= 1'b1;
        end
    end

    assign ETH_RSTN = phy_rst_done_r;

    // Internal reset: active after MMCM lock AND PHY reset done
    wire int_rst_n = sys_rst_n & mmcm_locked & phy_rst_done_r;

    // =========================================================================
    // MDIO tristate
    // =========================================================================
    wire mdio_o, mdio_oe, mdio_i;
    assign ETH_MDIO = mdio_oe ? mdio_o : 1'bz;
    assign mdio_i   = ETH_MDIO;

    // =========================================================================
    // AXI4-Lite bus (test_sequencer -> eth_mac_sys)
    // =========================================================================
    wire [7:0]  axi_awaddr;
    wire        axi_awvalid, axi_awready;
    wire [31:0] axi_wdata;
    wire [3:0]  axi_wstrb;
    wire        axi_wvalid, axi_wready;
    wire [1:0]  axi_bresp;
    wire        axi_bvalid;
    wire        axi_bready;
    wire [7:0]  axi_araddr;
    wire        axi_arvalid, axi_arready;
    wire [31:0] axi_rdata;
    wire [1:0]  axi_rresp;
    wire        axi_rvalid;
    wire        axi_rready;

    // =========================================================================
    // AXI4-Stream TX mux: test_sequencer / ARP / ICMP / stats / UDP / blast
    // =========================================================================
    wire        arp_tx_active;  // test_sequencer owns TX when high

    // Test sequencer TX
    wire [7:0]  seq_tx_tdata;
    wire        seq_tx_tvalid;
    wire        seq_tx_tready;
    wire        seq_tx_tlast;

    // ARP responder TX
    wire [7:0]  arp_tx_tdata;
    wire        arp_tx_tvalid;
    wire        arp_tx_tready;
    wire        arp_tx_tlast;

    // ICMP echo TX
    wire [7:0]  icmp_tx_tdata;
    wire        icmp_tx_tvalid;
    wire        icmp_tx_tready;
    wire        icmp_tx_tlast;
    wire        icmp_tx_start;

    // UDP echo TX
    wire [7:0]  udp_tx_tdata;
    wire        udp_tx_tvalid;
    wire        udp_tx_tready;
    wire        udp_tx_tlast;
    wire        udp_tx_start;

    // UDP stats TX
    wire [7:0]  stats_tx_tdata;
    wire        stats_tx_tvalid;
    wire        stats_tx_tready;
    wire        stats_tx_tlast;
    wire        stats_tx_start;

    // UDP blast TX
    wire [7:0]  blast_tx_tdata;
    wire        blast_tx_tvalid;
    wire        blast_tx_tready;
    wire        blast_tx_tlast;
    wire        blast_tx_start;

    wire        mac_tx_tready;
    wire [7:0]  mac_tx_tdata;
    wire        mac_tx_tvalid;
    wire        mac_tx_tlast;

    // Every 256 blast frames, open a ~20us service window so ARP/ICMP/stats
    // replies are not hidden behind a continuous line-rate UDP burst.
    localparam [7:0]  BLAST_SERVICE_INTERVAL    = 8'd255;
    localparam [11:0] BLAST_SERVICE_IDLE_CYCLES = 12'd2048;

    arty_tx_arbiter #(
        .BLAST_SERVICE_INTERVAL   (BLAST_SERVICE_INTERVAL),
        .BLAST_SERVICE_IDLE_CYCLES(BLAST_SERVICE_IDLE_CYCLES)
    ) u_tx_arb (
        .clk           (sys_clk),
        .rst_n         (int_rst_n),
        .arp_tx_active (arp_tx_active),
        .seq_tdata     (seq_tx_tdata),
        .seq_tvalid    (seq_tx_tvalid),
        .seq_tready    (seq_tx_tready),
        .seq_tlast     (seq_tx_tlast),
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
    // AXI4-Stream RX from MAC
    // =========================================================================
    wire [7:0]  mac_rx_tdata;
    wire        mac_rx_tvalid;
    wire        mac_rx_tlast;
    wire        mac_rx_terror;
    wire        mac_rx_tsof;

    // =========================================================================
    // Ethernet MAC System
    // =========================================================================
    wire irq;

    eth_mac_sys #(.PHY_INTERFACE("MII")) u_mac_sys (
        .clk            (sys_clk),
        .rst_n          (int_rst_n),
        // AXI4-Lite CSR
        .s_axi_awaddr   (axi_awaddr),
        .s_axi_awvalid  (axi_awvalid),
        .s_axi_awready  (axi_awready),
        .s_axi_wdata    (axi_wdata),
        .s_axi_wstrb    (axi_wstrb),
        .s_axi_wvalid   (axi_wvalid),
        .s_axi_wready   (axi_wready),
        .s_axi_bresp    (axi_bresp),
        .s_axi_bvalid   (axi_bvalid),
        .s_axi_bready   (axi_bready),
        .s_axi_araddr   (axi_araddr),
        .s_axi_arvalid  (axi_arvalid),
        .s_axi_arready  (axi_arready),
        .s_axi_rdata    (axi_rdata),
        .s_axi_rresp    (axi_rresp),
        .s_axi_rvalid   (axi_rvalid),
        .s_axi_rready   (axi_rready),
        // AXI4-Stream TX
        .s_axis_tdata   (mac_tx_tdata),
        .s_axis_tvalid  (mac_tx_tvalid),
        .s_axis_tready  (mac_tx_tready),
        .s_axis_tlast   (mac_tx_tlast),
        // AXI4-Stream RX
        .m_axis_tdata   (mac_rx_tdata),
        .m_axis_tvalid  (mac_rx_tvalid),
        .m_axis_tready  (1'b1),
        .m_axis_tlast   (mac_rx_tlast),
        .m_axis_terror  (mac_rx_terror),
        .m_axis_tsof    (mac_rx_tsof),
        // MII
        .mii_txd        (ETH_TXD),
        .mii_tx_en      (ETH_TX_EN),
        .mii_tx_clk     (ETH_TX_CLK),
        .mii_rxd        (ETH_RXD),
        .mii_rx_dv      (ETH_RX_DV),
        .mii_rx_er      (ETH_RXERR),
        .mii_rx_clk     (ETH_RX_CLK),
        .mii_col        (ETH_COL),
        .mii_crs        (ETH_CRS),
        // RGMII (unused)
        .clk_125        (1'b0),
        .clk_125_90     (1'b0),
        .clk_25         (1'b0),
        .clk_2_5        (1'b0),
        .rgmii_txd      (),
        .rgmii_tx_ctl   (),
        .rgmii_txc      (),
        .rgmii_rxd      (4'd0),
        .rgmii_rx_ctl   (1'b0),
        .rgmii_rxc      (1'b0),
        // MDIO
        .mdc            (ETH_MDC),
        .mdio_i         (mdio_i),
        .mdio_o         (mdio_o),
        .mdio_oe        (mdio_oe),
        // IRQ
        .irq            (irq)
    );

    // =========================================================================
    // UART TX
    // =========================================================================
    wire [7:0] uart_data;
    wire       uart_valid;
    wire       uart_busy;

    uart_tx #(
        .CLK_FREQ(100_000_000),
        .BAUD(115200)
    ) u_uart (
        .clk       (sys_clk),
        .rst_n     (int_rst_n),
        .data      (uart_data),
        .data_valid(uart_valid),
        .busy      (uart_busy),
        .txd       (UART_TXD)
    );

    // =========================================================================
    // Test Sequencer
    // =========================================================================
    wire seq_link_up, seq_phy_id_ok, seq_tx_done, seq_rx_done;

    test_sequencer u_seq (
        .clk           (sys_clk),
        .rst_n         (int_rst_n),
        .phy_rst_done  (phy_rst_done_r),
        // AXI-Lite master
        .m_axi_awaddr  (axi_awaddr),
        .m_axi_awvalid (axi_awvalid),
        .m_axi_awready (axi_awready),
        .m_axi_wdata   (axi_wdata),
        .m_axi_wstrb   (axi_wstrb),
        .m_axi_wvalid  (axi_wvalid),
        .m_axi_wready  (axi_wready),
        .m_axi_bvalid  (axi_bvalid),
        .m_axi_bready  (axi_bready),
        .m_axi_araddr  (axi_araddr),
        .m_axi_arvalid (axi_arvalid),
        .m_axi_arready (axi_arready),
        .m_axi_rdata   (axi_rdata),
        .m_axi_rvalid  (axi_rvalid),
        .m_axi_rready  (axi_rready),
        // TX AXI-Stream
        .tx_tdata      (seq_tx_tdata),
        .tx_tvalid     (seq_tx_tvalid),
        .tx_tready     (seq_tx_tready),
        .tx_tlast      (seq_tx_tlast),
        // UART
        .uart_data     (uart_data),
        .uart_valid    (uart_valid),
        .uart_busy     (uart_busy),
        // Status
        .link_up       (seq_link_up),
        .phy_id_ok     (seq_phy_id_ok),
        .tx_done       (seq_tx_done),
        .rx_done       (seq_rx_done),
        .arp_tx_active (arp_tx_active)
    );

    // =========================================================================
    // ARP Responder
    // =========================================================================
    arp_responder u_arp (
        .clk           (sys_clk),
        .rst_n         (int_rst_n),
        .enable        (~arp_tx_active),  // enabled after test_sequencer releases TX
        .rx_tdata      (mac_rx_tdata),
        .rx_tvalid     (mac_rx_tvalid),
        .rx_tlast      (mac_rx_tlast),
        .rx_terror     (mac_rx_terror),
        .rx_tsof       (mac_rx_tsof),
        .tx_tdata      (arp_tx_tdata),
        .tx_tvalid     (arp_tx_tvalid),
        .tx_tready     (arp_tx_tready),
        .tx_tlast      (arp_tx_tlast),
        .our_mac       (OUR_MAC),
        .our_ip        (OUR_IP),
        .arp_reply_sent()
    );

    // =========================================================================
    // Network RX parser (Ethernet -> IP -> ICMP demux)
    // =========================================================================
    wire [7:0]  netrx_icmp_data;
    wire        netrx_icmp_valid;
    wire        netrx_icmp_last;
    wire [31:0] netrx_icmp_src_ip;
    wire [47:0] netrx_rx_src_mac;
    wire [7:0]  netrx_udp_data;
    wire        netrx_udp_valid;
    wire        netrx_udp_last;
    wire [31:0] netrx_udp_src_ip;
    wire [15:0] netrx_udp_src_port;
    wire [15:0] netrx_udp_dst_port;
    wire [15:0] netrx_udp_length;

    net_rx u_net_rx (
        .clk            (sys_clk),
        .rst_n          (int_rst_n),
        .s_axis_tdata   (mac_rx_tdata),
        .s_axis_tvalid  (mac_rx_tvalid),
        .s_axis_tlast   (mac_rx_tlast),
        .s_axis_tsof    (mac_rx_tsof),
        .s_axis_terror  (mac_rx_terror),
        .arp_data       (),          // ARP handled by arp_responder directly
        .arp_valid      (),
        .arp_last       (),
        .icmp_data      (netrx_icmp_data),
        .icmp_valid     (netrx_icmp_valid),
        .icmp_last      (netrx_icmp_last),
        .icmp_src_ip    (netrx_icmp_src_ip),
        .udp_data       (netrx_udp_data),
        .udp_valid      (netrx_udp_valid),
        .udp_last       (netrx_udp_last),
        .udp_src_ip     (netrx_udp_src_ip),
        .udp_src_port   (netrx_udp_src_port),
        .udp_dst_port   (netrx_udp_dst_port),
        .udp_length     (netrx_udp_length),
        .rx_src_mac     (netrx_rx_src_mac),
        .our_ip         (OUR_IP)
    );

    // =========================================================================
    // ICMP Echo Responder (ping reply)
    // =========================================================================
    icmp_echo u_icmp (
        .clk            (sys_clk),
        .rst_n          (int_rst_n),
        .our_mac        (OUR_MAC),
        .our_ip         (OUR_IP),
        .icmp_rx_data   (netrx_icmp_data),
        .icmp_rx_valid  (netrx_icmp_valid),
        .icmp_rx_last   (netrx_icmp_last),
        .icmp_rx_src_ip (netrx_icmp_src_ip),
        .rx_src_mac     (netrx_rx_src_mac),
        .tx_data        (icmp_tx_tdata),
        .tx_valid       (icmp_tx_tvalid),
        .tx_last        (icmp_tx_tlast),
        .tx_ready       (icmp_tx_tready),
        .tx_start       (icmp_tx_start)
    );

    // =========================================================================
    // UDP Blast — line-rate UDP traffic generator for iperf benchmarking.
    // Auto-trigger: any UDP packet received with dst-port = 9997 captures the
    // host's MAC + IP and starts a fixed-length burst out to {host, 5001}
    // (iperf2 -u -s default port). Trigger payload is optional:
    //   bytes 0..2: extra inter-frame delay in 100 MHz cycles
    //   bytes 3..6: burst frame count
    //   bytes 7..8: destination UDP port override
    // Old 0-byte/3-byte/7-byte triggers keep using the trigger source port.
    // =========================================================================
    localparam [15:0] BLAST_TRIGGER_PORT = 16'd9997;
    localparam [15:0] BLAST_IPERF_PORT   = 16'd5001;
    localparam [15:0] IPERF_SINK_PORT    = 16'd5001;
    localparam [15:0] IPERF_STATS_PORT   = 16'd9996;
    localparam [15:0] UDP_ECHO_PORT      = 16'd9999;
    localparam [31:0] BLAST_BURST_LEN    = 32'd1000000;
    // Plain iperf cannot also send the trigger from its receive socket. Wait
    // one second after a trigger so the host can start `iperf -u -s`.
    localparam [31:0] BLAST_START_DELAY_CYCLES = 32'd100000000;
    localparam [13:0] BLAST_PAYLOAD_SIZE = 14'd1472;

    reg [47:0] blast_dst_mac;
    reg [31:0] blast_dst_ip;
    reg [15:0] blast_dst_port;     // = trigger's src port  (host's listen port)
    reg [15:0] blast_src_port;     // = trigger's dst port  (BLAST_TRIGGER_PORT)
    reg [31:0] blast_remaining;
    reg [23:0] blast_ifg_delay;
    wire [31:0] blast_pkts_sent;
    wire        blast_pkt_done_pulse;
    wire        blast_enable = (blast_remaining != 32'd0);
    reg         blast_tx_start_d;
    wire        blast_tx_start_pulse = blast_tx_start && !blast_tx_start_d;

    wire        blast_trigger_start;
    wire [47:0] blast_trigger_dst_mac;
    wire [31:0] blast_trigger_dst_ip;
    wire [15:0] blast_trigger_dst_port;
    wire [15:0] blast_trigger_src_port;
    wire [23:0] blast_trigger_ifg_delay;
    wire [31:0] blast_trigger_count;

    udp_blast_trigger #(
        .TRIGGER_PORT(BLAST_TRIGGER_PORT),
        .IGNORE_SRC_PORT(BLAST_IPERF_PORT),
        .DEFAULT_COUNT(BLAST_BURST_LEN)
    ) u_blast_trigger (
        .clk             (sys_clk),
        .rst_n           (int_rst_n),
        .udp_rx_data     (netrx_udp_data),
        .udp_rx_valid    (netrx_udp_valid),
        .udp_rx_last     (netrx_udp_last),
        .udp_rx_src_mac  (netrx_rx_src_mac),
        .udp_rx_src_ip   (netrx_udp_src_ip),
        .udp_rx_src_port (netrx_udp_src_port),
        .udp_rx_dst_port (netrx_udp_dst_port),
        .busy            (blast_remaining != 32'd0),
        .start           (blast_trigger_start),
        .dst_mac         (blast_trigger_dst_mac),
        .dst_ip          (blast_trigger_dst_ip),
        .dst_port        (blast_trigger_dst_port),
        .src_port        (blast_trigger_src_port),
        .ifg_delay       (blast_trigger_ifg_delay),
        .packet_count    (blast_trigger_count)
    );

    always @(posedge sys_clk or negedge int_rst_n) begin
        if (!int_rst_n) begin
            blast_dst_mac   <= 48'd0;
            blast_dst_ip    <= 32'd0;
            blast_dst_port  <= 16'd0;
            blast_src_port  <= 16'd0;
            blast_remaining <= 32'd0;
            blast_ifg_delay <= 24'd0;
            blast_tx_start_d <= 1'b0;
        end else begin
            blast_tx_start_d <= blast_tx_start;

            // Trigger: end of any UDP frame to the trigger port. Refuse to
            // re-arm mid-burst so the destination latches stay coherent.
            //
            // Mirror the trigger's 4-tuple so the burst looks like a normal
            // reverse-flow reply to the host's stack/firewall:
            //   trigger : host:src_port  -> board:dst_port (= 9997)
            //   blast   : board:dst_port -> host:src_port
            if (blast_trigger_start && blast_remaining == 32'd0) begin
                blast_dst_mac   <= blast_trigger_dst_mac;
                blast_dst_ip    <= blast_trigger_dst_ip;
                blast_dst_port  <= blast_trigger_dst_port;
                blast_src_port  <= blast_trigger_src_port;
                blast_ifg_delay <= blast_trigger_ifg_delay;
                blast_remaining <= blast_trigger_count;
            end else if (blast_tx_start_pulse && blast_remaining != 32'd0) begin
                blast_remaining <= blast_remaining - 32'd1;
            end
        end
    end

    udp_blast #(
        .START_DELAY_CYCLES(BLAST_START_DELAY_CYCLES)
    ) u_blast (
        .clk            (sys_clk),
        .rst_n          (int_rst_n),
        .our_mac        (OUR_MAC),
        .our_ip         (OUR_IP),
        .dst_mac        (blast_dst_mac),
        .dst_ip         (blast_dst_ip),
        .dst_port       (blast_dst_port),
        .src_port       (blast_src_port),
        .payload_size   (BLAST_PAYLOAD_SIZE),
        .enable         (blast_enable),
        // Inter-frame gap in sys_clk cycles. 0 = back-to-back packets; the
        // MAC supplies preamble/SFD/FCS/IFG, so this is 100 Mbps wire rate
        // for 1518-byte frames on the MII link.
        .inter_frame_delay (blast_ifg_delay),
        .pkts_sent      (blast_pkts_sent),
        .pkt_done_pulse (blast_pkt_done_pulse),
        .tx_data        (blast_tx_tdata),
        .tx_valid       (blast_tx_tvalid),
        .tx_last        (blast_tx_tlast),
        .tx_ready       (blast_tx_tready),
        .tx_start       (blast_tx_start)
    );

    // =========================================================================
    // Passive iperf2 UDP sink + binary stats query responder.
    // Host can send:
    //   iperf -u -c 192.168.137.200 -p 5001 -b 90M -l 1472 --no-udp-fin
    // Then query UDP/9996 with "G" for counters, or "C" to clear counters.
    // =========================================================================
    wire [31:0] iperf_stat_packets;
    wire [31:0] iperf_stat_bytes;
    wire [31:0] iperf_stat_first_seq;
    wire [31:0] iperf_stat_last_seq;
    wire [31:0] iperf_stat_seq_gaps;
    wire [31:0] iperf_stat_out_of_order;
    wire [31:0] iperf_stat_final_packets;
    wire [31:0] iperf_stat_last_src_ip;
    wire [15:0] iperf_stat_last_src_port;
    wire        iperf_stats_clear;
    udp_iperf_sink #(
        .LISTEN_PORT(IPERF_SINK_PORT)
    ) u_iperf_sink (
        .clk                (sys_clk),
        .rst_n              (int_rst_n),
        .udp_rx_data        (netrx_udp_data),
        .udp_rx_valid       (netrx_udp_valid),
        .udp_rx_last        (netrx_udp_last),
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
        .clk                 (sys_clk),
        .rst_n               (int_rst_n),
        .our_mac             (OUR_MAC),
        .our_ip              (OUR_IP),
        .stats_port          (IPERF_STATS_PORT),
        .udp_rx_data         (netrx_udp_data),
        .udp_rx_valid        (netrx_udp_valid),
        .udp_rx_last         (netrx_udp_last),
        .udp_rx_src_ip       (netrx_udp_src_ip),
        .udp_rx_src_port     (netrx_udp_src_port),
        .udp_rx_dst_port     (netrx_udp_dst_port),
        .rx_src_mac          (netrx_rx_src_mac),
        .stat_packets        (iperf_stat_packets),
        .stat_bytes          (iperf_stat_bytes),
        .stat_first_seq      (iperf_stat_first_seq),
        .stat_last_seq       (iperf_stat_last_seq),
        .stat_seq_gaps       (iperf_stat_seq_gaps),
        .stat_out_of_order   (iperf_stat_out_of_order),
        .stat_final_packets  (iperf_stat_final_packets),
        .stat_last_src_ip    (iperf_stat_last_src_ip),
        .stat_last_src_port  (iperf_stat_last_src_port),
        .clear_stats         (iperf_stats_clear),
        .tx_data             (stats_tx_tdata),
        .tx_valid            (stats_tx_tvalid),
        .tx_last             (stats_tx_tlast),
        .tx_ready            (stats_tx_tready),
        .tx_start            (stats_tx_start)
    );

    // =========================================================================
    // UDP Echo Responder (only UDP/9999, so iperf/control traffic is not echoed)
    // =========================================================================
    udp_echo #(
        .BUF_SIZE(1536),
        .LISTEN_PORT(UDP_ECHO_PORT)
    ) u_udp (
        .clk             (sys_clk),
        .rst_n           (int_rst_n),
        .our_mac         (OUR_MAC),
        .our_ip          (OUR_IP),
        .udp_rx_data     (netrx_udp_data),
        .udp_rx_valid    (netrx_udp_valid),
        .udp_rx_last     (netrx_udp_last),
        .udp_rx_src_ip   (netrx_udp_src_ip),
        .udp_rx_src_port (netrx_udp_src_port),
        .udp_rx_dst_port (netrx_udp_dst_port),
        .udp_rx_length   (netrx_udp_length),
        .rx_src_mac      (netrx_rx_src_mac),
        .tx_data         (udp_tx_tdata),
        .tx_valid        (udp_tx_tvalid),
        .tx_last         (udp_tx_tlast),
        .tx_ready        (udp_tx_tready),
        .tx_start        (udp_tx_start)
    );

    // =========================================================================
    // LEDs
    // =========================================================================
    assign LED[0] = seq_link_up;
    assign LED[1] = seq_phy_id_ok;
    assign LED[2] = seq_tx_done;
    assign LED[3] = seq_rx_done;

`ifdef FCAPZ_DEBUG
    // =========================================================================
    // fpgacapZero debug — ELA (USER1/USER2) + EIO (USER3)
    //
    // ELA probes (64 bits):
    //   [5:0]   seq_state       — test_sequencer FSM state
    //   [6]     phy_rst_done_r  — PHY reset complete
    //   [7]     mmcm_locked     — MMCM lock
    //   [8]     int_rst_n       — internal reset (active-low)
    //   [9]     sys_rst_n       — system reset (BTN0 inverted)
    //   [10]    printing        — UART string printer active
    //   [11]    uart_valid      — UART byte strobe
    //   [12]    uart_busy       — UART TX busy
    //   [13]    arp_tx_active   — sequencer owns TX
    //   [14]    axi_arvalid     — AXI-Lite AR valid
    //   [15]    axi_arready     — AXI-Lite AR ready
    //   [16]    axi_rvalid      — AXI-Lite R valid
    //   [17]    axi_awvalid     — AXI-Lite AW valid
    //   [18]    axi_wvalid      — AXI-Lite W valid
    //   [19]    axi_bvalid      — AXI-Lite B valid
    //   [63:20] unused (tied 0)
    //
    // EIO read-only (64 bits):
    //   [5:0]   seq_state
    //   [37:6]  rd_data_r[31:0]
    //   [62:38] phy_rst_cnt[24:0]
    //   [63]    phy_rst_done_r
    // =========================================================================
    wire [63:0] ela_probe;
    assign ela_probe[5:0]   = u_seq.state;
    assign ela_probe[6]     = phy_rst_done_r;
    assign ela_probe[7]     = mmcm_locked;
    assign ela_probe[8]     = int_rst_n;
    assign ela_probe[9]     = sys_rst_n;
    assign ela_probe[10]    = u_seq.printing;
    assign ela_probe[11]    = uart_valid;
    assign ela_probe[12]    = uart_busy;
    assign ela_probe[13]    = arp_tx_active;
    assign ela_probe[14]    = axi_arvalid;
    assign ela_probe[15]    = axi_arready;
    assign ela_probe[16]    = axi_rvalid;
    assign ela_probe[17]    = axi_awvalid;
    assign ela_probe[18]    = axi_wvalid;
    assign ela_probe[19]    = axi_bvalid;
    assign ela_probe[63:20] = 44'd0;

    // Trigger on phy_rst_done_r rising edge (bit 6)
    fcapz_ela_xilinx7 #(
        .SAMPLE_W   (64),
        .DEPTH      (1024),
        .TRIG_STAGES(1),
        .CTRL_CHAIN (1),
        .DATA_CHAIN (2)
    ) u_ela (
        .sample_clk  (sys_clk),
        .sample_rst  (1'b0),  // ELA never reset from fabric — stays armed through BTN0
        .probe_in    (ela_probe),
        .trigger_in  (1'b0),
        .trigger_out ()
    );

    wire [63:0] eio_in;
    assign eio_in[5:0]   = u_seq.state;
    assign eio_in[37:6]  = u_seq.rd_data_r[31:0];
    assign eio_in[62:38] = phy_rst_cnt[24:0];
    assign eio_in[63]    = phy_rst_done_r;

    fcapz_eio_xilinx7 #(
        .IN_W  (64),
        .OUT_W (1),
        .CHAIN (3)
    ) u_eio (
        .probe_in  (eio_in),
        .probe_out ()
    );
`endif // FCAPZ_DEBUG

endmodule
