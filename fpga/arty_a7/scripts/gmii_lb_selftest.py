#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""gmii_lb_selftest.py - Run the on-silicon GMII loopback self-test over JTAG.

Needs the build_arty_gmii_lb.tcl bitstream on the board and a hw_server on
:3121. Drives gmii_lb_selftest.v through the fcapz EIO (eio-write bit 0 = run,
bit 1 = clear), lets traffic run, stops it, drains, and decodes the counters
from eio-read bits [319:64].

PASS requires: every frame sent came back exact and clean, frames longer than
the ~4083 bytes the old RX CDC FIFO truncated came back exact, the longest
exact frame is 9014 bytes (9018 on the wire with FCS), and no bad frames,
terror or sequence gaps.

    python fpga/arty_a7/scripts/gmii_lb_selftest.py --seconds 60
"""

import argparse
import subprocess
import sys
import time

MARKER = 0xB0A
FIELDS = [  # (name, lsb, width) within the 256-bit self-test status
    ("tx_frames", 0, 32),
    ("rx_ok", 32, 32),
    ("rx_ok_big", 64, 32),
    ("rx_bad", 96, 32),
    ("rx_terror", 128, 32),
    ("seq_gap", 160, 32),
    ("max_ok_len", 192, 16),
    ("first_bad_len", 208, 16),
    ("first_bad_seq", 224, 16),
    ("init_done", 240, 1),
    ("run", 241, 1),
    ("mmcm_locked", 242, 1),
    ("marker", 244, 12),
]


def fcapz(args, base, retries=5):
    """Run one fcapz CLI command, retrying transient JTAG enumeration misses."""
    last = ""
    for _ in range(retries):
        r = subprocess.run(["fcapz"] + base + args, capture_output=True, text=True)
        out = (r.stdout + r.stderr).strip()
        if r.returncode == 0:
            return out
        last = out
        time.sleep(2)
    sys.exit(f"ERROR: fcapz {' '.join(args)} failed:\n{last}")


def read_status(base):
    raw = int(fcapz(["eio-read"], base).splitlines()[-1], 16)
    st = raw >> 64
    return {name: (st >> lsb) & ((1 << w) - 1) for name, lsb, w in FIELDS}


def show(s, label):
    print(f"{label}: tx={s['tx_frames']} ok={s['rx_ok']} ok_big={s['rx_ok_big']} "
          f"bad={s['rx_bad']} terror={s['rx_terror']} seq_gap={s['seq_gap']} "
          f"max_ok_len={s['max_ok_len']}", flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--seconds", type=float, default=30.0, help="traffic duration")
    ap.add_argument("--port", default="3121", help="hw_server port")
    ap.add_argument("--tap", default="xc7a100t.tap", help="JTAG TAP name")
    ap.add_argument("--interval", type=float, default=10.0, help="progress read period")
    a = ap.parse_args()
    base = ["--backend", "hw_server", "--port", a.port, "--tap", a.tap]

    s = read_status(base)
    if s["marker"] != MARKER:
        sys.exit(f"ERROR: self-test marker {s['marker']:#x} != {MARKER:#x} - "
                 "is the build_arty_gmii_lb bitstream programmed?")
    if not (s["init_done"] and s["mmcm_locked"]):
        sys.exit(f"ERROR: self-test not ready (init_done={s['init_done']}, "
                 f"mmcm_locked={s['mmcm_locked']})")

    fcapz(["eio-write", "0x2"], base)          # clear
    time.sleep(0.2)
    fcapz(["eio-write", "0x1"], base)          # run
    t0 = time.monotonic()
    while time.monotonic() - t0 < a.seconds:
        time.sleep(min(a.interval, max(0.0, a.seconds - (time.monotonic() - t0))))
        show(read_status(base), f"  t={time.monotonic() - t0:5.1f}s")
    fcapz(["eio-write", "0x0"], base)          # stop; in-flight frames drain
    time.sleep(1.0)
    s = read_status(base)
    show(s, "final")

    checks = [
        ("frames were sent", s["tx_frames"] > 0),
        ("every frame came back exact and clean", s["rx_ok"] == s["tx_frames"]),
        ("frames > 4083 B came back exact", s["rx_ok_big"] > 0),
        ("longest exact frame is 9014 B (9018 with FCS)", s["max_ok_len"] == 9014),
        ("no bad frames", s["rx_bad"] == 0),
        ("no terror", s["rx_terror"] == 0),
        ("no sequence gaps", s["seq_gap"] == 0),
    ]
    fails = 0
    for name, ok in checks:
        print(f"{'PASS' if ok else 'FAIL'}: {name}")
        fails += not ok
    if s["rx_bad"]:
        print(f"INFO: first bad frame seq[15:0]={s['first_bad_seq']} "
              f"len={s['first_bad_len']}")
    print("ALL TESTS PASSED" if not fails else f"{fails} check(s) FAILED")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
