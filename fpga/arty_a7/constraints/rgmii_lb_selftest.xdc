## SPDX-License-Identifier: Apache-2.0
## Copyright (c) 2026 Leonardo Capossio - bard0 design
##
## RGMII pad loopback self-test (build_arty_rgmii_lb.tcl only).
## Six pins of Pmod header JC (bank 14, 3.3 V), each driven and read back
## through its own IOBUF. Nothing may be plugged into JC.
##   RGMII_LB[0] TXD0/RXD0     JC pin 1  U12
##   RGMII_LB[1] TXD1/RXD1     JC pin 2  V12
##   RGMII_LB[2] TXD2/RXD2     JC pin 4  V11
##   RGMII_LB[3] TXD3/RXD3     JC pin 7  U14
##   RGMII_LB[4] TX_CTL/RX_CTL JC pin 8  V14
##   RGMII_LB[5] TXC/RXC       JC pin 3  V10
set_property -dict {PACKAGE_PIN U12 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {RGMII_LB[0]}]
set_property -dict {PACKAGE_PIN V12 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {RGMII_LB[1]}]
set_property -dict {PACKAGE_PIN V11 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {RGMII_LB[2]}]
set_property -dict {PACKAGE_PIN U14 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {RGMII_LB[3]}]
set_property -dict {PACKAGE_PIN V14 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {RGMII_LB[4]}]
set_property -dict {PACKAGE_PIN V10 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {RGMII_LB[5]}]
## No JC pin is clock-capable, so the read-back RXC reaches its BUFG over
## general routing. That adds clock insertion delay, which the RX IDELAY tap
## sweep measures; a board with RXC on an MRCC/SRCC pin has less.
## The cells are matched as u?<name>: the Verilog has u_bufg_rxc / u_mmcm, the
## VHDL port (rgmii_lb_selftest.vhd) has bufg_rxc / mmcm in generate u, which
## Vivado names u.bufg_rxc / u.mmcm.
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -of_objects [get_pins u_rgmii_lb/u?bufg_rxc/I]]

## RXC as the pad sees it. At 1G, TXC leaves TXC_PHASE (90) degrees after the
## data, so at the pad the data is valid from 2 ns before to 2 ns after each
## RXC edge. Allow 0.5 ns of output skew between the six ODDR/IOBUF paths:
## valid 1.5 ns either side of each edge (center-aligned DDR input template).
## STA checks these at the IDELAY_INIT tap only, and its slow-corner RXC delay
## over general routing is well above what the tap sweep measures, so the RX
## hold violations it reports at tap 0 are expected: the sweep decides.
create_clock -name rgmii_lb_rxc -period 8.000 [get_ports {RGMII_LB[5]}]
set rgmii_lb_rx [get_ports {RGMII_LB[0] RGMII_LB[1] RGMII_LB[2] RGMII_LB[3] RGMII_LB[4]}]
set_input_delay -clock rgmii_lb_rxc -max 2.500 $rgmii_lb_rx
set_input_delay -clock rgmii_lb_rxc -min 1.500 $rgmii_lb_rx
set_input_delay -clock rgmii_lb_rxc -clock_fall -max 2.500 -add_delay $rgmii_lb_rx
set_input_delay -clock rgmii_lb_rxc -clock_fall -min 1.500 -add_delay $rgmii_lb_rx
## The outputs feed only their own pads; the input delays above stand for them.
set_false_path -to [get_ports {RGMII_LB[*]}]

## The 125 MHz clocks come from an MMCM on sys_clk, so Vivado would time the
## sys <-> media crossings as synchronous. gmii_cdc handles them as
## asynchronous, as on a board where the PHY RX clock is independent: constrain
## them that way (see gmii_lb_selftest.xdc). clk_125 and the TXC clock stay in
## one group: rgmii_if times a path between them. The read-back RXC is
## asynchronous to both as far as the MAC's CDC is concerned.
set lb_clk_125 [get_clocks -of_objects [get_pins u_rgmii_lb/u?mmcm/CLKOUT0]]
set lb_clk_90  [get_clocks -of_objects [get_pins u_rgmii_lb/u?mmcm/CLKOUT1]]
set lb_clk_200 [get_clocks -of_objects [get_pins u_rgmii_lb/u?mmcm/CLKOUT2]]
set_clock_groups -asynchronous \
    -group [get_clocks sys_clk] \
    -group [list $lb_clk_125 $lb_clk_90] \
    -group $lb_clk_200 \
    -group [get_clocks rgmii_lb_rxc]
