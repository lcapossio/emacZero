// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// gthe4_common_10g.v - GTHE4_COMMON with QPLL0 at 10.3125 GHz for 10GBASE-R
// from a 156.25 MHz reference clock. QPLL1 is powered down.
//
// The primitive is instantiated directly (no Transceiver Wizard IP). Every
// attribute that differs from the UNISIM default is set below; the values
// were cross-checked against a scratch Transceiver Wizard reference
// configuration that is not part of this repository. Every primitive input
// is tied explicitly; outputs not used are left open.
//
// refclk is the IBUFDS_GTE4 output. QPLL0_REFCLK_SEL picks the QPLL0 input it
// is connected to (the refclk is connected to that input only):
//   3'b001 GTREFCLK00  3'b010 GTREFCLK01
//   3'b011 GTNORTHREFCLK00  3'b100 GTNORTHREFCLK01
//   3'b101 GTSOUTHREFCLK00  3'b110 GTSOUTHREFCLK01
// Keep the default, GTREFCLK00, even for a reference from another quad: as
// with the Wizard, Vivado then routes it over the north / south reference
// clock lines itself and sets the select to match. Choosing a north / south
// input by hand fights the placer: on the ZCU106 (reference on Quad 226
// MGTREFCLK1, SFP channels in Quad 225) GTSOUTHREFCLK01 / 3'b110 built and
// routed but left QPLL0 with no clock, and driving more inputs made Vivado
// move the IBUFDS_GTE4 onto the unconnected MGTREFCLK0 buffer.
// Verilog 2001
// =============================================================================

module gthe4_common_10g #(
    parameter [2:0] QPLL0_REFCLK_SEL = 3'b001
) (
    input  wire refclk,            // from IBUFDS_GTE4 .O
    input  wire drpclk,            // free-running
    input  wire qpll0reset,
    output wire qpll0lock,
    output wire qpll0refclklost,
    output wire qpll0outclk,       // to GTHE4_CHANNEL .QPLL0CLK
    output wire qpll0outrefclk     // to GTHE4_CHANNEL .QPLL0REFCLK
);

    wire gtrefclk00      = (QPLL0_REFCLK_SEL == 3'b001) ? refclk : 1'b0;
    wire gtrefclk01      = (QPLL0_REFCLK_SEL == 3'b010) ? refclk : 1'b0;
    wire gtnorthrefclk00 = (QPLL0_REFCLK_SEL == 3'b011) ? refclk : 1'b0;
    wire gtnorthrefclk01 = (QPLL0_REFCLK_SEL == 3'b100) ? refclk : 1'b0;
    wire gtsouthrefclk00 = (QPLL0_REFCLK_SEL == 3'b101) ? refclk : 1'b0;
    wire gtsouthrefclk01 = (QPLL0_REFCLK_SEL == 3'b110) ? refclk : 1'b0;

    GTHE4_COMMON #(
        // QPLL0: 156.25 MHz reference / 1 x 66 (QPLL0_FBDIV default) = 10.3125 GHz
        // VCO, half-rate output = 5.15625 GHz, both edges -> 10.3125 Gb/s
        .QPLL0CLKOUT_RATE            ("HALF"),
        .QPLL0_CFG0                  (16'b0011001100011100),
        .QPLL0_CFG1                  (16'b1101000000111000),
        .QPLL0_CFG2                  (16'b0000111111000000),
        .QPLL0_CFG4                  (16'b0000000000000011),
        .QPLL0_CP                    (10'b0011111111),
        .QPLL0_INIT_CFG0             (16'b0000001010110010),
        .QPLL0_LOCK_CFG              (16'b0010010111101000),
        .QPLL0_LPF                   (10'b1000111111),
        .QPLL0_RATE_SW_USE_DRP       (1'b1),
        .QPLL0_SDM_CFG0              (16'b0000000010000000),
        // Bias generator
        .BIAS_CFG2                   (16'b0000000100100100),
        .BIAS_CFG3                   (16'b0000000001000001),
        .BIAS_CFG4                   (16'b0000000000010000),
        // QPLL0 feedback divider sigma-delta (fractional-N off) and its supply filter
        .PPF0_CFG                    (16'b0000011000000000),
        .SDM0INITSEED0_0             (16'b0000000100010001),
        .SDM0INITSEED0_1             (9'b000010001)
    ) u_gthe4_common (
        .DRPDO                 (),
        .DRPRDY                (),
        .PMARSVDOUT0           (),
        .PMARSVDOUT1           (),
        .QPLL0FBCLKLOST        (),
        .QPLL0LOCK             (qpll0lock),
        .QPLL0OUTCLK           (qpll0outclk),
        .QPLL0OUTREFCLK        (qpll0outrefclk),
        .QPLL0REFCLKLOST       (qpll0refclklost),
        .QPLL1FBCLKLOST        (),
        .QPLL1LOCK             (),
        .QPLL1OUTCLK           (),
        .QPLL1OUTREFCLK        (),
        .QPLL1REFCLKLOST       (),
        .QPLLDMONITOR0         (),
        .QPLLDMONITOR1         (),
        .REFCLKOUTMONITOR0     (),
        .REFCLKOUTMONITOR1     (),
        .RXRECCLK0SEL          (),
        .RXRECCLK1SEL          (),
        .SDM0FINALOUT          (),
        .SDM0TESTDATA          (),
        .SDM1FINALOUT          (),
        .SDM1TESTDATA          (),
        .TCONGPO               (),
        .TCONRSVDOUT0          (),
        .BGBYPASSB             (1'h1),
        .BGMONITORENB          (1'h1),
        .BGPDB                 (1'h1),
        .BGRCALOVRD            (5'h1F),
        .BGRCALOVRDENB         (1'h1),
        .DRPADDR               (16'h0),
        .DRPCLK                (drpclk),
        .DRPDI                 (16'h0),
        .DRPEN                 (1'h0),
        .DRPWE                 (1'h0),
        .GTGREFCLK0            (1'h0),
        .GTGREFCLK1            (1'h0),
        .GTNORTHREFCLK00       (gtnorthrefclk00),
        .GTNORTHREFCLK01       (gtnorthrefclk01),
        .GTNORTHREFCLK10       (1'h0),
        .GTNORTHREFCLK11       (1'h0),
        .GTREFCLK00            (gtrefclk00),
        .GTREFCLK01            (gtrefclk01),
        .GTREFCLK10            (1'h0),
        .GTREFCLK11            (1'h0),
        .GTSOUTHREFCLK00       (gtsouthrefclk00),
        .GTSOUTHREFCLK01       (gtsouthrefclk01),
        .GTSOUTHREFCLK10       (1'h0),
        .GTSOUTHREFCLK11       (1'h0),
        .PCIERATEQPLL0         (3'h0),
        .PCIERATEQPLL1         (3'h0),
        .PMARSVD0              (8'h0),
        .PMARSVD1              (8'h0),
        .QPLL0CLKRSVD0         (1'h0),
        .QPLL0CLKRSVD1         (1'h0),
        .QPLL0FBDIV            (8'h0),
        .QPLL0LOCKDETCLK       (1'h0),
        .QPLL0LOCKEN           (1'h1),
        .QPLL0PD               (1'h0),
        .QPLL0REFCLKSEL        (QPLL0_REFCLK_SEL),
        .QPLL0RESET            (qpll0reset),
        .QPLL1CLKRSVD0         (1'h0),
        .QPLL1CLKRSVD1         (1'h0),
        .QPLL1FBDIV            (8'h0),
        .QPLL1LOCKDETCLK       (1'h0),
        .QPLL1LOCKEN           (1'h0),
        .QPLL1PD               (1'h1),
        .QPLL1REFCLKSEL        (3'h1),
        .QPLL1RESET            (1'h1),
        .QPLLRSVD1             (8'h0),
        .QPLLRSVD2             (5'h0),
        .QPLLRSVD3             (5'h0),
        .QPLLRSVD4             (8'h0),
        .RCALENB               (1'h1),
        .SDM0DATA              (25'h0),
        .SDM0RESET             (1'h0),
        .SDM0TOGGLE            (1'h0),
        .SDM0WIDTH             (2'h0),
        .SDM1DATA              (25'h0),
        .SDM1RESET             (1'h0),
        .SDM1TOGGLE            (1'h0),
        .SDM1WIDTH             (2'h0),
        .TCONGPI               (10'h0),
        .TCONPOWERUP           (1'h0),
        .TCONRESET             (2'h0),
        .TCONRSVDIN1           (2'h0)
    );

endmodule
