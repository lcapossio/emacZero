// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// eth_mac_sys_standin.v - Parity-only stand-in for eth_mac_sys.
// Read on the Verilog (golden) side of the proofs of the board modules that
// instantiate eth_mac_sys (sim/parity/sfp_lb_tester, sim/parity/
// gmii_lb_selftest); eth_mac_sys_standin.vhd is the line-for-line VHDL twin
// on the candidate side. The real eth_mac_sys is proven on its own
// (sim/parity/eth_mac_sys, ~11 minutes), so these proofs leave it out and
// check only the logic and the wiring around it.
//
// Same name, parameters and ports as rtl/eth_mac_sys.v; no MAC behaviour.
// A port-only (empty) module is NOT used: its outputs would be undriven, Yosys
// turns undriven nets into x, and everything downstream of the box then
// "proves" equivalent whatever it computes (checked: `q + y` vs `q - y`
// passes). Instead:
//   - every output bit is its own bit of the 332-bit register bb_q, so in the
//     induction step (arbitrary paired state) the outputs take any value;
//   - bb_q rotates by one and XORs in every input bit (clocks other than clk
//     included) at bits 331:232 and a fingerprint of every parameter at
//     231:0 (each integer in its own 32-bit field, each string one bit per
//     legal value; disjoint from the inputs, so an input never cancels a
//     parameter), so a miswired input or a wrong parameter value changes
//     bb_q, a state point paired by name (u_mac.bb_q), and the proof fails
//     (under this stand-in model);
//   - each bit i also XORs in bb_q[i+150] AND bb_q[i+220] (mod 332), which
//     for every output bit (0..111) are two bits no port shows. A rotation
//     alone made each output the previous cycle's value of the output below
//     it plus a constant (m_axis_tlast was m_axis_tvalid one cycle late), so
//     nothing here told an output from a registered copy of its neighbour.
//     The AND term removes that one-cycle correlation, not every constraint
//     on the outputs' history: a deterministic register cannot give them
//     every possible history, so equivalence holds against this stand-in;
//   - outputs are registered only, so a loopback from outputs to inputs
//     (gmii_lb_selftest) makes no combinational loop.
// RX_AXIS_ADDR_WIDTH enters the fingerprint as its resolved value, so the
// VHDL 0-sentinel default (auto_or) is compared against the Verilog default.
// =============================================================================

module eth_mac_sys #(
    parameter PHY_INTERFACE     = "MII",
    parameter MCAST_HASH_FILTER = 0,
    parameter MAX_FRAME         = 9018,
    parameter RX_AXIS_ADDR_WIDTH = ($clog2(MAX_FRAME) > 11) ? $clog2(MAX_FRAME) : 11,
    parameter TX_CSUM_OFFLOAD   = 0,
    parameter RX_CSUM_OFFLOAD   = 0,
    parameter CDC_RAM_STYLE     = "BLOCK",
    parameter CLK_FREQ_HZ       = 100_000_000,
    parameter RGMII_SPEEDS      = "ALL",
    parameter MII_DEBUG         = 0
)(
    input  wire        clk,
    input  wire        rst_n,
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
    input  wire [7:0]  s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    output wire [7:0]  m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output wire        m_axis_terror,
    output wire        m_axis_tsof,
    output wire [3:0]  mii_txd,
    output wire        mii_tx_en,
    input  wire        mii_tx_clk,
    input  wire [3:0]  mii_rxd,
    input  wire        mii_rx_dv,
    input  wire        mii_rx_er,
    input  wire        mii_rx_clk,
    input  wire        mii_col,
    input  wire        mii_crs,
    input  wire        clk_125,
    input  wire        clk_125_90,
    input  wire        clk_25,
    input  wire        clk_2_5,
    output wire [3:0]  rgmii_txd,
    output wire        rgmii_tx_ctl,
    output wire        rgmii_txc,
    input  wire [3:0]  rgmii_rxd,
    input  wire        rgmii_rx_ctl,
    input  wire        rgmii_rxc,
    output wire [7:0]  phy_gmii_txd,
    output wire        phy_gmii_tx_en,
    output wire        phy_gmii_tx_er,
    output wire        phy_gmii_txc,
    input  wire        phy_gmii_rx_clk,
    input  wire [7:0]  phy_gmii_rxd,
    input  wire        phy_gmii_rx_dv,
    input  wire        phy_gmii_rx_er,
    output wire        mdc,
    input  wire        mdio_i,
    output wire        mdio_o,
    output wire        mdio_oe,
    output wire [31:0] cfg_ip_addr,
    output wire        irq
);

    // Parameter fingerprint
    localparam [31:0] FP_MAX  = MAX_FRAME;
    localparam [31:0] FP_CLK  = CLK_FREQ_HZ;
    localparam [31:0] FP_AW   = RX_AXIS_ADDR_WIDTH;
    localparam [31:0] FP_MCF  = MCAST_HASH_FILTER;
    localparam [31:0] FP_TXC  = TX_CSUM_OFFLOAD;
    localparam [31:0] FP_RXC  = RX_CSUM_OFFLOAD;
    localparam [31:0] FP_DBG  = MII_DEBUG;
    localparam [7:0]  FP_STR  = {PHY_INTERFACE == "MII", PHY_INTERFACE == "GMII",
                                 PHY_INTERFACE == "RGMII",
                                 CDC_RAM_STYLE == "BLOCK", CDC_RAM_STYLE == "DISTRIBUTED",
                                 RGMII_SPEEDS == "ALL", RGMII_SPEEDS == "1G_ONLY",
                                 RGMII_SPEEDS == "10_100"};
    localparam [231:0] GEN_FP = {FP_STR, FP_DBG, FP_RXC, FP_TXC, FP_MCF,
                                 FP_AW, FP_CLK, FP_MAX};

    // Every input but clk / rst_n, in port order (100 bits)
    wire [99:0] in_bits = {s_axi_awaddr, s_axi_awvalid, s_axi_wdata, s_axi_wstrb,
                           s_axi_wvalid, s_axi_bready, s_axi_araddr, s_axi_arvalid,
                           s_axi_rready, s_axis_tdata, s_axis_tvalid, s_axis_tlast,
                           m_axis_tready, mii_tx_clk, mii_rxd, mii_rx_dv, mii_rx_er,
                           mii_rx_clk, mii_col, mii_crs, clk_125, clk_125_90, clk_25,
                           clk_2_5, rgmii_rxd, rgmii_rx_ctl, rgmii_rxc,
                           phy_gmii_rx_clk, phy_gmii_rxd, phy_gmii_rx_dv,
                           phy_gmii_rx_er, mdio_i};

    reg [331:0] bb_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) bb_q <= 332'd0;
        else        bb_q <= {bb_q[330:0], bb_q[331]} ^ {in_bits, GEN_FP}
                            ^ ({bb_q[149:0], bb_q[331:150]} & {bb_q[219:0], bb_q[331:220]});
    end

    // Every output bit from its own register bit, in port order (112 bits)
    assign s_axi_awready  = bb_q[0];
    assign s_axi_wready   = bb_q[1];
    assign s_axi_bresp    = bb_q[3:2];
    assign s_axi_bvalid   = bb_q[4];
    assign s_axi_arready  = bb_q[5];
    assign s_axi_rdata    = bb_q[37:6];
    assign s_axi_rresp    = bb_q[39:38];
    assign s_axi_rvalid   = bb_q[40];
    assign s_axis_tready  = bb_q[41];
    assign m_axis_tdata   = bb_q[49:42];
    assign m_axis_tvalid  = bb_q[50];
    assign m_axis_tlast   = bb_q[51];
    assign m_axis_terror  = bb_q[52];
    assign m_axis_tsof    = bb_q[53];
    assign mii_txd        = bb_q[57:54];
    assign mii_tx_en      = bb_q[58];
    assign rgmii_txd      = bb_q[62:59];
    assign rgmii_tx_ctl   = bb_q[63];
    assign rgmii_txc      = bb_q[64];
    assign phy_gmii_txd   = bb_q[72:65];
    assign phy_gmii_tx_en = bb_q[73];
    assign phy_gmii_tx_er = bb_q[74];
    assign phy_gmii_txc   = bb_q[75];
    assign mdc            = bb_q[76];
    assign mdio_o         = bb_q[77];
    assign mdio_oe        = bb_q[78];
    assign cfg_ip_addr    = bb_q[110:79];
    assign irq            = bb_q[111];

endmodule
