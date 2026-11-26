// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// Test harness: the ZCU106 10G design's MAC mode short of the transceiver.
// axis_test_gen64 (app_clk) -> eth_mac_sys_10g -> pcs10gbr TX (clk) -> serial
// loopback with a bit offset -> pcs10gbr RX -> eth_mac_sys_10g ->
// axis_test_chk64 (app_clk), with the board's eth_mac_sys_10g settings and
// its CSRs driven through axil_cmd_master, as the EIO does on the board.
module h_mac10g_test_loop #(
    parameter OFFSET = 23,
    parameter BER_TIMER_CYCLES = 4000
) (
    input  wire        clk,             // transceiver user clock
    input  wire        rst_n,
    input  wire        app_clk,
    input  wire        app_rst_n,
    input  wire        enable,
    input  wire [15:0] len,
    input  wire        sweep,
    input  wire [7:0]  ipg,
    input  wire        inj_err,
    input  wire        clear,
    output wire [31:0] gen_frames,
    output wire [31:0] good_frames,
    output wire [31:0] bad_frames,
    output wire [31:0] tuser_frames,
    output wire [31:0] seq_gaps,
    output wire        block_lock,
    output wire        hi_ber,
    // CSR command port (axil_cmd_master)
    input  wire        csr_go,
    input  wire        csr_write,
    input  wire [7:0]  csr_addr,
    input  wire [31:0] csr_wdata,
    output wire        csr_ack,
    output wire [31:0] csr_rdata
);
    wire [63:0] xgmii_txd, xgmii_rxd, gt_txdata;
    wire [7:0]  xgmii_txc, xgmii_rxc;
    wire        xgmii_tx_ready, xgmii_rx_valid;
    wire [15:0] ber_cnt;
    wire [63:0] g_tdata, r_tdata;
    wire [7:0]  g_tkeep, r_tkeep;
    wire        g_tvalid, g_tlast, g_tready, r_tvalid, r_tlast, r_tuser;

    reg  [63:0] prev;
    always @(posedge clk) prev <= gt_txdata;
    wire [127:0] two = {gt_txdata, prev};
    wire [63:0]  gt_rxdata = two[OFFSET +: 64];

    axis_test_gen64 u_gen (
        .clk (app_clk), .rst_n (app_rst_n), .enable (enable), .len (len),
        .sweep (sweep), .ipg (ipg), .inj_err (inj_err),
        .m_axis_tdata (g_tdata), .m_axis_tkeep (g_tkeep),
        .m_axis_tvalid (g_tvalid), .m_axis_tlast (g_tlast),
        .m_axis_tready (g_tready), .frames (gen_frames)
    );

    wire [7:0]  awaddr, araddr;
    wire [31:0] wdata, rdata;
    wire [3:0]  wstrb;
    wire [1:0]  bresp, rresp;
    wire        awvalid, awready, wvalid, wready, bvalid, bready;
    wire        arvalid, arready, rvalid, rready;

    axil_cmd_master u_cmd (
        .clk (app_clk), .rst_n (app_rst_n),
        .go (csr_go), .write (csr_write), .addr (csr_addr), .wdata (csr_wdata),
        .ack (csr_ack), .rdata (csr_rdata),
        .m_axi_awaddr (awaddr), .m_axi_awvalid (awvalid), .m_axi_awready (awready),
        .m_axi_wdata (wdata), .m_axi_wstrb (wstrb), .m_axi_wvalid (wvalid),
        .m_axi_wready (wready), .m_axi_bvalid (bvalid), .m_axi_bready (bready),
        .m_axi_araddr (araddr), .m_axi_arvalid (arvalid), .m_axi_arready (arready),
        .m_axi_rdata (rdata), .m_axi_rvalid (rvalid), .m_axi_rready (rready)
    );

    eth_mac_sys_10g #(
        .TX_FIFO_ADDR_WIDTH (12),
        .RX_FIFO_ADDR_WIDTH (12),
        .TXRX_EN_AT_RESET   (1),
        .JUMBO_AT_RESET     (1),
        .MAC_ADDR_AT_RESET  (48'h020000000001)
    ) u_sys (
        .clk (app_clk), .rst_n (app_rst_n),
        .s_axi_awaddr (awaddr), .s_axi_awvalid (awvalid), .s_axi_awready (awready),
        .s_axi_wdata (wdata), .s_axi_wstrb (wstrb), .s_axi_wvalid (wvalid),
        .s_axi_wready (wready), .s_axi_bresp (bresp), .s_axi_bvalid (bvalid),
        .s_axi_bready (bready), .s_axi_araddr (araddr), .s_axi_arvalid (arvalid),
        .s_axi_arready (arready), .s_axi_rdata (rdata), .s_axi_rresp (rresp),
        .s_axi_rvalid (rvalid), .s_axi_rready (rready),
        .s_axis_tdata (g_tdata), .s_axis_tkeep (g_tkeep),
        .s_axis_tvalid (g_tvalid), .s_axis_tready (g_tready),
        .s_axis_tlast (g_tlast), .s_axis_tuser (1'b0),
        .m_axis_tdata (r_tdata), .m_axis_tkeep (r_tkeep),
        .m_axis_tvalid (r_tvalid), .m_axis_tready (1'b1),
        .m_axis_tlast (r_tlast), .m_axis_tuser (r_tuser),
        .xgmii_tx_clk (clk), .xgmii_tx_rst_n (rst_n),
        .xgmii_txd (xgmii_txd), .xgmii_txc (xgmii_txc),
        .xgmii_tx_ready (xgmii_tx_ready),
        .xgmii_rx_clk (clk), .xgmii_rx_rst_n (rst_n),
        .xgmii_rxd (xgmii_rxd), .xgmii_rxc (xgmii_rxc),
        .xgmii_rx_valid (xgmii_rx_valid),
        .pcs_block_lock (block_lock), .pcs_hi_ber (hi_ber)
    );

    pcs10gbr #(.BER_TIMER_CYCLES(BER_TIMER_CYCLES)) u_pcs (
        .tx_clk (clk), .tx_rst_n (rst_n), .xgmii_txd (xgmii_txd),
        .xgmii_txc (xgmii_txc), .xgmii_tx_ready (xgmii_tx_ready),
        .gt_txdata (gt_txdata),
        .rx_clk (clk), .rx_rst_n (rst_n), .gt_rxdata (gt_rxdata),
        .xgmii_rxd (xgmii_rxd), .xgmii_rxc (xgmii_rxc),
        .xgmii_rx_valid (xgmii_rx_valid),
        .rx_block_lock (block_lock), .rx_hi_ber (hi_ber), .rx_ber_cnt (ber_cnt)
    );

    axis_test_chk64 u_chk (
        .clk (app_clk), .rst_n (app_rst_n), .clear (clear),
        .s_axis_tdata (r_tdata), .s_axis_tkeep (r_tkeep),
        .s_axis_tvalid (r_tvalid), .s_axis_tlast (r_tlast),
        .s_axis_tuser (r_tuser),
        .good_frames (good_frames), .bad_frames (bad_frames),
        .tuser_frames (tuser_frames), .seq_gaps (seq_gaps),
        .good_pulse (), .bad_pulse ()
    );
endmodule
