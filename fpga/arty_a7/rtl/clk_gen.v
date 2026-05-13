// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio - bard0 design
// =============================================================================
// clk_gen.v - Clock generator for Arty A7 Ethernet test
// Uses MMCME2_BASE to produce 25 MHz from 100 MHz input.
// VCO = 100 MHz * 10 = 1000 MHz, CLKOUT0 = 1000 / 40 = 25 MHz.
// Verilog 2001
// =============================================================================

module clk_gen (
    input  wire clk_in,      // 100 MHz input
    output wire clk_25,      // 25 MHz output
    output wire locked       // MMCM lock indicator
);

    wire clk_25_buf;
    wire clkfb;
    wire clkfb_buf;

    MMCME2_BASE #(
        .BANDWIDTH       ("OPTIMIZED"),
        .CLKFBOUT_MULT_F (10.0),      // VCO = 100 * 10 = 1000 MHz
        .CLKFBOUT_PHASE  (0.0),
        .CLKIN1_PERIOD   (10.0),       // 100 MHz
        .CLKOUT0_DIVIDE_F(40.0),      // 1000 / 40 = 25 MHz
        .CLKOUT0_PHASE   (0.0),
        .CLKOUT0_DUTY_CYCLE(0.5),
        .DIVCLK_DIVIDE   (1),
        .REF_JITTER1     (0.010),
        .STARTUP_WAIT    ("FALSE")
    ) u_mmcm (
        .CLKIN1   (clk_in),
        .CLKFBIN  (clkfb_buf),
        .CLKFBOUT (clkfb),
        .CLKOUT0  (clk_25_buf),
        .CLKOUT1  (),
        .CLKOUT2  (),
        .CLKOUT3  (),
        .CLKOUT4  (),
        .CLKOUT5  (),
        .CLKOUT6  (),
        .CLKFBOUTB(),
        .CLKOUT0B (),
        .CLKOUT1B (),
        .CLKOUT2B (),
        .CLKOUT3B (),
        .LOCKED   (locked),
        .PWRDWN   (1'b0),
        .RST      (1'b0)
    );

    BUFG u_bufg_fb  (.I(clkfb),     .O(clkfb_buf));
    BUFG u_bufg_25  (.I(clk_25_buf),.O(clk_25));

endmodule
