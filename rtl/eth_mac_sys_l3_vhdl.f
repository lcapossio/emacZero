# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
# emacZero L3 helper modules, VHDL port (analyse as VHDL-93 after
# rtl/eth_mac_sys_vhdl.f, which provides emz_util_pkg). See docs/vhdl_port.md.
# Each module is proven equivalent to its rtl/net/*.v golden in sim/parity/.
#
# Not ported yet: rtl/net/net_rx.v (the Ethernet/IP/UDP parser that feeds
# these responders). Until it is, mix it in as Verilog.
rtl/vhdl/icmp_echo.vhd
rtl/vhdl/udp_echo.vhd
rtl/vhdl/udp_blast.vhd
rtl/vhdl/udp_blast_trigger.vhd
rtl/vhdl/udp_iperf_sink.vhd
rtl/vhdl/udp_stats_reply.vhd
