# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
# SFP GTH reference clock from USER_MGT_SI570 (U56) through the SI53340
# buffer (U51): 156.25 MHz at power-up, no programming needed. It enters on
# Quad 226 MGTREFCLK1 and reaches the SFP0 channel in Quad 225 over the GT
# south reference clock routing. Read by build_zcu106.tcl (default).
set_property PACKAGE_PIN U10 [get_ports SFP_REFCLK_P]
set_property PACKAGE_PIN U9  [get_ports SFP_REFCLK_N]
create_clock -name sfp_refclk -period 6.400 [get_ports SFP_REFCLK_P]
