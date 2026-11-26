// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// zcu106_10g_top.v - 10GBASE-R bring-up on SFP cage 0 of the AMD ZCU106
//
//   xgmii_test_gen -> pcs10gbr TX -> GTHE4 (10.3125 Gb/s) -> SFP0
//   SFP0 -> GTHE4 -> pcs10gbr RX -> xgmii_test_chk
//
// No AMD IP: the GTHE4_COMMON / GTHE4_CHANNEL primitives are instantiated
// directly (gthe4_common_10g.v, gthe4_channel_10g.v), reset by gt10g_reset.v,
// with the clean-room PCS from rtl/pcs10gbr*.v.
//
// Clocks:
//   clk_50     300 MHz USER_SI570 / 6, free-running: GT DRP / reset clock
//   refclk     USER_MGT_SI570 156.25 MHz, Quad 226 MGTREFCLK1 -> QPLL0 of
//              Quad 225 over the south reference clock routing
//   txusrclk2  161.13 MHz, BUFG_GT /2 of TXOUTCLK (txusrclk is /1, 322 MHz):
//              PCS TX and the generator
//   rxusrclk2  161.13 MHz from RXOUTCLK (recovered clock): PCS RX, checker
//
// Control and status over an fcapz EIO on USER3 (CHAIN 3); see the EIO block
// for the bit map and scripts/sfp10g_test.py for the host side. Power-up
// state: normal (no loopback) toward the SFP, generator off.
//
// LEDs: 0 QPLL0 lock      1 TX reset done    2 RX reset done
//       3 PCS block lock  4 no high BER      5 good test frame seen
//       6 bad test frame seen (sticky until the counters are cleared)
//       7 txusrclk2 heartbeat
// Verilog 2001
// =============================================================================

module zcu106_10g_top (
    input  wire       USER_SI570_SYSCLK_P,   // 300 MHz
    input  wire       USER_SI570_SYSCLK_N,
    input  wire       CPU_RESET,             // active high

    input  wire       SFP_REFCLK_P,          // 156.25 MHz
    input  wire       SFP_REFCLK_N,
    output wire       SFP0_TX_P,
    output wire       SFP0_TX_N,
    input  wire       SFP0_RX_P,
    input  wire       SFP0_RX_N,
    output wire       SFP0_TX_DISABLE_B,     // high = laser on

    output wire [7:0] LED
);

    // =========================================================================
    // Free-running 50 MHz control clock and reset
    // =========================================================================
    wire clk_300_ibuf, clk_50;

    IBUFDS u_sysclk_ibuf (
        .I  (USER_SI570_SYSCLK_P),
        .IB (USER_SI570_SYSCLK_N),
        .O  (clk_300_ibuf)
    );

    BUFGCE_DIV #(.BUFGCE_DIVIDE(6)) u_clk_50_buf (
        .I   (clk_300_ibuf),
        .CE  (1'b1),
        .CLR (1'b0),
        .O   (clk_50)
    );

    (* ASYNC_REG = "TRUE" *) reg [2:0] rst50_sync;
    always @(posedge clk_50 or posedge CPU_RESET) begin
        if (CPU_RESET) rst50_sync <= 3'b000;
        else           rst50_sync <= {rst50_sync[1:0], 1'b1};
    end

    // EIO controls (defined in the EIO block)
    wire [63:0] ctrl;
    wire [2:0]  ctl_loopback   = ctrl[2:0];
    wire        ctl_txpol      = ctrl[3];
    wire        ctl_rxpol      = ctrl[4];
    wire        ctl_lpm        = ctrl[5];
    wire        ctl_tx_restart = ctrl[6];
    wire        ctl_rx_restart = ctrl[7];
    wire        ctl_gen_en     = ctrl[8];
    wire        ctl_inj        = ctrl[9];
    wire        ctl_clear      = ctrl[10];
    wire        ctl_gt_reset   = ctrl[11];
    wire        ctl_laser_off  = ctrl[12];
    wire [7:0]  ctl_len        = ctrl[23:16];
    wire [7:0]  ctl_ipg        = ctrl[31:24];
    wire [4:0]  ctl_txdiff     = ctrl[36:32];
    wire [4:0]  ctl_txpost     = ctrl[44:40];
    wire [4:0]  ctl_txpre      = ctrl[52:48];

    // EIO outputs come from the TCK domain: synchronize the reset controls
    (* ASYNC_REG = "TRUE" *) reg [5:0] s50_gtr, s50_txr, s50_rxr;
    always @(posedge clk_50) begin
        s50_gtr <= {s50_gtr[4:0], ctl_gt_reset};
        s50_txr <= {s50_txr[4:0], ctl_tx_restart};
        s50_rxr <= {s50_rxr[4:0], ctl_rx_restart};
    end
    wire gt_rst = !rst50_sync[2] || s50_gtr[1];

    // =========================================================================
    // Reference clock
    // =========================================================================
    wire refclk, refclk_div2;

    IBUFDS_GTE4 #(
        .REFCLK_EN_TX_PATH  (1'b0),
        .REFCLK_HROW_CK_SEL (2'b00),     // ODIV2 = O (for the frequency meter)
        .REFCLK_ICNTL_RX    (2'b00)
    ) u_refclk_ibuf (
        .I     (SFP_REFCLK_P),
        .IB    (SFP_REFCLK_N),
        .CEB   (1'b0),
        .O     (refclk),
        .ODIV2 (refclk_div2)
    );

    wire refclk_fab;
    BUFG_GT u_refclk_fab (
        .I (refclk_div2), .CE (1'b1), .CEMASK (1'b0), .CLR (1'b0),
        .CLRMASK (1'b0), .DIV (3'd0), .O (refclk_fab)
    );

    // =========================================================================
    // GT: common (QPLL0), channel, reset sequencer, user clock buffers
    // =========================================================================
    wire qpll0reset, qpll0lock, qpll0refclklost, qpll0outclk, qpll0outrefclk;

    gthe4_common_10g #(.QPLL0_REFCLK_SEL(3'b110)) u_common (
        .refclk          (refclk),
        .drpclk          (clk_50),
        .qpll0reset      (qpll0reset),
        .qpll0lock       (qpll0lock),
        .qpll0refclklost (qpll0refclklost),
        .qpll0outclk     (qpll0outclk),
        .qpll0outrefclk  (qpll0outrefclk)
    );

    wire gttxreset, gtrxreset, txprogdivreset, rxprogdivreset;
    wire txuserrdy, rxuserrdy, tx_done, rx_done;
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
    always @(posedge rxusrclk2) s_rxpol <= {s_rxpol[0], ctl_rxpol};

    gthe4_channel_10g u_channel (
        .drpclk            (clk_50),
        .qpll0clk          (qpll0outclk),
        .qpll0refclk       (qpll0outrefclk),
        .gthrxp            (SFP0_RX_P),
        .gthrxn            (SFP0_RX_N),
        .gthtxp            (SFP0_TX_P),
        .gthtxn            (SFP0_TX_N),
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
        .rst               (gt_rst),
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

    // =========================================================================
    // PCS and test traffic
    // =========================================================================
    // Domain resets: async assert, release synchronized to the user clock
    (* ASYNC_REG = "TRUE" *) reg [2:0] tx_rst_sync, rx_rst_sync;
    always @(posedge txusrclk2 or negedge tx_done)
        if (!tx_done) tx_rst_sync <= 3'b000; else tx_rst_sync <= {tx_rst_sync[1:0], 1'b1};
    always @(posedge rxusrclk2 or negedge rx_done)
        if (!rx_done) rx_rst_sync <= 3'b000; else rx_rst_sync <= {rx_rst_sync[1:0], 1'b1};
    wire tx_rst_n = tx_rst_sync[2];
    wire rx_rst_n = rx_rst_sync[2];

    wire [63:0] xgmii_txd, xgmii_rxd;
    wire [7:0]  xgmii_txc, xgmii_rxc;
    wire        xgmii_tx_ready, xgmii_rx_valid;
    wire        block_lock, hi_ber;
    wire [15:0] ber_cnt;

    pcs10gbr u_pcs (
        .tx_clk         (txusrclk2),
        .tx_rst_n       (tx_rst_n),
        .xgmii_txd      (xgmii_txd),
        .xgmii_txc      (xgmii_txc),
        .xgmii_tx_ready (xgmii_tx_ready),
        .gt_txdata      (gt_txdata),
        .rx_clk         (rxusrclk2),
        .rx_rst_n       (rx_rst_n),
        .gt_rxdata      (gt_rxdata),
        .xgmii_rxd      (xgmii_rxd),
        .xgmii_rxc      (xgmii_rxc),
        .xgmii_rx_valid (xgmii_rx_valid),
        .rx_block_lock  (block_lock),
        .rx_hi_ber      (hi_ber),
        .rx_ber_cnt     (ber_cnt)
    );

    // Generator controls into txusrclk2 (static except the inject pulse)
    (* ASYNC_REG = "TRUE" *) reg [2:0] s_gen_en, s_inj;
    always @(posedge txusrclk2) begin
        s_gen_en <= {s_gen_en[1:0], ctl_gen_en};
        s_inj    <= {s_inj[1:0], ctl_inj};
    end
    wire [7:0] len_words = ctl_len + 8'd8;   // EIO 0 -> 8 words (64 bytes)

    wire [31:0] gen_frames;
    xgmii_test_gen u_gen (
        .clk            (txusrclk2),
        .rst_n          (tx_rst_n),
        .enable         (s_gen_en[2]),
        .len_words      (len_words),
        .ipg_words      (ctl_ipg),
        .inj_err        (s_inj[1] && !s_inj[2]),
        .xgmii_tx_ready (xgmii_tx_ready),
        .xgmii_txd      (xgmii_txd),
        .xgmii_txc      (xgmii_txc),
        .frames         (gen_frames)
    );

    (* ASYNC_REG = "TRUE" *) reg [2:0] s_clr;
    always @(posedge rxusrclk2) s_clr <= {s_clr[1:0], ctl_clear};

    wire [31:0] good_frames, bad_frames, seq_gaps, bad_words, lf_words;
    wire        good_pulse, bad_pulse;
    xgmii_test_chk u_chk (
        .clk            (rxusrclk2),
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

    // Block lock losses (rxusrclk2)
    reg        lock_d;
    reg [31:0] lock_losses;
    always @(posedge rxusrclk2 or negedge rx_rst_n) begin
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
    // Frequency meters: cycles per 2^22 clk_50 cycles (83.9 ms window).
    // 161.13 MHz reads about 13,516,800; 156.25 MHz about 13,107,200.
    // =========================================================================
    reg [21:0] fm_div = 22'd0;
    reg        fm_tog = 1'b0;
    always @(posedge clk_50) begin
        fm_div <= fm_div + 22'd1;
        if (fm_div == 22'h3FFFFF) fm_tog <= ~fm_tog;
    end

    wire [23:0] fm_tx, fm_rx, fm_ref;
    freq_meter_10g u_fm_tx  (.clk (txusrclk2),  .tog (fm_tog), .meas (fm_tx));
    freq_meter_10g u_fm_rx  (.clk (rxusrclk2),  .tog (fm_tog), .meas (fm_rx));
    freq_meter_10g u_fm_ref (.clk (refclk_fab), .tog (fm_tog), .meas (fm_ref));

    // =========================================================================
    // fcapz EIO (USER3)
    // eio-write [63:0]:
    //   [2:0] LOOPBACK (0 normal, 2 near-end PMA)   [3] TX polarity
    //   [4] RX polarity    [5] RX LPM (0 = DFE)      [6] TX path restart
    //   [7] RX path restart (do it after a LOOPBACK change)
    //   [8] generator on   [9] inject one payload bit error (rising edge)
    //   [10] clear checker counters   [11] full GT reset   [12] laser off
    //   [23:16] frame words - 8   [31:24] idle words between frames
    //   [36:32] TXDIFFCTRL ^ 0x18   [44:40] TXPOSTCURSOR   [52:48] TXPRECURSOR
    // eio-read [415:0]: see the probe_in concatenation; the low 32 bits are
    //   the status bits, the top 16 bits a layout marker (0x10F0). Counters
    //   cross from the GT clock domains unsynchronized: read twice if a value
    //   must be exact.
    // =========================================================================
    reg [3:0] bad_seen;
    always @(posedge rxusrclk2 or negedge rx_rst_n)
        if (!rx_rst_n)       bad_seen <= 4'd0;
        else if (s_clr[2])   bad_seen <= 4'd0;
        else if (bad_pulse)  bad_seen <= 4'hF;

    wire [31:0] status = {
        8'd0,
        bad_seen[0], good_frames != 32'd0, rxcdrlock, hi_ber,      // [23:20]
        block_lock, qpll0refclklost, txbufstatus,                   // [19:16]
        1'b0, rxbufstatus, txprgdivresetdone, rxprgdivresetdone,    // [15:10]
        txpmaresetdone, rxpmaresetdone,                             // [9:8]
        txresetdone, rxresetdone, tx_done, rx_done,                 // [7:4]
        rxuserrdy, txuserrdy, gtpowergood, qpll0lock                // [3:0]
    };

    fcapz_eio_xilinxus #(
        .IN_W  (416),
        .OUT_W (64),
        .CHAIN (3)
    ) u_eio (
        .probe_in  ({16'h10F0, 8'd1, 8'd0,                // [415:384] marker, layout
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
                     status}),                            // [31:0]
        .probe_out (ctrl)
    );

    // =========================================================================
    // LEDs and laser
    // =========================================================================
    reg [27:0] hb = 28'd0;
    always @(posedge txusrclk2) hb <= hb + 28'd1;

    reg [23:0] good_led = 24'd0;
    always @(posedge rxusrclk2)
        if (good_pulse)            good_led <= 24'hFFFFFF;
        else if (good_led != 0)    good_led <= good_led - 24'd1;

    assign LED = {hb[27], bad_seen[0], good_led != 24'd0, !hi_ber,
                  block_lock, rx_done, tx_done, qpll0lock};

    assign SFP0_TX_DISABLE_B = !ctl_laser_off;

endmodule

// Cycles of clk per window; the window is a toggle from another clock
// domain, synchronized here. Holds the last count for a whole window.
module freq_meter_10g (
    input  wire        clk,
    input  wire        tog,
    output reg  [23:0] meas
);
    (* ASYNC_REG = "TRUE" *) reg [2:0] s = 3'd0;
    reg [23:0] cnt = 24'd0;
    initial meas = 24'd0;
    always @(posedge clk) begin
        s <= {s[1:0], tog};
        if (s[2] != s[1]) begin
            meas <= cnt;
            cnt  <= 24'd1;
        end else if (cnt != 24'hFFFFFF) begin
            cnt  <= cnt + 24'd1;
        end
    end
endmodule
