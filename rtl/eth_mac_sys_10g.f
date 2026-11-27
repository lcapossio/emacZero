# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
# emacZero eth_mac_sys_10g flat filelist (Verilog 2001): the 10G MAC system
# (64-bit AXI4-Stream <-> XGMII) and the 10GBASE-R PCS that drives it.
# Paths are relative to the project root. Use with:
#   iverilog  -g2001 -Irtl -f rtl/eth_mac_sys_10g.f -o build.vvp <tb.v>
#   vivado    -> read_verilog -file_list rtl/eth_mac_sys_10g.f
#
# Tops: eth_mac_sys_10g (MAC system), pcs10gbr (PCS)
rtl/crc32_d64.v
rtl/async_fifo.v
rtl/axis_async_frame_fifo.v
rtl/cdc_event_count.v
rtl/eth_mac_10g_tx.v
rtl/eth_mac_10g_rx.v
rtl/eth_rs_10g.v
rtl/eth_pause_10g.v
rtl/eth_mac_sys_10g.v
rtl/pcs10gbr_enc.v
rtl/pcs10gbr_dec.v
rtl/pcs10gbr_scrambler.v
rtl/pcs10gbr_gearbox_tx.v
rtl/pcs10gbr_gearbox_rx.v
rtl/pcs10gbr_block_lock.v
rtl/pcs10gbr_ber_mon.v
rtl/pcs10gbr.v
