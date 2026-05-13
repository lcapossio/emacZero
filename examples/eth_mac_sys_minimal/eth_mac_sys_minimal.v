// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// eth_mac_sys_minimal.v
//
// Minimal eth_mac_sys integration template. Brings every host-side port out
// at the top so an external SoC can wire up:
//   - AXI4-Lite CSR (from CPU)
//   - AXI4-Stream TX (from packet producer)
//   - AXI4-Stream RX (to packet consumer)
//   - MII pins   (to PHY)
//   - MDIO       (to PHY, with tristate buffer in the host shell)
//
// Copy this file, set PHY_INTERFACE to "MII" or "RGMII", and remove ports
// for the interface you don't use.
//
// Verilog 2001.
// =============================================================================

module eth_mac_sys_minimal #(
    parameter PHY_INTERFACE = "MII"     // "MII" or "RGMII"
) (
    input  wire        clk,             // 100 MHz system clock
    input  wire        rst_n,

    // ---- AXI4-Lite CSR (slave) ----
    input  wire [6:0]  s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [6:0]  s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,

    // ---- AXI4-Stream TX (host -> MAC) ----
    input  wire [7:0]  s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,

    // ---- AXI4-Stream RX (MAC -> host) ----
    output wire [7:0]  m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output wire        m_axis_terror,
    output wire        m_axis_tsof,

    // ---- MII PHY (used when PHY_INTERFACE="MII") ----
    output wire [3:0]  mii_txd,
    output wire        mii_tx_en,
    input  wire        mii_tx_clk,
    input  wire [3:0]  mii_rxd,
    input  wire        mii_rx_dv,
    input  wire        mii_rx_er,
    input  wire        mii_rx_clk,
    input  wire        mii_col,
    input  wire        mii_crs,

    // ---- RGMII PHY (used when PHY_INTERFACE="RGMII") ----
    input  wire        clk_125,         // 125 MHz
    input  wire        clk_125_90,      // 125 MHz, 90-deg phase
    input  wire        clk_25,          // 25 MHz  (100M ref)
    input  wire        clk_2_5,         // 2.5 MHz (10M  ref)
    output wire [3:0]  rgmii_txd,
    output wire        rgmii_tx_ctl,
    output wire        rgmii_txc,
    input  wire [3:0]  rgmii_rxd,
    input  wire        rgmii_rx_ctl,
    input  wire        rgmii_rxc,

    // ---- MDIO (1-bit pad with tristate handled in host shell) ----
    output wire        mdc,
    input  wire        mdio_i,
    output wire        mdio_o,
    output wire        mdio_oe,

    // ---- Interrupt to host CPU ----
    output wire        irq
);

    eth_mac_sys #(
        .PHY_INTERFACE (PHY_INTERFACE)
    ) u_mac (
        .clk           (clk),
        .rst_n         (rst_n),

        .s_axi_awaddr  (s_axi_awaddr),
        .s_axi_awvalid (s_axi_awvalid),
        .s_axi_awready (s_axi_awready),
        .s_axi_wdata   (s_axi_wdata),
        .s_axi_wstrb   (s_axi_wstrb),
        .s_axi_wvalid  (s_axi_wvalid),
        .s_axi_wready  (s_axi_wready),
        .s_axi_bresp   (s_axi_bresp),
        .s_axi_bvalid  (s_axi_bvalid),
        .s_axi_bready  (s_axi_bready),
        .s_axi_araddr  (s_axi_araddr),
        .s_axi_arvalid (s_axi_arvalid),
        .s_axi_arready (s_axi_arready),
        .s_axi_rdata   (s_axi_rdata),
        .s_axi_rresp   (s_axi_rresp),
        .s_axi_rvalid  (s_axi_rvalid),
        .s_axi_rready  (s_axi_rready),

        .s_axis_tdata  (s_axis_tdata),
        .s_axis_tvalid (s_axis_tvalid),
        .s_axis_tready (s_axis_tready),
        .s_axis_tlast  (s_axis_tlast),

        .m_axis_tdata  (m_axis_tdata),
        .m_axis_tvalid (m_axis_tvalid),
        .m_axis_tready (m_axis_tready),
        .m_axis_tlast  (m_axis_tlast),
        .m_axis_terror (m_axis_terror),
        .m_axis_tsof   (m_axis_tsof),

        .mii_txd       (mii_txd),
        .mii_tx_en     (mii_tx_en),
        .mii_tx_clk    (mii_tx_clk),
        .mii_rxd       (mii_rxd),
        .mii_rx_dv     (mii_rx_dv),
        .mii_rx_er     (mii_rx_er),
        .mii_rx_clk    (mii_rx_clk),
        .mii_col       (mii_col),
        .mii_crs       (mii_crs),

        .clk_125       (clk_125),
        .clk_125_90    (clk_125_90),
        .clk_25        (clk_25),
        .clk_2_5       (clk_2_5),
        .rgmii_txd     (rgmii_txd),
        .rgmii_tx_ctl  (rgmii_tx_ctl),
        .rgmii_txc     (rgmii_txc),
        .rgmii_rxd     (rgmii_rxd),
        .rgmii_rx_ctl  (rgmii_rx_ctl),
        .rgmii_rxc     (rgmii_rxc),

        .mdc           (mdc),
        .mdio_i        (mdio_i),
        .mdio_o        (mdio_o),
        .mdio_oe       (mdio_oe),

        .irq           (irq)
    );

endmodule
