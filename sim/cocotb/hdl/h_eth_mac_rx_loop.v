// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// h_eth_mac_rx_loop.v - cocotb harness: eth_mac_tx feeding eth_mac_rx
//
// The DUT pair of tb_eth_mac_rx_mcast.v, tb_eth_mac_rx_backpressure.v,
// tb_eth_mac_rx_byte0.v and tb_eth_mac_sys_jumbo.v. Those benches loop the TX
// GMII outputs back into the RX GMII inputs through a negedge register
// (lb_*); the test drives that register from Python, so here gmii_tx* are
// outputs and lb_* are inputs. The RX configuration inputs that the benches
// tie to different constants are ports; the test drives them.
// Port names follow the benches' net names. Same entity in
// h_eth_mac_rx_loop.vhd.
// =============================================================================

module h_eth_mac_rx_loop #(
    parameter TX_MAX_FRAME         = 9018,
    parameter MCAST_HASH_FILTER    = 0,
    parameter AXIS_FIFO_ADDR_WIDTH = 11
)(
    input  wire        clk,
    input  wire        rst_n,

    // TX AXI4-Stream input
    input  wire [7:0]  tx_tdata,
    input  wire        tx_tvalid,
    output wire        tx_tready,
    input  wire        tx_tlast,

    // TX GMII output (to the test's loopback register)
    output wire [7:0]  gmii_txd,
    output wire        gmii_tx_en,
    output wire        gmii_tx_er,

    // RX GMII input (the loopback register's outputs)
    input  wire [7:0]  lb_rxd,
    input  wire        lb_rx_dv,
    input  wire        lb_rx_er,

    // RX configuration
    input  wire [47:0] our_mac,
    input  wire        promisc,
    input  wire        passthrough,
    input  wire        jumbo_en,
    input  wire        rx_csum_en,
    input  wire [63:0] mcast_hash_table,

    // RX AXI4-Stream output
    output wire [7:0]  rx_tdata,
    output wire        rx_tvalid,
    input  wire        rx_tready,
    output wire        rx_tlast,
    output wire        rx_terror,
    output wire        rx_tsof,

    // RX stat pulses
    output wire        stat_done,
    output wire [13:0] stat_len,
    output wire        stat_err_fcs,
    output wire        stat_err_align,
    output wire        stat_err_overflow,
    output wire        stat_err_oversize,
    output wire        stat_err_csum,
    output wire        stat_is_bcast,
    output wire        stat_is_mcast,
    output wire        stat_drop
);

    eth_mac_tx #(.MAX_FRAME(TX_MAX_FRAME)) u_tx (
        .clk           (clk),
        .rst_n         (rst_n),
        .tx_start_ok   (1'b1),
        .gmii_txd      (gmii_txd),
        .gmii_tx_en    (gmii_tx_en),
        .gmii_tx_er    (gmii_tx_er),
        .s_axis_tdata  (tx_tdata),
        .s_axis_tvalid (tx_tvalid),
        .s_axis_tready (tx_tready),
        .s_axis_tkeep  (1'b1),
        .s_axis_tlast  (tx_tlast),
        .tx_active     (),
        .dbg_state     (),
        .dbg_stall_cnt ()
    );

    eth_mac_rx #(
        .MCAST_HASH_FILTER    (MCAST_HASH_FILTER),
        .AXIS_FIFO_ADDR_WIDTH (AXIS_FIFO_ADDR_WIDTH)
    ) u_rx (
        .clk               (clk),
        .rst_n             (rst_n),
        .gmii_rxd          (lb_rxd),
        .gmii_rx_dv        (lb_rx_dv),
        .gmii_rx_er        (lb_rx_er),
        .our_mac           (our_mac),
        .promisc           (promisc),
        .passthrough       (passthrough),
        .jumbo_en          (jumbo_en),
        .rx_csum_en        (rx_csum_en),
        .mcast_hash_table  (mcast_hash_table),
        .m_axis_tdata      (rx_tdata),
        .m_axis_tvalid     (rx_tvalid),
        .m_axis_tready     (rx_tready),
        .m_axis_tlast      (rx_tlast),
        .m_axis_terror     (rx_terror),
        .m_axis_tsof       (rx_tsof),
        .stat_done         (stat_done),
        .stat_len          (stat_len),
        .stat_err_fcs      (stat_err_fcs),
        .stat_err_align    (stat_err_align),
        .stat_err_overflow (stat_err_overflow),
        .stat_err_oversize (stat_err_oversize),
        .stat_err_csum     (stat_err_csum),
        .stat_is_bcast     (stat_is_bcast),
        .stat_is_mcast     (stat_is_mcast),
        .stat_drop         (stat_drop)
    );

endmodule
