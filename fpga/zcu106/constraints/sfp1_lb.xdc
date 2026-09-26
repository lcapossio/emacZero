# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
# =============================================================================
# sfp1_lb.xdc - Extra constraints for the SFP0 <-> SFP1 loopback build
# (build_zcu106.tcl ... lb). Read after zcu106.xdc.
# =============================================================================

# ---- SFP cage 1 serial lanes (GTHE4_CHANNEL_X0Y11, Quad 225) ----
set_property PACKAGE_PIN W6 [get_ports SFP1_TX_P]
set_property PACKAGE_PIN W5 [get_ports SFP1_TX_N]
set_property PACKAGE_PIN W2 [get_ports SFP1_RX_P]
set_property PACKAGE_PIN W1 [get_ports SFP1_RX_N]

# ---- SFP1 TX_DISABLE (high = laser on, as SFP0) ----
set_property PACKAGE_PIN AF20 [get_ports SFP1_TX_DISABLE_B]
set_property IOSTANDARD LVCMOS12 [get_ports SFP1_TX_DISABLE_B]
set_false_path -to [get_ports SFP1_TX_DISABLE_B]

# ---- fcapz EIO: JTAG TCK from BSCANE2 ----
# The EIO synchronizes probe_in into TCK and probe_out is synchronized in
# sfp_lb_tester, so TCK is asynchronous to every fabric clock.
create_clock -name tck_bscan -period 100.0 \
    [get_pins -of_objects [get_cells -hierarchical -filter {REF_NAME == BSCANE2}] \
              -filter {REF_PIN_NAME == TCK}]
# On UltraScale+ the BSCANE2 TCK output has a timing arc from the JTAG port,
# so Vivado flags a clock defined on it (TIMING-2). It is still the point
# that starts the TCK domain, as in the fcapz examples.
create_waiver -type METHODOLOGY -id TIMING-2 -user emacZero \
    -objects [get_clocks tck_bscan] \
    -description "fcapz BSCANE2 TCK is the intended JTAG clock source"
set_clock_groups -asynchronous \
    -group [get_clocks tck_bscan] \
    -group [get_clocks -include_generated_clocks sysclk_300] \
    -group [get_clocks -include_generated_clocks sfp_refclk]
