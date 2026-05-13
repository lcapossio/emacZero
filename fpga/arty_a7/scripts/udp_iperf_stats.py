#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
"""
udp_iperf_stats.py - Query/clear FPGA iperf sink counters.

Examples:
  python fpga/arty_a7/scripts/udp_iperf_stats.py --clear
  python fpga/arty_a7/scripts/udp_iperf_stats.py
"""

import argparse
import socket
import struct


BOARD_IP = "192.168.137.200"
STATS_PORT = 9996


def query(board_ip, port, command, timeout):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        sock.sendto(command.encode("ascii"), (board_ip, port))
        data, _addr = sock.recvfrom(256)
    finally:
        sock.close()

    if len(data) != 44 or data[:4] != b"IPS0" or data[40:44] != b"DONE":
        raise RuntimeError(f"unexpected stats reply: {data.hex()}")

    fields = struct.unpack("!7I I H H", data[4:40])
    return {
        "packets": fields[0],
        "bytes": fields[1],
        "first_seq": fields[2],
        "last_seq": fields[3],
        "seq_gaps": fields[4],
        "out_of_order": fields[5],
        "final_packets": fields[6],
        "last_src_ip": socket.inet_ntoa(struct.pack("!I", fields[7])),
        "last_src_port": fields[8],
        "flags": fields[9],
    }


def main():
    parser = argparse.ArgumentParser(description="Query FPGA iperf sink counters")
    parser.add_argument("--board", default=BOARD_IP, help="FPGA IPv4 address")
    parser.add_argument("--port", type=int, default=STATS_PORT, help="stats UDP port")
    parser.add_argument("--clear", action="store_true", help="clear counters")
    parser.add_argument("--timeout", type=float, default=1.0, help="socket timeout seconds")
    args = parser.parse_args()

    stats = query(args.board, args.port, "C" if args.clear else "G", args.timeout)
    print(
        "packets={packets} bytes={bytes} first_seq={first_seq} last_seq={last_seq} "
        "seq_gaps={seq_gaps} out_of_order={out_of_order} final_packets={final_packets} "
        "last_src={last_src_ip}:{last_src_port}".format(**stats)
    )


if __name__ == "__main__":
    main()
