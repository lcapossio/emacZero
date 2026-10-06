#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
"""
sfp_perf_test.py - 1 Gb/s throughput test of the ZCU106 SFP0 demo from a host.

The demo (zcu106_eth_demo.v) has the throughput blocks of the Arty demo:
  UDP/9997  blast trigger: the FPGA sends a bounded, back-to-back burst of
            iperf2-format datagrams to the socket that sent the trigger
  UDP/5001  iperf2 UDP sink, counting packets, bytes and sequence gaps
  UDP/9996  sink stats ("G" read, "C" read and clear)

Tests (--tests, comma separated; default rx,tx,duplex):
  rx      FPGA -> host, 1472-byte payloads at line rate. Every datagram is
          received and checked for sequence; the NIC's own counters are read
          too, so a host that cannot keep up shows as host drops, not as link
          loss.
  tx      host -> FPGA, 1472-byte payloads as fast as the host sends; the FPGA
          counts what arrived.
  duplex  rx and tx at the same time.
  sweep   (information only) one second of line-rate frames from the FPGA at
          each of 1518, 1024, 512, 256, 128 and 64 bytes, counted by the NIC.
          A host receive path has a frame-rate ceiling, so the small sizes
          show the host's limit rather than the link's.

A packet the host stack sends out of order arrives late at the FPGA: the
sink counts a sequence gap and then an out-of-order packet. The tx checks
pass when every packet and byte arrived; reorders are reported, not failed.

Line rate for 1472-byte UDP payloads is 81,274 frames/s, 957.1 Mb/s of UDP
payload (987 Mb/s of Ethernet frames, 1000 Mb/s on the wire).

The host NIC needs an address on the demo's subnet, e.g. 192.168.137.1/24.
NIC counters are read with PowerShell on Windows and from sysfs on Linux
(--nic names the interface; omit it to skip them).

Usage:
  python fpga/zcu106/scripts/sfp_perf_test.py --nic <interface>
  python fpga/zcu106/scripts/sfp_perf_test.py --nic <interface> --tests rx --count 5000000
"""

import argparse
import json
import os
import socket
import struct
import subprocess
import sys
import threading
import time

BOARD_IP = "192.168.137.200"
TRIGGER_PORT = 9997
SINK_PORT = 5001
STATS_PORT = 9996
LISTEN_PORT = 5002

ETH_OVERHEAD = 14 + 20 + 8 + 4 + 8 + 12   # MAC hdr, IP, UDP, FCS, preamble, IFG


def line_rate_fps(payload):
    return 125_000_000 / (payload + ETH_OVERHEAD)


def mbps(nbytes, secs):
    return nbytes * 8 / secs / 1e6 if secs > 0 else 0.0


# --------------------------------------------------------------------------
# NIC counters
# --------------------------------------------------------------------------
def nic_counters(nic):
    if not nic:
        return None
    if sys.platform.startswith("win"):
        cmd = ("Get-NetAdapterStatistics -Name '%s' | Select-Object "
               "ReceivedUnicastPackets,ReceivedBytes,ReceivedDiscardedPackets,"
               "ReceivedPacketErrors,SentUnicastPackets,SentBytes,"
               "OutboundDiscardedPackets,OutboundPacketErrors | ConvertTo-Json" % nic)
        ps = os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32",
                          "WindowsPowerShell", "v1.0", "powershell.exe")
        out = subprocess.run([ps, "-NoProfile", "-Command", cmd],
                             capture_output=True, text=True, timeout=30)
        if out.returncode != 0 or not out.stdout.strip():
            raise RuntimeError("cannot read NIC counters for %r: %s" % (nic, out.stderr.strip()))
        d = json.loads(out.stdout)
        return {
            "rx_pkts": d["ReceivedUnicastPackets"], "rx_bytes": d["ReceivedBytes"],
            "rx_drop": d["ReceivedDiscardedPackets"], "rx_err": d["ReceivedPacketErrors"],
            "tx_pkts": d["SentUnicastPackets"], "tx_bytes": d["SentBytes"],
            "tx_drop": d["OutboundDiscardedPackets"], "tx_err": d["OutboundPacketErrors"],
        }
    base = "/sys/class/net/%s/statistics/" % nic

    def rd(n):
        with open(base + n) as fh:
            return int(fh.read())
    return {
        "rx_pkts": rd("rx_packets"), "rx_bytes": rd("rx_bytes"),
        "rx_drop": rd("rx_dropped"), "rx_err": rd("rx_errors"),
        "tx_pkts": rd("tx_packets"), "tx_bytes": rd("tx_bytes"),
        "tx_drop": rd("tx_dropped"), "tx_err": rd("tx_errors"),
    }


def nic_delta(a, b):
    if a is None or b is None:
        return None
    return {k: b[k] - a[k] for k in a}


# --------------------------------------------------------------------------
# FPGA sink stats
# --------------------------------------------------------------------------
def query_stats(board, command, timeout=1.0, tries=5):
    for _ in range(tries):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(timeout)
        try:
            sock.sendto(command.encode("ascii"), (board, STATS_PORT))
            data, _ = sock.recvfrom(256)
        except socket.timeout:
            continue
        finally:
            sock.close()
        if len(data) != 44 or data[:4] != b"IPS0" or data[40:44] != b"DONE":
            raise RuntimeError("unexpected stats reply: " + data.hex())
        f = struct.unpack("!7I I H H", data[4:40])
        return {"packets": f[0], "bytes": f[1], "first_seq": f[2], "last_seq": f[3],
                "seq_gaps": f[4], "out_of_order": f[5]}
    raise RuntimeError("no stats reply from %s:%d" % (board, STATS_PORT))


# --------------------------------------------------------------------------
# FPGA -> host
# --------------------------------------------------------------------------
class BlastReceiver:
    """Trigger a blast from a bound socket and count what comes back."""

    def __init__(self, board, port, count, payload, idle_timeout):
        self.board, self.count, self.payload = board, count, payload
        self.idle_timeout = idle_timeout
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 64 << 20)
        self.sock.bind(("", port))
        self.port = port
        self.result = None

    def trigger(self):
        trig = struct.pack("!3sIHH", b"\x00\x00\x00", self.count, self.port, self.payload)
        self.sock.sendto(trig, (self.board, TRIGGER_PORT))

    def run(self):
        buf = bytearray(2048)
        recv_into = self.sock.recv_into
        n = nbytes = bad_len = gaps = ooo = 0
        expect = 0
        t_first = t_last = None
        self.sock.settimeout(3.0)            # wait for the first datagram
        try:
            while n < self.count:
                k = recv_into(buf)
                t = time.perf_counter()
                if t_first is None:
                    t_first = t
                    self.sock.settimeout(self.idle_timeout)
                t_last = t
                n += 1
                nbytes += k
                if k != self.payload:
                    bad_len += 1
                seq = (buf[0] << 24) | (buf[1] << 16) | (buf[2] << 8) | buf[3]
                if seq != expect:
                    if seq > expect:
                        gaps += seq - expect
                    else:
                        ooo += 1
                expect = seq + 1
        except socket.timeout:
            pass
        self.sock.close()
        secs = (t_last - t_first) if (t_first and t_last and t_last > t_first) else 0.0
        self.result = {"received": n, "bytes": nbytes, "bad_len": bad_len,
                       "seq_gaps": gaps, "out_of_order": ooo, "secs": secs,
                       "last_seq": expect - 1}


def report_rx(name, count, payload, r, nic_d):
    ideal = line_rate_fps(payload)
    print("[%s] FPGA -> host, %d x %d-byte payload" % (name, count, payload))
    rate = r["received"] / r["secs"] if r["secs"] else 0
    print("  host app: %d received (%.4f%% lost), %.1f Mb/s payload, %.0f frames/s "
          "(%.2f%% of line rate), seq gaps %d, out of order %d, bad length %d"
          % (r["received"], 100.0 * (count - r["received"]) / count,
             mbps(r["bytes"], r["secs"]), rate, 100.0 * rate / ideal,
             r["seq_gaps"], r["out_of_order"], r["bad_len"]))
    ok = r["out_of_order"] == 0 and r["bad_len"] == 0
    if nic_d is not None:
        # The NIC decides link loss: datagrams the host app missed but the
        # NIC received are host drops. Other traffic on the port can add a
        # few frames; none may go missing.
        print("  NIC: %d frames received (%+d vs sent), rx errors %d, rx discards %d"
              % (nic_d["rx_pkts"], nic_d["rx_pkts"] - count, nic_d["rx_err"], nic_d["rx_drop"]))
        ok &= nic_d["rx_pkts"] >= count and nic_d["rx_err"] == 0
    else:
        ok &= r["received"] == count
    print("  %s" % ("PASS" if ok else "FAIL"))
    return ok


def test_rx(args, payload, count):
    nic0 = nic_counters(args.nic)
    rx = BlastReceiver(args.board, args.listen_port, count, payload, args.idle_timeout)
    th = threading.Thread(target=rx.run)
    th.start()
    rx.trigger()
    th.join()
    nic1 = nic_counters(args.nic)
    return report_rx("rx", count, payload, rx.result, nic_delta(nic0, nic1))


def test_sweep(args):
    """One second of line-rate frames per size, counted by the NIC."""
    if not args.nic:
        print("[sweep] needs --nic; skipped")
        return
    print("[sweep] FPGA -> host, 1 s of line-rate frames per size (NIC counters)")
    for payload in (1472, 978, 466, 210, 82, 18):
        fps = line_rate_fps(payload)
        count = int(fps)
        nic0 = nic_counters(args.nic)
        rx = BlastReceiver(args.board, args.listen_port, count, payload, args.idle_timeout)
        rx.trigger()
        last, d = None, None
        while True:                       # until the count stops moving
            time.sleep(1.5)
            d = nic_delta(nic0, nic_counters(args.nic))
            if d["rx_pkts"] == last:
                break
            last = d["rx_pkts"]
        rx.sock.close()
        print("  %4d-byte frames, %7.0f frames/s: NIC received %7d of %7d (%6.2f%%), "
              "discards %d" % (payload + 46, fps, d["rx_pkts"], count,
                               100.0 * d["rx_pkts"] / count, d["rx_drop"]))


# --------------------------------------------------------------------------
# host -> FPGA
# --------------------------------------------------------------------------
def send_iperf(board, count, payload, mbps_limit, out):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 8 << 20)
    sock.connect((board, SINK_PORT))
    pkt = bytearray(payload)
    send = sock.send
    pack = struct.pack_into
    gap = (payload * 8 / (mbps_limit * 1e6)) if mbps_limit else 0.0
    sent = errors = 0
    t0 = time.perf_counter()
    next_t = t0
    for i in range(count):
        pack("!I", pkt, 0, i)
        try:
            send(pkt)
            sent += 1
        except OSError:
            errors += 1
        if gap:
            next_t += gap
            while time.perf_counter() < next_t:
                pass
    secs = time.perf_counter() - t0
    sock.close()
    out.update({"sent": sent, "errors": errors, "secs": secs})


def report_tx(name, payload, s, st, nic_d):
    ideal = line_rate_fps(payload)
    rate = s["sent"] / s["secs"] if s["secs"] else 0
    print("[%s] host -> FPGA, %d x %d-byte payload" % (name, s["sent"], payload))
    print("  host sent: %d in %.2f s, %.1f Mb/s payload, %.0f frames/s (%.2f%% of line rate), "
          "send errors %d" % (s["sent"], s["secs"], mbps(s["sent"] * payload, s["secs"]),
                              rate, 100.0 * rate / ideal, s["errors"]))
    if nic_d is not None:
        print("  NIC: %d frames sent, tx errors %d, tx discards %d"
              % (nic_d["tx_pkts"], nic_d["tx_err"], nic_d["tx_drop"]))
    lost = s["sent"] - st["packets"]
    print("  FPGA counted: %d packets, %d bytes mod 2^32 (%d lost), seq gaps %d, out of order %d%s"
          % (st["packets"], st["bytes"], lost, st["seq_gaps"], st["out_of_order"],
             " (reordered by the host, none lost)"
             if lost == 0 and st["out_of_order"] else ""))
    # The FPGA counters are 32 bits: compare bytes modulo 2^32 (a 10-minute
    # line-rate run is about 72 GB).
    ok = (lost == 0 and st["bytes"] == (s["sent"] * payload) & 0xFFFFFFFF
          and st["seq_gaps"] <= st["out_of_order"])
    print("  %s" % ("PASS" if ok else "FAIL"))
    return ok


def test_tx(args):
    query_stats(args.board, "C")
    nic0 = nic_counters(args.nic)
    s = {}
    send_iperf(args.board, args.count, 1472, args.tx_mbps, s)
    time.sleep(0.5)
    st = query_stats(args.board, "G")
    nic1 = nic_counters(args.nic)
    return report_tx("tx", 1472, s, st, nic_delta(nic0, nic1))


def test_duplex(args):
    query_stats(args.board, "C")
    nic0 = nic_counters(args.nic)
    rx = BlastReceiver(args.board, args.listen_port, args.count, 1472, args.idle_timeout)
    th = threading.Thread(target=rx.run)
    th.start()
    rx.trigger()
    s = {}
    send_iperf(args.board, args.count, 1472, args.tx_mbps, s)
    th.join()
    time.sleep(0.5)
    st = query_stats(args.board, "G")
    nic1 = nic_counters(args.nic)
    d = nic_delta(nic0, nic1)
    ok_rx = report_rx("duplex", args.count, 1472, rx.result, d)
    ok_tx = report_tx("duplex", 1472, s, st, d)
    return ok_rx and ok_tx


def main():
    ap = argparse.ArgumentParser(description="ZCU106 SFP0 1 Gb/s throughput test")
    ap.add_argument("--board", default=BOARD_IP)
    ap.add_argument("--nic", default=None,
                    help="host interface facing the board, for NIC counters")
    ap.add_argument("--tests", default="rx,tx,duplex")
    ap.add_argument("--count", type=int, default=1_000_000,
                    help="frames per direction for rx / tx / duplex (default 1,000,000)")
    ap.add_argument("--tx-mbps", type=float, default=0.0,
                    help="pace host -> FPGA payload rate (0 = as fast as possible)")
    ap.add_argument("--listen-port", type=int, default=LISTEN_PORT)
    ap.add_argument("--idle-timeout", type=float, default=1.0)
    args = ap.parse_args()

    tests = [t.strip() for t in args.tests.split(",") if t.strip()]
    print("Board %s, NIC %s, line rate at 1472 B: %.0f frames/s, %.1f Mb/s payload"
          % (args.board, args.nic or "(not read)", line_rate_fps(1472),
             mbps(line_rate_fps(1472) * 1472, 1.0)))
    query_stats(args.board, "G")              # reachable at all?
    results = {}
    for t in tests:
        if t == "rx":
            results[t] = test_rx(args, 1472, args.count)
        elif t == "sweep":
            test_sweep(args)
            continue
        elif t == "tx":
            results[t] = test_tx(args)
        elif t == "duplex":
            results[t] = test_duplex(args)
        else:
            ap.error("unknown test %r" % t)
        time.sleep(0.5)
    print()
    for t, ok in results.items():
        print("%-7s %s" % (t, "PASS" if ok else "FAIL"))
    return 0 if all(results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
