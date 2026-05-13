#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
"""
run_hw_regression.py - Hardware-only Arty A7 regression profiles.

These tests require a programmed board and a host NIC on the demo subnet. They
are intentionally separate from build_and_test.py because they exercise real
Ethernet hardware and take wall-clock time.
"""

import argparse
import socket
import struct
import subprocess
import sys
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_BOARD_IP = "192.168.137.200"
STATS_PORT = 9996


PROFILES = {
    "bidirectional-smoke": {
        "description": "Short simultaneous UDP check with host-stable Python pacing",
        "argv": [
            "udp_bidirectional_test.py",
            "--secs", "5",
            "--host-mbps", "70",
            "--fpga-ifg-cycles", "8000",
            "--min-mbps", "60",
            "--max-loss-pct", "1",
        ],
    },
    "bidirectional-long": {
        "description": "60 s bidirectional stress profile used for line-rate work",
        "argv": [
            "udp_bidirectional_test.py",
            "--secs", "60",
            "--host-mbps", "99",
            "--fpga-ifg-cycles", "8000",
            "--min-mbps", "50",
            "--max-loss-pct", "5",
        ],
    },
}


def profile_command(python_exe, name, board):
    spec = PROFILES[name]
    script = SCRIPT_DIR / spec["argv"][0]
    cmd = [python_exe, str(script), *spec["argv"][1:]]
    if board:
        cmd.extend(["--board", board])
    return cmd


def print_cmd(cmd):
    print(" ".join(f'"{arg}"' if " " in arg else arg for arg in cmd))


def probe_board(board_ip, timeout):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        sock.sendto(b"G", (board_ip, STATS_PORT))
        data, _addr = sock.recvfrom(256)
    finally:
        sock.close()

    if len(data) != 44 or data[:4] != b"IPS0" or data[40:44] != b"DONE":
        raise RuntimeError(f"unexpected UDP/{STATS_PORT} probe reply: {data.hex()}")

    fields = struct.unpack("!7I I H H", data[4:40])
    return fields[0], fields[1]


def main():
    parser = argparse.ArgumentParser(description="Run emacZero Arty hardware regression profiles")
    parser.add_argument("profiles", nargs="*", help="profile names to run")
    parser.add_argument("--profile", action="append", default=[],
                        help="profile name to run; may be repeated")
    parser.add_argument("--list", action="store_true", help="list available profiles")
    parser.add_argument("--dry-run", action="store_true", help="print commands without running them")
    parser.add_argument("--board", default=DEFAULT_BOARD_IP, help="FPGA IPv4 address")
    parser.add_argument("--probe-timeout", type=float, default=1.0,
                        help="seconds to wait for the initial UDP/9996 board probe")
    parser.add_argument("--skip-probe", action="store_true",
                        help="skip the initial UDP/9996 board reachability probe")
    parser.add_argument("--python", default=sys.executable, help="Python executable to use")
    args = parser.parse_args()

    selected = [*args.profile, *args.profiles]

    if args.list:
        for name, spec in PROFILES.items():
            print(f"{name}: {spec['description']}")
        return 0

    if not selected:
        selected = ["bidirectional-smoke"]

    unknown = [name for name in selected if name not in PROFILES]
    if unknown:
        parser.error("unknown profile(s): " + ", ".join(unknown))

    if not args.dry_run and not args.skip_probe:
        print(f"== board probe: {args.board}:UDP/{STATS_PORT} ==", flush=True)
        try:
            packets, bytes_seen = probe_board(args.board, args.probe_timeout)
        except OSError as exc:
            print(f"FAIL: board did not reply to UDP/{STATS_PORT} stats probe: {exc}", file=sys.stderr)
            return 2
        except RuntimeError as exc:
            print(f"FAIL: {exc}", file=sys.stderr)
            return 2
        print(f"probe ok: FPGA iperf sink counters packets={packets} bytes={bytes_seen}")

    for name in selected:
        cmd = profile_command(args.python, name, args.board)
        print(f"== {name}: {PROFILES[name]['description']} ==", flush=True)
        print_cmd(cmd)
        sys.stdout.flush()
        if args.dry_run:
            continue
        result = subprocess.run(cmd, cwd=SCRIPT_DIR.parents[2])
        if result.returncode:
            return result.returncode

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
