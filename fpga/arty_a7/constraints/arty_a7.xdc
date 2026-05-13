# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
## =============================================================================
## Arty A7-100T Constraints for emacZero Ethernet MAC Hardware Test
## FPGA: XC7A100TCSG324-1
## =============================================================================

## ---- System Clock (100 MHz) ----
set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports CLK100MHZ]
create_clock -period 10.000 -name sys_clk [get_ports CLK100MHZ]

## ---- Reset Button (BTN0, active-high) ----
set_property -dict {PACKAGE_PIN D9 IOSTANDARD LVCMOS33} [get_ports BTN0]

## ---- LEDs ----
set_property -dict {PACKAGE_PIN H5  IOSTANDARD LVCMOS33} [get_ports {LED[0]}]
set_property -dict {PACKAGE_PIN J5  IOSTANDARD LVCMOS33} [get_ports {LED[1]}]
set_property -dict {PACKAGE_PIN T9  IOSTANDARD LVCMOS33} [get_ports {LED[2]}]
set_property -dict {PACKAGE_PIN T10 IOSTANDARD LVCMOS33} [get_ports {LED[3]}]

## ---- UART (USB-UART bridge, FPGA TX only) ----
set_property -dict {PACKAGE_PIN D10 IOSTANDARD LVCMOS33} [get_ports UART_TXD]

## ---- Ethernet MII (Bank 15, LVCMOS33) ----
## TX
set_property -dict {PACKAGE_PIN H14 IOSTANDARD LVCMOS33} [get_ports {ETH_TXD[0]}]
set_property -dict {PACKAGE_PIN J14 IOSTANDARD LVCMOS33} [get_ports {ETH_TXD[1]}]
set_property -dict {PACKAGE_PIN J13 IOSTANDARD LVCMOS33} [get_ports {ETH_TXD[2]}]
set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS33} [get_ports {ETH_TXD[3]}]
set_property -dict {PACKAGE_PIN H15 IOSTANDARD LVCMOS33} [get_ports ETH_TX_EN]
set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports ETH_TX_CLK]

## RX
set_property -dict {PACKAGE_PIN D18 IOSTANDARD LVCMOS33} [get_ports {ETH_RXD[0]}]
set_property -dict {PACKAGE_PIN E17 IOSTANDARD LVCMOS33} [get_ports {ETH_RXD[1]}]
set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVCMOS33} [get_ports {ETH_RXD[2]}]
set_property -dict {PACKAGE_PIN G17 IOSTANDARD LVCMOS33} [get_ports {ETH_RXD[3]}]
set_property -dict {PACKAGE_PIN G16 IOSTANDARD LVCMOS33} [get_ports ETH_RX_DV]
set_property -dict {PACKAGE_PIN C17 IOSTANDARD LVCMOS33} [get_ports ETH_RXERR]
set_property -dict {PACKAGE_PIN F15 IOSTANDARD LVCMOS33} [get_ports ETH_RX_CLK]

## Control
set_property -dict {PACKAGE_PIN G14 IOSTANDARD LVCMOS33} [get_ports ETH_CRS]
set_property -dict {PACKAGE_PIN D17 IOSTANDARD LVCMOS33} [get_ports ETH_COL]

## Management
set_property -dict {PACKAGE_PIN K13 IOSTANDARD LVCMOS33} [get_ports ETH_MDIO]
set_property -dict {PACKAGE_PIN F16 IOSTANDARD LVCMOS33} [get_ports ETH_MDC]

## Clock and Reset
set_property -dict {PACKAGE_PIN G18 IOSTANDARD LVCMOS33} [get_ports ETH_REF_CLK]
set_property -dict {PACKAGE_PIN C16 IOSTANDARD LVCMOS33} [get_ports ETH_RSTN]

## ---- MII Clock Constraints ----
create_clock -period 40.000 -name eth_rx_clk [get_ports ETH_RX_CLK]
create_clock -period 40.000 -name eth_tx_clk [get_ports ETH_TX_CLK]

## Async clock domain crossings (handled by CDC FIFOs in mii_if.v)
set_clock_groups -asynchronous \
    -group [get_clocks sys_clk] \
    -group [get_clocks eth_rx_clk] \
    -group [get_clocks eth_tx_clk]

## ---- Bitstream Configuration ----
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]
