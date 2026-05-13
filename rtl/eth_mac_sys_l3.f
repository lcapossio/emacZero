# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
# emacZero L3 helper modules (Ethernet/IP/ICMP/UDP parser, responders, and
# Arty UDP throughput/iperf helpers).
# Use alongside rtl/eth_mac_sys.f when you want the optional demo network stack.
rtl/net/net_rx.v
rtl/net/icmp_echo.v
rtl/net/udp_echo.v
rtl/net/udp_blast.v
rtl/net/udp_blast_trigger.v
rtl/net/udp_iperf_sink.v
rtl/net/udp_stats_reply.v
