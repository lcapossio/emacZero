#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
"""
udp_bidirectional_test.py - Python-only bidirectional UDP throughput test.

Direction A, FPGA -> host:
  - Bind UDP/5002.
  - Send a UDP/9997 trigger from that same socket.
  - Count the FPGA's iperf2-format blast packets.

Direction B, host -> FPGA:
  - Clear FPGA iperf sink counters on UDP/9996.
  - Send iperf2-format UDP payloads to FPGA UDP/5001.
  - Query FPGA counters and print the receiver-side result.

This avoids host iperf/firewall quirks while still using the same FPGA RTL
interfaces and the same iperf2 UDP_datagram payload header format.
"""

import argparse
import math
import multiprocessing as mp
import queue
import socket
import struct
import time


BOARD_IP = "192.168.137.200"
HOST_LISTEN_PORT = 5002
FPGA_IPERF_PORT = 5001
FPGA_TRIGGER_PORT = 9997
FPGA_STATS_PORT = 9996
PAYLOAD_BYTES = 1472


def query_stats(board_ip, command, timeout):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        sock.sendto(command.encode("ascii"), (board_ip, FPGA_STATS_PORT))
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


def fpga_to_host_receiver(args, ready_evt, result_queue):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 22)
    sock.bind((args.bind, args.listen_port))
    sock.settimeout(0.2)

    burst_packets = args.fpga_packets
    if burst_packets is None:
        wire_len = PAYLOAD_BYTES + 14 + 20 + 8 + 4 + 8 + 12
        pps = 100_000_000.0 / (wire_len * 8 + args.fpga_ifg_cycles)
        burst_packets = max(1, int(math.ceil(args.secs * pps)))

    trigger_payload = (
        int(args.fpga_ifg_cycles).to_bytes(3, "big") +
        int(burst_packets).to_bytes(4, "big") +
        int(args.listen_port).to_bytes(2, "big")
    )

    sock.connect((args.board, FPGA_TRIGGER_PORT))
    sock.send(trigger_payload)
    ready_evt.set()

    end = time.perf_counter() + args.secs + args.rx_grace
    first_t = None
    last_t = None
    first_seq = None
    last_seq = None
    rx_pkts = 0
    rx_bytes = 0
    seq_gaps = 0
    out_of_order = 0
    ignored = 0

    while time.perf_counter() < end:
        try:
            data = sock.recv(2048)
        except socket.timeout:
            continue

        if len(data) != PAYLOAD_BYTES:
            ignored += 1
            continue

        now = time.perf_counter()
        if first_t is None:
            first_t = now
        last_t = now
        rx_pkts += 1
        rx_bytes += len(data)

        seq = struct.unpack(">I", data[:4])[0]
        if first_seq is None:
            first_seq = seq
        elif last_seq is not None:
            if seq == last_seq + 1:
                pass
            elif seq > last_seq + 1:
                seq_gaps += seq - last_seq - 1
            else:
                out_of_order += 1
        last_seq = seq

    sock.close()

    dur = (last_t - first_t) if first_t is not None and last_t and last_t > first_t else 0.0
    result_queue.put({
        "requested": burst_packets,
        "packets": rx_pkts,
        "bytes": rx_bytes,
        "duration": dur,
        "mbps": (rx_bytes * 8 / dur / 1_000_000) if dur > 0 else 0.0,
        "first_seq": first_seq,
        "last_seq": last_seq,
        "seq_gaps": seq_gaps,
        "out_of_order": out_of_order,
        "ignored": ignored,
    })


def host_to_fpga_sender(args, start_evt, result_queue):
    start_evt.wait(timeout=3.0)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 20)
    sock.connect((args.board, FPGA_IPERF_PORT))

    interval = (PAYLOAD_BYTES * 8) / (args.host_mbps * 1_000_000.0)
    start = time.perf_counter()
    end = start + args.secs
    next_send = start
    seq = 0
    sent_bytes = 0
    filler = bytes((i & 0xff) for i in range(PAYLOAD_BYTES - 12))

    while time.perf_counter() < end:
        now = time.time()
        sec = int(now)
        usec = int((now - sec) * 1_000_000)
        sock.send(struct.pack(">III", seq, sec, usec) + filler)
        seq += 1
        sent_bytes += PAYLOAD_BYTES

        next_send += interval
        while True:
            remaining = next_send - time.perf_counter()
            if remaining <= 0:
                break
            if remaining > 0.002:
                time.sleep(remaining / 2)

    elapsed = time.perf_counter() - start
    sock.close()
    result_queue.put({
        "sent_packets": seq,
        "sent_bytes": sent_bytes,
        "mbps": sent_bytes * 8 / elapsed / 1_000_000 if elapsed > 0 else 0.0,
    })


def pct(numer, denom):
    return (100.0 * numer / denom) if denom else 0.0


def main():
    parser = argparse.ArgumentParser(description="Python bidirectional UDP test for emacZero Arty")
    parser.add_argument("--board", default=BOARD_IP, help="FPGA IPv4 address")
    parser.add_argument("--bind", default="", help="local bind address for FPGA->host receive")
    parser.add_argument("--listen-port", type=int, default=HOST_LISTEN_PORT)
    parser.add_argument("--secs", type=float, default=5.0)
    parser.add_argument("--host-mbps", type=float, default=50.0,
                        help="host->FPGA UDP payload target rate")
    parser.add_argument("--fpga-packets", type=int, default=None,
                        help="FPGA->host burst packets; default derives from --secs")
    parser.add_argument("--fpga-ifg-cycles", type=int, default=14000)
    parser.add_argument("--rx-grace", type=float, default=3.0)
    parser.add_argument("--min-mbps", type=float, default=40.0,
                        help="minimum acceptable measured payload Mbps per direction")
    parser.add_argument("--max-loss-pct", type=float, default=5.0)
    parser.add_argument("--timeout", type=float, default=3.0)
    args = parser.parse_args()

    print("== emacZero bidirectional UDP test (Python) ==")
    print(f"  Board         : {args.board}")
    print(f"  FPGA -> host  : UDP/{args.listen_port}")
    print(f"  Host -> FPGA  : UDP/{FPGA_IPERF_PORT}, target {args.host_mbps:.1f} Mbps")
    print(f"  Window        : {args.secs:.1f} s")
    print()

    query_stats(args.board, "C", args.timeout)

    ctx = mp.get_context("spawn")
    ready_evt = ctx.Event()
    fpga_rx_queue = ctx.Queue()
    host_tx_queue = ctx.Queue()
    rx_proc = ctx.Process(target=fpga_to_host_receiver, args=(args, ready_evt, fpga_rx_queue))
    tx_proc = ctx.Process(target=host_to_fpga_sender, args=(args, ready_evt, host_tx_queue))

    rx_proc.start()
    tx_proc.start()
    tx_proc.join()
    rx_proc.join()
    try:
        fpga_rx = fpga_rx_queue.get(timeout=1.0)
    except queue.Empty:
        fpga_rx = {}
    try:
        host_tx = host_tx_queue.get(timeout=1.0)
    except queue.Empty:
        host_tx = {}

    stats = query_stats(args.board, "G", args.timeout)

    print("-- FPGA -> host --")
    print(f"  Received      : {fpga_rx.get('packets', 0)} / {fpga_rx.get('requested', 0)} packets")
    print(f"  Throughput    : {fpga_rx.get('mbps', 0.0):.2f} Mbps")
    print(f"  Sequence      : first={fpga_rx.get('first_seq')} last={fpga_rx.get('last_seq')}")
    print(f"  Gaps/OOO      : {fpga_rx.get('seq_gaps', 0)} gaps, {fpga_rx.get('out_of_order', 0)} out-of-order")

    print()
    print("-- Host -> FPGA --")
    fpga_observed_mbps = stats["bytes"] * 8 / args.secs / 1_000_000
    print(f"  Sent target   : {host_tx.get('sent_packets', 0)} packets, {host_tx.get('mbps', 0.0):.2f} Mbps")
    print(f"  FPGA counted  : {stats['packets']} packets, {stats['bytes']} bytes")
    print(f"  FPGA observed : {fpga_observed_mbps:.2f} Mbps")
    print(f"  Sequence      : first={stats['first_seq']} last={stats['last_seq']}")
    print(f"  Gaps/OOO      : {stats['seq_gaps']} gaps, {stats['out_of_order']} out-of-order")

    fpga_loss = fpga_rx.get("seq_gaps", 0)
    fpga_total = fpga_rx.get("packets", 0) + fpga_loss
    host_loss = max(0, host_tx.get("sent_packets", 0) - stats["packets"])
    host_total = host_tx.get("sent_packets", 0)

    fpga_pass = (
        fpga_rx.get("packets", 0) > 0 and
        fpga_rx.get("mbps", 0.0) >= args.min_mbps and
        pct(fpga_loss, fpga_total) <= args.max_loss_pct and
        fpga_rx.get("out_of_order", 0) == 0
    )
    host_pass = (
        stats["packets"] > 0 and
        fpga_observed_mbps >= args.min_mbps and
        pct(host_loss, host_total) <= args.max_loss_pct
    )

    print()
    print("-- summary --")
    print(f"  FPGA -> host  : {'PASS' if fpga_pass else 'FAIL'}")
    print(f"  Host -> FPGA  : {'PASS' if host_pass else 'FAIL'}")
    if not (fpga_pass and host_pass):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
