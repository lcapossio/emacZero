// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// zcu106_10g_lane.v - one port of the ZCU106 10G design, short of the
// transceiver: the PCS and both test paths.
//
//   raw:  xgmii_test_gen -> pcs10gbr TX -> gt_txdata
//         gt_rxdata -> pcs10gbr RX -> xgmii_test_chk
//   MAC:  axis_test_gen64 (clk_app) -> eth_mac_sys_10g -> pcs10gbr TX -> ...
//         ... -> pcs10gbr RX -> eth_mac_sys_10g -> axis_test_chk64 (clk_app)
//
// eth_mac_sys_10g's CSRs are reached through axil_cmd_master. zcu106_10g_top
// puts one lane on each transceiver; the simulation harnesses connect lanes
// to each other through a serial loopback. ctrl is this port's 128 bits of
// the EIO output (TCK domain; bit map in zcu106_10g_top.v): the lane uses
// the generator, checker, mode and CSR fields; the top uses the transceiver
// fields. Controls cross into each clock domain through synchronizers.
// Verilog 2001
// =============================================================================

module zcu106_10g_lane #(
    parameter BER_TIMER_CYCLES = 20142     // as pcs10gbr: 125 us at 161.13 MHz
) (
    input  wire         tx_clk,            // TXUSRCLK2
    input  wire         tx_rst_n,
    input  wire         rx_clk,            // RXUSRCLK2
    input  wire         rx_rst_n,
    input  wire         clk_app,
    input  wire         app_rst_n,
    input  wire [127:0] ctrl,

    output wire [63:0]  gt_txdata,
    input  wire [63:0]  gt_rxdata,

    output wire         block_lock,
    output wire         hi_ber,
    output wire [15:0]  ber_cnt,
    output reg  [31:0]  lock_losses,
    // raw XGMII path (gen_frames: TX domain, the rest: RX domain)
    output wire [31:0]  gen_frames,
    output wire [31:0]  good_frames,
    output wire [31:0]  bad_frames,
    output wire [31:0]  seq_gaps,
    output wire [31:0]  bad_words,
    output wire [31:0]  lf_words,
    // MAC path (clk_app)
    output wire [31:0]  mac_gen_frames,
    output wire [31:0]  mac_good,
    output wire [31:0]  mac_bad,
    output wire [31:0]  mac_tuser,
    output wire [31:0]  mac_seq_gaps,
    output wire         csr_ack,
    output wire [31:0]  csr_rdata,
    // the checker of the selected mode: a bad frame since the last clear
    // (sticky), a good frame in the last ~0.1 s
    output wire         sel_bad_seen,
    output wire         sel_good_led
);

    wire        ctl_gen_en    = ctrl[8];
    wire        ctl_inj       = ctrl[9];
    wire        ctl_clear     = ctrl[10];
    wire        ctl_mac_mode  = ctrl[13];
    wire        ctl_sweep     = ctrl[14];
    wire [7:0]  ctl_len       = ctrl[23:16];
    wire [7:0]  ctl_ipg       = ctrl[31:24];
    wire [15:0] ctl_mac_len   = ctrl[79:64];
    wire [7:0]  ctl_csr_addr  = ctrl[87:80];
    wire [31:0] ctl_csr_wdata = ctrl[119:88];
    wire        ctl_csr_go    = ctrl[120];
    wire        ctl_csr_write = ctrl[121];

    // =========================================================================
    // PCS
    // =========================================================================
    wire [63:0] xgmii_txd, xgmii_rxd;
    wire [7:0]  xgmii_txc, xgmii_rxc;
    wire        xgmii_tx_ready, xgmii_rx_valid;

    pcs10gbr #(.BER_TIMER_CYCLES(BER_TIMER_CYCLES)) u_pcs (
        .tx_clk         (tx_clk),
        .tx_rst_n       (tx_rst_n),
        .xgmii_txd      (xgmii_txd),
        .xgmii_txc      (xgmii_txc),
        .xgmii_tx_ready (xgmii_tx_ready),
        .gt_txdata      (gt_txdata),
        .rx_clk         (rx_clk),
        .rx_rst_n       (rx_rst_n),
        .gt_rxdata      (gt_rxdata),
        .xgmii_rxd      (xgmii_rxd),
        .xgmii_rxc      (xgmii_rxc),
        .xgmii_rx_valid (xgmii_rx_valid),
        .rx_block_lock  (block_lock),
        .rx_hi_ber      (hi_ber),
        .rx_ber_cnt     (ber_cnt)
    );

    // =========================================================================
    // Raw XGMII test path (transceiver clocks)
    // =========================================================================
    (* ASYNC_REG = "TRUE" *) reg [2:0] s_gen_en, s_inj, s_mac_tx;
    always @(posedge tx_clk) begin
        s_gen_en <= {s_gen_en[1:0], ctl_gen_en};
        s_inj    <= {s_inj[1:0], ctl_inj};
        s_mac_tx <= {s_mac_tx[1:0], ctl_mac_mode};
    end
    wire mac_tx = s_mac_tx[2];
    wire inj_p  = s_inj[1] && !s_inj[2];
    wire [63:0] gen_txd, mac_txd;
    wire [7:0]  gen_txc, mac_txc;
    // switch modes with the generators off: a frame cut in half is lost
    assign xgmii_txd = mac_tx ? mac_txd : gen_txd;
    assign xgmii_txc = mac_tx ? mac_txc : gen_txc;
    wire [7:0] len_words = ctl_len + 8'd8;   // EIO 0 -> 8 words (64 bytes)

    xgmii_test_gen u_gen (
        .clk            (tx_clk),
        .rst_n          (tx_rst_n),
        .enable         (s_gen_en[2] && !mac_tx),
        .len_words      (len_words),
        .ipg_words      (ctl_ipg),
        .inj_err        (inj_p && !mac_tx),
        .xgmii_tx_ready (xgmii_tx_ready),
        .xgmii_txd      (gen_txd),
        .xgmii_txc      (gen_txc),
        .frames         (gen_frames)
    );

    (* ASYNC_REG = "TRUE" *) reg [2:0] s_clr;
    always @(posedge rx_clk) s_clr <= {s_clr[1:0], ctl_clear};

    wire good_pulse, bad_pulse;
    xgmii_test_chk u_chk (
        .clk            (rx_clk),
        .rst_n          (rx_rst_n),
        .clear          (s_clr[2]),
        .len_words      (len_words),
        .xgmii_rxd      (xgmii_rxd),
        .xgmii_rxc      (xgmii_rxc),
        .xgmii_rx_valid (xgmii_rx_valid),
        .good_frames    (good_frames),
        .bad_frames     (bad_frames),
        .seq_gaps       (seq_gaps),
        .bad_words      (bad_words),
        .lf_words       (lf_words),
        .good_pulse     (good_pulse),
        .bad_pulse      (bad_pulse)
    );

    // block lock losses
    reg lock_d;
    always @(posedge rx_clk or negedge rx_rst_n) begin
        if (!rx_rst_n) begin
            lock_d      <= 1'b0;
            lock_losses <= 32'd0;
        end else begin
            lock_d <= block_lock;
            if (s_clr[2])                   lock_losses <= 32'd0;
            else if (lock_d && !block_lock) lock_losses <= lock_losses + 32'd1;
        end
    end

    // =========================================================================
    // MAC mode: test frames through eth_mac_sys_10g; generator, checker and
    // CSRs on clk_app
    // =========================================================================
    (* ASYNC_REG = "TRUE" *) reg [2:0] a_gen_en, a_inj, a_mac, a_clr;
    always @(posedge clk_app) begin
        a_gen_en <= {a_gen_en[1:0], ctl_gen_en};
        a_inj    <= {a_inj[1:0], ctl_inj};
        a_mac    <= {a_mac[1:0], ctl_mac_mode};
        a_clr    <= {a_clr[1:0], ctl_clear};
    end
    wire mac_app = a_mac[2];

    wire [63:0] mg_tdata, mr_tdata;
    wire [7:0]  mg_tkeep, mr_tkeep;
    wire        mg_tvalid, mg_tlast, mg_tready;
    wire        mr_tvalid, mr_tlast, mr_tuser;
    axis_test_gen64 u_mgen (
        .clk           (clk_app),
        .rst_n         (app_rst_n),
        .enable        (a_gen_en[2] && mac_app),
        .len           (ctl_mac_len),
        .sweep         (ctl_sweep),
        .ipg           (ctl_ipg),
        .inj_err       (a_inj[1] && !a_inj[2] && mac_app),
        .m_axis_tdata  (mg_tdata),
        .m_axis_tkeep  (mg_tkeep),
        .m_axis_tvalid (mg_tvalid),
        .m_axis_tlast  (mg_tlast),
        .m_axis_tready (mg_tready),
        .frames        (mac_gen_frames)
    );

    wire [7:0]  csr_awaddr, csr_araddr;
    wire [31:0] csr_wdata, csr_rdata_bus;
    wire [3:0]  csr_wstrb;
    wire [1:0]  csr_bresp, csr_rresp;
    wire        csr_awvalid, csr_awready, csr_wvalid, csr_wready;
    wire        csr_bvalid, csr_bready, csr_arvalid, csr_arready;
    wire        csr_rvalid, csr_rready;

    axil_cmd_master u_csr_cmd (
        .clk           (clk_app),
        .rst_n         (app_rst_n),
        .go            (ctl_csr_go),
        .write         (ctl_csr_write),
        .addr          (ctl_csr_addr),
        .wdata         (ctl_csr_wdata),
        .ack           (csr_ack),
        .rdata         (csr_rdata),
        .m_axi_awaddr  (csr_awaddr),
        .m_axi_awvalid (csr_awvalid),
        .m_axi_awready (csr_awready),
        .m_axi_wdata   (csr_wdata),
        .m_axi_wstrb   (csr_wstrb),
        .m_axi_wvalid  (csr_wvalid),
        .m_axi_wready  (csr_wready),
        .m_axi_bvalid  (csr_bvalid),
        .m_axi_bready  (csr_bready),
        .m_axi_araddr  (csr_araddr),
        .m_axi_arvalid (csr_arvalid),
        .m_axi_arready (csr_arready),
        .m_axi_rdata   (csr_rdata_bus),
        .m_axi_rvalid  (csr_rvalid),
        .m_axi_rready  (csr_rready)
    );

    // No CPU on this board design: TX/RX and jumbo frames are on from reset
    // and the station address is the test frames' destination.
    eth_mac_sys_10g #(
        .TX_FIFO_ADDR_WIDTH (12),
        .RX_FIFO_ADDR_WIDTH (12),
        .TXRX_EN_AT_RESET   (1),
        .JUMBO_AT_RESET     (1),
        .MAC_ADDR_AT_RESET  (48'h020000000001)
    ) u_sys (
        .clk            (clk_app),
        .rst_n          (app_rst_n),
        .s_axi_awaddr   (csr_awaddr),
        .s_axi_awvalid  (csr_awvalid),
        .s_axi_awready  (csr_awready),
        .s_axi_wdata    (csr_wdata),
        .s_axi_wstrb    (csr_wstrb),
        .s_axi_wvalid   (csr_wvalid),
        .s_axi_wready   (csr_wready),
        .s_axi_bresp    (csr_bresp),
        .s_axi_bvalid   (csr_bvalid),
        .s_axi_bready   (csr_bready),
        .s_axi_araddr   (csr_araddr),
        .s_axi_arvalid  (csr_arvalid),
        .s_axi_arready  (csr_arready),
        .s_axi_rdata    (csr_rdata_bus),
        .s_axi_rresp    (csr_rresp),
        .s_axi_rvalid   (csr_rvalid),
        .s_axi_rready   (csr_rready),
        .s_axis_tdata   (mg_tdata),
        .s_axis_tkeep   (mg_tkeep),
        .s_axis_tvalid  (mg_tvalid),
        .s_axis_tready  (mg_tready),
        .s_axis_tlast   (mg_tlast),
        .s_axis_tuser   (1'b0),
        .m_axis_tdata   (mr_tdata),
        .m_axis_tkeep   (mr_tkeep),
        .m_axis_tvalid  (mr_tvalid),
        .m_axis_tready  (1'b1),
        .m_axis_tlast   (mr_tlast),
        .m_axis_tuser   (mr_tuser),
        .xgmii_tx_clk   (tx_clk),
        .xgmii_tx_rst_n (tx_rst_n),
        .xgmii_txd      (mac_txd),
        .xgmii_txc      (mac_txc),
        .xgmii_tx_ready (xgmii_tx_ready),
        .xgmii_rx_clk   (rx_clk),
        .xgmii_rx_rst_n (rx_rst_n),
        .xgmii_rxd      (xgmii_rxd),
        .xgmii_rxc      (xgmii_rxc),
        .xgmii_rx_valid (xgmii_rx_valid),
        .pcs_block_lock (block_lock),
        .pcs_hi_ber     (hi_ber)
    );

    wire mac_good_pulse, mac_bad_pulse;
    axis_test_chk64 u_mchk (
        .clk           (clk_app),
        .rst_n         (app_rst_n),
        .clear         (a_clr[2]),
        .s_axis_tdata  (mr_tdata),
        .s_axis_tkeep  (mr_tkeep),
        .s_axis_tvalid (mr_tvalid),
        .s_axis_tlast  (mr_tlast),
        .s_axis_tuser  (mr_tuser),
        .good_frames   (mac_good),
        .bad_frames    (mac_bad),
        .tuser_frames  (mac_tuser),
        .seq_gaps      (mac_seq_gaps),
        .good_pulse    (mac_good_pulse),
        .bad_pulse     (mac_bad_pulse)
    );

    // =========================================================================
    // Seen-good / seen-bad indications for the LEDs and the status word
    // =========================================================================
    reg bad_seen;
    always @(posedge rx_clk or negedge rx_rst_n)
        if (!rx_rst_n)       bad_seen <= 1'b0;
        else if (s_clr[2])   bad_seen <= 1'b0;
        else if (bad_pulse)  bad_seen <= 1'b1;
    reg mac_bad_seen;
    always @(posedge clk_app or negedge app_rst_n)
        if (!app_rst_n)         mac_bad_seen <= 1'b0;
        else if (a_clr[2])      mac_bad_seen <= 1'b0;
        else if (mac_bad_pulse) mac_bad_seen <= 1'b1;

    reg [23:0] good_led;
    always @(posedge rx_clk or negedge rx_rst_n)
        if (!rx_rst_n)              good_led <= 24'd0;
        else if (good_pulse)        good_led <= 24'hFFFFFF;
        else if (good_led != 0)     good_led <= good_led - 24'd1;
    reg [23:0] mac_good_led;
    always @(posedge clk_app or negedge app_rst_n)
        if (!app_rst_n)             mac_good_led <= 24'd0;
        else if (mac_good_pulse)    mac_good_led <= 24'hFFFFFF;
        else if (mac_good_led != 0) mac_good_led <= mac_good_led - 24'd1;

    // the mode bit picks the checker (static setting)
    assign sel_bad_seen = ctl_mac_mode ? mac_bad_seen : bad_seen;
    assign sel_good_led = ctl_mac_mode ? (mac_good_led != 24'd0)
                                       : (good_led != 24'd0);

endmodule
