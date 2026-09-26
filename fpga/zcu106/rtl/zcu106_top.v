// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// zcu106_top.v - emacZero over SFP (1000BASE-X) on the AMD ZCU106
//
//   SFP cage 0 <-> GTH <-> 1G/2.5G PCS/PMA IP (1000BASE-X) <-GMII-> eth_mac_sys
//
// eth_mac_sys runs in PHY_INTERFACE="GMII" mode with its system clock, its
// GMII TX clock and its GMII RX clock all on the PCS/PMA 125 MHz userclk2, so
// the whole MAC and the demo L3 stack (ARP, ICMP echo, UDP echo on port 9999)
// are one 125 MHz clock domain.
//
// GTH reference clock (REFCLK_SI5328, set by build_zcu106.tcl):
//   0 (default): USER_MGT_SI570 (U56), 156.25 MHz at power-up, Quad 226
//      MGTREFCLK1 (U10/U9), shared into Quad 225. No setup needed; this is
//      the clock the AMD and verilog-ethernet ZCU102/ZCU106 SFP designs use.
//   1: Si5328 (U20), Quad 225 MGTREFCLK1 (W10/W9). It has no non-volatile
//      memory, so i2c_init programs it to 125 MHz over PL IIC1 (through the
//      TCA9548A mux) before the PCS/PMA reset is released.
// Either way the GT makes the 125 MHz userclk2. A watchdog re-pulses the
// PCS/PMA reset every 2 s until the GT reports reset done (covers the Si5328
// lock time, which can be ~20 s). This logic runs from the free-running
// 300 MHz user clock divided to 50 MHz, which is also the PCS/PMA independent
// (DRP / reset) clock.
//
// LEDs: 0 refclk ready (Si5328 programmed, or always on with the Si570)
//       1 I2C NACK seen        2 GT reset done
//       3 PCS link sync        4 1000BASE-X link up 5 RX frame activity
//       6 TX frame activity    7 userclk2 heartbeat (GT clock running)
// DIP 0: 1 disables 1000BASE-X auto-negotiation (for partners without AN).
// Verilog 2001
// =============================================================================

module zcu106_top #(
    parameter REFCLK_SI5328 = 0         // 0: USER_MGT_SI570, 1: Si5328
) (
    // 300 MHz free-running user clock (Si570)
    input  wire       USER_SI570_SYSCLK_P,
    input  wire       USER_SI570_SYSCLK_N,
    input  wire       CPU_RESET,          // active high

    // SFP cage 0, GTH, and its reference clock (see REFCLK_SI5328)
    input  wire       SFP_REFCLK_P,
    input  wire       SFP_REFCLK_N,
    output wire       SFP0_TX_P,
    output wire       SFP0_TX_N,
    input  wire       SFP0_RX_P,
    input  wire       SFP0_RX_N,
    output wire       SFP0_TX_DISABLE_B,  // high = laser on (J16 also forces on)

    // PL I2C to the Si5328 (through the TCA9548A mux); released (high-Z)
    // when REFCLK_SI5328 = 0
    output wire       IIC_SCL,            // open drain (no clock stretching)
    inout  wire       IIC_SDA,

    input  wire       DIP_AN_DISABLE,
    output wire [7:0] LED
);

    localparam [47:0] OUR_MAC = 48'h02_00_00_00_00_01;
    localparam [15:0] UDP_ECHO_PORT = 16'd9999;

    // =========================================================================
    // 50 MHz free-running clock: 300 MHz / 6
    // =========================================================================
    wire clk_300_ibuf;
    wire clk_50;

    IBUFDS u_sysclk_ibuf (
        .I  (USER_SI570_SYSCLK_P),
        .IB (USER_SI570_SYSCLK_N),
        .O  (clk_300_ibuf)
    );

    BUFGCE_DIV #(.BUFGCE_DIVIDE(6)) u_clk_50_buf (
        .I   (clk_300_ibuf),
        .CE  (1'b1),
        .CLR (1'b0),
        .O   (clk_50)
    );

    // CPU_RESET synchronized into clk_50 (async assert, sync release)
    (* ASYNC_REG = "TRUE" *) reg [2:0] rst50_sync;
    always @(posedge clk_50 or posedge CPU_RESET) begin
        if (CPU_RESET) rst50_sync <= 3'b000;
        else           rst50_sync <= {rst50_sync[1:0], 1'b1};
    end
    wire rst50_n = rst50_sync[2];

    // =========================================================================
    // Reference clock bring-up (Si5328 over I2C, or nothing for the Si570)
    // =========================================================================
    wire       scl_t, sda_t;
    wire       refclk_ready;
    wire [7:0] i2c_nacks;

    assign IIC_SCL = scl_t ? 1'bz : 1'b0;
    assign IIC_SDA = sda_t ? 1'bz : 1'b0;

    generate if (REFCLK_SI5328) begin : gen_si5328
    i2c_init #(
        .CLK_HZ      (50_000_000),
        .I2C_HZ      (100_000),
        .START_DELAY (50_000_000),        // 1 s: let the system controller
                                          // finish its own Si5328 setup
        .RETRY_DELAY (50_000_000 / 10),
        .DONE_DELAY  (50_000_000 / 10)    // lock wait is the GT watchdog's job
    ) u_si5328_init (
        .clk        (clk_50),
        .rst_n      (rst50_n),
        .scl_t      (scl_t),
        .sda_t      (sda_t),
        .sda_i      (IIC_SDA),
        .done       (refclk_ready),
        .busy       (),
        .nack_count (i2c_nacks)
    );
    end else begin : gen_si570
    // The USER_MGT_SI570 runs at 156.25 MHz from power-up; leave I2C alone.
    assign scl_t       = 1'b1;
    assign sda_t       = 1'b1;
    assign refclk_ready = 1'b1;
    assign i2c_nacks   = 8'd0;
    end endgenerate

    // Keep the SFP laser off until the reference clock is ready.
    assign SFP0_TX_DISABLE_B = refclk_ready;

    // GT bring-up watchdog: hold the PCS/PMA in reset until the reference
    // clock is ready, then pulse its reset for 1 ms every 2 s until the GT
    // reports reset done (covers the Si5328 lock time).
    localparam integer WD_PERIOD   = 100_000_000;  // 2 s at 50 MHz
    localparam integer RESET_PULSE = 50_000;       // 1 ms
    wire       gt_resetdone;
    (* ASYNC_REG = "TRUE" *) reg [2:0] gt_done_sync;
    reg [26:0] wd_cnt;
    reg        pcs_reset;
    always @(posedge clk_50) gt_done_sync <= {gt_done_sync[1:0], gt_resetdone};
    always @(posedge clk_50 or negedge rst50_n) begin
        if (!rst50_n) begin
            wd_cnt    <= 27'd0;
            pcs_reset <= 1'b1;
        end else if (!refclk_ready) begin
            wd_cnt    <= 27'd0;
            pcs_reset <= 1'b1;
        end else if (gt_done_sync[2]) begin
            wd_cnt    <= 27'd0;
            pcs_reset <= 1'b0;
        end else begin
            wd_cnt    <= (wd_cnt == WD_PERIOD - 1) ? 27'd0 : wd_cnt + 27'd1;
            pcs_reset <= (wd_cnt < RESET_PULSE);
        end
    end

    // =========================================================================
    // PCS/PMA (1000BASE-X over GTH, shared logic in core)
    // =========================================================================
    wire        userclk2;
    wire        gt_mmcm_locked;
    wire        pma_reset_out;
    wire [15:0] pcs_status;

    wire [7:0]  gmii_txd;
    wire        gmii_tx_en;
    wire        gmii_tx_er;
    wire [7:0]  gmii_rxd;
    wire        gmii_rx_dv;
    wire        gmii_rx_er;

    // DIP_AN_DISABLE is a static strap; synchronize it into userclk2, the
    // clock the PCS/PMA samples configuration_vector on.
    (* ASYNC_REG = "TRUE" *) reg [1:0] an_dis_sync;
    always @(posedge userclk2) an_dis_sync <= {an_dis_sync[0], DIP_AN_DISABLE};

    pcs_pma_1000basex u_pcs_pma (
        .gtrefclk_p             (SFP_REFCLK_P),
        .gtrefclk_n             (SFP_REFCLK_N),
        .gtrefclk_out           (),
        .txn                    (SFP0_TX_N),
        .txp                    (SFP0_TX_P),
        .rxn                    (SFP0_RX_N),
        .rxp                    (SFP0_RX_P),
        .independent_clock_bufg (clk_50),
        .userclk_out            (),
        .userclk2_out           (userclk2),
        .rxuserclk_out          (),
        .rxuserclk2_out         (),
        .gtpowergood            (),
        .resetdone              (gt_resetdone),
        .pma_reset_out          (pma_reset_out),
        .mmcm_locked_out        (gt_mmcm_locked),
        .gmii_txd               (gmii_txd),
        .gmii_tx_en             (gmii_tx_en),
        .gmii_tx_er             (gmii_tx_er),
        .gmii_rxd               (gmii_rxd),
        .gmii_rx_dv             (gmii_rx_dv),
        .gmii_rx_er             (gmii_rx_er),
        .gmii_isolate           (),
        // [4] AN enable, [3] isolate, [2] powerdown, [1] loopback, [0] unidir
        .configuration_vector   ({~an_dis_sync[1], 4'b0000}),
        .an_interrupt           (),
        // 1000BASE-X base page: full duplex only, no PAUSE advertised
        .an_adv_config_vector   (16'h0020),
        .an_restart_config      (1'b0),
        .status_vector          (pcs_status),
        .reset                  (pcs_reset),
        .signal_detect          (1'b1)
    );

    // MAC reset: released once the GT is up and userclk2 is running. The
    // three PCS/PMA status bits are each synchronized into clk_50 (reset done
    // reuses the watchdog's gt_done_sync) and then combined in a flop, so the
    // async reset below is driven glitch-free.
    (* ASYNC_REG = "TRUE" *) reg [1:0] gt_locked_sync, pma_rst_sync;
    reg mac_rst_async_n;
    always @(posedge clk_50 or negedge rst50_n) begin
        if (!rst50_n) begin
            gt_locked_sync  <= 2'b00;
            pma_rst_sync    <= 2'b11;
            mac_rst_async_n <= 1'b0;
        end else begin
            gt_locked_sync  <= {gt_locked_sync[0],  gt_mmcm_locked};
            pma_rst_sync    <= {pma_rst_sync[0],    pma_reset_out};
            mac_rst_async_n <= gt_done_sync[2] & gt_locked_sync[1] & ~pma_rst_sync[1];
        end
    end
    (* ASYNC_REG = "TRUE" *) reg [2:0] mac_rst_sync;
    always @(posedge userclk2 or negedge mac_rst_async_n) begin
        if (!mac_rst_async_n) mac_rst_sync <= 3'b000;
        else                  mac_rst_sync <= {mac_rst_sync[1:0], 1'b1};
    end
    wire rst_n = mac_rst_sync[2];

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
        .clk           (userclk2),
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
    // Ethernet MAC (GMII mode). CSRs stay at their reset values: TX/RX
    // enabled, speed 1G, MAC 02:00:00:00:00:01, IP 192.168.137.200.
    // =========================================================================
    wire [7:0]  mac_rx_tdata;
    wire        mac_rx_tvalid, mac_rx_tlast, mac_rx_terror, mac_rx_tsof;

    eth_mac_sys #(
        .PHY_INTERFACE ("GMII"),
        .CLK_FREQ_HZ   (125_000_000)
    ) u_mac_sys (
        .clk            (userclk2),
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
        .clk_125        (userclk2),
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
        .phy_gmii_rx_clk (userclk2),
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

    // =========================================================================
    // Demo L3 stack: ARP responder, IPv4/ICMP/UDP parser, ping, UDP echo
    // =========================================================================
    arp_responder u_arp (
        .clk            (userclk2),
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
    wire        netrx_icmp_valid, netrx_icmp_last;
    wire [31:0] netrx_icmp_src_ip;
    wire [47:0] netrx_rx_src_mac;
    wire [7:0]  netrx_udp_data;
    wire        netrx_udp_valid, netrx_udp_last;
    wire [31:0] netrx_udp_src_ip;
    wire [15:0] netrx_udp_src_port, netrx_udp_dst_port, netrx_udp_length;

    net_rx u_net_rx (
        .clk            (userclk2),
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
        .icmp_src_ip    (netrx_icmp_src_ip),
        .udp_data       (netrx_udp_data),
        .udp_valid      (netrx_udp_valid),
        .udp_last       (netrx_udp_last),
        .udp_src_ip     (netrx_udp_src_ip),
        .udp_src_port   (netrx_udp_src_port),
        .udp_dst_port   (netrx_udp_dst_port),
        .udp_length     (netrx_udp_length),
        .rx_src_mac     (netrx_rx_src_mac),
        .our_ip         (cfg_ip_addr)
    );

    icmp_echo u_icmp (
        .clk            (userclk2),
        .rst_n          (rst_n),
        .our_mac        (OUR_MAC),
        .our_ip         (cfg_ip_addr),
        .icmp_rx_data   (netrx_icmp_data),
        .icmp_rx_valid  (netrx_icmp_valid),
        .icmp_rx_last   (netrx_icmp_last),
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
        .clk             (userclk2),
        .rst_n           (rst_n),
        .our_mac         (OUR_MAC),
        .our_ip          (cfg_ip_addr),
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
        .tx_start        ()
    );

    // =========================================================================
    // LEDs
    // =========================================================================
    // Activity: stretch a frame-end pulse to ~67 ms at 125 MHz.
    reg [22:0] rx_led_cnt, tx_led_cnt;
    reg [26:0] heartbeat = 27'd0;
    always @(posedge userclk2 or negedge rst_n) begin
        if (!rst_n) begin
            rx_led_cnt <= 23'd0;
            tx_led_cnt <= 23'd0;
        end else begin
            if (mac_rx_tvalid && mac_rx_tlast)       rx_led_cnt <= {23{1'b1}};
            else if (rx_led_cnt != 0)                rx_led_cnt <= rx_led_cnt - 23'd1;
            if (mac_tx_tvalid && mac_tx_tready && mac_tx_tlast)
                                                     tx_led_cnt <= {23{1'b1}};
            else if (tx_led_cnt != 0)                tx_led_cnt <= tx_led_cnt - 23'd1;
        end
    end
    always @(posedge userclk2) heartbeat <= heartbeat + 27'd1;

    assign LED[0] = refclk_ready;
    assign LED[1] = (i2c_nacks != 8'd0);
    assign LED[2] = gt_resetdone;
    assign LED[3] = pcs_status[1];
    assign LED[4] = pcs_status[0];
    assign LED[5] = (rx_led_cnt != 0);
    assign LED[6] = (tx_led_cnt != 0);
    assign LED[7] = heartbeat[26];

endmodule
