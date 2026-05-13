#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
"""
udp_blast_sniff.py - Wire-level capture of the FPGA UDP blast.

Uses scapy + Npcap to sniff packets directly off the host NIC, before any
Windows firewall / stack filtering. Determines whether the FPGA is actually
emitting line-rate UDP or whether the visible 3-packet ceiling is a host-side
filter.

Workflow:
  1. Bind a UDP socket on port 5001 and fire a "GO" trigger to the board:9997.
  2. Run scapy.sniff() on the host NIC for a few seconds.
  3. Filter for IP/UDP from 192.168.137.200 -> us:5001.
  4. Print packet count, bytes, computed Mbps, plus the first / last seq
     numbers in each capture.

Requires: pip install scapy ; Npcap (https://npcap.com) installed for sniffing.
"""
import argparse
import socket
import struct
import sys
import threading
import time

from scapy.all import sniff, IP, UDP, Raw, conf


BOARD_IP     = "192.168.137.200"
TRIGGER_PORT = 9997
LISTEN_PORT  = 5001
NIC          = "Ethernet 3"   # Realtek USB GbE @ 192.168.137.1


def trigger(board_ip, ifg_cycles):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.bind(("", LISTEN_PORT))
    except OSError:
        # Port may already be bound by another instance; trigger from
        # an ephemeral port and accept that the OS-level recv won't work.
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    payload = (
        max(0, min(ifg_cycles, 0xFFFFFF)).to_bytes(3, "big") +
        (1000000).to_bytes(4, "big") +
        LISTEN_PORT.to_bytes(2, "big")
    )
    sock.sendto(payload, (board_ip, TRIGGER_PORT))
    sock.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iface",   default=NIC)
    ap.add_argument("--secs",    type=float, default=15.0)
    ap.add_argument("--board",   default=BOARD_IP)
    ap.add_argument("--ifg-cycles", type=int, default=0,
                    help="Extra inter-frame delay in 100 MHz FPGA cycles (0 = line rate)")
    args = ap.parse_args()

    print(f"== UDP blast wire-level sniff ==")
    print(f"  Iface  : {args.iface}")
    print(f"  Board  : {args.board}")
    print(f"  Window : {args.secs:.1f}s")
    wire_len = 1472 + 14 + 20 + 8 + 4 + 8 + 12
    exp_wire_mbps = 100.0 * wire_len / (wire_len + max(args.ifg_cycles, 0) * 0.125)
    exp_udp_mbps = exp_wire_mbps * 1472 / wire_len
    print(f"  IFG    : {args.ifg_cycles} cycles")
    print(f"  Expect : {exp_wire_mbps:.2f} Mbps wire, {exp_udp_mbps:.2f} Mbps UDP payload")
    print()

    # Set scapy capture iface; tolerate missing iface (Npcap permission issues)
    try:
        conf.iface = args.iface
    except Exception as e:
        print(f"  warning: setting conf.iface failed ({e}); falling back to default")

    # Counters that the sniff callback updates
    counters = {
        "rx_pkts":    0,
        "rx_bytes":   0,
        "first_seq":  None,
        "last_seq":   None,
        "min_seq":    None,
        "max_seq":    None,
        "first_t":    None,
        "last_t":     None,
        "missing":    0,
        "any_pkts":   0,  # packets seen at all (any direction, any port)
        "truncated":  0,
    }

    counters["dump_remain"] = 5

    def cb(pkt):
        counters["any_pkts"] += 1
        if IP in pkt and UDP in pkt and pkt[IP].src == args.board and pkt[UDP].dport == LISTEN_PORT:
            counters["rx_pkts"]  += 1
            wire_len = getattr(pkt, "wirelen", len(pkt)) or len(pkt)
            cap_len = len(pkt)
            counters["rx_bytes"] += wire_len
            if cap_len < wire_len:
                counters["truncated"] += 1
            now = time.perf_counter()
            if counters["first_t"] is None:
                counters["first_t"] = now
            counters["last_t"] = now
            payload = bytes(pkt[UDP].payload)
            if counters["dump_remain"] > 0:
                counters["dump_remain"] -= 1
                hex_first = " ".join(f"{b:02x}" for b in payload[:24])
                ip_tot = pkt[IP].len
                udp_len = pkt[UDP].len
                print(f"  pkt#{counters['rx_pkts']} cap={cap_len} wire={wire_len} ip.len={ip_tot} udp.len={udp_len} payload={len(payload)} first24={hex_first}")
            if len(payload) >= 4:
                seq = struct.unpack(">I", payload[:4])[0]
                if counters["first_seq"] is None:
                    counters["first_seq"] = seq
                if counters["last_seq"] is not None and seq != counters["last_seq"] + 1:
                    counters["missing"] += abs(seq - counters["last_seq"] - 1)
                counters["last_seq"] = seq
                if counters["min_seq"] is None or seq < counters["min_seq"]:
                    counters["min_seq"] = seq
                if counters["max_seq"] is None or seq > counters["max_seq"]:
                    counters["max_seq"] = seq

    # Trigger the burst from a worker so we can start sniff() in this thread
    def fire_trigger():
        time.sleep(0.5)  # give sniff() time to start
        print(f"  triggering blast (ifg_cycles={args.ifg_cycles})...")
        trigger(args.board, args.ifg_cycles)

    t = threading.Thread(target=fire_trigger, daemon=True)
    t.start()

    print(f"  starting sniff on {args.iface} for {args.secs:.1f}s...")
    try:
        sniff(prn=cb, store=False, timeout=args.secs, iface=args.iface,
              filter="udp")
    except Exception as e:
        print(f"  iface-specific sniff failed ({e}); retrying with default iface")
        sniff(prn=cb, store=False, timeout=args.secs, filter="udp")

    rx = counters["rx_pkts"]
    if rx == 0:
        print()
        print("  No matching UDP packets seen on the wire.")
        print(f"  ({counters['any_pkts']} packets total during capture window.)")
        print()
        print("  -> Either the FPGA isn't transmitting or the iface is wrong.")
        return

    dur = (counters["last_t"] or 0) - (counters["first_t"] or 0)
    if dur <= 0:
        dur = args.secs

    mbps = counters["rx_bytes"] * 8 / dur / 1_000_000 if dur > 0 else 0
    pps  = rx / dur if dur > 0 else 0

    seq_span = (counters["max_seq"] or 0) - (counters["min_seq"] or 0) + 1
    expected_pkts = seq_span if counters["min_seq"] is not None else rx

    print()
    print("-- wire-level results --")
    print(f"  Total packets seen on iface : {counters['any_pkts']}")
    print(f"  Matching board UDP frames   : {rx}")
    print(f"  Bytes (incl L2 hdr/FCS)     : {counters['rx_bytes']:,}")
    print(f"  Capture-truncated packets   : {counters['truncated']}")
    print(f"  Active duration             : {dur*1000:.1f} ms")
    print(f"  Wire throughput             : {mbps:.2f} Mbps   ({pps:.0f} pps)")
    print(f"  First seq / last seq        : {counters['first_seq']} / {counters['last_seq']}")
    print(f"  Seq span (max-min+1)        : {expected_pkts}")
    print(f"  Gaps in seq sequence        : {counters['missing']}")
    if expected_pkts > 0:
        print(f"  Capture-vs-span ratio       : {100.0*rx/expected_pkts:.2f}%")


if __name__ == "__main__":
    main()
