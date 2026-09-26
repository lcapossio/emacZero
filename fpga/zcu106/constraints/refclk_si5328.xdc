# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
# SFP GTH reference clock from the Si5328 (U20), programmed to 125 MHz by
# i2c_init over I2C. Quad 225 MGTREFCLK1. Read by build_zcu106.tcl when
# built with -tclargs si5328.
set_property PACKAGE_PIN W10 [get_ports SFP_REFCLK_P]
set_property PACKAGE_PIN W9  [get_ports SFP_REFCLK_N]
create_clock -name sfp_refclk -period 8.000 [get_ports SFP_REFCLK_P]
