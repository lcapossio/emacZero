#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
"""
scapy_test.py - Low-level Ethernet test for emacZero board.

Uses scapy to send raw ARP/ICMP frames and capture replies, bypassing the OS
network stack. Requires admin/root privileges and Npcap on Windows.

Usage: python scapy_test.py [iface]
"""

import sys
import time
from scapy.all import (
    Ether, ARP, IP, ICMP, Raw,
    srp1, sr1, sniff, sendp, get_if_list, get_if_hwaddr, conf,
)

BOARD_IP  = "192.168.137.200"
BOARD_MAC = "02:00:00:00:00:01"
HOST_IP   = "192.168.137.1"


def find_iface():
    """Find the Ethernet 3 interface name (Npcap GUID format)."""
    # Try by IP address first
    from scapy.arch.windows import get_windows_if_list
    for ifc in get_windows_if_list():
        ips = ifc.get("ips", [])
        if HOST_IP in ips:
            return ifc["name"]
    return None


def test_arp(iface):
    """Send ARP request, capture reply, validate."""
    print(f"\n[ARP Test] Sending ARP request for {BOARD_IP} on {iface}")
    arp_req = Ether(dst="ff:ff:ff:ff:ff:ff") / ARP(pdst=BOARD_IP, psrc=HOST_IP)
    reply = srp1(arp_req, iface=iface, timeout=2, verbose=0)
    if reply is None:
        print("  FAIL: No ARP reply received")
        return False
    if not reply.haslayer(ARP):
        print(f"  FAIL: Reply is not ARP: {reply.summary()}")
        return False
    arp = reply[ARP]
    print(f"  Received ARP reply:")
    print(f"    op       = {arp.op} ({'is-at' if arp.op == 2 else 'who-has'})")
    print(f"    hwsrc    = {arp.hwsrc}")
    print(f"    psrc     = {arp.psrc}")
    print(f"    hwdst    = {arp.hwdst}")
    print(f"    pdst     = {arp.pdst}")
    if arp.op != 2:
        print(f"  FAIL: Expected op=2 (reply), got op={arp.op}")
        return False
    if arp.hwsrc.lower() != BOARD_MAC.lower():
        print(f"  FAIL: Expected hwsrc={BOARD_MAC}, got {arp.hwsrc}")
        return False
    if arp.psrc != BOARD_IP:
        print(f"  FAIL: Expected psrc={BOARD_IP}, got {arp.psrc}")
        return False
    print(f"  PASS")
    return True


def test_icmp(iface, count=5):
    """Send ICMP echo requests, capture replies, validate."""
    print(f"\n[ICMP Test] Sending {count} ICMP echo requests to {BOARD_IP}")
    received = 0
    for seq in range(count):
        pkt = Ether(dst=BOARD_MAC) / IP(dst=BOARD_IP, src=HOST_IP) / \
              ICMP(type=8, id=0xBEEF, seq=seq) / Raw(load=b"emacZero" * 4)
        reply = srp1(pkt, iface=iface, timeout=2, verbose=0)
        if reply is None:
            print(f"  seq={seq}: TIMEOUT")
            continue
        if not reply.haslayer(ICMP):
            print(f"  seq={seq}: not ICMP: {reply.summary()}")
            continue
        icmp = reply[ICMP]
        ip = reply[IP]
        if icmp.type != 0:
            print(f"  seq={seq}: not echo reply (type={icmp.type})")
            continue
        if ip.src != BOARD_IP:
            print(f"  seq={seq}: wrong src IP: {ip.src}")
            continue
        if icmp.seq != seq:
            print(f"  seq={seq}: wrong seq in reply: {icmp.seq}")
            continue
        # Check checksums
        # Force scapy to recompute and compare
        orig_chk = icmp.chksum
        del icmp.chksum
        recomputed = ICMP(bytes(icmp)).chksum
        if orig_chk != recomputed:
            print(f"  seq={seq}: BAD ICMP checksum (got 0x{orig_chk:04x}, "
                  f"expected 0x{recomputed:04x})")
            continue
        print(f"  seq={seq}: PASS  ({len(reply)} bytes, ttl={ip.ttl})")
        received += 1
    print(f"  Result: {received}/{count} valid ICMP echo replies")
    return received == count


def sniff_test(iface, duration=3):
    """Just sniff what comes from the board."""
    print(f"\n[Sniff Test] Capturing frames from {BOARD_MAC} for {duration}s")
    pkts = sniff(iface=iface, filter=f"ether src {BOARD_MAC}",
                 timeout=duration, store=True)
    print(f"  Captured {len(pkts)} frame(s) from board")
    for i, p in enumerate(pkts[:5]):
        print(f"    [{i}] {p.summary()}")
    return len(pkts) > 0


def main():
    iface = sys.argv[1] if len(sys.argv) > 1 else find_iface()
    if iface is None:
        print("ERROR: Could not auto-detect interface. Available:")
        for n in get_if_list():
            print(f"  {n}")
        sys.exit(1)
    print(f"Using interface: {iface}")
    try:
        print(f"  Host MAC: {get_if_hwaddr(iface)}")
    except Exception as e:
        print(f"  (could not get host MAC: {e})")

    arp_ok  = test_arp(iface)
    if arp_ok:
        icmp_ok = test_icmp(iface, count=5)
    else:
        icmp_ok = False
        print("\n[ICMP Test] SKIPPED (no ARP reply)")

    # Always do a passive sniff to see if board is sending anything at all
    sniff_test(iface, duration=3)

    print("\n" + "=" * 50)
    if arp_ok and icmp_ok:
        print("  ALL TESTS PASSED")
        sys.exit(0)
    else:
        print(f"  ARP: {'PASS' if arp_ok else 'FAIL'}")
        print(f"  ICMP: {'PASS' if icmp_ok else 'FAIL'}")
        sys.exit(1)


if __name__ == "__main__":
    main()
