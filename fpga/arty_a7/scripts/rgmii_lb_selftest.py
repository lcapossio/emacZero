#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""rgmii_lb_selftest.py - Run the on-silicon RGMII pad-loopback self-test over JTAG.

Needs the build_arty_rgmii_lb.tcl bitstream on the board, nothing plugged into
Pmod JC, and a hw_server on :3121. Drives rgmii_lb_selftest.v through the
fcapz EIO (eio-write bits: [0] run, [1] clear, [3:2] speed, [8:4] RX IDELAY
tap, [9] tap load, [25:10] PAUSE quanta, [26] PAUSE rx_en, [27] PAUSE send)
and decodes its counters from eio-read bits [391:64].

For each speed (1G, 100M, 10M by default) it stops traffic, selects the speed,
clears the counters, runs traffic, stops, drains, and requires: every frame
sent came back exact and clean, frames longer than 4083 bytes came back exact,
the longest exact frame is 9014 bytes (9018 on the wire with FCS), and no bad
frames, terror or sequence gaps.

Then, at each speed, the MAC sends PAUSE frames to itself while traffic runs
(skip with --no-pause). Each must come back with every checked field right
(all but the source address), the data frames must stay exact and in order, and the longest gap between frames the MAC accepted
(max_gap) shows whether TX paused:
  honored  PAUSE_CTRL rx_en set, --pause-quanta Q (default 0x2000, about 58
           longest-frame times at every speed): max_gap is Q x 512 bit times
           within two longest-frame times;
  ignored  rx_en clear, same Q: max_gap stays within two frame times;
  XON      rx_en set, Q = 0xFFFF, refreshed every eighth of that pause for
           about 0.5 s, then Q = 0. Host timestamps around every EIO send
           write must show each PAUSE frame taking effect before the one
           before it could run out; max_gap must then cover the time from the
           first 0xFFFF frame to the Q = 0 frame (TX paused) and end within
           two frame times (+1 ms) of the Q = 0 frame's write (TX resumed),
           and every PAUSE frame must come back right (all but the first are
           sent while TX is paused). That also shows it was the Q = 0 frame
           that resumed TX, not the 0xFFFF pause running out, as long as the
           EIO writes are fast against the pause: at 1G, where 0xFFFF quanta
           are only 33.5 ms, slow JTAG writes can make the two
           indistinguishable, and the script then says so instead of
           counting it. An attempt in which a host stall may have let a pause
           run out before the next one took effect is void and repeated (up
           to three attempts).

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
IN_W, OUT_W = 64 + 328, 32
FIELDS = [  # (name, lsb, width) within the 328-bit self-test status
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
    ("pause_rx_en", 263, 1),
    ("max_gap", 264, 32),
    ("pause_ok", 296, 16),
    ("pause_bad", 312, 16),
]
SPEEDS = {"1000": 0b00, "100": 0b01, "10": 0b10}
CLK_NS = 8                                    # clk_125 period, max_gap unit
QUANTUM_NS = {"1000": 512, "100": 5120, "10": 51200}   # 512 bit times
# Longest frame on the wire: 9018 B + 8 preamble/SFD + 12 IFG.
FRAME_NS = {name: 9038 * 8 * q // 512 for name, q in QUANTUM_NS.items()}
# The honored/ignored checks allow two longest-frame times either way, so the
# pause must be well longer: at least four of them (the same at every speed).
MIN_QUANTA = -(-4 * FRAME_NS["1000"] // QUANTUM_NS["1000"])
XON_HOLD_S = 0.5                              # PAUSE held this long before Q = 0


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
        self.quanta = 0
        self.rx_en = 0
        self.running = 0

    def write(self, run=None, clear=0, load=0, send=0):
        if run is not None:
            self.running = run
        self.eio.write_outputs(self.running | clear << 1 | self.speed << 2 | self.tap << 4
                               | load << 9 | self.quanta << 10 | self.rx_en << 26
                               | send << 27)

    def status(self):
        st = self.eio.read_inputs() >> 64
        return {name: (st >> lsb) & ((1 << w) - 1) for name, lsb, w in FIELDS}

    def set_tap(self, tap):
        self.tap = tap
        self.write(run=0)
        self.write(load=1)
        self.write()
        if self.status()["tap"] != tap:
            sys.exit(f"ERROR: tap {tap} did not load")

    def set_speed(self, code):
        self.speed = code
        self.write(run=0)                    # stopped, new speed
        t0 = time.monotonic()
        while time.monotonic() - t0 < 2.0:
            s = self.status()
            if s["speed"] == code and s["init_done"]:
                time.sleep(0.05)             # TX takes it after 5 TXC periods
                return
        sys.exit(f"ERROR: speed {code:#04b} was not written to CTRL")

    def set_pause_rx(self, rx_en):
        self.rx_en = rx_en
        self.write()
        t0 = time.monotonic()
        while time.monotonic() - t0 < 2.0:
            s = self.status()
            if s["pause_rx_en"] == rx_en and s["init_done"]:
                return
        sys.exit(f"ERROR: PAUSE rx_en {rx_en} was not written to PAUSE_CTRL")

    def send_pause(self, quanta):
        """Set the quanta, then raise send: PAUSE_QUANTA, PAUSE_CTRL tx_send."""
        self.quanta = quanta
        self.write()
        self.write(send=1)
        self.write()

    def start(self):
        self.write(run=0, clear=1)
        time.sleep(0.05)
        self.write()
        self.write(run=1)

    def stop(self):
        self.write(run=0)                    # in-flight frames drain
        time.sleep(1.0)
        return self.status()

    def run(self, seconds, interval=None, label=""):
        """Clear, run for seconds, stop, drain; return the final status."""
        self.write(run=0, clear=1)
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
        return self.stop()


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


def pause_tests(t, name, quanta):
    """PAUSE honored, ignored and cancelled by XON at the current speed."""
    q_ns, f_ns = QUANTUM_NS[name], FRAME_NS[name]
    fails = 0

    def report(check, ok):
        nonlocal fails
        print(f"{'PASS' if ok else 'FAIL'}: {name}M PAUSE {check}")
        fails += not ok

    def one(label, rx_en, q):
        t.set_pause_rx(rx_en)
        t.start()
        time.sleep(0.1 + 3 * f_ns * 1e-9)    # traffic flowing
        t.send_pause(q)
        time.sleep(q * q_ns * 1e-9 + 3 * f_ns * 1e-9 + 0.1)
        s = t.stop()
        gap_ns = s["max_gap"] * CLK_NS
        print(f"  {name}M PAUSE {label}: max_gap={gap_ns / 1e3:.1f} us "
              f"pause_ok={s['pause_ok']} pause_bad={s['pause_bad']} "
              f"tx={s['tx_frames']} ok={s['rx_ok']} bad={s['rx_bad']}", flush=True)
        report(f"{label}: data frames exact and in order", clean(s))
        return s, gap_ns

    dur = quanta * q_ns
    s, gap = one(f"honored (Q={quanta:#x}, {dur / 1e3:.0f} us)", 1, quanta)
    report("honored: frame came back with every checked field right", s["pause_ok"] == 1 and s["pause_bad"] == 0)
    report(f"honored: max_gap {gap / 1e3:.1f} us is the pause within two frames "
           f"({gap / dur:.3f} x)", abs(gap - dur) <= 2 * f_ns)

    s, gap = one(f"ignored (Q={quanta:#x}, rx_en clear)", 0, quanta)
    report("ignored: frame came back with every checked field right", s["pause_ok"] == 1 and s["pause_bad"] == 0)
    report(f"ignored: max_gap {gap / 1e3:.1f} us within two frames", gap <= 2 * f_ns)

    # XON. Hold a 0xFFFF pause for about XON_HOLD_S, refreshing it well
    # before it can run out, then send Q = 0. Each PAUSE frame leaves during
    # the EIO write that raises send, behind at most the data frame on the
    # wire, so it takes effect between that write's start and two frames
    # after its end. Host timestamps (perf_counter: time.monotonic ticks in
    # ~16 ms steps on Windows) around every send write therefore give:
    #   - continuity: each pause takes effect before the one before it can
    #     run out, i.e. end(next) + 2 frames < start(prev) + full, for every
    #     refresh and for the Q = 0 frame; `slack` is the smallest margin;
    #   - max_gap >= x0 - on1 - 2 frames  (TX stayed paused until Q = 0)
    #   - max_gap <= x1 - on0 + 2 frames + 1 ms  (TX resumed at Q = 0).
    # Had Q = 0 been ignored, TX would have stayed paused (continuously, by
    # the above) until the last 0xFFFF pause ran out, no earlier than `full`
    # after the last refresh write started (last0); the upper bound tells
    # the two apart only while that end lies beyond it, which slow JTAG
    # writes (5-10 ms each) can rule out at 1G, where 0xFFFF quanta are only
    # 33.5 ms.
    full_s = 0xFFFF * q_ns * 1e-9
    f_s = f_ns * 1e-9
    refresh_s = full_s / 8

    def send_edge():
        t0 = time.perf_counter()
        t.write(send=1)
        return t0, time.perf_counter()

    def xon_once():
        t.set_pause_rx(1)
        t.quanta = 0xFFFF
        t.start()                            # also writes the quanta
        time.sleep(0.1 + 3 * f_s)            # traffic flowing
        edges = [send_edge()]
        t.write()
        while time.perf_counter() + refresh_s < edges[0][0] + XON_HOLD_S:
            time.sleep(max(0.0, edges[-1][0] + refresh_s - time.perf_counter()))
            edges.append(send_edge())
            t.write()
        edges.append(send_edge())            # last refresh
        t.quanta = 0
        t.write()                            # send low, quanta 0
        x0, x1 = send_edge()                 # Q = 0
        t.write()
        last0 = edges[-1][0]
        # Run on past the end of the last 0xFFFF pause, so a Q = 0 frame
        # that did not resume TX shows as a longer stall.
        time.sleep(max(0.0, last0 + full_s - time.perf_counter()) + 3 * f_s + 0.1)
        nxt = edges[1:] + [(x0, x1)]
        slack = min(p0 + full_s - (n1 + 2 * f_s) for (p0, _), (_, n1) in zip(edges, nxt))
        return t.stop(), edges[0], last0, x0, x1, len(edges), slack

    # A host stall (Windows, USB) between two writes can let a pause run out
    # before the next one lands, which says nothing about the MAC: the
    # attempt is void and is repeated, up to three times.
    for attempt in range(1, 4):
        s, (on0, on1), last0, x0, x1, sent, slack = xon_once()
        if slack > 0:
            break
        print(f"INFO: {name}M PAUSE XON attempt {attempt}: a pause may have run out "
              f"before the next one took effect ({-slack * 1e3:.1f} ms short against "
              f"the {full_s * 1e3:.1f} ms pause); the host stalled, so this attempt "
              "does not count", flush=True)
    valid = slack > 0
    gap = s["max_gap"] * CLK_NS * 1e-9
    lo = x0 - on1 - 2 * f_s
    hi = x1 - on0 + 2 * f_s + 1e-3
    ignored = last0 + full_s - on1 - 2 * f_s     # shortest stall had Q = 0 been ignored
    print(f"  {name}M PAUSE XON (Q=0xffff x{sent}, continuity margin {slack * 1e3:.1f} ms, "
          f"then Q=0 after {x0 - on0:.3f} s): max_gap={gap * 1e3:.1f} ms "
          f"(host bounds {lo * 1e3:.1f}..{hi * 1e3:.1f} ms; ignoring Q=0 would give "
          f">= {ignored * 1e3:.1f} ms) pause_ok={s['pause_ok']} pause_bad={s['pause_bad']}",
          flush=True)
    report("XON: data frames exact and in order", clean(s))
    report(f"XON: all {sent + 1} PAUSE frames came back with every checked field right",
           s["pause_ok"] == sent + 1 and s["pause_bad"] == 0)
    report("XON: each pause took effect before the last could run out", valid)
    report("XON: the 0xffff pauses stopped TX until the Q=0 frame", valid and gap >= lo)
    report("XON: TX resumed within two frames (+1 ms) of the Q=0 frame's write", gap <= hi)
    if ignored > hi:
        report("XON: that was the Q=0 frame, not the 0xffff pause running out",
               valid and lo <= gap <= hi)
    else:
        print(f"INFO: {name}M PAUSE XON: JTAG write times are too long against a "
              f"{full_s * 1e3:.1f} ms pause to tell the Q=0 frame from the pause "
              "running out at this speed (not counted)")
    t.set_pause_rx(0)
    return fails


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
    ap.add_argument("--no-pause", action="store_true", help="skip the PAUSE tests")
    ap.add_argument("--pause-quanta", type=lambda v: int(v, 0), default=0x2000,
                    help="quanta for the honored/ignored PAUSE tests")
    a = ap.parse_args()
    if a.tap is not None and not 0 <= a.tap <= 31:
        ap.error("--tap must be 0..31")
    if not MIN_QUANTA <= a.pause_quanta <= 0xFFFF:
        ap.error(f"--pause-quanta must be {MIN_QUANTA:#x}..0xffff: the honored and "
                 "ignored checks allow two longest-frame times either way, so the "
                 "pause must be at least four of them")

    t = SelfTest(a.port)
    s = t.status()
    if s["marker"] != MARKER:
        sys.exit(f"ERROR: self-test marker {s['marker']:#x} != {MARKER:#x} - "
                 "is the build_arty_rgmii_lb bitstream programmed?")
    if not (s["init_done"] and s["mmcm_locked"] and s["idelay_rdy"]):
        sys.exit(f"ERROR: self-test not ready (init_done={s['init_done']}, "
                 f"mmcm_locked={s['mmcm_locked']}, idelay_rdy={s['idelay_rdy']})")
    t.speed, t.tap, t.rx_en = s["speed"], s["tap"], s["pause_rx_en"]

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
        if not a.no_pause:
            fails += pause_tests(t, name, a.pause_quanta)

    t.set_speed(SPEEDS["1000"])
    print("ALL TESTS PASSED" if not fails else f"{fails} check(s) FAILED")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
