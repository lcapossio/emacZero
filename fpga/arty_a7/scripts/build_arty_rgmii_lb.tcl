# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
# =============================================================================
# build_arty_rgmii_lb.tcl - Debug build plus the RGMII pad-loopback self-test
# Same as build_arty_debug.tcl, with rgmii_lb_selftest.v (a second eth_mac_sys,
# PHY_INTERFACE="RGMII", MAX_FRAME=9018, looped back at the pads of Pmod JC)
# wired to the EIO. Nothing may be plugged into JC. Output: build_arty_rgmii_lb/.
# Usage: vivado -mode batch -source fpga/arty_a7/scripts/build_arty_rgmii_lb.tcl
# Run from the repository root directory.
# =============================================================================

set rgmii_lb 1
source [file join [file dirname [info script]] build_arty_debug.tcl]
