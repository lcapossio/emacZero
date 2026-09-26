#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""sfp_lb_test.py - Run the ZCU106 SFP0 <-> SFP1 loopback test over JTAG.

Needs the loopback bitstream (build_zcu106.tcl -tclargs lb) on the board, a
fiber between the SFP0 and SFP1 modules, and a hw_server on :3121. Talks to
the fcapz EIO in zcu106_top (eio-write bit 0 = run, bit 1 = clear; eio-read
bits [319:0]) through the fcapz CLI from the fcapz submodule.

The tester on SFP1 sends ARP requests, pings and UDP port-9999 frames to the
emacZero demo on SFP0 and checks every reply. PASS requires both 1000BASE-X
links up, replies of all three kinds, and no bad replies or timeouts.

    python fpga/zcu106/scripts/sfp_lb_test.py --seconds 30
"""

import argparse
import os
import subprocess
import sys
import time

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
FCAPZ_HOST = os.path.join(REPO, "fcapz", "host")

MARKER = 0x106
FIELDS = [  # (name, lsb, width) within the 320-bit EIO input
    ("tx_count", 0, 32),
    ("ok_arp", 32, 32),
    ("ok_icmp", 64, 32),
    ("ok_udp", 96, 32),
    ("bad", 128, 32),
    ("timeouts", 160, 32),
    ("max_rtt", 192, 16),
    ("first_reason", 208, 4),
    ("first_kind", 212, 2),
    ("first_idx", 214, 16),
    ("first_got", 230, 8),
    ("first_exp", 238, 8),
    ("first_seq", 246, 16),
    ("init_done", 262, 1),
    ("run", 263, 1),
    ("sfp0_status", 264, 16),
    ("sfp1_status", 280, 16),
    ("sfp0_resetdone", 296, 1),
    ("sfp1_resetdone", 297, 1),
    ("refclk_ready", 298, 1),
    ("marker", 308, 12),
]
REASONS = {1: "byte mismatch", 2: "wrong length", 3: "terror (FCS)",
           4: "IPv4 header checksum", 5: "ICMP checksum", 6: "timeout",
           7: "unexpected frame"}
KINDS = {0: "ARP", 1: "ICMP", 2: "UDP"}


def fcapz(args, base, retries=5):
    """Run one fcapz CLI command, retrying transient JTAG enumeration misses."""
    env = dict(os.environ)
    env["PYTHONPATH"] = FCAPZ_HOST + os.pathsep + env.get("PYTHONPATH", "")
    last = ""
    for _ in range(retries):
        r = subprocess.run([sys.executable, "-m", "fcapz.cli"] + base + args,
                           capture_output=True, text=True, env=env)
        out = (r.stdout + r.stderr).strip()
        if r.returncode == 0:
            return out
        last = out
        time.sleep(2)
    sys.exit(f"ERROR: fcapz {' '.join(args)} failed:\n{last}")


def read_status(base):
    raw = int(fcapz(["eio-read"], base).splitlines()[-1], 16)
    return {name: (raw >> lsb) & ((1 << w) - 1) for name, lsb, w in FIELDS}


def link(st):
    """Decode PCS/PMA status_vector bits [0] link status and [1] link sync."""
    return f"link={st & 1} sync={(st >> 1) & 1}"


def show(s, label):
    ok = s["ok_arp"] + s["ok_icmp"] + s["ok_udp"]
    print(f"{label}: tx={s['tx_count']} ok={ok} (arp={s['ok_arp']} "
          f"icmp={s['ok_icmp']} udp={s['ok_udp']}) bad={s['bad']} "
          f"timeouts={s['timeouts']} max_rtt={s['max_rtt'] * 8} ns", flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--seconds", type=float, default=30.0, help="traffic duration")
    ap.add_argument("--port", default="3121", help="hw_server port")
    ap.add_argument("--tap", default="xczu7.tap",
                    help="hw_server FPGA target (JTAG device name + .tap)")
    ap.add_argument("--interval", type=float, default=5.0, help="progress read period")
    a = ap.parse_args()
    base = ["--backend", "hw_server", "--port", a.port, "--tap", a.tap]

    s = read_status(base)
    if s["marker"] != MARKER:
        sys.exit(f"ERROR: marker {s['marker']:#x} != {MARKER:#x} - "
                 "is the loopback bitstream (build_zcu106.tcl -tclargs lb) programmed?")
    print(f"refclk_ready={s['refclk_ready']}  "
          f"SFP0: resetdone={s['sfp0_resetdone']} {link(s['sfp0_status'])}  "
          f"SFP1: resetdone={s['sfp1_resetdone']} {link(s['sfp1_status'])}  "
          f"tester init_done={s['init_done']}")
    if not (s["sfp0_status"] & 1 and s["sfp1_status"] & 1):
        sys.exit("ERROR: a 1000BASE-X link is down - check the fiber, the modules "
                 "and DIP 0 (auto-negotiation)")

    fcapz(["eio-write", "0x2"], base)          # clear
    time.sleep(0.2)
    fcapz(["eio-write", "0x1"], base)          # run
    t0 = time.monotonic()
    while time.monotonic() - t0 < a.seconds:
        time.sleep(min(a.interval, max(0.0, a.seconds - (time.monotonic() - t0))))
        # Progress only: counters move while this reads them, so a value can
        # be torn. The verdict uses the read after stop.
        show(read_status(base), f"  t={time.monotonic() - t0:5.1f}s")
    fcapz(["eio-write", "0x0"], base)          # stop; the last reply drains
    time.sleep(0.5)
    s = read_status(base)
    show(s, "final")

    ok = s["ok_arp"] + s["ok_icmp"] + s["ok_udp"]
    checks = [
        ("both links up", s["sfp0_status"] & 1 and s["sfp1_status"] & 1),
        ("requests were sent", s["tx_count"] > 0),
        ("ARP, ICMP and UDP replies all seen",
         s["ok_arp"] > 0 and s["ok_icmp"] > 0 and s["ok_udp"] > 0),
        ("every request got a correct reply", ok == s["tx_count"]),
        ("no bad replies", s["bad"] == 0),
        ("no timeouts", s["timeouts"] == 0),
    ]
    fails = 0
    for name, good in checks:
        print(f"{'PASS' if good else 'FAIL'}: {name}")
        fails += not good
    if s["bad"] or s["timeouts"]:
        print(f"INFO: first failure: {REASONS.get(s['first_reason'], s['first_reason'])}, "
              f"{KINDS.get(s['first_kind'], s['first_kind'])} seq={s['first_seq']}, "
              f"byte {s['first_idx']} got {s['first_got']:#04x} "
              f"expected {s['first_exp']:#04x}")
    print("ALL TESTS PASSED" if not fails else f"{fails} check(s) FAILED")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
