// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// h_mii_loopback.v - cocotb harness: eth_mac_tx -> mii_if (MII looped back) ->
// eth_mac_rx
//
// The DUT wiring of sim/tb/tb_mii_loopback.v (bench MII-LOOPBACK): mii_if's
// MII TX pins drive its own MII RX pins (mii_rxd = mii_txd, mii_rx_dv =
// mii_tx_en), RX sampled on a separate, phase-shifted mii_rx_clk that the test
// drives. eth_mac_tx feeds mii_if's GMII TX side with tx_start_ok tied high;
// eth_mac_rx takes mii_if's GMII RX side, our_mac = broadcast, jumbo on.
// The connections and tie-offs are the bench's; port names are the bench's
// net names. The bench also declares a never-driven mac_rx_tuser bus as a
// second (z) driver of mac_rx_error / mac_rx_sof; z resolves to the
// eth_mac_rx output, so it is left out here.
// TX_MAX_FRAME / AXIS_FIFO_ADDR_WIDTH only pass through to eth_mac_tx
// MAX_FRAME / eth_mac_rx AXIS_FIFO_ADDR_WIDTH (the bench uses the defaults)
// so the equivalence proof can shrink them. Same entity in h_mii_loopback.vhd.
// =============================================================================

module h_mii_loopback #(
    parameter TX_MAX_FRAME         = 9018,
    parameter AXIS_FIFO_ADDR_WIDTH = 11
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        mii_tx_clk,
    input  wire        mii_rx_clk,

    // MAC TX AXI4-Stream input
    input  wire [7:0]  tx_data,
    input  wire        tx_valid,
    output wire        tx_ready,
    input  wire        tx_last,

    // MAC RX AXI4-Stream output (m_axis_tready tied high, as in the bench)
    output wire [7:0]  mac_rx_data,
    output wire        mac_rx_valid,
    output wire        mac_rx_last,
    output wire        mac_rx_error,
    output wire        mac_rx_sof,

    // Nets the bench observes
    output wire [7:0]  gmii_txd,
    output wire        gmii_tx_en,
    output wire        gmii_tx_er,
    output wire [7:0]  gmii_rxd,
    output wire        gmii_rx_dv,
    output wire        gmii_rx_er,
    output wire [3:0]  mii_txd,
    output wire        mii_tx_en
);

    // MII loopback wires
    wire [3:0] mii_rxd;
    wire       mii_rx_dv;
    assign mii_rxd   = mii_txd;
    assign mii_rx_dv = mii_tx_en;

    wire tx_fifo_busy;

    mii_if u_mii (
        .clk(clk), .rst_n(rst_n),
        .mii_rxd(mii_rxd), .mii_rx_dv(mii_rx_dv), .mii_rx_er(1'b0),
        .mii_rx_clk(mii_rx_clk), .mii_col(1'b0), .mii_crs(1'b0),
        .mii_txd(mii_txd), .mii_tx_en(mii_tx_en), .mii_tx_clk(mii_tx_clk),
        .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en), .gmii_tx_er(gmii_tx_er),
        .gmii_rxd(gmii_rxd), .gmii_rx_dv(gmii_rx_dv), .gmii_rx_er(gmii_rx_er),
        .mii_tx_clk_out(),
        .tx_busy(tx_fifo_busy),
        .dbg_tx_fifo_empty(), .dbg_rx_prog_empty(),
        .dbg_rx_rd_empty(), .dbg_rx_reading(), .dbg_rx_frames_pending()
    );

    eth_mac_tx #(.MAX_FRAME(TX_MAX_FRAME)) u_mac_tx (
        .clk(clk), .rst_n(rst_n),
        .tx_start_ok(1'b1),
        .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en), .gmii_tx_er(gmii_tx_er),
        .s_axis_tdata(tx_data), .s_axis_tvalid(tx_valid),
        .s_axis_tready(tx_ready), .s_axis_tkeep(1'b1), .s_axis_tlast(tx_last),
        .tx_active()
    );

    eth_mac_rx #(.AXIS_FIFO_ADDR_WIDTH(AXIS_FIFO_ADDR_WIDTH)) u_mac_rx (
        .clk(clk), .rst_n(rst_n),
        .gmii_rxd(gmii_rxd), .gmii_rx_dv(gmii_rx_dv), .gmii_rx_er(gmii_rx_er),
        .our_mac(48'hFF_FF_FF_FF_FF_FF),  // accept broadcast
        .promisc(1'b0),
        .passthrough(1'b0),
        .jumbo_en(1'b1), .rx_csum_en(1'b0),
        .mcast_hash_table(64'd0),
        .m_axis_tdata(mac_rx_data), .m_axis_tvalid(mac_rx_valid),
        .m_axis_tready(1'b1),
        .m_axis_tlast(mac_rx_last), .m_axis_terror(mac_rx_error), .m_axis_tsof(mac_rx_sof),
        .stat_done(), .stat_len(), .stat_err_fcs(), .stat_err_align(),
        .stat_err_overflow(), .stat_err_oversize(), .stat_err_csum(),
        .stat_is_bcast(), .stat_is_mcast(), .stat_drop()
    );

endmodule
