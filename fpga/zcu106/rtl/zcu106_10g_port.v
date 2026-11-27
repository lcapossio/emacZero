// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// zcu106_10g_port.v - one SFP port of zcu106_10g_top: a GTHE4 channel on the
// shared QPLL0, its user clock buffers and reset sequencer, and the PCS and
// test paths (zcu106_10g_lane.v). Builds this port's 640-bit block of the
// EIO input; ctrl is this port's 128 bits of the EIO output (both maps in
// zcu106_10g_top.v).
//
// Each port runs its own gt10g_reset. Only port 0's drives QPLL0RESET (the
// top leaves the other's unconnected); every port waits for QPLL0 lock and
// starts again if it is lost, so a full reset of port 0 resets both.
// Verilog 2001
// =============================================================================

module zcu106_10g_port #(
    parameter [7:0] PORT = 8'd0
) (
    input  wire         clk_50,            // free-running DRP / reset clock
    input  wire         rst_50,            // synchronous to clk_50
    input  wire         clk_app,
    input  wire         app_rst_n,
    input  wire [127:0] ctrl,              // TCK domain
    input  wire         fm_tog,            // frequency meter window (clk_50)
    input  wire [23:0]  fm_ref,

    input  wire         qpll0clk,
    input  wire         qpll0refclk,
    input  wire         qpll0lock,
    input  wire         qpll0refclklost,
    output wire         qpll0reset,

    input  wire         gthrxp,
    input  wire         gthrxn,
    output wire         gthtxp,
    output wire         gthtxn,

    output wire [639:0] probe,
    output wire         tx_done,
    output wire         rx_done,
    output wire         block_lock,
    output wire         hi_ber,
    output wire         sel_bad_seen,
    output wire         sel_good_led,
    output wire         laser_off
);

    wire [2:0] ctl_loopback   = ctrl[2:0];
    wire       ctl_txpol      = ctrl[3];
    wire       ctl_rxpol      = ctrl[4];
    wire       ctl_lpm        = ctrl[5];
    wire       ctl_tx_restart = ctrl[6];
    wire       ctl_rx_restart = ctrl[7];
    wire       ctl_gt_reset   = ctrl[11];
    wire       ctl_tx_inhibit = ctrl[123];
    wire [4:0] ctl_txdiff     = ctrl[36:32];
    wire [4:0] ctl_txpost     = ctrl[44:40];
    wire [4:0] ctl_txpre      = ctrl[52:48];
    assign laser_off = ctrl[12];

    // reset controls from the TCK domain into clk_50
    (* ASYNC_REG = "TRUE" *) reg [1:0] s50_gtr, s50_txr, s50_rxr;
    always @(posedge clk_50) begin
        s50_gtr <= {s50_gtr[0], ctl_gt_reset};
        s50_txr <= {s50_txr[0], ctl_tx_restart};
        s50_rxr <= {s50_rxr[0], ctl_rx_restart};
    end

    // =========================================================================
    // Channel, user clock buffers, reset sequencer
    // =========================================================================
    wire gttxreset, gtrxreset, txprogdivreset, rxprogdivreset;
    wire txuserrdy, rxuserrdy;
    wire gtpowergood, txpmaresetdone, rxpmaresetdone;
    wire txprgdivresetdone, rxprgdivresetdone, txresetdone, rxresetdone;
    wire txoutclk, rxoutclk, rxcdrlock;
    wire [2:0]  rxbufstatus;
    wire [1:0]  txbufstatus;
    wire [63:0] gt_txdata, gt_rxdata;
    wire txusrclk, txusrclk2, rxusrclk, rxusrclk2;

    // TX/RX polarity and loopback come from the TCK domain; they are static
    // settings (RX is reset after a loopback change), applied through two
    // flops in the GT user clock domains.
    (* ASYNC_REG = "TRUE" *) reg [1:0] s_txpol;
    (* ASYNC_REG = "TRUE" *) reg [1:0] s_rxpol;
    always @(posedge txusrclk2) s_txpol <= {s_txpol[0], ctl_txpol};
    (* ASYNC_REG = "TRUE" *) reg [1:0] s_txinh;
    always @(posedge txusrclk2) s_txinh <= {s_txinh[0], ctl_tx_inhibit};
    always @(posedge rxusrclk2) s_rxpol <= {s_rxpol[0], ctl_rxpol};

    gthe4_channel_10g u_channel (
        .drpclk            (clk_50),
        .qpll0clk          (qpll0clk),
        .qpll0refclk       (qpll0refclk),
        .gthrxp            (gthrxp),
        .gthrxn            (gthrxn),
        .gthtxp            (gthtxp),
        .gthtxn            (gthtxn),
        .gttxreset         (gttxreset),
        .gtrxreset         (gtrxreset),
        .txprogdivreset    (txprogdivreset),
        .rxprogdivreset    (rxprogdivreset),
        .txuserrdy         (txuserrdy),
        .rxuserrdy         (rxuserrdy),
        .gtpowergood       (gtpowergood),
        .txpmaresetdone    (txpmaresetdone),
        .rxpmaresetdone    (rxpmaresetdone),
        .txprgdivresetdone (txprgdivresetdone),
        .rxprgdivresetdone (rxprgdivresetdone),
        .txresetdone       (txresetdone),
        .rxresetdone       (rxresetdone),
        .txoutclk          (txoutclk),
        .rxoutclk          (rxoutclk),
        .txusrclk          (txusrclk),
        .txusrclk2         (txusrclk2),
        .rxusrclk          (rxusrclk),
        .rxusrclk2         (rxusrclk2),
        .txdata            (gt_txdata),
        .rxdata            (gt_rxdata),
        .loopback          (ctl_loopback),
        .txpolarity        (s_txpol[1]),
        .txinhibit         (s_txinh[1]),
        .rxpolarity        (s_rxpol[1]),
        .rxlpmen           (ctl_lpm),
        .txdiffctrl        (ctl_txdiff ^ 5'h18),   // EIO 0 = reference swing
        .txpostcursor      (ctl_txpost),
        .txprecursor       (ctl_txpre),
        .rxcdrlock         (rxcdrlock),
        .rxbufstatus       (rxbufstatus),
        .txbufstatus       (txbufstatus)
    );

    // User clock buffers: held in reset until the PMA reset is done, as the
    // Wizard's user clock helper does. TXUSRCLK = TXOUTCLK, TXUSRCLK2 = /2.
    wire tx_uclk_rst = !txpmaresetdone;
    wire rx_uclk_rst = !rxpmaresetdone;

    BUFG_GT u_txusrclk (
        .I (txoutclk), .CE (1'b1), .CEMASK (1'b0), .CLR (tx_uclk_rst),
        .CLRMASK (1'b0), .DIV (3'd0), .O (txusrclk)
    );
    BUFG_GT u_txusrclk2 (
        .I (txoutclk), .CE (1'b1), .CEMASK (1'b0), .CLR (tx_uclk_rst),
        .CLRMASK (1'b0), .DIV (3'd1), .O (txusrclk2)
    );
    BUFG_GT u_rxusrclk (
        .I (rxoutclk), .CE (1'b1), .CEMASK (1'b0), .CLR (rx_uclk_rst),
        .CLRMASK (1'b0), .DIV (3'd0), .O (rxusrclk)
    );
    BUFG_GT u_rxusrclk2 (
        .I (rxoutclk), .CE (1'b1), .CEMASK (1'b0), .CLR (rx_uclk_rst),
        .CLRMASK (1'b0), .DIV (3'd1), .O (rxusrclk2)
    );

    // "user clock active": two txusrclk2 / rxusrclk2 edges after the buffer
    // reset releases
    (* ASYNC_REG = "TRUE" *) reg [1:0] tx_act, rx_act;
    always @(posedge txusrclk2 or posedge tx_uclk_rst)
        if (tx_uclk_rst) tx_act <= 2'b00; else tx_act <= {tx_act[0], 1'b1};
    always @(posedge rxusrclk2 or posedge rx_uclk_rst)
        if (rx_uclk_rst) rx_act <= 2'b00; else rx_act <= {rx_act[0], 1'b1};

    gt10g_reset u_reset (
        .clk               (clk_50),
        .rst               (rst_50 || s50_gtr[1]),
        .tx_restart        (s50_txr[1]),
        .rx_restart        (s50_rxr[1]),
        .gtpowergood       (gtpowergood),
        .qpll0lock         (qpll0lock),
        .tx_usrclk_active  (tx_act[1]),
        .rx_usrclk_active  (rx_act[1]),
        .txresetdone       (txresetdone),
        .rxresetdone       (rxresetdone),
        .qpll0reset        (qpll0reset),
        .gttxreset         (gttxreset),
        .gtrxreset         (gtrxreset),
        .txprogdivreset    (txprogdivreset),
        .rxprogdivreset    (rxprogdivreset),
        .txuserrdy         (txuserrdy),
        .rxuserrdy         (rxuserrdy),
        .tx_done           (tx_done),
        .rx_done           (rx_done)
    );

    // Domain resets: async assert, release synchronized to the user clock
    (* ASYNC_REG = "TRUE" *) reg [2:0] tx_rst_sync, rx_rst_sync;
    always @(posedge txusrclk2 or negedge tx_done)
        if (!tx_done) tx_rst_sync <= 3'b000; else tx_rst_sync <= {tx_rst_sync[1:0], 1'b1};
    always @(posedge rxusrclk2 or negedge rx_done)
        if (!rx_done) rx_rst_sync <= 3'b000; else rx_rst_sync <= {rx_rst_sync[1:0], 1'b1};
    wire tx_rst_n = tx_rst_sync[2];
    wire rx_rst_n = rx_rst_sync[2];

    // =========================================================================
    // PCS and test paths
    // =========================================================================
    wire [15:0] ber_cnt;
    wire [31:0] lock_losses, gen_frames, good_frames, bad_frames, seq_gaps;
    wire [31:0] bad_words, lf_words, mac_gen_frames, mac_good, mac_bad;
    wire [31:0] mac_tuser, mac_seq_gaps, csr_rdata;
    wire        csr_ack;

    zcu106_10g_lane u_lane (
        .tx_clk         (txusrclk2),
        .tx_rst_n       (tx_rst_n),
        .rx_clk         (rxusrclk2),
        .rx_rst_n       (rx_rst_n),
        .clk_app        (clk_app),
        .app_rst_n      (app_rst_n),
        .ctrl           (ctrl),
        .gt_txdata      (gt_txdata),
        .gt_rxdata      (gt_rxdata),
        .block_lock     (block_lock),
        .hi_ber         (hi_ber),
        .ber_cnt        (ber_cnt),
        .lock_losses    (lock_losses),
        .gen_frames     (gen_frames),
        .good_frames    (good_frames),
        .bad_frames     (bad_frames),
        .seq_gaps       (seq_gaps),
        .bad_words      (bad_words),
        .lf_words       (lf_words),
        .mac_gen_frames (mac_gen_frames),
        .mac_good       (mac_good),
        .mac_bad        (mac_bad),
        .mac_tuser      (mac_tuser),
        .mac_seq_gaps   (mac_seq_gaps),
        .csr_ack        (csr_ack),
        .csr_rdata      (csr_rdata),
        .sel_bad_seen   (sel_bad_seen),
        .sel_good_led   (sel_good_led)
    );

    // =========================================================================
    // Frequency meters and this port's EIO input block
    // =========================================================================
    wire [23:0] fm_tx, fm_rx;
    freq_meter_10g u_fm_tx (.clk (txusrclk2), .tog (fm_tog), .meas (fm_tx));
    freq_meter_10g u_fm_rx (.clk (rxusrclk2), .tog (fm_tog), .meas (fm_rx));

    wire mac_mode = ctrl[13];
    wire [31:0] status = {
        8'd0,
        sel_bad_seen, (mac_mode ? mac_good : good_frames) != 32'd0, // [23:22]
        rxcdrlock, hi_ber,                                          // [21:20]
        block_lock, qpll0refclklost, txbufstatus,                   // [19:16]
        1'b0, rxbufstatus, txprgdivresetdone, rxprgdivresetdone,    // [15:10]
        txpmaresetdone, rxpmaresetdone,                             // [9:8]
        txresetdone, rxresetdone, tx_done, rx_done,                 // [7:4]
        rxuserrdy, txuserrdy, gtpowergood, qpll0lock                // [3:0]
    };

    assign probe = {16'h10F0, 8'd4, PORT,                // [639:608] marker, layout, port
                    csr_rdata,                           // [607:576] (clk_app)
                    31'd0, csr_ack,                      // [575:544] (clk_app)
                    mac_seq_gaps,                        // [543:512]
                    mac_tuser,                           // [511:480]
                    mac_bad,                             // [479:448]
                    mac_good,                            // [447:416]
                    mac_gen_frames,                      // [415:384] (clk_app)
                    gen_frames,                          // [383:352] (TX domain)
                    fm_ref, 8'd0,                        // [351:320]
                    fm_rx, 8'd0,                         // [319:288]
                    fm_tx, 8'd0,                         // [287:256]
                    lock_losses,                         // [255:224]
                    16'd0, ber_cnt,                      // [223:192]
                    lf_words,                            // [191:160]
                    bad_words,                           // [159:128]
                    seq_gaps,                            // [127:96]
                    bad_frames,                          // [95:64]
                    good_frames,                         // [63:32]
                    status};                             // [31:0]

endmodule
