# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
# =============================================================================
# zcu106_10g.xdc - 10GBASE-R bring-up (zcu106_10g_top) on SFP cage 0 of the
# AMD ZCU106. Pins as zcu106.xdc / refclk_si570.xdc (Vivado board files).
# =============================================================================

# ---- 300 MHz user clock (Si570) ----
set_property PACKAGE_PIN AH12 [get_ports USER_SI570_SYSCLK_P]
set_property PACKAGE_PIN AJ12 [get_ports USER_SI570_SYSCLK_N]
set_property IOSTANDARD DIFF_SSTL12 [get_ports {USER_SI570_SYSCLK_P USER_SI570_SYSCLK_N}]
create_clock -name sysclk_300 -period 3.333 [get_ports USER_SI570_SYSCLK_P]

# ---- CPU reset push button (active high) ----
set_property PACKAGE_PIN G13 [get_ports CPU_RESET]
set_property IOSTANDARD LVCMOS18 [get_ports CPU_RESET]

# ---- SFP GTH reference clock: USER_MGT_SI570 (U56) through the SI53340
#      buffer (U51), 156.25 MHz at power-up, Quad 226 MGTREFCLK1 ----
set_property PACKAGE_PIN U10 [get_ports SFP_REFCLK_P]
set_property PACKAGE_PIN U9  [get_ports SFP_REFCLK_N]
create_clock -name sfp_refclk -period 6.400 [get_ports SFP_REFCLK_P]

# ---- SFP cage 0 serial lanes: GTHE4_CHANNEL_X0Y10, Quad 225 ----
set_property PACKAGE_PIN Y4  [get_ports SFP0_TX_P]
set_property PACKAGE_PIN Y3  [get_ports SFP0_TX_N]
set_property PACKAGE_PIN AA2 [get_ports SFP0_RX_P]
set_property PACKAGE_PIN AA1 [get_ports SFP0_RX_N]
set_property LOC GTHE4_CHANNEL_X0Y10 [get_cells -hierarchical -filter {REF_NAME == GTHE4_CHANNEL}]
set_property LOC GTHE4_COMMON_X0Y2   [get_cells -hierarchical -filter {REF_NAME == GTHE4_COMMON}]

# ---- SFP0 TX_DISABLE (high = laser on; jumper J16 also forces it on) ----
set_property PACKAGE_PIN AE22 [get_ports SFP0_TX_DISABLE_B]
set_property IOSTANDARD LVCMOS12 [get_ports SFP0_TX_DISABLE_B]

# ---- LEDs ----
set_property PACKAGE_PIN AL11 [get_ports {LED[0]}]
set_property PACKAGE_PIN AL13 [get_ports {LED[1]}]
set_property PACKAGE_PIN AK13 [get_ports {LED[2]}]
set_property PACKAGE_PIN AE15 [get_ports {LED[3]}]
set_property PACKAGE_PIN AM8  [get_ports {LED[4]}]
set_property PACKAGE_PIN AM9  [get_ports {LED[5]}]
set_property PACKAGE_PIN AM10 [get_ports {LED[6]}]
set_property PACKAGE_PIN AM11 [get_ports {LED[7]}]
set_property IOSTANDARD LVCMOS12 [get_ports {LED[*]}]

# ---- GT user clocks ----
# Vivado does not derive clocks on TXOUTCLK / RXOUTCLK of a directly
# instantiated GTHE4_CHANNEL, so define both: 322.27 MHz (10.3125 Gb/s / 32,
# PROGDIV 16 of the 5.15625 GHz QPLL0 clock). The BUFG_GT /1 and /2 outputs
# (TX/RXUSRCLK, TX/RXUSRCLK2) are generated from them. TX (from the local
# refclk) and RX (recovered) are plesiochronous: unrelated groups below.
create_clock -name txoutclk -period 3.103 \
    [get_pins -hierarchical -filter {NAME =~ *u_gthe4_channel/TXOUTCLK}]
create_clock -name rxoutclk -period 3.103 \
    [get_pins -hierarchical -filter {NAME =~ *u_gthe4_channel/RXOUTCLK}]

# ---- Clock domains ----
# The 50 MHz control clock, the refclk meter clock, the TX user clocks, the
# RX recovered clock and TCK are unrelated. Only resets, static settings and
# status cross, through synchronizers, plus EIO status counters read as
# debug values.
create_clock -name tck_bscan -period 100.0 \
    [get_pins -of_objects [get_cells -hierarchical -filter {REF_NAME == BSCANE2}] \
              -filter {REF_PIN_NAME == TCK}]
create_waiver -type METHODOLOGY -id TIMING-2 -user emacZero \
    -objects [get_clocks tck_bscan] \
    -description "fcapz BSCANE2 TCK is the intended JTAG clock source"
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks sysclk_300] \
    -group [get_clocks -include_generated_clocks sfp_refclk] \
    -group [get_clocks -include_generated_clocks txoutclk] \
    -group [get_clocks -include_generated_clocks rxoutclk] \
    -group [get_clocks tck_bscan]

# Static / slow board inputs and LED outputs
set_false_path -from [get_ports CPU_RESET]
set_false_path -to   [get_ports {LED[*] SFP0_TX_DISABLE_B}]
