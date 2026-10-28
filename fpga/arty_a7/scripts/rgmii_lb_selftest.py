#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""rgmii_lb_selftest.py - Run the on-silicon RGMII pad-loopback self-test over JTAG.

Needs the build_arty_rgmii_lb.tcl bitstream on the board, nothing plugged into
Pmod JC, and a hw_server on :3121. Drives rgmii_lb_selftest.v through the
fcapz EIO (eio-write bits: [0] run, [1] clear, [3:2] speed, [8:4] RX IDELAY
tap, [9] tap load) and decodes its counters from eio-read bits [327:64].

For each speed (1G, 100M, 10M by default) it stops traffic, selects the speed,
clears the counters, runs traffic, stops, drains, and requires: every frame
sent came back exact and clean, frames longer than 4083 bytes came back exact,
the longest exact frame is 9014 bytes (9018 on the wire with FCS), and no bad
frames, terror or sequence gaps.

--sweep first steps the RX IDELAY tap through 0..31 at 1G, runs traffic
briefly at each tap, prints which taps pass, and uses the middle of the
longest passing run for the tests that follow (unless --tap is given).

    python fpga/arty_a7/scripts/rgmii_lb_selftest.py --sweep --seconds 20
"""

import argparse
import os
import sys
import time

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
sys.path.insert(0, os.path.join(REPO, "fcapz", "host"))

from fcapz.eio import EioController  # noqa: E402
from fcapz.transport import XilinxHwServerTransport  # noqa: E402

MARKER = 0xB0C
IN_W, OUT_W = 64 + 264, 10
FIELDS = [  # (name, lsb, width) within the 264-bit self-test status
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
    ("idelay_rdy", 243, 1),
    ("marker", 244, 12),
    ("speed", 256, 2),
    ("tap", 258, 5),
]
SPEEDS = {"1000": 0b00, "100": 0b01, "10": 0b10}


class SelfTest:
    def __init__(self, port):
        tp = XilinxHwServerTransport(port=int(port), fpga_name="xc7a100t")
        self.eio = EioController(tp, chain=3)
        self.eio.connect()
        if (self.eio.in_w, self.eio.out_w) != (IN_W, OUT_W):
            sys.exit(f"ERROR: EIO is {self.eio.in_w}/{self.eio.out_w} bits, expected "
                     f"{IN_W}/{OUT_W} - is the build_arty_rgmii_lb bitstream programmed?")
        self.speed = 0
        self.tap = 0

    def write(self, run=0, clear=0, load=0):
        self.eio.write_outputs(run | clear << 1 | self.speed << 2 | self.tap << 4 | load << 9)

    def status(self):
        st = self.eio.read_inputs() >> 64
        return {name: (st >> lsb) & ((1 << w) - 1) for name, lsb, w in FIELDS}

    def set_tap(self, tap):
        self.tap = tap
        self.write()
        self.write(load=1)
        self.write()
        if self.status()["tap"] != tap:
            sys.exit(f"ERROR: tap {tap} did not load")

    def set_speed(self, code):
        self.speed = code
        self.write()                         # stopped, new speed
        t0 = time.monotonic()
        while time.monotonic() - t0 < 2.0:
            s = self.status()
            if s["speed"] == code and s["init_done"]:
                time.sleep(0.05)             # TX takes it after 5 TXC periods
                return
        sys.exit(f"ERROR: speed {code:#04b} was not written to CTRL")

    def run(self, seconds, interval=None, label=""):
        """Clear, run for seconds, stop, drain; return the final status."""
        self.write(clear=1)
        time.sleep(0.05)
        self.write()
        self.write(run=1)
        t0 = time.monotonic()
        while time.monotonic() - t0 < seconds:
            time.sleep(min(interval or seconds,
                           max(0.0, seconds - (time.monotonic() - t0))))
            if interval:
                # Progress only: the counters move while this reads them.
                show(self.status(), f"  {label}t={time.monotonic() - t0:5.1f}s")
        self.write()                         # stop; in-flight frames drain
        time.sleep(1.0)
        return self.status()


def show(s, label):
    print(f"{label}: tx={s['tx_frames']} ok={s['rx_ok']} ok_big={s['rx_ok_big']} "
          f"bad={s['rx_bad']} terror={s['rx_terror']} seq_gap={s['seq_gap']} "
          f"max_ok_len={s['max_ok_len']}", flush=True)


def clean(s):
    return (s["tx_frames"] > 0 and s["rx_ok"] == s["tx_frames"] and s["rx_bad"] == 0
            and s["rx_terror"] == 0 and s["seq_gap"] == 0)


def sweep(t, seconds):
    """Step the tap through 0..31 at 1G; return the passing taps."""
    t.set_speed(SPEEDS["1000"])
    passing = []
    print("tap sweep at 1G:")
    for tap in range(32):
        t.set_tap(tap)
        s = t.run(seconds)
        ok = clean(s)
        passing += [tap] if ok else []
        print(f"  tap {tap:2d}: {'PASS' if ok else 'fail'}  tx={s['tx_frames']} "
              f"ok={s['rx_ok']} bad={s['rx_bad']} terror={s['rx_terror']} "
              f"gap={s['seq_gap']}", flush=True)
    return passing


def longest_run(taps):
    best, cur = [], []
    for tap in taps:
        cur = cur + [tap] if cur and tap == cur[-1] + 1 else [tap]
        if len(cur) > len(best):
            best = cur
    return best


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--speeds", default="1000,100,10",
                    help="comma-separated speeds to test, from 1000, 100, 10")
    ap.add_argument("--seconds", type=float, default=20.0, help="traffic per speed")
    ap.add_argument("--tap", type=int, default=None, help="RX IDELAY tap 0..31")
    ap.add_argument("--sweep", action="store_true", help="sweep the tap at 1G first")
    ap.add_argument("--sweep-seconds", type=float, default=0.5,
                    help="traffic per tap in the sweep")
    ap.add_argument("--port", default="3121", help="hw_server port")
    ap.add_argument("--interval", type=float, default=10.0, help="progress read period")
    a = ap.parse_args()

    t = SelfTest(a.port)
    s = t.status()
    if s["marker"] != MARKER:
        sys.exit(f"ERROR: self-test marker {s['marker']:#x} != {MARKER:#x} - "
                 "is the build_arty_rgmii_lb bitstream programmed?")
    if not (s["init_done"] and s["mmcm_locked"] and s["idelay_rdy"]):
        sys.exit(f"ERROR: self-test not ready (init_done={s['init_done']}, "
                 f"mmcm_locked={s['mmcm_locked']}, idelay_rdy={s['idelay_rdy']})")
    t.speed, t.tap = s["speed"], s["tap"]

    fails = 0
    tap = a.tap
    if a.sweep:
        passing = sweep(t, a.sweep_seconds)
        win = longest_run(passing)
        if win:
            print(f"passing taps: {passing}; longest run {win[0]}..{win[-1]} "
                  f"({len(win)} taps, ~{len(win) * 78} ps at 78 ps/tap)")
            if tap is None:
                tap = win[len(win) // 2]
        else:
            print("FAIL: no tap passes at 1G")
            fails += 1
    if tap is not None:
        t.set_tap(tap)
    print(f"RX IDELAY tap: {t.tap}")

    for name in a.speeds.split(","):
        t.set_speed(SPEEDS[name])
        s = t.run(a.seconds, a.interval, f"{name}M ")
        show(s, f"{name}M final")
        checks = [
            ("frames were sent", s["tx_frames"] > 0),
            ("every frame came back exact and clean", s["rx_ok"] == s["tx_frames"]),
            ("frames > 4083 B came back exact", s["rx_ok_big"] > 0),
            ("longest exact frame is 9014 B (9018 with FCS)", s["max_ok_len"] == 9014),
            ("no bad frames", s["rx_bad"] == 0),
            ("no terror", s["rx_terror"] == 0),
            ("no sequence gaps", s["seq_gap"] == 0),
        ]
        for check, ok in checks:
            print(f"{'PASS' if ok else 'FAIL'}: {name}M {check}")
            fails += not ok
        if s["rx_bad"]:
            print(f"INFO: {name}M first bad frame seq[15:0]={s['first_bad_seq']} "
                  f"len={s['first_bad_len']}")

    t.set_speed(SPEEDS["1000"])
    print("ALL TESTS PASSED" if not fails else f"{fails} check(s) FAILED")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
