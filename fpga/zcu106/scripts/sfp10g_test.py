#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""sfp10g_test.py - Drive and read the ZCU106 10GBASE-R bring-up design
(zcu106_10g_top, build_zcu106_10g.tcl) over its fcapz EIO on USER3.

Needs the bitstream on the board and a hw_server on :3121.

    python fpga/zcu106/scripts/sfp10g_test.py status
    python fpga/zcu106/scripts/sfp10g_test.py loop --loopback pma --seconds 10
    python fpga/zcu106/scripts/sfp10g_test.py loop --loopback none   # over the fibre
    python fpga/zcu106/scripts/sfp10g_test.py mac --loopback pma --len 60 --seconds 10
    python fpga/zcu106/scripts/sfp10g_test.py csr 0xC0          # read a MAC CSR
    python fpga/zcu106/scripts/sfp10g_test.py csr 0x04 0x43     # write one

status   prints the GT / PCS state, clock meters and checker counters.
loop     sets the loopback (none / pcs / pma), restarts the RX path, waits for
         block lock, then runs the generator for --seconds with --words words
         per frame (header + payload, 1..255) and --ipg idle words, and checks
         that every frame came back good, in sequence, with no lock loss.
         --inject adds one payload bit error, which must show up as exactly
         one bad frame. Exit status 0 on PASS.
mac      the same through the 10G MAC system eth_mac_sys_10g (MAC mode):
         Ethernet frames of --len bytes before the FCS (60..16000; --sweep
         steps 60..len frame by frame), --ipg idle 200 MHz cycles between
         frames, every byte checked after the RX FIFO. Prints the frame rate
         against the line rate for that length and the MAC's own counters
         (read over the CSR port), which must agree. --inject must give
         exactly one bad frame (sent with a good FCS, caught by the payload
         compare). Above 9014 bytes every frame must be counted oversize and
         dropped by the MAC; --sweep and --inject need --len <= 9014.
csr      reads (one argument) or writes (two) an eth_mac_sys_10g CSR; see
         the register map in rtl/eth_mac_sys_10g.v.

The `loop` test frames are not Ethernet frames (no FCS); the `mac` frames
are, but go to a made-up unicast address. Run traffic only in a loopback or
over a fibre between two cages / boards running this design, not toward a
switch.
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

MARKER, LAYOUT = 0x10F0, 3
EIO_IN_W, EIO_OUT_W = 640, 128

# probe_in fields (name, lsb, width), see the EIO block in zcu106_10g_top.v
FIELDS = [
    ("status", 0, 32),
    ("good_frames", 32, 32),
    ("bad_frames", 64, 32),
    ("seq_gaps", 96, 32),
    ("bad_words", 128, 32),
    ("lf_words", 160, 32),
    ("ber_cnt", 192, 16),
    ("lock_losses", 224, 32),
    ("fm_tx", 264, 24),
    ("fm_rx", 296, 24),
    ("fm_ref", 328, 24),
    ("gen_frames", 352, 32),
    ("mac_gen_frames", 384, 32),
    ("mac_good", 416, 32),
    ("mac_bad", 448, 32),
    ("mac_tuser", 480, 32),
    ("mac_seq_gaps", 512, 32),
    ("csr_ack", 544, 1),
    ("csr_rdata", 576, 32),
    ("layout", 616, 8),
    ("marker", 624, 16),
]
STATUS_BITS = [
    "qpll0lock", "gtpowergood", "txuserrdy", "rxuserrdy",
    "rx_done", "tx_done", "rxresetdone", "txresetdone",
    "rxpmaresetdone", "txpmaresetdone", "rxprgdivresetdone", "txprgdivresetdone",
    None, None, None, None,     # [14:12] rxbufstatus, [15] 0
    None, None, "qpll0refclklost", "block_lock",   # [17:16] txbufstatus
    "hi_ber", "rxcdrlock", "good_seen", "bad_seen",
]

# probe_out bits
LOOPBACK = {"none": 0, "pcs": 1, "pma": 2}
B_TXPOL, B_RXPOL, B_LPM, B_TXRST, B_RXRST = 3, 4, 5, 6, 7
B_GEN, B_INJ, B_CLEAR, B_GTRST, B_LASER_OFF = 8, 9, 10, 11, 12
B_MAC, B_SWEEP = 13, 14
B_CSR_GO, B_CSR_WRITE = 120, 121

# eth_mac_sys_10g CSRs (rtl/eth_mac_sys_10g.v)
R_TX_FRAMES, R_TX_BYTES, R_RX_FRAMES, R_RX_BYTES = 0xB0, 0xB8, 0xC0, 0xC8
MAC_COUNTERS = [  # (name, address, 64-bit)
    ("TX_FRAMES", R_TX_FRAMES, True), ("TX_BYTES", R_TX_BYTES, True),
    ("RX_FRAMES", R_RX_FRAMES, True), ("RX_BYTES", R_RX_BYTES, True),
    ("RX_ERR_FCS", 0xD0, False), ("RX_ERR_CTL", 0xD4, False),
    ("RX_ERR_OVERSIZE", 0xD8, False), ("RX_ERR_UNDERSIZE", 0xDC, False),
    ("RX_DROP", 0xE8, False), ("RX_DISCARD", 0xEC, False),
    ("TX_UNDERRUN", 0xF0, False), ("TX_DROP", 0xF4, False),
    ("TX_ERR", 0xF8, False), ("LOCK_LOSS", 0xFC, False),
]
WINDOW_S = (1 << 22) / 50e6     # frequency meter window


def transport(args):
    fpga = args.tap.removesuffix(".tap")
    return XilinxHwServerTransport(host=args.host, port=args.port, fpga_name=fpga,
                                   **_chain_shape_kwargs(fpga))


class Board:
    def __init__(self, args):
        self.eio = EioController(transport(args), chain=3)
        self.eio.connect()
        if (self.eio.in_w, self.eio.out_w) != (EIO_IN_W, EIO_OUT_W):
            raise SystemExit("EIO on USER3 is %d in / %d out, expected %d / %d: "
                             "not the 10G bring-up build"
                             % (self.eio.in_w, self.eio.out_w, EIO_IN_W, EIO_OUT_W))
        f = self.read()
        if (f["marker"], f["layout"]) != (MARKER, LAYOUT):
            raise SystemExit("EIO marker 0x%04x layout %d, expected 0x%04x layout %d"
                             % (f["marker"], f["layout"], MARKER, LAYOUT))
        self.ctrl = self.eio.read_outputs()

    def close(self):
        self.eio.close()

    def read(self):
        # counters cross into TCK unsynchronized: take two equal reads
        prev = None
        for _ in range(20):
            raw = self.eio.read_inputs()
            if raw == prev:
                break
            prev = raw
        f = {n: (raw >> lsb) & ((1 << w) - 1) for n, lsb, w in FIELDS}
        st = f["status"]
        for i, name in enumerate(STATUS_BITS):
            if name:
                f[name] = (st >> i) & 1
        f["rxbufstatus"] = (st >> 12) & 7
        f["txbufstatus"] = (st >> 16) & 3
        return f

    def write(self, value):
        self.eio.write_outputs(value)
        got = self.eio.read_outputs()
        if got != value:
            raise RuntimeError("EIO output reads 0x%x after writing 0x%x" % (got, value))
        self.ctrl = value

    def set_bit(self, bit, on):
        v = (self.ctrl | (1 << bit)) if on else (self.ctrl & ~(1 << bit))
        self.write(v)

    def pulse(self, bit, hold=0.01):
        self.set_bit(bit, True)
        time.sleep(hold)
        self.set_bit(bit, False)

    def set_field(self, lsb, width, value):
        m = ((1 << width) - 1) << lsb
        self.write((self.ctrl & ~m) | ((value << lsb) & m))

    def csr(self, addr, data=None):
        """One eth_mac_sys_10g CSR access; returns the value read."""
        v = self.ctrl
        v &= ~((0xFF << 80) | (0xFFFFFFFF << 88) | (1 << B_CSR_WRITE))
        v |= (addr & 0xFF) << 80
        if data is not None:
            v |= ((data & 0xFFFFFFFF) << 88) | (1 << B_CSR_WRITE)
        self.write(v)
        go = ((self.ctrl >> B_CSR_GO) & 1) ^ 1
        self.set_bit(B_CSR_GO, go)
        for _ in range(50):
            f = self.read()
            if f["csr_ack"] == go:
                return f["csr_rdata"]
        raise RuntimeError("CSR access to 0x%02x did not finish" % addr)

    def mac_counters(self):
        c = {}
        for name, addr, wide in MAC_COUNTERS:
            v = self.csr(addr)
            if wide:
                v |= self.csr(addr + 4) << 32
            c[name] = v
        return c

    def mac_clear(self):
        for _, addr, _ in MAC_COUNTERS:
            self.csr(addr, 0)


def mhz(count):
    return count / WINDOW_S / 1e6


def show(f):
    flags = " ".join(n for n in STATUS_BITS if n and f.get(n))
    print("status 0x%08x: %s" % (f["status"], flags))
    print("  rxbufstatus %d  txbufstatus %d" % (f["rxbufstatus"], f["txbufstatus"]))
    print("  clocks: txusrclk2 %.4f MHz  rxusrclk2 %.4f MHz  refclk %.4f MHz"
          % (mhz(f["fm_tx"]), mhz(f["fm_rx"]), mhz(f["fm_ref"])))
    print("  block_lock %d hi_ber %d ber_cnt %d lock_losses %d lf_words %d"
          % (f["block_lock"], f["hi_ber"], f["ber_cnt"], f["lock_losses"], f["lf_words"]))
    print("  gen_frames %d good %d bad %d seq_gaps %d bad_words %d"
          % (f["gen_frames"], f["good_frames"], f["bad_frames"], f["seq_gaps"],
             f["bad_words"]))
    print("  MAC: gen_frames %d good %d bad %d tuser %d seq_gaps %d"
          % (f["mac_gen_frames"], f["mac_good"], f["mac_bad"], f["mac_tuser"],
             f["mac_seq_gaps"]))


def wait_lock(b, timeout=2.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        f = b.read()
        if f["rx_done"] and f["block_lock"] and not f["hi_ber"]:
            return f
        time.sleep(0.05)
    return None


def cmd_loop(b, args):
    words = args.words
    if not 1 <= words <= 255:
        raise SystemExit("--words must be 1..255")
    b.set_bit(B_GEN, False)
    time.sleep(0.01)
    b.set_bit(B_MAC, False)
    b.set_field(0, 3, LOOPBACK[args.loopback])
    b.set_bit(B_LPM, args.lpm)
    b.set_field(16, 8, (words - 8) & 0xFF)
    b.set_field(24, 8, args.ipg)
    b.pulse(B_RXRST)
    f = wait_lock(b)
    if f is None:
        show(b.read())
        print("FAIL: no block lock")
        return 1
    b.pulse(B_CLEAR)
    g0 = b.read()["gen_frames"]
    b.set_bit(B_GEN, True)
    if args.inject:
        time.sleep(args.seconds / 2)
        b.pulse(B_INJ)
        time.sleep(args.seconds / 2)
    else:
        time.sleep(args.seconds)
    b.set_bit(B_GEN, False)
    time.sleep(0.05)
    f = b.read()
    show(f)
    sent = (f["gen_frames"] - g0) & 0xFFFFFFFF
    # line rate: (words + 2) words per frame plus ipg, 32 of 33 cycles carry a
    # word at 161.13 MHz -> payload Gb/s of the test frames
    rate = sent * (words + 2 + args.ipg) * 64 / args.seconds / 1e9
    print("  sent %d frames in %.1f s: %.3f Gb/s of XGMII words (10.000 max)"
          % (sent, args.seconds, rate))
    want_bad = 1 if args.inject else 0
    ok = (f["good_frames"] + f["bad_frames"] == sent and f["bad_frames"] == want_bad
          and f["seq_gaps"] == 0 and f["lock_losses"] == 0
          and f["bad_words"] == want_bad and f["block_lock"])
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


def cmd_mac(b, args):
    if not 60 <= args.len <= 16000:
        raise SystemExit("--len must be 60..16000")
    if args.len > 9014 and (args.sweep or args.inject):
        # how many swept frames are oversize depends on where the sweep is
        # when the run starts, and an injected error hides in a frame that
        # is flagged anyway: neither can be checked
        raise SystemExit("--sweep and --inject need --len <= 9014 "
                         "(the RX MAC's jumbo limit)")
    b.set_bit(B_GEN, False)
    time.sleep(0.01)
    b.set_bit(B_MAC, True)
    b.set_bit(B_SWEEP, args.sweep)
    b.set_field(0, 3, LOOPBACK[args.loopback])
    b.set_bit(B_LPM, args.lpm)
    b.set_field(64, 16, args.len)
    b.set_field(24, 8, args.ipg)
    b.pulse(B_RXRST)
    f = wait_lock(b)
    if f is None:
        show(b.read())
        print("FAIL: no block lock")
        return 1
    time.sleep(0.01)
    b.pulse(B_CLEAR)
    b.mac_clear()
    g0 = b.read()["mac_gen_frames"]
    b.set_bit(B_GEN, True)
    if args.inject:
        time.sleep(args.seconds / 2)
        b.pulse(B_INJ)
        time.sleep(args.seconds / 2)
    else:
        time.sleep(args.seconds)
    b.set_bit(B_GEN, False)
    time.sleep(0.05)
    f = b.read()
    show(f)
    sent = (f["mac_gen_frames"] - g0) & 0xFFFFFFFF
    # line bytes per frame: preamble/SFD 8 + frame + FCS 4 + 12 gap on average
    avg_len = (60 + args.len) / 2 if args.sweep else args.len
    pps = sent / args.seconds
    line = 10e9 / ((avg_len + 4 + 8 + 12) * 8)
    print("  sent %d frames in %.1f s: %.4f Mpps, %.3f Gb/s of frames with FCS; "
          "line rate for %s bytes %.4f Mpps (%.2f%%)"
          % (sent, args.seconds, pps / 1e6, pps * (avg_len + 4) * 8 / 1e9,
             "%.0f" % avg_len, line / 1e6, 100 * pps / line))
    c = b.mac_counters()
    print("  MAC counters: " + " ".join("%s %d" % kv for kv in c.items()))
    want_bad = 1 if args.inject else 0
    over = args.len > 9014
    if over:
        # above the RX MAC's jumbo limit (9018 bytes with the FCS): every
        # frame is counted oversize and dropped, none reaches the checker
        print("  frames over 9018 bytes: expecting every one dropped (oversize)")
    delivered = 0 if over else sent
    ok = (f["mac_good"] + f["mac_bad"] == delivered and f["mac_bad"] == want_bad
          and f["mac_tuser"] == 0 and f["mac_seq_gaps"] == 0
          and c["TX_FRAMES"] == sent and c["TX_UNDERRUN"] == 0
          and c["RX_ERR_FCS"] == 0 and c["RX_DROP"] == 0
          and c["RX_FRAMES"] == delivered
          and c["RX_ERR_OVERSIZE"] == (sent if over else 0)
          and f["lock_losses"] == 0 and f["block_lock"])
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=3121)
    ap.add_argument("--tap", default="xczu7.tap")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    lp = sub.add_parser("loop")
    lp.add_argument("--loopback", choices=sorted(LOOPBACK), default="pma")
    lp.add_argument("--seconds", type=float, default=5.0)
    lp.add_argument("--words", type=int, default=8)
    lp.add_argument("--ipg", type=int, default=0)
    lp.add_argument("--lpm", action="store_true", help="LPM receiver instead of DFE")
    lp.add_argument("--inject", action="store_true")
    mp = sub.add_parser("mac")
    mp.add_argument("--loopback", choices=sorted(LOOPBACK), default="pma")
    mp.add_argument("--seconds", type=float, default=5.0)
    mp.add_argument("--len", type=int, default=60)
    mp.add_argument("--sweep", action="store_true")
    mp.add_argument("--ipg", type=int, default=0)
    mp.add_argument("--lpm", action="store_true", help="LPM receiver instead of DFE")
    mp.add_argument("--inject", action="store_true")
    cp = sub.add_parser("csr")
    cp.add_argument("addr", type=lambda x: int(x, 0))
    cp.add_argument("data", type=lambda x: int(x, 0), nargs="?")
    for name in ("restart-rx", "restart-tx", "gt-reset"):
        sub.add_parser(name)
    args = ap.parse_args()

    b = Board(args)
    try:
        if args.cmd == "status":
            show(b.read())
            return 0
        if args.cmd == "loop":
            return cmd_loop(b, args)
        if args.cmd == "mac":
            return cmd_mac(b, args)
        if args.cmd == "csr":
            v = b.csr(args.addr, args.data)
            if args.data is None:
                print("0x%02x: 0x%08x (%d)" % (args.addr, v, v))
            return 0
        bit = {"restart-rx": B_RXRST, "restart-tx": B_TXRST, "gt-reset": B_GTRST}[args.cmd]
        b.pulse(bit)
        time.sleep(0.2)
        show(b.read())
        return 0
    finally:
        b.close()


if __name__ == "__main__":
    sys.exit(main())
