#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""sfp_lb_test.py - Run the ZCU106 SFP0 <-> SFP1 loopback tests over JTAG.

Needs the loopback bitstream (build_zcu106.tcl -tclargs lb) on the board, a
fiber between the SFP0 and SFP1 modules, and a hw_server on :3121. Drives the
fcapz EIO in zcu106_top through the fcapz host library from the fcapz
submodule, over one hw_server session.

The tester on SFP1 sends ARP requests, pings and UDP port-9999 frames to the
emacZero demo on SFP0 and checks every reply. The tests:

  links      identity, reference clock, both 1000BASE-X links up
  traffic    ARP / ICMP / UDP traffic for --seconds, every reply correct
  negative   frames the demo must ignore (wrong MAC / IP / ARP target / UDP
             port, bad IP or ICMP checksum, bad FCS, GMII tx_er) get no reply
  short      ICMP 0..17-byte and UDP 1..18-byte payloads (padded frames):
             every reply correct
  sfp1-laser SFP1 laser off for 1 s: both links drop and come back, then
             traffic is clean again (skipped if the link never drops: a
             board jumper can force the transmitter on)
  sfp0-laser the same with the SFP0 laser (J16 can force it on)
  sfp1-reset SFP1 PCS/PMA reset: link drops and comes back, clean traffic
  an-off     auto-negotiation off on both cores: link up, clean traffic,
             then AN back on
  an-restart AN restart on both cores: link comes back, clean traffic
  soak       long traffic run (--soak seconds, off by default)

    python fpga/zcu106/scripts/sfp_lb_test.py
    python fpga/zcu106/scripts/sfp_lb_test.py --tests links,traffic --seconds 60
    python fpga/zcu106/scripts/sfp_lb_test.py --tests links,soak --soak 3600
"""

import argparse
import os
import sys
import time

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
sys.path.insert(0, os.path.join(REPO, "fcapz", "host"))

from fcapz.cli import _chain_shape_kwargs          # noqa: E402
from fcapz.eio import EioController                 # noqa: E402
from fcapz.transport import XilinxHwServerTransport  # noqa: E402

MARKER, LAYOUT = 0x106, 2
IN_W = 608
FIELDS = [  # (name, lsb, width) within the EIO input, layout 2
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
    ("ok_neg", 264, 32),
    ("neg_fail", 296, 8),
    ("rx_bytes", 304, 48),
    ("neg_replies", 352, 32),
    ("sfp0_status", 384, 16),
    ("sfp1_status", 400, 16),
    ("sfp0_downs", 416, 16),
    ("sfp1_downs", 432, 16),
    ("demo_rx_frames", 448, 16),
    ("demo_tx_frames", 464, 16),
    ("tst_tx_frames", 480, 16),
    ("tst_rx_frames", 496, 16),
    ("demo_rx_errs", 512, 16),
    ("tst_rx_errs", 528, 16),
    ("userclk2_count", 544, 24),
    ("sfp0_resetdone", 576, 1),
    ("sfp1_resetdone", 577, 1),
    ("refclk_ready", 578, 1),
    ("an_disabled", 579, 1),
    ("refclk_si5328", 580, 1),
    ("mac_running", 581, 1),
    ("layout", 592, 4),
    ("marker", 596, 12),
]
# EIO output bits
RUN, CLEAR, NEG, SHORT = 1 << 0, 1 << 1, 1 << 2, 1 << 3
LASER1_OFF, SFP1_RST, AN_OFF, AN_RESTART = 1 << 4, 1 << 5, 1 << 6, 1 << 7
LASER0_OFF = 1 << 8

REASONS = {1: "byte mismatch", 2: "wrong length", 3: "terror (FCS)",
           4: "IPv4 header checksum", 5: "ICMP checksum", 6: "timeout",
           7: "unexpected frame"}
KINDS = {0: "ARP", 1: "ICMP", 2: "UDP"}
NEG_VARIANTS = ["wrong destination MAC", "wrong destination IP",
                "ARP for another IP", "UDP to another port",
                "bad IPv4 header checksum", "bad ICMP checksum",
                "bad FCS", "GMII tx_er mid-frame"]


class Board:
    """One hw_server session to the loopback EIO."""

    def __init__(self, host, port, tap):
        fpga = tap.removesuffix(".tap")
        t = XilinxHwServerTransport(host=host, port=port, fpga_name=fpga,
                                    **_chain_shape_kwargs(fpga))
        self.eio = EioController(t, chain=3)
        self.eio.connect()
        self.ctrl = 0

    def close(self):
        try:
            self.write(0)
        finally:
            self.eio.close()

    def read(self):
        raw = self.eio.read_inputs()
        return {n: (raw >> lsb) & ((1 << w) - 1) for n, lsb, w in FIELDS}

    def write(self, value):
        self.ctrl = value
        self.eio.write_outputs(value)

    def set(self, bits, on=True):
        self.write((self.ctrl | bits) if on else (self.ctrl & ~bits))

    def pulse(self, bits, seconds=0.1):
        self.set(bits, True)
        time.sleep(seconds)
        self.set(bits, False)

    def clear(self):
        self.pulse(CLEAR, 0.05)

    def links_up(self, s=None):
        s = s or self.read()
        return bool(s["sfp0_status"] & 1 and s["sfp1_status"] & 1
                    and s["mac_running"] and s["init_done"])

    def wait_links(self, timeout=15.0):
        """Wait for both links; returns the time taken, or None."""
        t0 = time.monotonic()
        while time.monotonic() - t0 < timeout:
            if self.links_up():
                return time.monotonic() - t0
            time.sleep(0.1)
        return None

    def traffic(self, seconds, extra=0, progress=0.0):
        """Clear, run for `seconds`, stop, and return the final status."""
        self.set(RUN | NEG | SHORT, False)
        self.clear()
        self.set(RUN | extra)
        t0 = time.monotonic()
        next_show = progress
        while time.monotonic() - t0 < seconds:
            time.sleep(min(0.5, max(0.0, seconds - (time.monotonic() - t0))))
            if progress and time.monotonic() - t0 >= next_show:
                next_show += progress
                # Counters move during the read, so this can be torn; only
                # the read after stop is checked.
                show(self.read(), f"    t={time.monotonic() - t0:6.0f}s")
        self.set(RUN | extra, False)
        time.sleep(0.3)                                    # last reply drains
        return self.read()


def ok_valid(s):
    return s["ok_arp"] + s["ok_icmp"] + s["ok_udp"]


def show(s, label):
    print(f"{label}: tx={s['tx_count']} ok={ok_valid(s)} (arp={s['ok_arp']} "
          f"icmp={s['ok_icmp']} udp={s['ok_udp']}) neg_ok={s['ok_neg']} "
          f"neg_replied={s['neg_replies']} bad={s['bad']} "
          f"timeouts={s['timeouts']} max_rtt={s['max_rtt'] * 8} ns", flush=True)


def hops(s):
    """GMII frame counters along the path (16-bit, wrap), for diagnosis."""
    return (f"GMII frames: tester TX {s['tst_tx_frames']} -> demo RX "
            f"{s['demo_rx_frames']} (rx_er {s['demo_rx_errs']}), demo TX "
            f"{s['demo_tx_frames']} -> tester RX {s['tst_rx_frames']} "
            f"(rx_er {s['tst_rx_errs']})")


def userclk2_mhz(s):
    return s["userclk2_count"] / (2 ** 22 / 50e6) / 1e6


def first_failure(s):
    return (f"first failure: {REASONS.get(s['first_reason'], s['first_reason'])}, "
            f"{KINDS.get(s['first_kind'], s['first_kind'])} seq={s['first_seq']}, "
            f"byte {s['first_idx']} got {s['first_got']:#04x} "
            f"expected {s['first_exp']:#04x}")


class Results:
    def __init__(self):
        self.rows = []

    def add(self, verdict, test, text):
        self.rows.append((verdict, test, text))
        print(f"  {verdict}: {text}", flush=True)

    def check(self, test, cond, text):
        self.add("PASS" if cond else "FAIL", test, text)
        return cond


def clean_traffic(b, r, test, seconds, progress=0.0):
    """Traffic window that must be error-free; returns the status."""
    s = b.traffic(seconds, progress=progress)
    show(s, "  final")
    okv = ok_valid(s)
    r.check(test, s["tx_count"] > 0 and s["ok_arp"] and s["ok_icmp"] and s["ok_udp"],
            "ARP, ICMP and UDP requests sent and answered")
    good = r.check(test, okv == s["tx_count"] and s["bad"] == 0 and s["timeouts"] == 0,
                   f"all {s['tx_count']} requests answered correctly "
                   f"(bad={s['bad']}, timeouts={s['timeouts']})")
    if not good and (s["bad"] or s["timeouts"]):
        print("    " + first_failure(s))
        print("    " + hops(s))
    return s


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
def t_links(b, r, a):
    s = b.read()
    ident = s["marker"] == MARKER and s["layout"] == LAYOUT and b.eio.in_w == IN_W
    if not r.check("links", ident,
                   f"loopback bitstream, EIO layout {s['layout']} ({b.eio.in_w} bits)"):
        raise SystemExit("ERROR: not the current loopback bitstream "
                         "(build_zcu106.tcl -tclargs lb)")
    clk = "Si5328 (125 MHz)" if s["refclk_si5328"] else "USER_MGT_SI570 (156.25 MHz)"
    r.add("INFO", "links", f"reference clock {clk}, AN "
          f"{'disabled (DIP 0)' if s['an_disabled'] else 'enabled'}")
    mhz = userclk2_mhz(s)
    r.check("links", abs(mhz - 125.0) < 0.1, f"userclk2 at {mhz:.3f} MHz")
    r.check("links", s["refclk_ready"], "reference clock ready")
    r.check("links", s["sfp0_resetdone"] and s["sfp1_resetdone"], "both GTs reset done")
    t = b.wait_links(30.0)
    r.check("links", t is not None, "both 1000BASE-X links up, MAC running")


def t_traffic(b, r, a):
    s = clean_traffic(b, r, "traffic", a.seconds, progress=a.interval)
    r.add("INFO", "traffic", f"{s['rx_bytes']} reply bytes, worst round trip "
          f"{s['max_rtt'] * 8 / 1000:.1f} us")


def t_soak(b, r, a):
    if a.soak <= 0:
        r.add("SKIP", "soak", "no --soak duration given")
        return
    s = clean_traffic(b, r, "soak", a.soak, progress=max(a.interval, 60.0))
    # Requests and replies carry about the same bytes; count both directions.
    bits = 2 * 8 * s["rx_bytes"]
    if s["bad"] == 0 and s["timeouts"] == 0 and bits:
        r.add("INFO", "soak", f"{bits:.3g} data bits error-free: bit error rate "
              f"< {3.0 / bits:.1e} (95% confidence)")


def t_negative(b, r, a):
    s = b.traffic(a.neg_seconds, extra=NEG)
    show(s, "  final")
    fail = s["neg_fail"]
    r.check("negative", s["ok_neg"] + s["neg_replies"] >= 16,
            f"{s['ok_neg'] + s['neg_replies']} negative frames sent")
    for v, name in enumerate(NEG_VARIANTS):
        answered = bool(fail >> v & 1)
        r.check("negative", not answered,
                f"variant {v} ({name}) {'ANSWERED' if answered else 'ignored'}")
    r.check("negative", ok_valid(s) + s["ok_neg"] + s["neg_replies"] == s["tx_count"]
            and s["bad"] == 0 and s["timeouts"] == 0,
            "valid requests in between all answered correctly")


def t_short(b, r, a):
    s = b.traffic(5.0, extra=SHORT)
    show(s, "  final")
    n = s["tx_count"] - s["ok_arp"]
    if s["bad"] or s["timeouts"]:
        r.add("INFO", "short", first_failure(s))
    r.check("short", ok_valid(s) == s["tx_count"] and s["ok_icmp"] > 0
            and s["ok_udp"] > 0 and s["bad"] == 0 and s["timeouts"] == 0,
            f"{s['ok_icmp'] + s['ok_udp']} of {n} ICMP/UDP requests with "
            "short payloads answered correctly")


def link_event(b, r, test, bits, hold, expect_down=True, skip_text=""):
    """Apply `bits` for `hold` seconds with no traffic, then check recovery."""
    b.set(RUN | NEG | SHORT, False)
    b.clear()
    b.set(bits)
    time.sleep(hold)
    during = b.read()
    b.set(bits, False)
    t = b.wait_links(30.0)
    after = b.read()
    downs0, downs1 = after["sfp0_downs"], after["sfp1_downs"]
    dropped = (downs0 + downs1) > 0 or not b.links_up(during)
    if expect_down is None:            # laser: may be forced on by a jumper
        if not dropped:
            r.add("SKIP", test, "link never dropped - " + skip_text)
            return False
    elif not expect_down:              # AN restart: a drop is allowed
        r.add("INFO", test, f"link-down events: SFP0 {downs0}, SFP1 {downs1}")
    else:
        r.check(test, dropped, f"link dropped (SFP0 downs={downs0}, "
                f"SFP1 downs={downs1})")
    if not r.check(test, t is not None,
                   f"both links back {'in %.1f s' % t if t is not None else 'NOT within 30 s'}"):
        return False
    clean_traffic(b, r, test, 5.0)
    return True


def t_sfp1_laser(b, r, a):
    link_event(b, r, "sfp1-laser", LASER1_OFF, 1.0, expect_down=None,
               skip_text="TX_DISABLE on AF20 has no effect; the module's "
                         "transmitter is probably forced on by a board jumper")


def t_sfp0_laser(b, r, a):
    link_event(b, r, "sfp0-laser", LASER0_OFF, 1.0, expect_down=None,
               skip_text="SFP0 laser is probably forced on (J16)")


def t_sfp1_reset(b, r, a):
    link_event(b, r, "sfp1-reset", SFP1_RST, 0.2)


def t_an_off(b, r, a):
    if b.read()["an_disabled"]:
        r.add("SKIP", "an-off", "AN already disabled by DIP 0")
        return
    b.set(RUN | NEG | SHORT, False)
    b.set(AN_OFF)
    time.sleep(0.2)
    s = b.read()
    r.check("an-off", s["an_disabled"], "AN disabled on both cores")
    t = b.wait_links(10.0)
    if t is None:                      # a restart may be needed to relink
        b.pulse(AN_RESTART)
        t = b.wait_links(10.0)
    if r.check("an-off", t is not None, "links up with AN off"):
        clean_traffic(b, r, "an-off", 5.0)
    b.set(AN_OFF, False)
    b.pulse(AN_RESTART)
    t = b.wait_links(15.0)
    if r.check("an-off", t is not None, "links up again with AN back on"):
        clean_traffic(b, r, "an-off", 5.0)


def t_an_restart(b, r, a):
    link_event(b, r, "an-restart", AN_RESTART, 0.1, expect_down=False)


TESTS = {
    "links": t_links,
    "traffic": t_traffic,
    "negative": t_negative,
    "short": t_short,
    "sfp1-laser": t_sfp1_laser,
    "sfp0-laser": t_sfp0_laser,
    "sfp1-reset": t_sfp1_reset,
    "an-off": t_an_off,
    "an-restart": t_an_restart,
    "soak": t_soak,
}


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--tests", default=",".join(TESTS),
                    help="comma-separated tests (default: all)")
    ap.add_argument("--seconds", type=float, default=30.0, help="traffic test duration")
    ap.add_argument("--neg-seconds", type=float, default=10.0, help="negative test duration")
    ap.add_argument("--soak", type=float, default=0.0, help="soak duration (0 = skip)")
    ap.add_argument("--interval", type=float, default=10.0, help="progress read period")
    ap.add_argument("--host", default="127.0.0.1", help="hw_server host")
    ap.add_argument("--port", type=int, default=3121, help="hw_server port")
    ap.add_argument("--tap", default="xczu7.tap",
                    help="hw_server FPGA target (JTAG device name + .tap)")
    a = ap.parse_args()
    names = [t.strip() for t in a.tests.split(",") if t.strip()]
    for n in names:
        if n not in TESTS:
            sys.exit(f"ERROR: unknown test {n!r} (have: {', '.join(TESTS)})")
    if "links" in names:
        names.remove("links")
    names.insert(0, "links")           # always identify the board first

    b = Board(a.host, a.port, a.tap)
    r = Results()
    try:
        for n in names:
            print(f"== {n}", flush=True)
            TESTS[n](b, r, a)
    finally:
        b.close()

    print("\nSummary:")
    counts = {}
    for verdict, test, text in r.rows:
        counts[verdict] = counts.get(verdict, 0) + 1
        if verdict != "PASS":
            print(f"  {verdict:7s} {test}: {text}")
    print("  " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    fails = counts.get("FAIL", 0)
    print("ALL TESTS PASSED" if not fails else f"{fails} check(s) FAILED")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
