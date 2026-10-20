// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// h_eth_mac_rx_jumbo_gate.v - cocotb harness for tb_eth_mac_rx_jumbo_gate.v
//
// One eth_mac_tx and two eth_mac_rx wired as in the bench: u_rx with the
// default limits, u_rx2 with MAX_FRAME_JUMBO = 1518, both fed by the same
// loopback register (lb_*), which the test drives from Python on the falling
// edge; gmii_tx* are outputs for that. RX tie-offs are the bench's constants.
// Port names follow the bench's net names. Same entity in
// h_eth_mac_rx_jumbo_gate.vhd.
// AXIS_FIFO_ADDR_WIDTH is passed to both RXs (bench: the default, 11); it is
// a parameter only so the equivalence proof can shrink the FIFO.
// =============================================================================

module h_eth_mac_rx_jumbo_gate #(
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

    // RX GMII input (the loopback register's outputs), shared by both RXs
    input  wire [7:0]  lb_rxd,
    input  wire        lb_rx_dv,
    input  wire        lb_rx_er,

    input  wire        jumbo_en,

    // u_rx (MAX_FRAME_JUMBO = 9018)
    output wire [7:0]  rx_tdata,
    output wire        rx_tvalid,
    output wire        rx_tlast,
    output wire        rx_terror,
    output wire        rx_tsof,
    output wire        stat_done1,
    output wire        stat_ovs1,

    // u_rx2 (MAX_FRAME_JUMBO = 1518)
    output wire        rx2_tvalid,
    output wire        rx2_tlast,
    output wire        rx2_terror,
    output wire        stat_done2,
    output wire        stat_ovs2
);

    eth_mac_tx u_tx (
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

    eth_mac_rx #(.AXIS_FIFO_ADDR_WIDTH(AXIS_FIFO_ADDR_WIDTH)) u_rx (
        .clk               (clk),
        .rst_n             (rst_n),
        .gmii_rxd          (lb_rxd),
        .gmii_rx_dv        (lb_rx_dv),
        .gmii_rx_er        (lb_rx_er),
        .our_mac           (48'hFF_FF_FF_FF_FF_FF),
        .promisc           (1'b0),
        .passthrough       (1'b0),
        .jumbo_en          (jumbo_en),
        .rx_csum_en        (1'b0),
        .mcast_hash_table  (64'd0),
        .m_axis_tdata      (rx_tdata),
        .m_axis_tvalid     (rx_tvalid),
        .m_axis_tready     (1'b1),
        .m_axis_tlast      (rx_tlast),
        .m_axis_terror     (rx_terror),
        .m_axis_tsof       (rx_tsof),
        .stat_done         (stat_done1),
        .stat_len          (),
        .stat_err_fcs      (),
        .stat_err_align    (),
        .stat_err_overflow (),
        .stat_err_oversize (stat_ovs1),
        .stat_err_csum     (),
        .stat_is_bcast     (),
        .stat_is_mcast     (),
        .stat_drop         ()
    );

    eth_mac_rx #(
        .AXIS_FIFO_ADDR_WIDTH (AXIS_FIFO_ADDR_WIDTH),
        .MAX_FRAME_JUMBO      (1518)
    ) u_rx2 (
        .clk               (clk),
        .rst_n             (rst_n),
        .gmii_rxd          (lb_rxd),
        .gmii_rx_dv        (lb_rx_dv),
        .gmii_rx_er        (lb_rx_er),
        .our_mac           (48'hFF_FF_FF_FF_FF_FF),
        .promisc           (1'b0),
        .passthrough       (1'b0),
        .jumbo_en          (jumbo_en),
        .rx_csum_en        (1'b0),
        .mcast_hash_table  (64'd0),
        .m_axis_tdata      (),
        .m_axis_tvalid     (rx2_tvalid),
        .m_axis_tready     (1'b1),
        .m_axis_tlast      (rx2_tlast),
        .m_axis_terror     (rx2_terror),
        .m_axis_tsof       (),
        .stat_done         (stat_done2),
        .stat_len          (),
        .stat_err_fcs      (),
        .stat_err_align    (),
        .stat_err_overflow (),
        .stat_err_oversize (stat_ovs2),
        .stat_err_csum     (),
        .stat_is_bcast     (),
        .stat_is_mcast     (),
        .stat_drop         ()
    );

endmodule
