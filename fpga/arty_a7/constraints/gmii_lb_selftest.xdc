## SPDX-License-Identifier: Apache-2.0
## Copyright (c) 2026 Leonardo Capossio - bard0 design
##
## GMII loopback self-test (build_arty_gmii_lb.tcl only).
## The 125 MHz media clock comes from an MMCM on sys_clk, so Vivado would treat
## the sys <-> media crossings as synchronous and time them at the 2 ns
## 100/125 MHz edge spacing. gmii_cdc handles them as asynchronous (gray-coded
## FIFO pointers, 2-FF synchronizers), as on a board where the 125 MHz clock and
## the PHY RX clock are independent - so constrain them that way.
set lb_clk_125 [get_clocks -of_objects [get_pins u_gmii_lb/u_mmcm/CLKOUT0]]
set_clock_groups -asynchronous \
    -group [get_clocks sys_clk] \
    -group $lb_clk_125
