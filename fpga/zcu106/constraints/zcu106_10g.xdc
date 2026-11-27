# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
# =============================================================================
# zcu106_10g.xdc - 10GBASE-R (zcu106_10g_top) on SFP cages 0 and 1 of the
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
# Hold the buffer on the MGTREFCLK1 buffer of Quad 226 (the U10/U9 pins): the
# placer can otherwise move it to the MGTREFCLK0 buffer, which has no clock,
# while still reporting the ports on U10/U9.
set_property LOC GTHE4_COMMON_X0Y3 [get_cells -hierarchical -filter {REF_NAME == IBUFDS_GTE4}]
set_property BEL GTHE4_COMMON.IBUFDS1_GTHE4 [get_cells -hierarchical -filter {REF_NAME == IBUFDS_GTE4}]

# ---- SFP cage 0 serial lanes: GTHE4_CHANNEL_X0Y10, Quad 225 (port 0) ----
set_property PACKAGE_PIN Y4  [get_ports SFP0_TX_P]
set_property PACKAGE_PIN Y3  [get_ports SFP0_TX_N]
set_property PACKAGE_PIN AA2 [get_ports SFP0_RX_P]
set_property PACKAGE_PIN AA1 [get_ports SFP0_RX_N]
set_property LOC GTHE4_CHANNEL_X0Y10 \
    [get_cells -hierarchical -filter {REF_NAME == GTHE4_CHANNEL && NAME =~ u_port0/*}]

# ---- SFP cage 1 serial lanes: GTHE4_CHANNEL_X0Y11, Quad 225 (port 1) ----
set_property PACKAGE_PIN W6 [get_ports SFP1_TX_P]
set_property PACKAGE_PIN W5 [get_ports SFP1_TX_N]
set_property PACKAGE_PIN W2 [get_ports SFP1_RX_P]
set_property PACKAGE_PIN W1 [get_ports SFP1_RX_N]
set_property LOC GTHE4_CHANNEL_X0Y11 \
    [get_cells -hierarchical -filter {REF_NAME == GTHE4_CHANNEL && NAME =~ u_port1/*}]

set_property LOC GTHE4_COMMON_X0Y2 [get_cells -hierarchical -filter {REF_NAME == GTHE4_COMMON}]

# ---- SFP TX_DISABLE (high = laser on; jumper J16 also forces SFP0's on) ----
set_property PACKAGE_PIN AE22 [get_ports SFP0_TX_DISABLE_B]
set_property PACKAGE_PIN AF20 [get_ports SFP1_TX_DISABLE_B]
set_property IOSTANDARD LVCMOS12 [get_ports {SFP0_TX_DISABLE_B SFP1_TX_DISABLE_B}]

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
# refclk) and RX (recovered) are plesiochronous: unrelated groups below, one
# per port and direction.
create_clock -name txoutclk0 -period 3.103 \
    [get_pins -hierarchical -filter {NAME =~ u_port0/*u_gthe4_channel/TXOUTCLK}]
create_clock -name rxoutclk0 -period 3.103 \
    [get_pins -hierarchical -filter {NAME =~ u_port0/*u_gthe4_channel/RXOUTCLK}]
create_clock -name txoutclk1 -period 3.103 \
    [get_pins -hierarchical -filter {NAME =~ u_port1/*u_gthe4_channel/TXOUTCLK}]
create_clock -name rxoutclk1 -period 3.103 \
    [get_pins -hierarchical -filter {NAME =~ u_port1/*u_gthe4_channel/RXOUTCLK}]

# ---- Clock domains ----
# The 50 MHz control clock, the refclk meter clock, TCK, and each port's TX
# user clock and RX recovered clock are unrelated. Between those only resets,
# static settings and status cross, through synchronizers, plus EIO status
# counters read as debug values: cut as asynchronous groups.
# TCK is defined on BSCANE2 INTERNAL_TCK, where AMD's timing model starts it,
# so it reaches the fabric TCK net and the path back into TDO is timed too.
create_clock -name tck_bscan -period 100.0 \
    [get_pins -of_objects [get_cells -hierarchical -filter {REF_NAME == BSCANE2}] \
              -filter {REF_PIN_NAME == INTERNAL_TCK}]
create_waiver -type METHODOLOGY -id TIMING-2 -user emacZero \
    -objects [get_clocks tck_bscan] \
    -description "fcapz BSCANE2 TCK is the intended JTAG clock source"
set clk_app [get_clocks -of_objects [get_pins u_app_mmcm/CLKOUT0]]
set clk_50  [get_clocks -of_objects [get_pins u_clk_50_buf/O]]
set gt_usr  [get_clocks -include_generated_clocks {txoutclk0 rxoutclk0 txoutclk1 rxoutclk1}]
set_clock_groups -asynchronous -group [get_clocks tck_bscan]
set_clock_groups -asynchronous -group [get_clocks -include_generated_clocks sfp_refclk]
set_clock_groups -asynchronous -group $clk_50
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks txoutclk0] \
    -group [get_clocks -include_generated_clocks rxoutclk0] \
    -group [get_clocks -include_generated_clocks txoutclk1] \
    -group [get_clocks -include_generated_clocks rxoutclk1]
# clk_app <-> the GT user clocks carry the MAC frame FIFOs, the statistics
# FIFOs and the event counters: Gray pointers, and data words or snapshots
# that a synchronized request or pointer qualifies. Not cut: bound every such
# path to 4 ns, under the 5 ns clk_app period, so a Gray pointer's bits
# cannot arrive out of order and bundled data settles before its qualifier.
set_max_delay -datapath_only -from $clk_app -to $gt_usr 4.0
set_max_delay -datapath_only -from $gt_usr -to $clk_app 4.0

# Static / slow board inputs and LED outputs
set_false_path -from [get_ports CPU_RESET]
set_false_path -to   [get_ports {LED[*] SFP0_TX_DISABLE_B SFP1_TX_DISABLE_B}]
