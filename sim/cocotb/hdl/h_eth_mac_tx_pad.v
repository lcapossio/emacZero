// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// h_eth_mac_tx_pad.v - cocotb harness: the DUT pair of tb_eth_mac_tx_pad.v
//
// eth_mac_tx (GMII framer) and mii_tx_saf (MII framer) side by side on one
// AXIS source, wired as the bench wires them: sel_gmii picks the framer that
// sees s_tvalid and whose tready comes back as s_tready. Port names follow
// the bench's net names. Parameters pass through (defaults = the RTL
// defaults the bench uses); they exist so the parity proof can run small.
// Same entity in h_eth_mac_tx_pad.vhd.
// =============================================================================

module h_eth_mac_tx_pad #(
    parameter MAC_MAX_FRAME       = 9018,
    parameter SAF_MAX_FRAME       = 1518,
    parameter SAF_FIFO_ADDR_WIDTH = 12
)(
    input  wire       clk,
    input  wire       mclk,
    input  wire       rst_n,

    input  wire [7:0] s_tdata,
    input  wire       s_tvalid,
    input  wire       s_tlast,
    input  wire       sel_gmii,    // 1 = eth_mac_tx, 0 = mii_tx_saf
    output wire       s_tready,

    output wire [7:0] gmii_txd,
    output wire       gmii_tx_en,
    output wire       gmii_tx_er,

    output wire [3:0] mii_txd,
    output wire       mii_tx_en
);

    wire rdy_g, rdy_m;
    assign s_tready = sel_gmii ? rdy_g : rdy_m;

    eth_mac_tx #(.MAX_FRAME(MAC_MAX_FRAME)) u_gmii (
        .clk           (clk),
        .rst_n         (rst_n),
        .tx_start_ok   (1'b1),
        .gmii_txd      (gmii_txd),
        .gmii_tx_en    (gmii_tx_en),
        .gmii_tx_er    (gmii_tx_er),
        .s_axis_tdata  (s_tdata),
        .s_axis_tvalid (s_tvalid && sel_gmii),
        .s_axis_tready (rdy_g),
        .s_axis_tlast  (s_tlast),
        .s_axis_tkeep  (1'b1),
        .tx_active     (),
        .dbg_state     (),
        .dbg_stall_cnt ()
    );

    mii_tx_saf #(
        .MAX_FRAME       (SAF_MAX_FRAME),
        .FIFO_ADDR_WIDTH (SAF_FIFO_ADDR_WIDTH)
    ) u_mii (
        .clk           (clk),
        .rst_n         (rst_n),
        .s_axis_tdata  (s_tdata),
        .s_axis_tvalid (s_tvalid && !sel_gmii),
        .s_axis_tready (rdy_m),
        .s_axis_tlast  (s_tlast),
        .ctl_axis_tdata  (8'd0),
        .ctl_axis_tvalid (1'b0),
        .ctl_axis_tready (),
        .ctl_axis_tlast  (1'b0),
        .tx_start_ok   (1'b1),
        .mii_tx_clk    (mclk),
        .mii_txd       (mii_txd),
        .mii_tx_en     (mii_tx_en),
        .tx_busy       (),
        .tx_fifo_level (),
        .tx_active     (),
        .tx_byte_stb   (),
        .tx_frame_done (),
        .dbg_saf       ()
    );

endmodule
