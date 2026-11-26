// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// zcu106_10g_top.v - 10GBASE-R on SFP cages 0 and 1 of the AMD ZCU106
//
// Two identical ports (zcu106_10g_port.v), each a GTHE4 channel with the PCS
// and two test paths (zcu106_10g_lane.v):
//   xgmii_test_gen -> pcs10gbr TX -> GTHE4 (10.3125 Gb/s) -> SFPn
//   SFPn -> GTHE4 -> pcs10gbr RX -> xgmii_test_chk
// or, in MAC mode, Ethernet frames through the 10G MAC system:
//   axis_test_gen64 (clk_app) -> eth_mac_sys_10g -> pcs10gbr TX -> ...
//   ... -> pcs10gbr RX -> eth_mac_sys_10g -> axis_test_chk64 (clk_app)
// Each port's checkers check whatever its receiver gets: its own frames in a
// near-end loopback, the other port's over a fibre from SFP0 to SFP1.
//
// No AMD IP: the GTHE4_COMMON / GTHE4_CHANNEL primitives are instantiated
// directly (gthe4_common_10g.v, gthe4_channel_10g.v), reset by gt10g_reset.v,
// with the clean-room PCS from rtl/pcs10gbr*.v.
//
// Clocks:
//   clk_50     300 MHz USER_SI570 / 6, free-running: GT DRP / reset clock
//   clk_app    200 MHz, MMCM from the same 300 MHz: eth_mac_sys_10g's
//              application side, MAC mode generators and checkers
//   refclk     USER_MGT_SI570 156.25 MHz, Quad 226 MGTREFCLK1 -> QPLL0 of
//              Quad 225 (GTREFCLK00; Vivado routes it over the south
//              reference clock lines), shared by both channels
//   per port:  txusrclk2 161.13 MHz, BUFG_GT /2 of TXOUTCLK (txusrclk is /1,
//              322 MHz): PCS TX, TX MAC, raw XGMII generator
//              rxusrclk2 161.13 MHz from RXOUTCLK (recovered clock): PCS RX,
//              RX MAC, raw XGMII checker
//
// Control and status over an fcapz EIO on USER3 (CHAIN 3); bit maps below
// and scripts/sfp10g_test.py for the host side. Power-up state: normal (no
// loopback), generators off.
//
// LEDs: 0 QPLL0 lock         1 port 0 TX and RX reset done
//       2 port 1 TX and RX reset done
//       3 port 0 block lock  4 port 1 block lock (each blinks with a high
//         BER)
//       5 good test frame seen (either port)
//       6 bad test frame seen (either port; sticky until cleared; LEDs 5
//         and 6 follow the checkers of each port's selected mode)
//       7 heartbeat (clk_50)
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
    output wire       SFP1_TX_P,
    output wire       SFP1_TX_N,
    input  wire       SFP1_RX_P,
    input  wire       SFP1_RX_N,
    output wire       SFP1_TX_DISABLE_B,

    output wire [7:0] LED
);

    // =========================================================================
    // Free-running 50 MHz control clock, application clock, resets
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

    // 200 MHz application clock: VCO 1200 MHz = 300 * 4, / 6
    wire clk_app_mmcm, app_fb, app_locked, clk_app;
    MMCME4_BASE #(
        .CLKIN1_PERIOD    (3.333),
        .CLKFBOUT_MULT_F  (4.0),
        .DIVCLK_DIVIDE    (1),
        .CLKOUT0_DIVIDE_F (6.0)
    ) u_app_mmcm (
        .CLKIN1    (clk_300_ibuf),
        .CLKFBIN   (app_fb),
        .CLKFBOUT  (app_fb),
        .CLKFBOUTB (),
        .CLKOUT0   (clk_app_mmcm),
        .CLKOUT0B  (), .CLKOUT1 (), .CLKOUT1B (), .CLKOUT2 (), .CLKOUT2B (),
        .CLKOUT3   (), .CLKOUT3B (), .CLKOUT4 (), .CLKOUT5 (), .CLKOUT6 (),
        .LOCKED    (app_locked),
        .PWRDWN    (1'b0),
        .RST       (CPU_RESET)
    );
    BUFG u_clk_app_buf (.I (clk_app_mmcm), .O (clk_app));

    (* ASYNC_REG = "TRUE" *) reg [2:0] app_rst_sync;
    always @(posedge clk_app or negedge app_locked) begin
        if (!app_locked) app_rst_sync <= 3'b000;
        else             app_rst_sync <= {app_rst_sync[1:0], 1'b1};
    end
    wire app_rst_n = app_rst_sync[2];

    (* ASYNC_REG = "TRUE" *) reg [2:0] rst50_sync;
    always @(posedge clk_50 or posedge CPU_RESET) begin
        if (CPU_RESET) rst50_sync <= 3'b000;
        else           rst50_sync <= {rst50_sync[1:0], 1'b1};
    end
    wire rst_50 = !rst50_sync[2];

    // =========================================================================
    // Reference clock and QPLL0
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

    wire qpll0reset, qpll0lock, qpll0refclklost, qpll0outclk, qpll0outrefclk;

    gthe4_common_10g #(.QPLL0_REFCLK_SEL(3'b001)) u_common (
        .refclk          (refclk),
        .drpclk          (clk_50),
        .qpll0reset      (qpll0reset),
        .qpll0lock       (qpll0lock),
        .qpll0refclklost (qpll0refclklost),
        .qpll0outclk     (qpll0outclk),
        .qpll0outrefclk  (qpll0outrefclk)
    );

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

    wire [23:0] fm_ref;
    freq_meter_10g u_fm_ref (.clk (refclk_fab), .tog (fm_tog), .meas (fm_ref));

    // =========================================================================
    // fcapz EIO (USER3)
    // eio-write [255:0]: port p's controls are [128p+127:128p], each:
    //   [2:0] LOOPBACK (0 normal, 2 near-end PMA)   [3] TX polarity
    //   [4] RX polarity    [5] RX LPM (0 = DFE)      [6] TX path restart
    //   [7] RX path restart (do it after a LOOPBACK change)
    //   [8] generator on   [9] inject one payload bit error (rising edge)
    //   [10] clear checker counters
    //   [11] full GT reset (port 0: QPLL0 too, so both ports)   [12] laser off
    //   [13] MAC mode (frames through the 10G MAC)   [14] MAC length sweep
    //   [15] MAC mode frames are IPv4 / UDP datagrams (set it before [8])
    //   [23:16] frame words - 8   [31:24] idle words between frames
    //   [36:32] TXDIFFCTRL ^ 0x18   [44:40] TXPOSTCURSOR   [52:48] TXPRECURSOR
    //   [79:64] MAC mode frame length in bytes, no FCS (60..16000; with the
    //   sweep, the top of the 60..len sweep). [31:24] is also the MAC mode
    //   gap, in clk_app cycles.
    //   [87:80] CSR address  [119:88] CSR write data  [120] CSR go (toggle:
    //   set the other fields first)  [121] CSR write (0 = read)
    // eio-read [1279:0]: port p's status is [640p+639:640p], laid out in
    //   zcu106_10g_port.v: the low 32 bits are the status bits, the top 32
    //   bits {marker 0x10F0, layout 4, port}. Counters cross from their clock
    //   domains unsynchronized: read twice if a value must be exact. [544]
    //   equals CSR go once the access is done, and [607:576] then holds the
    //   read data.
    // =========================================================================
    wire [255:0]  ctrl;
    wire [639:0]  probe0, probe1;

    fcapz_eio_xilinxus #(
        .IN_W  (1280),
        .OUT_W (256),
        .CHAIN (3)
    ) u_eio (
        .probe_in  ({probe1, probe0}),
        .probe_out (ctrl)
    );

    // =========================================================================
    // Ports
    // =========================================================================
    wire tx_done0, rx_done0, lock0, hi_ber0, bad0, good0, laser_off0;
    wire tx_done1, rx_done1, lock1, hi_ber1, bad1, good1, laser_off1;

    zcu106_10g_port #(.PORT(8'd0)) u_port0 (
        .clk_50          (clk_50),
        .rst_50          (rst_50),
        .clk_app         (clk_app),
        .app_rst_n       (app_rst_n),
        .ctrl            (ctrl[127:0]),
        .fm_tog          (fm_tog),
        .fm_ref          (fm_ref),
        .qpll0clk        (qpll0outclk),
        .qpll0refclk     (qpll0outrefclk),
        .qpll0lock       (qpll0lock),
        .qpll0refclklost (qpll0refclklost),
        .qpll0reset      (qpll0reset),
        .gthrxp          (SFP0_RX_P),
        .gthrxn          (SFP0_RX_N),
        .gthtxp          (SFP0_TX_P),
        .gthtxn          (SFP0_TX_N),
        .probe           (probe0),
        .tx_done         (tx_done0),
        .rx_done         (rx_done0),
        .block_lock      (lock0),
        .hi_ber          (hi_ber0),
        .sel_bad_seen    (bad0),
        .sel_good_led    (good0),
        .laser_off       (laser_off0)
    );

    zcu106_10g_port #(.PORT(8'd1)) u_port1 (
        .clk_50          (clk_50),
        .rst_50          (rst_50),
        .clk_app         (clk_app),
        .app_rst_n       (app_rst_n),
        .ctrl            (ctrl[255:128]),
        .fm_tog          (fm_tog),
        .fm_ref          (fm_ref),
        .qpll0clk        (qpll0outclk),
        .qpll0refclk     (qpll0outrefclk),
        .qpll0lock       (qpll0lock),
        .qpll0refclklost (qpll0refclklost),
        .qpll0reset      (),                 // port 0 owns QPLL0
        .gthrxp          (SFP1_RX_P),
        .gthrxn          (SFP1_RX_N),
        .gthtxp          (SFP1_TX_P),
        .gthtxn          (SFP1_TX_N),
        .probe           (probe1),
        .tx_done         (tx_done1),
        .rx_done         (rx_done1),
        .block_lock      (lock1),
        .hi_ber          (hi_ber1),
        .sel_bad_seen    (bad1),
        .sel_good_led    (good1),
        .laser_off       (laser_off1)
    );

    // =========================================================================
    // LEDs and lasers
    // =========================================================================
    reg [25:0] hb = 26'd0;
    always @(posedge clk_50) hb <= hb + 26'd1;

    // block-lock LEDs also show a high BER: they blink
    assign LED = {hb[25], bad0 || bad1, good0 || good1,
                  lock1 && (!hi_ber1 || hb[22]), lock0 && (!hi_ber0 || hb[22]),
                  tx_done1 && rx_done1, tx_done0 && rx_done0, qpll0lock};

    assign SFP0_TX_DISABLE_B = !laser_off0;
    assign SFP1_TX_DISABLE_B = !laser_off1;

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
