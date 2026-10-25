#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""linux_bench.py - Throughput and accounting benchmark of the Linux driver.

Runs iperf3 from a host against a board that runs the emaczero driver, and
reads the board's counters before and after every test: the MAC's own
counters (ethtool -S), the interface's packet counts, kernel messages, BQL
and free memory. For each test it checks that the MAC and the interface
agree: TX frames the MAC sent against packets the interface sent, and RX
frames the MAC received minus the ones it flagged as bad (RX errors) against
packets the interface received.

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
Prefer the serial console, or ssh over another interface: ssh over the
interface under test adds its own frames between the readings, so the
comparison is then only approximate.

Each test waits --settle seconds after iperf3 ends before reading the
counters, so the last frames have left and been completed. A test is
invalid, and the script exits non-zero, when a counter is missing or went
backwards (driver reloaded, readout failed); it also exits non-zero when
the counts differ.

iperf3 is searched in PATH; --iperf3 overrides it (for example "wsl iperf3"
on Windows). Bind the host side with --bind when the host has more than one
route to the board.

Usage:
  python sw/linux/scripts/linux_bench.py --board 192.168.237.50 \\
      --bind 192.168.237.1 --serial /dev/ttyUSB1 --out results.md
  python sw/linux/scripts/linux_bench.py --board 192.168.237.50 --ssh root@10.0.0.2 \\
      --tests soak --soak 300 --raw soak.json
"""
import argparse
import datetime
import json
import os
import re
import shlex
import subprocess
import sys
import time

# Built with an empty "" inside so the shell's echo of the command never
# contains the marker the command prints.
BEGIN, END = "__EMZ_BENCH_BEGIN__", "__EMZ_BENCH_END__"

# Counters the accounting needs in every snapshot.
REQUIRED = ("hw_tx_frames", "hw_rx_frames", "hw_rx_errors", "hw_rx_err_overflow",
            "hw_rx_err_csum", "hw_rx_drop_fifo_full", "if_tx_packets", "if_rx_packets",
            "if_rx_dropped", "if_rx_errors", "if_rx_length_errors", "dmesg_lines")


class BoardError(RuntimeError):
    """The board's shell did not answer as expected."""


def split_marker(name):
    return f'{name[:6]}""{name[6:]}'


class SerialBoard:
    """A root shell on the board's serial console."""

    def __init__(self, port, baud):
        import serial  # pylint: disable=import-outside-toplevel

        self.port = serial.Serial(port, baud, timeout=0.2)
        self.port.write(b"\n")
        if "login:" in self._read(idle=1.5):
            self.port.write(b"root\n")
            self._read(idle=2.0)
        self._read(idle=0.5)

    def _read(self, until=None, idle=1.0, cap=120.0):
        buf, start, last = b"", time.time(), time.time()
        while time.time() - start < cap:
            data = self.port.read(4096)
            if data:
                buf += data
                last = time.time()
                if until and until.search(buf.decode(errors="replace").replace("\r", "")):
                    break
            elif not until and time.time() - last > idle:
                break
        return buf.decode(errors="replace").replace("\r", "")

    def run(self, cmd):
        self.port.write(f"echo {split_marker(BEGIN)}; {cmd}; "
                        f"echo {split_marker(END)} $?\n".encode())
        end = re.compile(rf"^{END} (\d+)$", re.M)
        out = self._read(until=end)
        lines = out.split("\n")
        try:
            first = lines.index(BEGIN) + 1
        except ValueError as exc:
            raise BoardError(f"no answer to: {cmd}") from exc
        last = next((i for i in range(first, len(lines)) if end.match(lines[i])), None)
        if last is None:
            raise BoardError(f"no end of output for: {cmd}")
        return "\n".join(lines[first:last])

    def close(self):
        self.port.close()


class SshBoard:
    """A shell on the board over ssh."""

    def __init__(self, target):
        self.target = target

    def run(self, cmd):
        res = subprocess.run(["ssh", self.target, cmd], capture_output=True, text=True,
                             timeout=120, check=False)
        if res.returncode == 255:
            raise BoardError(f"ssh {self.target}: {res.stderr.strip()}")
        return res.stdout

    def close(self):
        pass


def snapshot(board, ifname):
    """Counters of the board, as a dict of name -> int."""
    stats = " ".join(["rx_packets", "tx_packets", "rx_dropped", "tx_dropped", "rx_errors",
                      "tx_errors", "rx_length_errors"])
    out = board.run(
        f"ethtool -S {ifname}; "
        f"for f in {stats}; do "
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
        # the receiver's "packets" is its highest sequence number and
        # "lost_packets" the gaps below it: a lost tail shows only as the
        # difference from what the sender sent
        return f"UDP 1472-byte, {args.udp_rate}b/s offered, {key}", {
            key: f"{mbps(rx):.0f} Mb/s received ({mbps(tx):.0f} sent); iperf3: "
                 f"{tx['packets']:,} sent, receiver sequence to {rx['packets']:,}, "
                 f"{rx['lost_packets']:,} gaps"}
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
    """Returns (verdict, notes); verdict is "agree", "differ" or "invalid"."""
    missing = [k for k in REQUIRED if k not in before or k not in after]
    if missing:
        return "invalid", [f"invalid: counters missing: {', '.join(missing)}"]
    delta = {k: after[k] - before[k] for k in REQUIRED}
    back = [k for k, v in delta.items() if v < 0]
    if back:
        return "invalid", [f"invalid: counters went backwards (driver reloaded?): "
                           f"{', '.join(back)}"]

    def diff(mac, lnx):
        return "" if mac == lnx else f" (MAC {mac - lnx:+,})"

    mac_tx, if_tx = delta["hw_tx_frames"], delta["if_tx_packets"]
    mac_rx, bad = delta["hw_rx_frames"], delta["hw_rx_errors"]
    if_rx = delta["if_rx_packets"]
    notes = [f"TX: MAC {mac_tx:,}, interface {if_tx:,}" + diff(mac_tx, if_tx),
             f"RX: MAC {mac_rx:,} - bad {bad:,} = {mac_rx - bad:,}, interface {if_rx:,}"
             + diff(mac_rx - bad, if_rx),
             f"MAC RX bad checksum (in bad above) {delta['hw_rx_err_csum']:,}",
             f"MAC RX overflow {delta['hw_rx_err_overflow']:,}, dropped for FIFO full "
             f"{delta['hw_rx_drop_fifo_full']:,}; interface RX dropped "
             f"{delta['if_rx_dropped']:,}, errors {delta['if_rx_errors']:,}, length errors "
             f"{delta['if_rx_length_errors']:,}"]
    if delta["dmesg_lines"] > 0:
        msgs = board.run(f"dmesg | tail -n {delta['dmesg_lines']}").strip()
        notes.append("kernel messages:\n" + "\n".join("    " + m for m in msgs.splitlines()))
    else:
        notes.append("no kernel messages")
    notes.append(f"BQL inflight after: {after.get('bql_inflight', '?')}, free memory "
                 f"{after.get('mem_free_kb', 0) - before.get('mem_free_kb', 0):+,} kB")
    verdict = "agree" if mac_tx == if_tx and mac_rx - bad == if_rx else "differ"
    return verdict, notes


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--board", required=True, help="board address (iperf3 server)")
    ap.add_argument("--bind", help="host address to bind iperf3 to")
    ap.add_argument("--iperf3", default="iperf3", help="host iperf3 command")
    ap.add_argument("--serial", help="board serial console (e.g. COM15, /dev/ttyUSB1)")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--ssh", help="board ssh target (e.g. root@10.0.0.2)")
    ap.add_argument("--ifname", default="eth1", help="board interface")
    ap.add_argument("--tests", default="tcp-rx,tcp-tx,udp-rx,udp-tx,bidir")
    ap.add_argument("--time", type=int, default=10, help="seconds per test")
    ap.add_argument("--soak", type=int, default=300, help="seconds of the soak test")
    ap.add_argument("--udp-rate", default="950M", help="UDP offered rate")
    ap.add_argument("--settle", type=float, default=2.0,
                    help="seconds to wait after a test before reading the counters")
    ap.add_argument("--conditions", default="", help="test conditions for the report")
    ap.add_argument("--out", help="write the Markdown report here too")
    ap.add_argument("--raw", help="write the raw counter snapshots here (JSON)")
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
        report += ["Board: " + ", ".join(info.splitlines()) + "; counters read over "
                   + ("the serial console" if args.serial else
                      f"ssh ({args.ssh}; approximate if over the interface under test)"), ""]
    host_ver = subprocess.run(shlex.split(args.iperf3) + ["--version"], capture_output=True,
                              text=True, check=False).stdout.splitlines()
    report += [f"Host: {host_ver[0] if host_ver else 'iperf3'}; {args.time} s per test "
               f"unless stated", ""]

    verdicts, raw = [], []
    for name in [t.strip() for t in args.tests.split(",") if t.strip()]:
        before = snapshot(board, args.ifname) if board else None
        desc, result = run_test(args, name)
        block = [f"## {desc}", ""] + [f"- {k}: {v}" for k, v in result.items()]
        if board:
            time.sleep(args.settle)
            after = snapshot(board, args.ifname)
            verdict, notes = accounting(before, after, board)
            verdicts.append(verdict)
            raw.append({"test": name, "before": before, "after": after, "verdict": verdict})
            block += [f"- {n}" for n in notes]
        block.append("")
        report += block
        print("\n".join(block), file=sys.stderr)

    if board:
        board.close()
        if all(v == "agree" for v in verdicts):
            report.append("MAC and interface counts agree in every test.")
        else:
            report.append(f"Tests: {verdicts.count('agree')} agree, {verdicts.count('differ')} "
                          f"differ, {verdicts.count('invalid')} invalid. A fold of the MAC "
                          f"counters into the driver's 64-bit totals loses what a counter "
                          f"takes during its read and clear (sw/linux/README.md, "
                          f"Statistics); a larger or persistent difference has another cause.")
    text = "\n".join(report) + "\n"
    sys.stdout.write(text)
    for path, content in ((args.out, text), (args.raw, json.dumps(raw, indent=1) + "\n")):
        if path:
            os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
            with open(path, "w", encoding="utf-8", newline="\n") as f:
                f.write(content)
    return 0 if all(v == "agree" for v in verdicts) else 1


if __name__ == "__main__":
    sys.exit(main())
