// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// Test harness: eth_mac_sys_10g (app clock clk) -> XGMII -> pcs10gbr TX ->
// serial loopback with a bit offset -> pcs10gbr RX -> XGMII -> back into the
// same eth_mac_sys_10g. The PCS and both MACs run on gt_clk (the transceiver
// user clock); clk is unrelated, so both frame FIFOs cross clock domains.
// tx_rst_n / rx_rst_n reset one direction of the transceiver side alone (PCS
// and the system's XGMII side), as a transceiver TX or RX reset does.
// cut replaces the received serial data with zeros (a broken fibre): the PCS
// loses block lock and sends local fault sequences up to the system.
module h_eth_mac_sys_10g_loop #(
    parameter OFFSET             = 37,
    parameter BER_TIMER_CYCLES   = 4000,
    parameter TX_FIFO_ADDR_WIDTH = 11,
    parameter RX_FIFO_ADDR_WIDTH = 11
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        gt_clk,
    input  wire        gt_rst_n,
    input  wire        tx_rst_n,
    input  wire        rx_rst_n,
    input  wire        cut,

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

    input  wire [63:0] s_axis_tdata,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tuser,

    output wire [63:0] m_axis_tdata,
    output wire [7:0]  m_axis_tkeep,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output wire        m_axis_tuser,

    output wire [63:0] xgmii_txd,
    output wire [7:0]  xgmii_txc,
    output wire        xgmii_tx_ready,
    output wire        block_lock
);
    wire [63:0] xgmii_rxd, gt_txdata;
    wire [7:0]  xgmii_rxc;
    wire        xgmii_rx_valid, hi_ber;
    wire [15:0] ber_cnt;
    wire        x_tx_rst_n = gt_rst_n && tx_rst_n;
    wire        x_rx_rst_n = gt_rst_n && rx_rst_n;

    reg  [63:0] prev;
    always @(posedge gt_clk) prev <= gt_txdata;
    wire [127:0] two = {gt_txdata, prev};
    wire [63:0]  gt_rxdata = cut ? 64'd0 : two[OFFSET +: 64];

    eth_mac_sys_10g #(
        .TX_FIFO_ADDR_WIDTH (TX_FIFO_ADDR_WIDTH),
        .RX_FIFO_ADDR_WIDTH (RX_FIFO_ADDR_WIDTH),
        .MCAST_HASH_FILTER  (1)
    ) u_sys (
        .clk (clk), .rst_n (rst_n),
        .s_axi_awaddr (s_axi_awaddr), .s_axi_awvalid (s_axi_awvalid),
        .s_axi_awready (s_axi_awready), .s_axi_wdata (s_axi_wdata),
        .s_axi_wstrb (s_axi_wstrb), .s_axi_wvalid (s_axi_wvalid),
        .s_axi_wready (s_axi_wready), .s_axi_bresp (s_axi_bresp),
        .s_axi_bvalid (s_axi_bvalid), .s_axi_bready (s_axi_bready),
        .s_axi_araddr (s_axi_araddr), .s_axi_arvalid (s_axi_arvalid),
        .s_axi_arready (s_axi_arready), .s_axi_rdata (s_axi_rdata),
        .s_axi_rresp (s_axi_rresp), .s_axi_rvalid (s_axi_rvalid),
        .s_axi_rready (s_axi_rready),
        .s_axis_tdata (s_axis_tdata), .s_axis_tkeep (s_axis_tkeep),
        .s_axis_tvalid (s_axis_tvalid), .s_axis_tready (s_axis_tready),
        .s_axis_tlast (s_axis_tlast), .s_axis_tuser (s_axis_tuser),
        .m_axis_tdata (m_axis_tdata), .m_axis_tkeep (m_axis_tkeep),
        .m_axis_tvalid (m_axis_tvalid), .m_axis_tready (m_axis_tready),
        .m_axis_tlast (m_axis_tlast), .m_axis_tuser (m_axis_tuser),
        .xgmii_tx_clk (gt_clk), .xgmii_tx_rst_n (x_tx_rst_n),
        .xgmii_txd (xgmii_txd), .xgmii_txc (xgmii_txc),
        .xgmii_tx_ready (xgmii_tx_ready),
        .xgmii_rx_clk (gt_clk), .xgmii_rx_rst_n (x_rx_rst_n),
        .xgmii_rxd (xgmii_rxd), .xgmii_rxc (xgmii_rxc),
        .xgmii_rx_valid (xgmii_rx_valid),
        .pcs_block_lock (block_lock), .pcs_hi_ber (hi_ber),
        .cfg_ip_addr    ()
    );

    pcs10gbr #(.BER_TIMER_CYCLES(BER_TIMER_CYCLES)) u_pcs (
        .tx_clk (gt_clk), .tx_rst_n (x_tx_rst_n), .xgmii_txd (xgmii_txd),
        .xgmii_txc (xgmii_txc), .xgmii_tx_ready (xgmii_tx_ready),
        .gt_txdata (gt_txdata),
        .rx_clk (gt_clk), .rx_rst_n (x_rx_rst_n), .gt_rxdata (gt_rxdata),
        .xgmii_rxd (xgmii_rxd), .xgmii_rxc (xgmii_rxc),
        .xgmii_rx_valid (xgmii_rx_valid),
        .rx_block_lock (block_lock), .rx_hi_ber (hi_ber), .rx_ber_cnt (ber_cnt)
    );
endmodule
