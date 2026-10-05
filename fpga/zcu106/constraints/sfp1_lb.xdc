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
