// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// Test harness: one port of the ZCU106 10G design (zcu106_10g_lane, as on
// the board) in MAC mode, its transceiver replaced by a serial loopback with
// a bit offset: axis_test_gen64 (app_clk) -> eth_mac_sys_10g -> pcs10gbr ->
// loopback -> pcs10gbr -> eth_mac_sys_10g -> axis_test_chk64 (app_clk).
// The named inputs fill in the lane's EIO control word; the CSRs are reached
// through the lane's axil_cmd_master, as the EIO does on the board.
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
    wire [63:0] gt_txdata;
    reg  [63:0] prev;
    always @(posedge clk) prev <= gt_txdata;
    wire [127:0] two = {gt_txdata, prev};
    wire [63:0]  gt_rxdata = two[OFFSET +: 64];

    // EIO control word (bit map in zcu106_10g_top.v), MAC mode on
    wire [127:0] ctrl = {6'd0, csr_write, csr_go, csr_wdata, csr_addr, len,
                         32'd0, ipg, 8'd0, 1'b0, sweep, 1'b1, 2'b00, clear,
                         inj_err, enable, 8'd0};

    zcu106_10g_lane #(.BER_TIMER_CYCLES(BER_TIMER_CYCLES)) u_lane (
        .tx_clk (clk), .tx_rst_n (rst_n), .rx_clk (clk), .rx_rst_n (rst_n),
        .clk_app (app_clk), .app_rst_n (app_rst_n), .ctrl (ctrl),
        .gt_txdata (gt_txdata), .gt_rxdata (gt_rxdata),
        .block_lock (block_lock), .hi_ber (hi_ber), .ber_cnt (),
        .lock_losses (), .gen_frames (), .good_frames (), .bad_frames (),
        .seq_gaps (), .bad_words (), .lf_words (),
        .mac_gen_frames (gen_frames), .mac_good (good_frames),
        .mac_bad (bad_frames), .mac_tuser (tuser_frames),
        .mac_seq_gaps (seq_gaps), .csr_ack (csr_ack), .csr_rdata (csr_rdata),
        .sel_bad_seen (), .sel_good_led ()
    );
endmodule
