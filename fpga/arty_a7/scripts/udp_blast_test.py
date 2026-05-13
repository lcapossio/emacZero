#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
"""
udp_blast_test.py - Trigger and measure the FPGA's UDP-blast generator.

Companion to rtl/net/udp_blast.v + the auto-trigger logic in arty_a7_top.v:

  1. Send one UDP "trigger" datagram to <board>:9997. The FPGA captures the
     trigger packet's source MAC + IP and enables a requested-length burst.
     Trigger payload is 3 bytes IFG delay + 4 bytes burst packet count +
     2 bytes destination UDP port override.
  2. Listen on UDP port 5002.  Each datagram from the FPGA
     starts with a 12-byte iperf2 UDP_datagram header — `id` (BE int32) is the
     sequence counter; we use it for loss / out-of-order accounting.
  3. Print per-second throughput + final summary.

If you have iperf2 installed (`iperf -u -s -p 5001 -i 1`) you can use that
instead — the FPGA emits packets in iperf2 v2 wire format. This script just
keeps the test self-contained when iperf isn't available.

Usage:
  python udp_blast_test.py                         # 12s burst, 1472B payload
  python udp_blast_test.py --secs 5
  python udp_blast_test.py --board 192.168.137.200 --listen-port 5001
"""
import argparse
import math
import socket
import struct
import sys
import threading
import time

BOARD_IP   = "192.168.137.200"
TRIGGER_PORT = 9997
LISTEN_PORT  = 5002
BLAST_PAYLOAD_BYTES = 1472


def receiver(listen_port, secs, stats, trigger_evt, board_ip):
    """Bind on listen_port and start counting. Once bound, fire the trigger
    *from the same socket* so the trigger's source port matches the listen
    port — Windows Firewall then sees the blast frames as part of the same
    UDP flow and lets them through."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 22)
    sock.bind(("", listen_port))
    sock.settimeout(0.2)

    trigger_payload = (
        stats["ifg_cycles"].to_bytes(3, "big") +
        stats["burst_packets"].to_bytes(4, "big") +
        listen_port.to_bytes(2, "big")
    )
    print(f"  listening on UDP port {listen_port}; firing trigger to {board_ip}:{TRIGGER_PORT}")
    sock.connect((board_ip, TRIGGER_PORT))
    sock.send(trigger_payload)
    trigger_evt.set()

    end = time.perf_counter() + secs + 2.0  # 2 s grace after the burst nominally ends
    last_seq = -1
    first_seq = None
    last_print = time.perf_counter()
    win_pkts = 0
    win_bytes = 0
    losses = 0
    out_of_order = 0
    rx_pkts = 0
    rx_bytes = 0
    rx_first_t = None
    rx_last_t  = 0.0
    while time.perf_counter() < end:
        try:
            data, _addr = sock.recvfrom(2048)
        except socket.timeout:
            now = time.perf_counter()
            if now - last_print >= 1.0:
                if win_bytes:
                    print(f"  [{now - rx_first_t if rx_first_t else 0:5.1f}s] "
                          f"{win_bytes*8/1e6 / max(now-last_print, 1e-6):6.2f} Mbps  "
                          f"{win_pkts:5d} pps")
                win_pkts  = 0
                win_bytes = 0
                last_print = now
            continue
        if len(data) != BLAST_PAYLOAD_BYTES:
            stats["ignored_pkts"] = stats.get("ignored_pkts", 0) + 1
            continue
        if rx_first_t is None:
            rx_first_t = time.perf_counter()
        rx_last_t = time.perf_counter()
        rx_pkts  += 1
        rx_bytes += len(data)
        win_pkts  += 1
        win_bytes += len(data)
        if len(data) >= 4:
            seq = struct.unpack(">I", data[:4])[0]
            if first_seq is None:
                first_seq = seq
            # Treat top bit as sign in iperf2 (last packet has id < 0); we
            # don't care for line-rate measurement.
            if last_seq >= 0:
                if seq == last_seq + 1:
                    pass
                elif seq > last_seq + 1:
                    losses += seq - last_seq - 1
                else:
                    out_of_order += 1
            last_seq = seq
        # Periodic banner — fall through to next iteration

    sock.close()
    stats["rx_pkts"]      = rx_pkts
    stats["rx_bytes"]     = rx_bytes
    stats["losses"]       = losses
    stats["out_of_order"] = out_of_order
    stats["first_seq"]    = first_seq
    stats["last_seq"]     = last_seq
    if rx_first_t and rx_last_t > rx_first_t:
        stats["dur_s"] = rx_last_t - rx_first_t
    else:
        stats["dur_s"] = 0.0


def main():
    ap = argparse.ArgumentParser(description="emacZero UDP blast (board → host) test")
    ap.add_argument("--board",       default=BOARD_IP)
    ap.add_argument("--listen-port", type=int, default=LISTEN_PORT)
    ap.add_argument("--secs",        type=float, default=15.0,
                    help="Receiver lifetime; matches the 1M-frame burst (~12s)")
    ap.add_argument("--ifg-cycles",  type=int, default=0,
                    help="Extra inter-frame delay in 100 MHz FPGA cycles (0 = line rate)")
    ap.add_argument("--burst-packets", type=int, default=None,
                    help="Override FPGA burst length; default matches --secs")
    args = ap.parse_args()

    if args.listen_port == TRIGGER_PORT:
        ap.error("--listen-port must differ from the trigger port")
    if args.listen_port == 5001:
        ap.error("--listen-port 5001 is reserved for host-to-FPGA iperf sink tests; use 5002 for the self-contained blast test")

    ifg_cycles = max(0, min(args.ifg_cycles, 0xFFFFFF))

    print("== emacZero UDP blast test (board -> host) ==")
    print(f"  Board       : {args.board}:{TRIGGER_PORT} (trigger)")
    print(f"  Listen      : UDP port {args.listen_port}")
    print(f"  Window      : {args.secs:.1f} s")
    print(f"  IFG delay   : {ifg_cycles} cycles")
    print()

    wire_len = BLAST_PAYLOAD_BYTES + 14 + 20 + 8 + 4 + 8 + 12
    frame_bits = wire_len * 8 + ifg_cycles
    fpga_pps = 100_000_000.0 / frame_bits
    burst_packets = args.burst_packets
    if burst_packets is None:
        burst_packets = int(math.ceil(max(args.secs, 0.001) * fpga_pps))
    burst_packets = max(1, min(burst_packets, 0xFFFFFFFF))

    wire_mbps = 100.0 * wire_len * 8 / frame_bits
    udp_mbps = wire_mbps * BLAST_PAYLOAD_BYTES / wire_len
    print(f"  Expected FPGA wire rate: {wire_mbps:.2f} Mbps")
    print(f"  Expected UDP payload   : {udp_mbps:.2f} Mbps")
    print(f"  Requested FPGA burst   : {burst_packets} packets ({burst_packets/fpga_pps:.2f} s)")
    print()

    stats = {"ifg_cycles": ifg_cycles, "burst_packets": burst_packets}
    trigger_evt = threading.Event()
    rx = threading.Thread(target=receiver,
                          args=(args.listen_port, args.secs, stats, trigger_evt, args.board),
                          daemon=True)
    rx.start()
    trigger_evt.wait(timeout=2.0)
    rx.join()

    print()
    print("-- results --")
    rx_pkts  = stats.get("rx_pkts", 0)
    rx_bytes = stats.get("rx_bytes", 0)
    dur      = stats.get("dur_s", 0.0)
    losses   = stats.get("losses", 0)
    ooo      = stats.get("out_of_order", 0)
    ignored  = stats.get("ignored_pkts", 0)
    first_seq = stats.get("first_seq", None)
    last_seq  = stats.get("last_seq", -1)

    print(f"  Received    : {rx_pkts} pkts, {rx_bytes/1e6:.2f} MB")
    if dur > 0:
        mbps = rx_bytes * 8 / dur / 1_000_000
        pps  = rx_pkts / dur
        print(f"  Duration    : {dur:.2f} s")
        print(f"  Throughput  : {mbps:.2f} Mbps   ({pps:.0f} pps)")
    if first_seq is not None and last_seq >= first_seq:
        print(f"  Sequence    : first={first_seq} last={last_seq} span={last_seq-first_seq+1}")
    print(f"  Losses      : {losses} dropped, {ooo} out-of-order")
    if ignored:
        print(f"  Ignored     : {ignored} non-blast datagrams")
    if rx_pkts > 0 and losses + rx_pkts > 0:
        loss_pct = 100.0 * losses / (rx_pkts + losses)
        print(f"  Loss rate   : {loss_pct:.3f}%")


if __name__ == "__main__":
    main()
