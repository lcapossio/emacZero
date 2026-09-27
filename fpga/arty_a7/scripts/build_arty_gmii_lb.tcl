# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
# =============================================================================
# build_arty_gmii_lb.tcl - Debug build plus the GMII loopback self-test
# Same as build_arty_debug.tcl, with gmii_lb_selftest.v (a second eth_mac_sys,
# PHY_INTERFACE="GMII", MAX_FRAME=9018, looped back in fabric) wired to the
# EIO. Output: build_arty_gmii_lb/.
# Usage: vivado -mode batch -source fpga/arty_a7/scripts/build_arty_gmii_lb.tcl
# Run from the repository root directory.
# =============================================================================

set gmii_lb 1
source [file join [file dirname [info script]] build_arty_debug.tcl]
