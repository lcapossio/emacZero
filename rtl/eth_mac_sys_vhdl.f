# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
# emacZero eth_mac_sys flat filelist (VHDL port, analyse in order as VHDL-93).
# Paths are relative to the project root. See docs/vhdl_port.md.
#   ghdl   -> ghdl -a --std=93 $(grep -v '^#' rtl/eth_mac_sys_vhdl.f)
#   vivado -> read_vhdl <each file>
#
# The first file selects the DDR / XPM target; it replaces the Verilog
# `define (XILINX_7SERIES, XILINX_ULTRASCALE_PLUS, INTEL_CYCLONE or SIM).
# Swap it for one of:
#   rtl/vhdl/target/emz_target_xilinx_7series.vhd
#   rtl/vhdl/target/emz_target_xilinx_ultrascale_plus.vhd
#   rtl/vhdl/target/emz_target_intel_cyclone.vhd
#   rtl/vhdl/target/emz_target_sim.vhd
#   rtl/vhdl/target/emz_target_none.vhd   (no DDR cell; RGMII outputs undriven)
#
# Top: eth_mac_sys
rtl/vhdl/target/emz_target_xilinx_7series.vhd
rtl/vhdl/emz_util_pkg.vhd
rtl/vhdl/emz_version_pkg.vhd
rtl/vhdl/crc32.vhd
rtl/vhdl/async_fifo.vhd
rtl/vhdl/sync_fifo.vhd
rtl/vhdl/mii_if.vhd
rtl/vhdl/mii_tx_saf.vhd
rtl/vhdl/csum_calc.vhd
rtl/vhdl/eth_mac_rx.vhd
rtl/vhdl/eth_mac_tx.vhd
rtl/vhdl/eth_mac.vhd
rtl/vhdl/mdio_master.vhd
rtl/vhdl/eth_stats.vhd
rtl/vhdl/eth_pause_rx.vhd
rtl/vhdl/eth_pause.vhd
rtl/vhdl/axilite_regs.vhd
rtl/vhdl/ddr_output.vhd
rtl/vhdl/ddr_input.vhd
rtl/vhdl/rgmii_if.vhd
rtl/vhdl/gmii_if.vhd
rtl/vhdl/gmii_cdc.vhd
rtl/vhdl/tx_csum_off.vhd
rtl/vhdl/eth_mac_sys.vhd
