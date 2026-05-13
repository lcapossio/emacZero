# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
# emacZero eth_mac_sys flat filelist (Verilog 2001).
# Paths are relative to the project root. Use with:
#   iverilog  -g2001 -f rtl/eth_mac_sys.f -o build.vvp <tb.v>
#   vivado    -> read_verilog -file_list rtl/eth_mac_sys.f
#   yosys     -> read_verilog $(cat rtl/eth_mac_sys.f | grep -v '^#')
#
# Top: eth_mac_sys
# Optional L3 add-ons: see rtl/eth_mac_sys_l3.f
rtl/crc32.v
rtl/async_fifo.v
rtl/sync_fifo.v
rtl/mii_if.v
rtl/eth_mac_rx.v
rtl/eth_mac_tx.v
rtl/eth_mac.v
rtl/mdio_master.v
rtl/eth_stats.v
rtl/eth_pause.v
rtl/axilite_regs.v
rtl/ddr_output.v
rtl/ddr_input.v
rtl/rgmii_if.v
rtl/gmii_cdc.v
rtl/net/tx_csum_off.v
rtl/eth_mac_sys.v
