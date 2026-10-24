#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""linux_bench.py - Throughput and accounting benchmark of the Linux driver.

Runs iperf3 from a host against a board that runs the emaczero driver, and
reads the board's counters before and after every test: the MAC's own
counters (ethtool -S), the interface's packet counts, kernel messages, BQL
and free memory. For each test it checks that the MAC and the interface
agree: TX frames the MAC sent against packets the interface sent, and RX
frames the MAC received minus its RX overflow count against packets the
interface received.

Tests (--tests, comma separated; default tcp-rx,tcp-tx,udp-rx,udp-tx,bidir):
  tcp-rx    TCP, host -> board (the board receives)
  tcp-tx    TCP, board -> host (iperf3 -R)
  udp-rx    UDP 1472-byte datagrams at --udp-rate, host -> board
  udp-tx    the same, board -> host
  bidir     TCP in both directions at once (iperf3 --bidir)
  soak      bidir for --soak seconds

The board needs iperf3, ethtool and a shell reachable either over a serial
console (--serial, needs pyserial) or over ssh (--ssh). The script starts
iperf3 -s on the board if it is not running. Without either option the
board's counters are not read and only the iperf3 results are reported.

iperf3 is searched in PATH; --iperf3 overrides it (for example "wsl iperf3"
on Windows). Bind the host side with --bind when the host has more than one
route to the board.

Usage:
  python sw/linux/scripts/linux_bench.py --board 192.168.237.50 \\
      --bind 192.168.237.1 --serial /dev/ttyUSB1 --out results.md
  python sw/linux/scripts/linux_bench.py --board 192.168.237.50 --ssh root@192.168.237.50 \\
      --tests soak --soak 300
"""
import argparse
import datetime
import json
import shlex
import subprocess
import sys
import time

MARK = "__EMZ_BENCH_DONE__"


class SerialBoard:
    """A root shell on the board's serial console."""

    def __init__(self, port, baud):
        import serial  # pylint: disable=import-outside-toplevel

        self.port = serial.Serial(port, baud, timeout=0.2)
        self.port.write(b"\n")
        if "login:" in self._read(idle=1.5):
            self.port.write(b"root\n")
            self._read(idle=2.0)

    def _read(self, until=None, idle=1.0, cap=120.0):
        buf, start, last = b"", time.time(), time.time()
        while time.time() - start < cap:
            data = self.port.read(4096)
            if data:
                buf += data
                last = time.time()
                if until and until.encode() in buf:
                    break
            elif not until and time.time() - last > idle:
                break
        return buf.decode(errors="replace").replace("\r", "")

    def run(self, cmd):
        self.port.write(f"{cmd}; echo {MARK}\n".encode())
        out = self._read(until=f"\n{MARK}")
        # drop the echoed command line, the marker and bare shell prompts
        lines = out.split("\n")
        start = next((i + 1 for i, ln in enumerate(lines) if MARK in ln), 0)
        return "\n".join(ln for ln in lines[start:]
                         if MARK not in ln and ln.strip() not in ("#", "$"))

    def close(self):
        self.port.close()


class SshBoard:
    """A shell on the board over ssh."""

    def __init__(self, target):
        self.target = target

    def run(self, cmd):
        res = subprocess.run(["ssh", self.target, cmd], capture_output=True, text=True,
                             timeout=120, check=False)
        return res.stdout

    def close(self):
        pass


def snapshot(board, ifname):
    """Counters of the board, as a dict of name -> int, plus kernel messages."""
    out = board.run(
        f"ethtool -S {ifname}; "
        f"for f in rx_packets tx_packets rx_dropped tx_dropped rx_errors tx_errors; do "
        f"echo if_$f: $(cat /sys/class/net/{ifname}/statistics/$f); done; "
        f"echo bql_inflight: $(cat /sys/class/net/{ifname}/queues/tx-0/byte_queue_limits/inflight); "
        f"echo mem_free_kb: $(awk '/MemFree/{{print $2}}' /proc/meminfo); "
        f"echo dmesg_lines: $(dmesg | wc -l)")
    snap = {}
    for line in out.splitlines():
        name, sep, value = line.strip().partition(":")
        if sep and value.strip().lstrip("-").isdigit():
            snap[name.strip()] = int(value)
    return snap


def iperf3(args, cmd):
    """One iperf3 client run; returns the parsed JSON."""
    argv = shlex.split(args.iperf3) + ["-c", args.board, "-J", "-f", "m"] + cmd
    if args.bind:
        argv += ["-B", args.bind]
    for attempt in range(3):
        res = subprocess.run(argv, capture_output=True, text=True, check=False)
        try:
            data = json.loads(res.stdout)
        except json.JSONDecodeError:
            data = {"error": res.stderr.strip() or "no output"}
        if "error" not in data:
            return data
        if "busy" not in data["error"] or attempt == 2:
            raise RuntimeError(f"iperf3 {' '.join(cmd)}: {data['error']}")
        time.sleep(5)
    return data


def mbps(section):
    return section["bits_per_second"] / 1e6


def run_test(args, name):
    """Returns (description, iperf3 summary dict)."""
    tcp = ["-t", str(args.time)]
    udp = ["-u", "-b", args.udp_rate, "-l", "1472", "-t", str(args.time)]
    if name == "tcp-rx":
        end = iperf3(args, tcp)["end"]
        return "TCP, board receives", {
            "board receives": f"{mbps(end['sum_received']):.0f} Mb/s, "
                              f"{end['sum_sent']['retransmits']} retransmits"}
    if name == "tcp-tx":
        end = iperf3(args, tcp + ["-R"])["end"]
        return "TCP, board sends", {
            "board sends": f"{mbps(end['sum_received']):.0f} Mb/s, "
                           f"{end['sum_sent']['retransmits']} retransmits"}
    if name in ("udp-rx", "udp-tx"):
        rev = name == "udp-tx"
        end = iperf3(args, udp + (["-R"] if rev else []))["end"]
        rx, tx = end["sum_received"], end["sum_sent"]
        key = "board sends" if rev else "board receives"
        return f"UDP 1472-byte, {args.udp_rate}b/s offered, {key}", {
            key: f"{mbps(rx):.0f} Mb/s received ({mbps(tx):.0f} sent), "
                 f"{rx['lost_packets']} of {tx['packets']} lost"}
    if name in ("bidir", "soak"):
        secs = args.soak if name == "soak" else args.time
        end = iperf3(args, ["-t", str(secs), "--bidir"])["end"]
        return f"TCP, both directions, {secs} s", {
            "board receives": f"{mbps(end['sum_received']):.0f} Mb/s, "
                              f"{end['sum_sent']['retransmits']} retransmits",
            "board sends": f"{mbps(end['sum_received_bidir_reverse']):.0f} Mb/s, "
                           f"{end['sum_sent_bidir_reverse']['retransmits']} retransmits"}
    raise ValueError(f"unknown test {name}")


def accounting(before, after, board):
    """Counter deltas over one test, and whether the MAC and Linux agree."""
    def delta(key):
        return after.get(key, 0) - before.get(key, 0)

    mac_tx, if_tx = delta("hw_tx_frames"), delta("if_tx_packets")
    mac_rx, ovf, if_rx = delta("hw_rx_frames"), delta("hw_rx_err_overflow"), delta("if_rx_packets")
    fifo = delta("hw_rx_drop_fifo_full")
    def diff(mac, lnx):
        return "" if mac == lnx else f" (MAC {mac - lnx:+,})"

    notes = [f"TX: MAC {mac_tx:,}, interface {if_tx:,}" + diff(mac_tx, if_tx),
             f"RX: MAC {mac_rx:,} - overflow {ovf:,} = {mac_rx - ovf:,}, interface {if_rx:,}"
             + diff(mac_rx - ovf, if_rx),
             f"MAC RX dropped for FIFO full: {fifo:,}"]
    new_msgs = delta("dmesg_lines")
    if new_msgs > 0:
        msgs = board.run(f"dmesg | tail -n {new_msgs}").strip()
        notes.append("kernel messages:\n" + "\n".join("    " + m for m in msgs.splitlines()))
    else:
        notes.append("no kernel messages")
    notes.append(f"BQL inflight after: {after.get('bql_inflight', '?')}, free memory "
                 f"{delta('mem_free_kb'):+,} kB")
    agree = mac_tx == if_tx and mac_rx - ovf == if_rx
    return agree, notes


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--board", required=True, help="board address (iperf3 server)")
    ap.add_argument("--bind", help="host address to bind iperf3 to")
    ap.add_argument("--iperf3", default="iperf3", help="host iperf3 command")
    ap.add_argument("--serial", help="board serial console (e.g. COM15, /dev/ttyUSB1)")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--ssh", help="board ssh target (e.g. root@192.168.237.50)")
    ap.add_argument("--ifname", default="eth1", help="board interface")
    ap.add_argument("--tests", default="tcp-rx,tcp-tx,udp-rx,udp-tx,bidir")
    ap.add_argument("--time", type=int, default=10, help="seconds per test")
    ap.add_argument("--soak", type=int, default=300, help="seconds of the soak test")
    ap.add_argument("--udp-rate", default="950M", help="UDP offered rate")
    ap.add_argument("--conditions", default="", help="test conditions for the report")
    ap.add_argument("--out", help="write the Markdown report here too")
    args = ap.parse_args()

    board = None
    if args.serial:
        board = SerialBoard(args.serial, args.baud)
    elif args.ssh:
        board = SshBoard(args.ssh)

    report = [f"# emaczero Linux driver benchmark, {datetime.date.today()}", ""]
    if args.conditions:
        report += [args.conditions, ""]
    if board:
        info = board.run(f"uname -r; ethtool -i {args.ifname} | head -2; "
                         f"pidof iperf3 > /dev/null || iperf3 -s -D").strip()
        report += ["Board: " + ", ".join(info.splitlines()), ""]
    host_ver = subprocess.run(shlex.split(args.iperf3) + ["--version"], capture_output=True,
                              text=True, check=False).stdout.splitlines()
    report += [f"Host: {host_ver[0] if host_ver else 'iperf3'}; {args.time} s per test "
               f"unless stated", ""]

    ok = True
    for name in [t.strip() for t in args.tests.split(",") if t.strip()]:
        before = snapshot(board, args.ifname) if board else None
        desc, result = run_test(args, name)
        block = [f"## {desc}", ""] + [f"- {k}: {v}" for k, v in result.items()]
        if board:
            agree, notes = accounting(before, snapshot(board, args.ifname), board)
            ok &= agree
            block += [f"- {n}" for n in notes]
        block.append("")
        report += block
        print("\n".join(block), file=sys.stderr)

    if board:
        report.append("MAC and interface counts agree in every test." if ok else
                      "MAC and interface counts differ in at least one test. The driver's "
                      "64-bit totals can lose a frame each time they fold the MAC's "
                      "counters (sw/linux/README.md, Statistics).")
        board.close()
    text = "\n".join(report) + "\n"
    if args.out:
        with open(args.out, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
    sys.stdout.write(text)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
