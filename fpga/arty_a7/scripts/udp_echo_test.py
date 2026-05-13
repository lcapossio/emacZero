#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
"""
udp_echo_test.py - Host-side UDP echo bandwidth + latency test for emacZero.

Pairs with rtl/net/udp_echo.v in the FPGA: any UDP packet sent to the board
gets echoed back with src/dst IP and src/dst UDP-port swapped. The host:

  1. Opens a UDP socket bound to a local port.
  2. Spawns a sender thread that blasts UDP packets at the board for `--secs`.
  3. Spawns a receiver thread that drains incoming echoes.
  4. Reports: TX rate (Mbps + pps), RX rate (Mbps + pps), echo loss %, RTT min/avg/max.

Each payload starts with an 8-byte little-endian timestamp (perf_counter_ns
truncated to 64 bits) so RX can compute per-packet latency. Remaining bytes
are filler.

Usage:
  python udp_echo_test.py                            # 1472B @ 50 Mbps for 10s
  python udp_echo_test.py --mbps 95 --secs 10        # near line rate
  python udp_echo_test.py --size 64                  # min frame stress
  python udp_echo_test.py --ip 192.168.137.200

Requires: nothing beyond the stdlib.
"""
import argparse
import select
import socket
import struct
import sys
import threading
import time

BOARD_IP   = "192.168.137.200"
BOARD_PORT = 9999


class Sender(threading.Thread):
    def __init__(self, sock, ip, port, payload_size, target_mbps, duration_s):
        super().__init__(daemon=True)
        self.sock        = sock
        self.ip          = ip
        self.port        = port
        self.size        = max(payload_size, 16)  # need 8 byte tstamp + 8 seq
        self.target_mbps = target_mbps
        self.duration_s  = duration_s
        self.sent_pkts   = 0
        self.sent_bytes  = 0
        self.actual_mbps = 0.0

    def run(self):
        # Account for Eth (14) + IP (20) + UDP (8) + FCS (4) + preamble (8) + IFG (12)
        wire_size = self.size + 14 + 20 + 8 + 4 + 8 + 12
        if self.size + 14 + 20 + 8 < 60:
            wire_size += 60 - (self.size + 14 + 20 + 8)  # min frame padding
        bytes_per_sec = self.target_mbps * 1_000_000 / 8
        target_pps    = bytes_per_sec / wire_size if self.target_mbps > 0 else 1e9
        interval      = 1.0 / target_pps if target_pps > 0 else 0

        start = time.perf_counter()
        end   = start + self.duration_s
        next_t = start
        seq = 0
        filler = b"\x55" * (self.size - 16)

        while True:
            now = time.perf_counter()
            if now >= end:
                break
            # 16-byte header: 8B tstamp_ns | 8B seq
            ts_ns = int(now * 1_000_000_000) & ((1 << 64) - 1)
            hdr = struct.pack("<QQ", ts_ns, seq)
            try:
                self.sock.sendto(hdr + filler, (self.ip, self.port))
            except OSError:
                time.sleep(0.001)
                continue
            seq += 1
            self.sent_pkts  += 1
            self.sent_bytes += self.size
            if interval > 0:
                next_t += interval
                slack = next_t - time.perf_counter()
                if slack > 0.0005:
                    time.sleep(slack)
                elif slack < -0.05:
                    next_t = time.perf_counter()

        elapsed = time.perf_counter() - start
        if elapsed > 0:
            self.actual_mbps = self.sent_bytes * 8 / elapsed / 1_000_000


class Receiver(threading.Thread):
    def __init__(self, sock, duration_s, sender):
        super().__init__(daemon=True)
        self.sock       = sock
        self.duration_s = duration_s
        self.sender     = sender
        self.rx_pkts    = 0
        self.rx_bytes   = 0
        self.rtt_min    = 1e18
        self.rtt_max    = 0.0
        self.rtt_sum    = 0.0
        self.rtt_n      = 0

    def run(self):
        # Drain for sender duration + 1s grace so trailing echoes get counted.
        end = time.perf_counter() + self.duration_s + 1.0
        self.sock.settimeout(0.2)
        while time.perf_counter() < end:
            try:
                data, _addr = self.sock.recvfrom(2048)
            except socket.timeout:
                continue
            except OSError:
                break
            self.rx_pkts  += 1
            self.rx_bytes += len(data)
            if len(data) >= 16:
                ts_ns, _seq = struct.unpack("<QQ", data[:16])
                rtt_s = time.perf_counter() - (ts_ns / 1_000_000_000)
                if 0 < rtt_s < 5.0:
                    self.rtt_sum += rtt_s
                    self.rtt_n   += 1
                    if rtt_s < self.rtt_min:
                        self.rtt_min = rtt_s
                    if rtt_s > self.rtt_max:
                        self.rtt_max = rtt_s


def main():
    ap = argparse.ArgumentParser(description="emacZero UDP echo throughput + latency")
    ap.add_argument("--ip",       default=BOARD_IP)
    ap.add_argument("--udp-port", type=int, default=BOARD_PORT)
    ap.add_argument("--size",     type=int, default=1472, help="UDP payload bytes")
    ap.add_argument("--mbps",     type=float, default=50.0)
    ap.add_argument("--secs",     type=float, default=10.0)
    args = ap.parse_args()

    print("== emacZero UDP echo test ==")
    print(f"  Board       : {args.ip}:{args.udp_port}")
    print(f"  Payload     : {args.size} bytes")
    print(f"  Target rate : {args.mbps:.1f} Mbps for {args.secs:.1f} s")
    print()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 22)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 20)
    sock.bind(("", 0))  # ephemeral local port; OS picks
    local_port = sock.getsockname()[1]
    sock.setblocking(False)
    print(f"  Local port  : {local_port}")
    print()

    payload_size = max(args.size, 16)
    filler = b"\x55" * (payload_size - 16)
    wire_size = payload_size + 14 + 20 + 8 + 4 + 8 + 12
    if payload_size + 14 + 20 + 8 < 60:
        wire_size += 60 - (payload_size + 14 + 20 + 8)
    bytes_per_sec = args.mbps * 1_000_000 / 8
    target_pps = bytes_per_sec / wire_size if args.mbps > 0 else 1e9
    interval = 1.0 / target_pps if target_pps > 0 else 0.0

    sent_pkts = 0
    sent_bytes = 0
    rx_pkts = 0
    rx_bytes = 0
    rtt_min = 1e18
    rtt_max = 0.0
    rtt_sum = 0.0
    rtt_n = 0

    start = time.perf_counter()
    end = start + args.secs
    next_t = start
    seq = 0

    def drain():
        nonlocal rx_pkts, rx_bytes, rtt_min, rtt_max, rtt_sum, rtt_n
        while True:
            readable, _w, _x = select.select([sock], [], [], 0)
            if not readable:
                break
            try:
                data, _addr = sock.recvfrom(2048)
            except (BlockingIOError, OSError):
                break
            rx_pkts += 1
            rx_bytes += len(data)
            if len(data) >= 16:
                ts_ns, _seq = struct.unpack("<QQ", data[:16])
                rtt_s = time.perf_counter() - (ts_ns / 1_000_000_000)
                if 0 < rtt_s < 5.0:
                    rtt_sum += rtt_s
                    rtt_n += 1
                    if rtt_s < rtt_min:
                        rtt_min = rtt_s
                    if rtt_s > rtt_max:
                        rtt_max = rtt_s

    while time.perf_counter() < end:
        now = time.perf_counter()
        if now >= next_t:
            ts_ns = int(now * 1_000_000_000) & ((1 << 64) - 1)
            hdr = struct.pack("<QQ", ts_ns, seq)
            try:
                sock.sendto(hdr + filler, (args.ip, args.udp_port))
                seq += 1
                sent_pkts += 1
                sent_bytes += payload_size
            except OSError:
                pass
            if interval > 0:
                next_t += interval
                if next_t < now - 0.05:
                    next_t = now
        drain()
        slack = min(next_t - time.perf_counter(), 0.001) if interval > 0 else 0
        if slack > 0:
            time.sleep(slack)

    tx_elapsed = time.perf_counter() - start
    drain_end = time.perf_counter() + 1.0
    while time.perf_counter() < drain_end:
        drain()
        time.sleep(0.001)
    sock.close()

    print("-- results --")
    actual_mbps = sent_bytes * 8 / tx_elapsed / 1_000_000 if tx_elapsed > 0 else 0.0
    print(f"  Host TX     : {sent_pkts} pkts, "
          f"{sent_bytes/1e6:.2f} MB, {actual_mbps:.2f} Mbps")
    print(f"  Host RX     : {rx_pkts} pkts, "
          f"{rx_bytes/1e6:.2f} MB")
    if sent_pkts > 0:
        loss = 100.0 * (sent_pkts - rx_pkts) / sent_pkts
        print(f"  Echo loss   : {loss:+.2f}%")
    if rtt_n > 0:
        avg_us = rtt_sum / rtt_n * 1e6
        print(f"  RTT (n={rtt_n}): "
              f"min={rtt_min*1e6:.1f}us, "
              f"avg={avg_us:.1f}us, "
              f"max={rtt_max*1e6:.1f}us")
    if rx_pkts > 0:
        rx_mbps = rx_bytes * 8 / args.secs / 1_000_000
        rx_pps  = rx_pkts / args.secs
        print(f"  Echo rate   : {rx_mbps:.2f} Mbps, {rx_pps:.0f} pps")


if __name__ == "__main__":
    main()
