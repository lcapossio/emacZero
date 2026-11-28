#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""sfp10g_test.py - Drive and read the ZCU106 10GBASE-R design
(zcu106_10g_top, build_zcu106_10g.tcl) over its fcapz EIO on USER3.

Needs the bitstream on the board and a hw_server on :3121. The design has two
ports, SFP0 and SFP1; --sfp picks the one loop, mac, service, csr and the
resets act on (default 0).

    python fpga/zcu106/scripts/sfp10g_test.py status
    python fpga/zcu106/scripts/sfp10g_test.py loop --loopback pma --seconds 10
    python fpga/zcu106/scripts/sfp10g_test.py mac --loopback pma --len 60 --seconds 10
    python fpga/zcu106/scripts/sfp10g_test.py --sfp 1 mac --loopback pma --len 1514
    python fpga/zcu106/scripts/sfp10g_test.py mac --csum --sweep --len 1514
    python fpga/zcu106/scripts/sfp10g_test.py dual --len 60 --seconds 10
    python fpga/zcu106/scripts/sfp10g_test.py dual --sweep --len 1514 --len1 9000
    python fpga/zcu106/scripts/sfp10g_test.py dual --udp --len 9014 --seconds 10
    python fpga/zcu106/scripts/sfp10g_test.py fault --len 60
    python fpga/zcu106/scripts/sfp10g_test.py --sfp 1 pause --len 1514
    python fpga/zcu106/scripts/sfp10g_test.py service --ip 192.168.10.200
    python fpga/zcu106/scripts/sfp10g_test.py csr 0xC0          # read a MAC CSR
    python fpga/zcu106/scripts/sfp10g_test.py csr 0x04 0x43     # write one

status   prints both ports' GT / PCS state, clock meters and checker counters.
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
         --csum (implies --udp, --len <= 9014) tests the MAC's checksum
         offload: the generator sends junk IPv4 and UDP checksums and the
         checker requires a correct UDP checksum (it sums each datagram
         itself). First for --seconds with the MAC's inserter and checker on
         (CTRL[7], CTRL[9]): every frame must arrive good, none failing the
         MAC's check (RX_ERR_CSUM 0). Then for 1 s with the checker alone:
         every frame must fail it and be dropped (RX_ERR_CSUM = RX_DISCARD =
         frames sent, none at the checker). CTRL is restored after.
dual     MAC mode on both ports at once over a fibre from SFP0 to SFP1 (no
         loopback): each port sends --len byte frames (port 1 --len1 if
         given; --sweep makes both sweep 60..their length) and checks every
         byte of the other's. Passes when frames went each way, every one
         arrived good and in order and both MACs' counters agree (TX_FRAMES
         and TX_BYTES of one = RX_FRAMES and RX_BYTES of the other, no error,
         drop or underrun). --inject puts one bad frame in port 0's stream,
         which port 1 must count once. Lengths up to 9014.
fault    link fault signalling over the same fibre: dual traffic of --len
         bytes, then SFP1's transmitter inhibited (held at a constant level)
         for --off seconds, which darkens SFP1 -> SFP0 (neither laser can be
         turned off on this board). SFP0 must report a local fault and send
         remote fault sequences, SFP1 must report the remote fault, and both
         MACs must stop starting frames, holding the generators off. With
         the transmitter back on, both faults must clear; the traffic is
         stopped and drained, and up to there SFP0 -> SFP1 must be lossless
         (every frame sent arrives, in order) while SFP1 -> SFP0 may lose
         only the frames on the fibre before SFP1 saw the remote fault: one
         sequence gap of at most CUT_LOST_MAX frames, no bad frame. Then a
         second traffic window, started and ended idle, must deliver every
         frame sent, both ways (generator, TX_FRAMES, RX_FRAMES and checker
         counts equal; no bad frame, sequence gap or FCS error).
pause    802.3x PAUSE on the --sfp port in a loopback: MAC mode with --len
         byte frames (60..6000) and the checker throttled to take a beat on
         16 - --throttle of every 16 clk_app cycles, far below line rate.
         First for 1 s without PAUSE, which must overflow the RX FIFO
         (RX_DROP), then for --seconds with automatic PAUSE (XOFF set to
         leave room for four frames above it, XON half of that, quanta
         --quanta): the port's own PAUSE frames come back and slow its
         sender, so every frame must arrive good and in order with no
         RX_DROP. The PAUSE frames must be counted sent and received
         (PAUSE_TX_CNT = PAUSE_RX_CNT > 0), in TX_FRAMES and RX_FRAMES, and
         dropped at the address filter (RX_DISCARD). Prints the frame rate
         against what the throttled checker can take.
--udp    (mac, dual) the frames are IPv4 / UDP datagrams instead (10.0.0.2
         -> 10.0.0.1, port 5001 -> 5001, UDP payload --len - 42 bytes, UDP
         checksum 0), and the checker checks every IPv4 / UDP header field
         and the IPv4 header checksum too. Also prints the UDP payload rate
         against the most a 10 Gb/s link carries in datagrams of that size:
         payload / (payload + 66 bytes of headers, FCS, preamble and gap).
service  puts the --sfp port in service mode: its MAC carries the demo L3
         stack (ARP, ping, UDP echo on port 9999) at MAC 02:00:00:00:00:01
         and --ip (written to IP_ADDR), instead of the test traffic, so a PC
         can reach it through a 10G switch. --watch prints the MAC's frame
         counters every second for that many seconds; --off returns the port
         to the test traffic.
csr      reads (one argument) or writes (two) an eth_mac_sys_10g CSR; see
         the register map in rtl/eth_mac_sys_10g.v.

The `loop` test frames are not Ethernet frames (no FCS); the `mac` frames
are, but go to a made-up unicast address. Run traffic only in a loopback or
over a fibre between two cages / boards running this design, not toward a
switch (service mode is the one meant for a switch).
"""

import argparse
import os
import sys
import time

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
sys.path.insert(0, os.path.join(REPO, "fcapz", "host"))

from fcapz.cli import _chain_shape_kwargs          # noqa: E402
from fcapz.eio import EioController, _ADDR_IN_BASE  # noqa: E402
from fcapz.transport import XilinxHwServerTransport  # noqa: E402

MARKER, LAYOUT = 0x10F0, 4
PORTS = 2
PORT_IN_W, PORT_OUT_W = 640, 128     # per port
EIO_IN_W, EIO_OUT_W = PORTS * PORT_IN_W, PORTS * PORT_OUT_W

# probe_in fields of one port (name, lsb, width), see zcu106_10g_port.v
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
    ("port", 608, 8),
    ("layout", 616, 8),
    ("marker", 624, 16),
]
FIELD = {n: (lsb, w) for n, lsb, w in FIELDS}
# The frequency meters change every window, so two whole reads in a row
# rarely match while they are in the comparison: leave them out of it.
METER_MASK = 0
for _q in range(PORTS):
    for _n in ("fm_tx", "fm_rx", "fm_ref"):
        _lsb, _w = FIELD[_n]
        METER_MASK |= ((1 << _w) - 1) << (_q * PORT_IN_W + _lsb)
STABLE_MASK = ((1 << EIO_IN_W) - 1) & ~METER_MASK
STATUS_BITS = [
    "qpll0lock", "gtpowergood", "txuserrdy", "rxuserrdy",
    "rx_done", "tx_done", "rxresetdone", "txresetdone",
    "rxpmaresetdone", "txpmaresetdone", "rxprgdivresetdone", "txprgdivresetdone",
    None, None, None, None,     # [14:12] rxbufstatus, [15] 0
    None, None, "qpll0refclklost", "block_lock",   # [17:16] txbufstatus
    "hi_ber", "rxcdrlock", "good_seen", "bad_seen",
]

# probe_out bits of one port
LOOPBACK = {"none": 0, "pcs": 1, "pma": 2}
B_TXPOL, B_RXPOL, B_LPM, B_TXRST, B_RXRST = 3, 4, 5, 6, 7
B_GEN, B_INJ, B_CLEAR, B_GTRST, B_LASER_OFF = 8, 9, 10, 11, 12
B_MAC, B_SWEEP, B_UDP = 13, 14, 15
B_CSUM = 53             # checksum test mode (with B_UDP)
B_CSR_GO, B_CSR_WRITE, B_SERVICE, B_TX_INHIBIT = 120, 121, 122, 123

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
    ("LOCAL_FAULTS", 0xA8, False), ("REMOTE_FAULTS", 0xAC, False),
    ("RX_ERR_CSUM", 0x80, False),
]
R_CTRL, R_STATUS, R_IP_ADDR = 0x04, 0x08, 0x40
C_TX_CSUM, C_RX_CSUM = 0x80, 0x200     # CTRL[7], CTRL[9]
R_PAUSE_CTRL, R_PAUSE_Q, R_PAUSE_RX, R_PAUSE_TX = 0x84, 0x88, 0x8C, 0x90
R_XOFF, R_XON, R_REFRESH = 0x9C, 0xA0, 0xA4
P_RX_EN, P_AUTO, P_CFG_ERR = 2, 4, 0x10
RX_FIFO_BYTES = 32768   # the lane's eth_mac_sys_10g, RX_FIFO_ADDR_WIDTH 12
B_THROTTLE = 124        # [127:124] checker throttle
CUT_LOST_MAX = 256      # fault: frames SFP1 may send into the dark (2..8 seen)
ST_LOCAL_FAULT, ST_REMOTE_FAULT = 1 << 3, 1 << 4
WINDOW_S = (1 << 22) / 50e6     # frequency meter window


def transport(args):
    fpga = args.tap.removesuffix(".tap")
    return XilinxHwServerTransport(host=args.host, port=args.port, fpga_name=fpga,
                                   **_chain_shape_kwargs(fpga))


class Board:
    """The EIO; bit and field numbers are those of one port (self.sfp)."""

    def __init__(self, args):
        self.sfp = args.sfp
        self.eio = EioController(transport(args), chain=3)
        self.eio.connect()
        if (self.eio.in_w, self.eio.out_w) != (EIO_IN_W, EIO_OUT_W):
            raise SystemExit("EIO on USER3 is %d in / %d out, expected %d / %d: "
                             "not the 10G build"
                             % (self.eio.in_w, self.eio.out_w, EIO_IN_W, EIO_OUT_W))
        for q, f in enumerate(self.read_all()):
            if (f["marker"], f["layout"], f["port"]) != (MARKER, LAYOUT, q):
                raise SystemExit("EIO port %d: marker 0x%04x layout %d port %d, "
                                 "expected 0x%04x layout %d"
                                 % (q, f["marker"], f["layout"], f["port"],
                                    MARKER, LAYOUT))
        self.ctrl = self.eio.read_outputs()

    def close(self):
        self.eio.close()

    def read(self, sfp=None):
        return self.read_all()[self.sfp if sfp is None else sfp]

    def read_all(self):
        # counters cross into TCK unsynchronized: take two equal reads (the
        # meters aside); every read is one JTAG round trip per 32-bit word
        prev = None
        for _ in range(20):
            raw = self.eio.read_inputs()
            if prev is not None and (raw ^ prev) & STABLE_MASK == 0:
                break
            prev = raw
        return [self._fields(raw >> (q * PORT_IN_W)) for q in range(PORTS)]

    def read_words(self, first, count):
        """`count` 32-bit probe_in words from word `first`, without reading
        the other words (fcapz's EioController reads all of them)."""
        e = self.eio
        with e._access():
            return [e._t.read_reg(e._abs(_ADDR_IN_BASE + 4 * (first + i)))
                    for i in range(count)]

    @staticmethod
    def _fields(raw):
        f = {n: (raw >> lsb) & ((1 << w) - 1) for n, lsb, w in FIELDS}
        st = f["status"]
        for i, name in enumerate(STATUS_BITS):
            if name:
                f[name] = (st >> i) & 1
        f["rxbufstatus"] = (st >> 12) & 7
        f["txbufstatus"] = (st >> 16) & 3
        return f

    def write(self, value):
        t0 = time.time()
        self.eio.write_outputs(value)
        self.t_write = (t0 + time.time()) / 2   # when it took effect, about
        got = self.eio.read_outputs()
        if got != value:
            raise RuntimeError("EIO output reads 0x%x after writing 0x%x" % (got, value))
        self.ctrl = value

    def _off(self, sfps):
        return [q * PORT_OUT_W for q in ([self.sfp] if sfps is None else sfps)]

    def set_bit(self, bit, on, sfps=None):
        """Set or clear a control bit of this port, or of every port in sfps
        at once (one EIO write)."""
        v = self.ctrl
        for o in self._off(sfps):
            v = (v | (1 << (bit + o))) if on else (v & ~(1 << (bit + o)))
        self.write(v)

    def pulse(self, bit, hold=0.01, sfps=None):
        self.set_bit(bit, True, sfps)
        time.sleep(hold)
        self.set_bit(bit, False, sfps)

    def set_field(self, lsb, width, value, sfps=None):
        v = self.ctrl
        for o in self._off(sfps):
            m = ((1 << width) - 1) << (lsb + o)
            v = (v & ~m) | ((value << (lsb + o)) & m)
        self.write(v)

    def csr(self, addr, data=None):
        """One eth_mac_sys_10g CSR access; returns the value read."""
        o = self.sfp * PORT_OUT_W
        v = self.ctrl
        v &= ~(((0xFF << 80) | (0xFFFFFFFF << 88) | (1 << B_CSR_WRITE)) << o)
        v |= ((addr & 0xFF) << 80) << o
        if data is not None:
            v |= (((data & 0xFFFFFFFF) << 88) | (1 << B_CSR_WRITE)) << o
        self.write(v)
        go = ((self.ctrl >> (B_CSR_GO + o)) & 1) ^ 1
        self.set_bit(B_CSR_GO, go)
        # poll the two words holding csr_ack and csr_rdata, not all 40;
        # csr_rdata is held from the ack toggle until the next access
        ack_bit = self.sfp * PORT_IN_W + FIELD["csr_ack"][0]
        dat_bit = self.sfp * PORT_IN_W + FIELD["csr_rdata"][0]
        assert dat_bit % 32 == 0 and dat_bit // 32 == ack_bit // 32 + 1
        for _ in range(50):
            ack, data = self.read_words(ack_bit // 32, 2)
            if (ack >> (ack_bit % 32)) & 1 == go:
                return data
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

    def mac_status(self, q):
        """Port q's eth_mac_sys_10g STATUS register."""
        self.sfp = q
        return self.csr(R_STATUS)


def faults(st):
    return " ".join(n for n, m in (("local_fault", ST_LOCAL_FAULT),
                                   ("remote_fault", ST_REMOTE_FAULT)) if st & m) or "-"


def mhz(count):
    return count / WINDOW_S / 1e6


def show(f):
    flags = " ".join(n for n in STATUS_BITS if n and f.get(n))
    print("SFP%d status 0x%08x: %s" % (f["port"], f["status"], flags))
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


def wait_lock(b, timeout=2.0, sfps=None):
    """Wait for RX reset done and block lock without a high BER on this port
    (or on every port in sfps); returns its fields (the list of them)."""
    t0 = time.time()
    while time.time() - t0 < timeout:
        fs = b.read_all()
        want = [fs[q] for q in ([b.sfp] if sfps is None else sfps)]
        if all(f["rx_done"] and f["block_lock"] and not f["hi_ber"] for f in want):
            return want[0] if sfps is None else want
        time.sleep(0.05)
    return None


def udp_line(pps, avg_len):
    """UDP payload rate of pps frames of avg_len bytes (no FCS), against the
    most a 10 Gb/s link carries at that size."""
    payload = avg_len - 42
    rate = pps * payload * 8
    best = 10e9 * payload / (avg_len + 24)
    return ("UDP payload %.3f Gb/s in %.0f-byte datagrams; the line carries at "
            "most %.3f Gb/s at that size (%.2f%%)"
            % (rate / 1e9, payload, best / 1e9, 100 * rate / best))


POLL_S = 30.0     # generator count polls: a 32-bit count wraps in >= ~80 s
M32 = 0xFFFFFFFF


def gen_count(b, q, field):
    """Port q's 32-bit generator count `field`, read while it runs: two
    back-to-back reads of its one word must agree to within a few ms of
    traffic, so a read torn by the unsynchronized crossing is not taken."""
    word = (q * PORT_IN_W + dict((n, lsb) for n, lsb, _ in FIELDS)[field]) // 32
    a = b.read_words(word, 1)[0]
    for _ in range(10):
        c = b.read_words(word, 1)[0]
        if (c - a) & M32 < 100000000:
            return c
        a = c
    raise SystemExit("unstable %s reads on port %d" % (field, q))


def run_gen(b, seconds, field, inject=False, sfps=None, inject_sfps=None):
    """Run the generators of this port (or of every port in sfps) for about
    `seconds`, with one injected error halfway if asked. Returns the time
    they really ran, from the middle of the EIO write that starts them to the
    middle of the one that stops them (a write takes tens of ms, so the
    requested time alone overstates short runs' rates by a few percent), and
    each port's frames sent, from its 32-bit generator count `field` polled
    every POLL_S so that runs past its wrap count right."""
    ports = [b.sfp] if sfps is None else list(sfps)
    last = {q: gen_count(b, q, field) for q in ports}
    sent = dict.fromkeys(ports, 0)

    def tally():
        for q in ports:
            v = gen_count(b, q, field)
            sent[q] += (v - last[q]) & M32
            last[q] = v

    def wait(t):
        end = time.time() + t
        while end - time.time() > POLL_S:
            time.sleep(POLL_S)
            tally()
        time.sleep(max(0.0, end - time.time()))

    b.set_bit(B_GEN, True, sfps)
    t_on = b.t_write
    if inject:
        wait(seconds / 2)
        b.pulse(B_INJ, sfps=inject_sfps if inject_sfps is not None else sfps)
        wait(seconds / 2)
    else:
        wait(seconds)
    b.set_bit(B_GEN, False, sfps)
    secs = b.t_write - t_on
    time.sleep(0.05)
    tally()
    return secs, sent


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
    secs, sent = run_gen(b, args.seconds, "gen_frames", args.inject)
    sent = sent[b.sfp]
    f = b.read()
    show(f)
    # line rate: (words + 2) words per frame plus ipg, 32 of 33 cycles carry a
    # word at 161.13 MHz -> payload Gb/s of the test frames
    rate = sent * (words + 2 + args.ipg) * 64 / secs / 1e9
    print("  sent %d frames in %.2f s: %.3f Gb/s of XGMII words (10.000 max)"
          % (sent, secs, rate))
    want_bad = 1 if args.inject else 0
    ok = (sent > 0
          and (f["good_frames"] + f["bad_frames"]) & M32 == sent & M32
          and f["bad_frames"] == want_bad
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
    if args.csum:
        if args.len > 9014:
            raise SystemExit("--csum needs --len <= 9014")
        args.udp = True
    b.set_bit(B_GEN, False)
    time.sleep(0.01)
    b.set_bit(B_MAC, True)
    b.set_bit(B_SWEEP, args.sweep)
    b.set_bit(B_UDP, args.udp)
    b.set_bit(B_CSUM, args.csum)
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
    if args.csum:
        ctrl0 = b.csr(R_CTRL)
        b.csr(R_CTRL, ctrl0 | C_TX_CSUM | C_RX_CSUM)
        print("  checksum test: CTRL 0x%03x, inserter and checker on"
              % (ctrl0 | C_TX_CSUM | C_RX_CSUM))
    b.pulse(B_CLEAR)
    b.mac_clear()
    secs, sent = run_gen(b, args.seconds, "mac_gen_frames", args.inject)
    sent = sent[b.sfp]
    f = b.read()
    show(f)
    # line bytes per frame: preamble/SFD 8 + frame + FCS 4 + 12 gap on average
    avg_len = (60 + args.len) / 2 if args.sweep else args.len
    pps = sent / secs
    line = 10e9 / ((avg_len + 4 + 8 + 12) * 8)
    print("  sent %d frames in %.2f s: %.4f Mpps, %.3f Gb/s of frames with FCS; "
          "line rate for %s bytes %.4f Mpps (%.2f%%)"
          % (sent, secs, pps / 1e6, pps * (avg_len + 4) * 8 / 1e9,
             "%.0f" % avg_len, line / 1e6, 100 * pps / line))
    if args.udp and args.len <= 9014:     # above, the RX MAC drops them all
        print("  " + udp_line(pps, avg_len))
    c = b.mac_counters()
    print("  MAC counters: " + " ".join("%s %d" % kv for kv in c.items()))
    want_bad = 1 if args.inject else 0
    over = args.len > 9014
    if over:
        # above the RX MAC's jumbo limit (9018 bytes with the FCS): every
        # frame is counted oversize and dropped, none reaches the checker
        print("  frames over 9018 bytes: expecting every one dropped (oversize)")
    delivered = 0 if over else sent
    ok = (sent > 0
          and (f["mac_good"] + f["mac_bad"]) & M32 == delivered & M32
          and f["mac_bad"] == want_bad
          and f["mac_tuser"] == 0 and f["mac_seq_gaps"] == 0
          and c["TX_FRAMES"] == sent and c["TX_UNDERRUN"] == 0
          and c["RX_ERR_FCS"] == 0 and c["RX_DROP"] == 0
          and c["RX_FRAMES"] == delivered
          and c["RX_ERR_OVERSIZE"] == (sent if over else 0)
          and c["RX_ERR_CSUM"] == 0
          and f["lock_losses"] == 0 and f["block_lock"])
    if args.csum:
        # the checker alone: every junk checksum fails it, every frame dropped
        b.csr(R_CTRL, ctrl0 | C_RX_CSUM)
        b.pulse(B_CLEAR)
        b.mac_clear()
        _, sent2 = run_gen(b, 1.0, "mac_gen_frames")
        sent2 = sent2[b.sfp]
        f2 = b.read()
        c2 = b.mac_counters()
        b.csr(R_CTRL, ctrl0)
        b.set_bit(B_CSUM, False)
        print("  checker alone (CTRL 0x%03x): sent %d, RX_ERR_CSUM %d, RX_DISCARD %d, "
              "checker good %d bad %d" % (ctrl0 | C_RX_CSUM, sent2, c2["RX_ERR_CSUM"],
                                          c2["RX_DISCARD"], f2["mac_good"], f2["mac_bad"]))
        ok = (ok and sent2 > 0
              and c2["RX_FRAMES"] == sent2 and c2["RX_ERR_CSUM"] == sent2 & M32
              and c2["RX_DISCARD"] == sent2 & M32 and c2["RX_ERR_FCS"] == 0
              and f2["mac_good"] == 0 and f2["mac_bad"] == 0)
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


def cmd_dual(b, args):
    lens = [args.len, args.len1 or args.len]
    if not all(60 <= n <= 9014 for n in lens):
        raise SystemExit("--len / --len1 must be 60..9014 (the RX MAC's jumbo limit)")
    both = list(range(PORTS))
    b.set_bit(B_GEN, False, both)
    time.sleep(0.01)
    b.set_bit(B_MAC, True, both)
    b.set_bit(B_SWEEP, args.sweep, both)
    b.set_bit(B_UDP, args.udp, both)
    b.set_bit(B_CSUM, False, both)
    b.set_field(0, 3, LOOPBACK["none"], both)
    b.set_bit(B_LPM, args.lpm, both)
    b.set_field(24, 8, args.ipg, both)
    for q in both:
        b.set_field(64, 16, lens[q], [q])
    b.pulse(B_RXRST, sfps=both)
    if wait_lock(b, sfps=both) is None:
        for f in b.read_all():
            show(f)
        print("FAIL: no block lock on both ports (is the fibre SFP0 <-> SFP1 in?)")
        return 1
    time.sleep(0.01)
    b.pulse(B_CLEAR, sfps=both)
    for q in both:
        b.sfp = q
        b.mac_clear()
    secs, sents = run_gen(b, args.seconds, "mac_gen_frames", args.inject, both, [0])
    fs = b.read_all()
    cs = []
    for q in both:
        b.sfp = q
        cs.append(b.mac_counters())
    ok = True
    for tx, rx in ((0, 1), (1, 0)):
        fr, ct, cr = fs[rx], cs[tx], cs[rx]
        sent = sents[tx]
        avg_len = (60 + lens[tx]) / 2 if args.sweep else lens[tx]
        pps = sent / secs
        line = 10e9 / ((avg_len + 4 + 8 + 12) * 8)
        print("SFP%d -> SFP%d: %d frames of %s bytes in %.2f s: %.4f Mpps, %.3f Gb/s "
              "of frames with FCS; line rate %.4f Mpps (%.2f%%)"
              % (tx, rx, sent, "%.0f" % avg_len, secs, pps / 1e6,
                 pps * (avg_len + 4) * 8 / 1e9, line / 1e6, 100 * pps / line))
        if args.udp:
            print("  " + udp_line(pps, avg_len))
        print("  checker at SFP%d: good %d bad %d tuser %d seq_gaps %d"
              % (rx, fr["mac_good"], fr["mac_bad"], fr["mac_tuser"], fr["mac_seq_gaps"]))
        print("  SFP%d TX_FRAMES %d TX_BYTES %d TX_UNDERRUN %d TX_DROP %d"
              % (tx, ct["TX_FRAMES"], ct["TX_BYTES"], ct["TX_UNDERRUN"], ct["TX_DROP"]))
        print("  SFP%d RX_FRAMES %d RX_BYTES %d RX_ERR_FCS %d RX_ERR_CTL %d "
              "RX_ERR_OVERSIZE %d RX_DROP %d RX_DISCARD %d lock_losses %d"
              % (rx, cr["RX_FRAMES"], cr["RX_BYTES"], cr["RX_ERR_FCS"],
                 cr["RX_ERR_CTL"], cr["RX_ERR_OVERSIZE"], cr["RX_DROP"],
                 cr["RX_DISCARD"], fr["lock_losses"]))
        want_bad = 1 if (args.inject and tx == 0) else 0
        good = (sent > 0
                and (fr["mac_good"] + fr["mac_bad"]) & M32 == sent & M32
                and fr["mac_bad"] == want_bad
                and fr["mac_tuser"] == 0 and fr["mac_seq_gaps"] == 0
                and ct["TX_FRAMES"] == sent and cr["RX_FRAMES"] == sent
                and ct["TX_BYTES"] == cr["RX_BYTES"]
                and ct["TX_UNDERRUN"] == 0 and ct["TX_DROP"] == 0
                and cr["RX_ERR_FCS"] == 0 and cr["RX_ERR_CTL"] == 0
                and cr["RX_ERR_OVERSIZE"] == 0 and cr["RX_DROP"] == 0
                and cr["RX_DISCARD"] == 0
                and fr["lock_losses"] == 0 and fr["block_lock"])
        print("  %s" % ("ok" if good else "FAIL"))
        ok = ok and good
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


def cmd_fault(b, args):
    if not 60 <= args.len <= 9014:
        raise SystemExit("--len must be 60..9014")
    both = list(range(PORTS))
    b.set_bit(B_GEN, False, both)
    b.set_bit(B_TX_INHIBIT, False, both)
    time.sleep(0.01)
    b.set_bit(B_MAC, True, both)
    b.set_bit(B_SWEEP, False, both)
    b.set_bit(B_UDP, False, both)
    b.set_field(0, 3, LOOPBACK["none"], both)
    b.set_field(24, 8, 0, both)
    b.set_field(64, 16, args.len, both)
    b.pulse(B_RXRST, sfps=both)
    if wait_lock(b, sfps=both) is None:
        print("FAIL: no block lock on both ports (is the fibre SFP0 <-> SFP1 in?)")
        return 1
    time.sleep(0.05)
    b.pulse(B_CLEAR, sfps=both)
    for q in both:
        b.sfp = q
        b.mac_clear()
    st0 = [b.mac_status(q) for q in both]
    ok = all(not st & (ST_LOCAL_FAULT | ST_REMOTE_FAULT) for st in st0)
    print("before: SFP0 %s, SFP1 %s" % (faults(st0[0]), faults(st0[1])))

    last = {q: gen_count(b, q, "mac_gen_frames") for q in both}
    b.set_bit(B_GEN, True, both)
    time.sleep(args.seconds)
    # SFP1's transmitter inhibited: SFP1 -> SFP0 goes dark
    b.set_bit(B_TX_INHIBIT, True, [1])
    time.sleep(0.1)
    g0 = [gen_count(b, q, "mac_gen_frames") for q in both]
    time.sleep(args.off)
    g1 = [gen_count(b, q, "mac_gen_frames") for q in both]
    st_off = [b.mac_status(q) for q in both]
    print("SFP1 TX off: SFP0 %s, SFP1 %s; generators %d and %d frames in %.1f s"
          % (faults(st_off[0]), faults(st_off[1]), (g1[0] - g0[0]) & M32,
             (g1[1] - g0[1]) & M32, args.off))
    held = all(((g1[q] - g0[q]) & M32) == 0 for q in both)
    ok = ok and bool(st_off[0] & ST_LOCAL_FAULT) and bool(st_off[1] & ST_REMOTE_FAULT) \
        and not st_off[1] & ST_LOCAL_FAULT and held
    # transmitter on again
    b.set_bit(B_TX_INHIBIT, False, [1])
    if wait_lock(b, timeout=5.0, sfps=both) is None:
        print("FAIL: no block lock after SFP1's transmitter came back")
        return 1
    time.sleep(0.1)
    # stop and drain: the cut phase's accounting is final here
    b.set_bit(B_GEN, False, both)
    time.sleep(0.05)
    sents = {q: (gen_count(b, q, "mac_gen_frames") - last[q]) & M32 for q in both}
    fa = b.read_all()
    ca = []
    for q in both:
        b.sfp = q
        ca.append(b.mac_counters())
    st_on = [b.mac_status(q) for q in both]
    print("SFP1 TX on: SFP0 %s, SFP1 %s"
          % (faults(st_on[0]), faults(st_on[1])))
    ok = ok and all(not st & (ST_LOCAL_FAULT | ST_REMOTE_FAULT) for st in st_on)
    for q in both:
        print("  SFP%d LOCAL_FAULTS %d REMOTE_FAULTS %d LOCK_LOSS %d TX_UNDERRUN %d "
              "TX_DROP %d RX_ERR_FCS %d" % (q, ca[q]["LOCAL_FAULTS"],
                                           ca[q]["REMOTE_FAULTS"], ca[q]["LOCK_LOSS"],
                                           ca[q]["TX_UNDERRUN"], ca[q]["TX_DROP"],
                                           ca[q]["RX_ERR_FCS"]))
    ok = ok and ca[0]["LOCAL_FAULTS"] >= 1 and ca[1]["REMOTE_FAULTS"] >= 1         and ca[1]["LOCAL_FAULTS"] == 0
    for tx, rx in ((0, 1), (1, 0)):
        fr, ct, cr = fa[rx], ca[tx], ca[rx]
        sent = sents[tx]
        lost = sent - ((fr["mac_good"] + fr["mac_bad"]) & M32)
        print("SFP%d -> SFP%d: sent %d, good %d bad %d tuser %d seq_gaps %d (%d lost); "
              "TX_FRAMES %d RX_FRAMES %d"
              % (tx, rx, sent, fr["mac_good"], fr["mac_bad"], fr["mac_tuser"],
                 fr["mac_seq_gaps"], lost, ct["TX_FRAMES"], cr["RX_FRAMES"]))
        good = (sent > 0 and fr["mac_bad"] == 0 and fr["mac_tuser"] == 0
                and ct["TX_FRAMES"] == sent and ct["TX_UNDERRUN"] == 0
                and ct["TX_DROP"] == 0 and cr["RX_DROP"] == 0)
        if tx == 0:     # the direction that stayed lit: nothing lost
            good = good and lost == 0 and fr["mac_seq_gaps"] == 0                 and cr["RX_FRAMES"] == sent and cr["RX_ERR_FCS"] == 0                 and fr["lock_losses"] == 0
        else:           # the frames on the fibre when it went dark
            good = good and fr["mac_seq_gaps"] == 1 and 0 < lost <= CUT_LOST_MAX                 and cr["RX_FRAMES"] == fr["mac_good"]
        print("  %s" % ("ok" if good else "FAIL"))
        ok = ok and good

    # after the recovery: a window of its own, started and ended idle, in
    # which every frame sent must arrive (a loss at its very end shows as a
    # count mismatch, not only as a sequence gap)
    g2 = [gen_count(b, q, "mac_gen_frames") for q in both]
    b.set_bit(B_GEN, True, both)
    time.sleep(args.seconds)
    b.set_bit(B_GEN, False, both)
    time.sleep(0.05)
    g3 = [gen_count(b, q, "mac_gen_frames") for q in both]
    fb = b.read_all()
    cb = []
    for q in both:
        b.sfp = q
        cb.append(b.mac_counters())
    for tx, rx in ((0, 1), (1, 0)):
        sent = (g3[tx] - g2[tx]) & M32
        d = {k: (fb[rx][k] - fa[rx][k]) & M32
             for k in ("mac_good", "mac_bad", "mac_tuser", "mac_seq_gaps")}
        dc = {k: cb[c][k] - ca[c][k]
              for c, k in ((tx, "TX_FRAMES"), (tx, "TX_DROP"), (rx, "RX_FRAMES"),
                           (rx, "RX_ERR_FCS"), (rx, "RX_DROP"))}
        print("SFP%d -> SFP%d after the recovery: sent %d, good %d bad %d tuser %d "
              "seq_gaps %d, TX_FRAMES %d RX_FRAMES %d RX_ERR_FCS %d"
              % (tx, rx, sent, d["mac_good"], d["mac_bad"], d["mac_tuser"],
                 d["mac_seq_gaps"], dc["TX_FRAMES"], dc["RX_FRAMES"], dc["RX_ERR_FCS"]))
        good = (sent > 1000 and d["mac_good"] == sent and d["mac_bad"] == 0
                and d["mac_tuser"] == 0 and d["mac_seq_gaps"] == 0
                and dc["TX_FRAMES"] == sent and dc["RX_FRAMES"] == sent
                and dc["TX_DROP"] == 0 and dc["RX_ERR_FCS"] == 0 and dc["RX_DROP"] == 0)
        print("  %s" % ("ok" if good else "FAIL"))
        ok = ok and good
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


def cmd_pause(b, args):
    if not 60 <= args.len <= 6000:
        raise SystemExit("--len must be 60..6000 (room for XOFF in the RX FIFO)")
    if not 1 <= args.throttle <= 15:
        raise SystemExit("--throttle must be 1..15")
    b.set_bit(B_GEN, False)
    time.sleep(0.01)
    b.set_bit(B_SERVICE, False)
    b.set_bit(B_MAC, True)
    b.set_bit(B_SWEEP, False)
    b.set_bit(B_UDP, False)
    b.set_field(0, 3, LOOPBACK[args.loopback])
    b.set_field(64, 16, args.len)
    b.set_field(24, 8, 0)
    b.csr(R_PAUSE_CTRL, 0)
    b.set_field(B_THROTTLE, 4, args.throttle)
    b.pulse(B_RXRST)
    if wait_lock(b) is None:
        show(b.read())
        print("FAIL: no block lock")
        return 1
    try:
        # without PAUSE: the throttled checker must lose frames
        time.sleep(0.01)
        b.pulse(B_CLEAR)
        b.mac_clear()
        run_gen(b, 1.0, "mac_gen_frames")
        c0 = b.mac_counters()
        print("  without PAUSE: RX_DROP %d of %d frames received"
              % (c0["RX_DROP"], c0["RX_FRAMES"]))
        if c0["RX_DROP"] == 0:
            print("  FAIL: the checker keeps up without PAUSE, so this run tests "
                  "nothing; use a higher --throttle or a longer --len")
        # automatic PAUSE
        flen = args.len + 24        # with FCS, preamble and gap
        xoff = RX_FIFO_BYTES - 8 - 4 * flen - 1024
        b.csr(R_PAUSE_Q, args.quanta)
        b.csr(R_XOFF, xoff)
        b.csr(R_XON, xoff // 2)
        b.csr(R_REFRESH, 0)
        b.csr(R_PAUSE_CTRL, P_RX_EN | P_AUTO)
        st = b.csr(R_PAUSE_CTRL)
        if st & P_CFG_ERR:
            print("FAIL: auto_cfg_err (PAUSE_CTRL 0x%02x)" % st)
            return 1
        b.pulse(B_CLEAR)
        b.mac_clear()
        b.csr(R_PAUSE_RX, 0)
        secs, sent = run_gen(b, args.seconds, "mac_gen_frames")
        sent = sent[b.sfp]
        time.sleep(0.05)
        f = b.read()
        c = b.mac_counters()
        prx, ptx = b.csr(R_PAUSE_RX), b.csr(R_PAUSE_TX)
    finally:
        b.csr(R_PAUSE_CTRL, 0)
        b.set_field(B_THROTTLE, 4, 0)
    show(f)
    print("  MAC counters: " + " ".join("%s %d" % kv for kv in c.items()))
    beats = (args.len + 7) // 8
    cap = (16 - args.throttle) / 16 * 200e6 / beats
    pps = sent / secs
    print("  XOFF %d XON %d quanta %d: sent %d frames in %.2f s, %.4f Mpps; the "
          "throttled checker takes at most %.4f Mpps (%.1f%%); %d PAUSE frames "
          "sent, %d received"
          % (xoff, xoff // 2, args.quanta, sent, secs, pps / 1e6, cap / 1e6,
             100 * pps / cap, ptx, prx))
    ok = (c0["RX_DROP"] > 0
          and sent > 0
          and f["mac_good"] == sent & M32 and f["mac_bad"] == 0
          and f["mac_tuser"] == 0 and f["mac_seq_gaps"] == 0
          and c["RX_DROP"] == 0 and c["RX_ERR_FCS"] == 0
          and c["TX_UNDERRUN"] == 0
          and ptx > 0 and prx == ptx
          and c["RX_DISCARD"] == prx
          and c["TX_FRAMES"] == sent + ptx and c["RX_FRAMES"] == sent + prx
          and f["lock_losses"] == 0 and f["block_lock"])
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


def cmd_service(b, args):
    b.set_bit(B_GEN, False)
    time.sleep(0.01)
    if args.off:
        b.set_bit(B_SERVICE, False)
        print("SFP%d back on the test traffic" % b.sfp)
        return 0
    try:
        ip = bytes(int(x) for x in args.ip.split("."))
        assert len(ip) == 4
    except (ValueError, AssertionError):
        raise SystemExit("--ip must be a dotted IPv4 address")
    q = b.sfp
    b.set_bit(B_MAC, True)
    b.set_field(0, 3, LOOPBACK["none"])
    b.set_bit(B_SERVICE, True)
    b.csr(R_IP_ADDR, int.from_bytes(ip, "big"))
    got = b.csr(R_IP_ADDR)
    b.mac_clear()
    f = wait_lock(b, timeout=1.0)
    print("SFP%d service mode: ARP, ping, UDP echo on port 9999 at %s, MAC "
          "02:00:00:00:00:01; block lock %s, link fault %s"
          % (q, ".".join(str(x) for x in got.to_bytes(4, "big")),
             "yes" if f else "NO", faults(b.mac_status(q))))
    if got != int.from_bytes(ip, "big"):
        print("FAIL: IP_ADDR reads 0x%08x" % got)
        return 1
    for _ in range(int(args.watch)):
        time.sleep(1.0)
        b.sfp = q
        c = {n: b.csr(a) for n, a in (("RX_FRAMES", 0xC0), ("TX_FRAMES", 0xB0),
                                     ("RX_DISCARD", 0xEC), ("RX_DROP", 0xE8),
                                     ("RX_ERR_FCS", 0xD0))}
        print("  " + " ".join("%s %d" % kv for kv in c.items()))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=3121)
    ap.add_argument("--tap", default="xczu7.tap")
    ap.add_argument("--sfp", type=int, choices=range(PORTS), default=0,
                    help="port for loop, mac, service, csr and the resets (default 0)")
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
    mp.add_argument("--udp", action="store_true", help="IPv4 / UDP datagrams")
    mp.add_argument("--csum", action="store_true",
                    help="checksum offload test (IPv4 / UDP, junk checksums)")
    dp = sub.add_parser("dual")
    dp.add_argument("--seconds", type=float, default=5.0)
    dp.add_argument("--len", type=int, default=60)
    dp.add_argument("--len1", type=int, default=0, help="port 1's length (default --len)")
    dp.add_argument("--sweep", action="store_true")
    dp.add_argument("--ipg", type=int, default=0)
    dp.add_argument("--lpm", action="store_true", help="LPM receivers instead of DFE")
    dp.add_argument("--inject", action="store_true")
    dp.add_argument("--udp", action="store_true", help="IPv4 / UDP datagrams")
    fp = sub.add_parser("fault")
    fp.add_argument("--seconds", type=float, default=1.0,
                    help="traffic before and after SFP1's transmitter is off")
    fp.add_argument("--off", type=float, default=1.0,
                    help="seconds with SFP1's transmitter off")
    fp.add_argument("--len", type=int, default=60)
    pp = sub.add_parser("pause")
    pp.add_argument("--loopback", choices=sorted(LOOPBACK), default="pma")
    pp.add_argument("--seconds", type=float, default=5.0)
    pp.add_argument("--len", type=int, default=1514)
    pp.add_argument("--throttle", type=int, default=10,
                    help="checker skips this many of every 16 cycles (1..15)")
    pp.add_argument("--quanta", type=lambda x: int(x, 0), default=0x400)
    sp = sub.add_parser("service")
    sp.add_argument("--ip", default="192.168.137.200")
    sp.add_argument("--watch", type=float, default=0)
    sp.add_argument("--off", action="store_true")
    cp = sub.add_parser("csr")
    cp.add_argument("addr", type=lambda x: int(x, 0))
    cp.add_argument("data", type=lambda x: int(x, 0), nargs="?")
    for name in ("restart-rx", "restart-tx", "gt-reset"):
        sub.add_parser(name)
    args = ap.parse_args()

    b = Board(args)
    try:
        if args.cmd == "status":
            for f in b.read_all():
                show(f)
            for q in range(PORTS):
                print("SFP%d MAC link fault: %s" % (q, faults(b.mac_status(q))))
            return 0
        if args.cmd == "fault":
            return cmd_fault(b, args)
        if args.cmd == "pause":
            return cmd_pause(b, args)
        if args.cmd == "service":
            return cmd_service(b, args)
        if args.cmd == "dual":
            return cmd_dual(b, args)
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
