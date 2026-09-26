# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
# =============================================================================
# zcu106.xdc - emacZero 1000BASE-X over SFP cage 0 on the AMD ZCU106
# Pin locations from the Vivado ZCU106 board files (board.xml/part0_pins.xml).
# =============================================================================

# ---- 300 MHz user clock (Si570) ----
set_property PACKAGE_PIN AH12 [get_ports USER_SI570_SYSCLK_P]
set_property PACKAGE_PIN AJ12 [get_ports USER_SI570_SYSCLK_N]
set_property IOSTANDARD DIFF_SSTL12 [get_ports {USER_SI570_SYSCLK_P USER_SI570_SYSCLK_N}]
create_clock -name sysclk_300 -period 3.333 [get_ports USER_SI570_SYSCLK_P]

# ---- CPU reset push button (active high) ----
set_property PACKAGE_PIN G13 [get_ports CPU_RESET]
set_property IOSTANDARD LVCMOS18 [get_ports CPU_RESET]

# ---- SFP GTH reference clock: pins and period are in refclk_si570.xdc or
#      refclk_si5328.xdc; build_zcu106.tcl reads the one that matches the
#      REFCLK_SI5328 generic. Both name the clock sfp_refclk. ----

# ---- SFP cage 0 serial lanes (the placer picks the GTH channel from these) ----
set_property PACKAGE_PIN Y4  [get_ports SFP0_TX_P]
set_property PACKAGE_PIN Y3  [get_ports SFP0_TX_N]
set_property PACKAGE_PIN AA2 [get_ports SFP0_RX_P]
set_property PACKAGE_PIN AA1 [get_ports SFP0_RX_N]

# ---- SFP0 TX_DISABLE (net SFP0_TX_DISABLE; drives Q9, so high = laser on).
#      Jumper J16 "SFP Enable" (default on) forces TX on regardless. ----
set_property PACKAGE_PIN AE22 [get_ports SFP0_TX_DISABLE_B]
set_property IOSTANDARD LVCMOS12 [get_ports SFP0_TX_DISABLE_B]

# ---- PL IIC1 (via PCA9306 level shifter; 10k pull-ups to 1.2 V on the FPGA
#      side) -> TCA9548A U34 (0x74) ch 4 -> Si5328 U20. Shared with PS I2C1
#      and the system controller. ----
set_property PACKAGE_PIN AH19 [get_ports IIC_SCL]
set_property PACKAGE_PIN AL21 [get_ports IIC_SDA]
set_property IOSTANDARD LVCMOS12 [get_ports {IIC_SCL IIC_SDA}]
set_property DRIVE 8 [get_ports {IIC_SCL IIC_SDA}]
set_property SLEW SLOW [get_ports {IIC_SCL IIC_SDA}]

# ---- DIP switch 0: disable 1000BASE-X auto-negotiation ----
set_property PACKAGE_PIN A17 [get_ports DIP_AN_DISABLE]
set_property IOSTANDARD LVCMOS18 [get_ports DIP_AN_DISABLE]

# ---- User LEDs ----
set_property PACKAGE_PIN AL11 [get_ports {LED[0]}]
set_property PACKAGE_PIN AL13 [get_ports {LED[1]}]
set_property PACKAGE_PIN AK13 [get_ports {LED[2]}]
set_property PACKAGE_PIN AE15 [get_ports {LED[3]}]
set_property PACKAGE_PIN AM8  [get_ports {LED[4]}]
set_property PACKAGE_PIN AM9  [get_ports {LED[5]}]
set_property PACKAGE_PIN AM10 [get_ports {LED[6]}]
set_property PACKAGE_PIN AM11 [get_ports {LED[7]}]
set_property IOSTANDARD LVCMOS12 [get_ports {LED[*]}]

# ---- Clock domains ----
# The 50 MHz control clock (300 MHz / 6) and the GT-derived clocks (userclk2
# etc., generated from sfp_refclk through the GTH) are unrelated. Only reset
# and status bits cross, all through synchronizers.
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks sysclk_300] \
    -group [get_clocks -include_generated_clocks sfp_refclk]

# Static / slow board inputs and LED outputs
set_false_path -from [get_ports {CPU_RESET DIP_AN_DISABLE}]
set_false_path -to   [get_ports {LED[*] SFP0_TX_DISABLE_B}]
set_false_path -to   [get_ports {IIC_SCL IIC_SDA}]
set_false_path -from [get_ports IIC_SDA]
