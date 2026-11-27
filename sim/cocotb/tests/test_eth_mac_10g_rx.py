# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""10 Gb/s receive MAC (rtl/eth_mac_10g_rx.v).

  eth_mac_10g_rx   an XGMII stream built here (starts in lane 0 and lane 4,
                   gaps down to the 5-byte receive minimum, the decoder's
                   one-in-33 valid gaps or random ones) against the AXIS
                   frames and stats a model expects: payload with preamble
                   and FCS removed, tuser on a bad FCS, a runt, an oversize
                   frame (VLAN and jumbo limits), an error character, a bad
                   SFD, a runaway frame; frames around a bad one unharmed.
"""
import random
import zlib

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly


SUITES = {
    "eth_mac_10g_rx": {
        "toplevel": "eth_mac_10g_rx",
        "sources": ["rtl/crc32_d64.v", "rtl/eth_mac_10g_rx.v"],
        "skip_vhdl": "10G MAC is Verilog only so far",
    },
}

IDLE, START, TERM, ERR = 0x07, 0xFB, 0xFD, 0xFE


def with_fcs(payload: bytes) -> bytes:
    return payload + zlib.crc32(payload).to_bytes(4, "little")


class Frame:
    """One frame on the line. body = bytes after the SFD (FCS included).
    exp_out = payload the MAC should deliver (None = nothing), exp_bad."""

    def __init__(self, body, exp_out, exp_bad, sfd=0xD5, err_at=None, no_term=False,
                 tail=None, pre=None, gap0=False, lost=False):
        self.body = body
        self.exp_out = exp_out
        self.exp_bad = exp_bad
        self.sfd = sfd
        self.err_at = err_at        # body index sent as an error character
        self.no_term = no_term
        self.tail = tail            # lanes sent instead of the terminate
        self.pre = pre              # lanes just before the start
        self.gap0 = gap0            # start right after the previous frame
        self.lost = lost            # never seen by the MAC (no stat_done)


def good(payload):
    return Frame(with_fcs(payload), payload, False)


def build_lanes(frames, rng, min_gap=5, max_gap=20, lane4=None):
    """Lay the frames out as (byte, ctl) lanes. Each frame starts at a 4-byte
    column at least min_gap bytes after the previous terminate."""
    lanes = [(IDLE, 1)] * 16
    for fr in frames:
        if not fr.gap0:
            gap = rng.randint(min_gap, max_gap)
            pre = fr.pre or []
            while (len(lanes) + len(pre)) % 4 or gap > 0:
                lanes.append((IDLE, 1))
                gap -= 1
            if lane4 is not None and ((len(lanes) + len(pre)) % 8 == 4) != lane4:
                lanes += [(IDLE, 1)] * 4
            lanes += pre
        assert len(lanes) % 4 == 0
        lanes.append((START, 1))
        lanes += [(0x55, 0)] * 6 + [(fr.sfd, 0)]
        for i, b in enumerate(fr.body):
            lanes.append((ERR, 1) if i == fr.err_at else (b, 0))
        if fr.tail is not None:
            lanes += fr.tail
        elif not fr.no_term:
            lanes.append((TERM, 1))
    lanes += [(IDLE, 1)] * (24 - len(lanes) % 8)
    words = []
    for i in range(0, len(lanes), 8):
        d = c = 0
        for k, (b, ct) in enumerate(lanes[i:i + 8]):
            d |= b << (8 * k)
            c |= ct << k
        words.append((d, c))
    return words


class RxBench:
    def __init__(self, dut, valid_fn=lambda c: True):
        self.dut = dut
        self.valid_fn = valid_fn
        self.frames = []           # (payload bytes, tuser)
        self.cur = bytearray()
        self.stats = []            # dicts per stat_done

    async def start(self, jumbo=0):
        dut = self.dut
        cocotb.start_soon(Clock(dut.clk, 6.2, "ns").start())
        dut.rst_n.value = 0
        dut.xgmii_rx_valid.value = 0
        dut.xgmii_rxd.value = 0x0707070707070707
        dut.xgmii_rxc.value = 0xFF
        dut.jumbo_en.value = jumbo
        await ClockCycles(dut.clk, 5)
        dut.rst_n.value = 1
        await ClockCycles(dut.clk, 2)

    def _sample(self):
        dut = self.dut
        if int(dut.m_axis_tvalid.value):
            d = int(dut.m_axis_tdata.value)
            keep = int(dut.m_axis_tkeep.value)
            last = int(dut.m_axis_tlast.value)
            if not last:
                assert keep == 0xFF, f"tkeep {keep:02x} on a middle beat"
            else:
                n = bin(keep).count("1")
                assert n >= 1 and keep == (1 << n) - 1, f"tkeep {keep:02x} on tlast"
            n = bin(keep).count("1")
            self.cur += d.to_bytes(8, "little")[:n]
            if last:
                self.frames.append((bytes(self.cur), int(dut.m_axis_tuser.value)))
                self.cur = bytearray()
        if int(dut.stat_done.value):
            self.stats.append({k: int(getattr(dut, "stat_" + k).value) for k in
                               ("len", "err_fcs", "err_ctl", "err_oversize",
                                "err_undersize", "is_bcast", "is_mcast")})

    async def run(self, words, tail=100):
        dut = self.dut
        i = 0
        cycle = 0
        idle = 0
        while idle < tail:
            await FallingEdge(dut.clk)
            v = self.valid_fn(cycle)
            cycle += 1
            if i < len(words) and v:
                dut.xgmii_rxd.value, dut.xgmii_rxc.value = words[i]
                dut.xgmii_rx_valid.value = 1
                i += 1
            else:
                dut.xgmii_rx_valid.value = 1 if v else 0
                dut.xgmii_rxd.value = 0x0707070707070707
                dut.xgmii_rxc.value = 0xFF
                if i >= len(words):
                    idle += 1
            await ReadOnly()
            self._sample()


def check(tb, frames):
    exp = [(f.exp_out, f.exp_bad) for f in frames if f.exp_out is not None]
    got = tb.frames
    assert len(got) == len(exp), f"{len(got)} frames out, expected {len(exp)}"
    for k, ((gp, gu), (ep, eb)) in enumerate(zip(got, exp)):
        assert gu == int(eb), f"frame {k} len {len(ep)}: tuser {gu}, expected {int(eb)}"
        if not eb:
            assert gp == ep, f"frame {k}: got {gp.hex()} exp {ep.hex()}"
        else:
            assert len(gp) == len(ep) or len(ep) > 16000, \
                f"bad frame {k}: {len(gp)} bytes out, {len(ep)} sent"
    seen = [f for f in frames if not f.lost]
    assert len(tb.stats) == len(seen), f"{len(tb.stats)} stat_done, {len(seen)} frames"
    assert tb.cur == b"", "a frame without tlast"


def valid_pcs(c):
    return (c % 33) != 32


# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=10, timeout_unit="ms")
async def rx_every_length(dut):
    """Payloads 60..200 and long ones, both start lanes, gaps 5..20,
    decoder valid pattern: every frame delivered right, stats right."""
    rng = random.Random(1)
    frames = [good(rng.randbytes(n)) for n in list(range(60, 201)) + [1514, 9014]]
    tb = RxBench(dut, valid_pcs)
    await tb.start(jumbo=1)
    await tb.run(build_lanes(frames, rng))
    check(tb, frames)
    for f, s in zip([f for f in frames if not f.lost], tb.stats):
        assert s["len"] == len(f.body)
        assert not (s["err_fcs"] or s["err_ctl"] or s["err_oversize"] or s["err_undersize"])


@cocotb.test(timeout_time=10, timeout_unit="ms")
async def rx_lane4_min_gap(dut):
    """Every frame in lane 4 at the minimum gap, every end lane: covers the
    terminate in the upper half of a shifted word followed by a start."""
    rng = random.Random(2)
    frames = [good(rng.randbytes(60 + (k % 16))) for k in range(300)]
    tb = RxBench(dut)
    await tb.start()
    await tb.run(build_lanes(frames, rng, 5, 5, lane4=True))
    check(tb, frames)
    rng = random.Random(3)   # and lane 0 only
    frames = [good(rng.randbytes(60 + (k % 16))) for k in range(300)]
    tb.frames, tb.stats = [], []
    await tb.run(build_lanes(frames, rng, 5, 5, lane4=False))
    check(tb, frames)


@cocotb.test(timeout_time=10, timeout_unit="ms")
async def rx_random_valid(dut):
    """Random valid gaps change nothing."""
    rng = random.Random(4)
    frames = [good(rng.randbytes(rng.randint(60, 300))) for _ in range(300)]
    vr = random.Random(5)
    tb = RxBench(dut, lambda c: vr.random() < 0.6)
    await tb.start()
    await tb.run(build_lanes(frames, rng))
    check(tb, frames)


@cocotb.test(timeout_time=10, timeout_unit="ms")
async def rx_errors(dut):
    """Bad FCS, error character, bad SFD, runts, tiny fragments: each
    flagged (or silent when it has no payload), neighbours good."""
    rng = random.Random(6)
    frames = []
    kinds = []
    for k in range(400):
        kind = k % 8
        p = rng.randbytes(rng.randint(60, 200))
        if kind == 1:                                 # bad FCS
            b = bytearray(with_fcs(p))
            b[rng.randrange(len(b))] ^= 1 << rng.randrange(8)
            frames.append(Frame(bytes(b), p, True))
        elif kind == 3:                               # error character
            b = with_fcs(p)
            frames.append(Frame(b, p, True, err_at=rng.randrange(len(b))))
        elif kind == 5:                               # bad SFD
            frames.append(Frame(with_fcs(p), p, True, sfd=0x55))
        elif kind == 7:                               # runt with a good FCS
            q = rng.randbytes(rng.randint(1, 59))
            frames.append(Frame(with_fcs(q), q, True))
        elif kind == 6 and k % 16 == 6:               # 0..4 bytes: no output
            frames.append(Frame(rng.randbytes(rng.randint(0, 4)), None, True))
        else:
            frames.append(good(p))
        kinds.append(kind)
    tb = RxBench(dut, valid_pcs)
    await tb.start()
    await tb.run(build_lanes(frames, rng))
    check(tb, frames)
    for f, s in zip([f for f in frames if not f.lost], tb.stats):
        assert s["len"] == len(f.body)
    for kind, s in zip(kinds, tb.stats):
        if kind == 1:
            assert s["err_fcs"] and not s["err_ctl"]
        if kind in (3, 5):
            assert s["err_ctl"]
        if kind == 7:
            assert s["err_undersize"] and not s["err_fcs"]


@cocotb.test(timeout_time=10, timeout_unit="ms")
async def rx_size_limits(dut):
    """1518 passes, 1519 is oversize; with a VLAN tag 1522 passes and 1523
    does not; jumbo_en lets 9018 through and stops 9019."""
    rng = random.Random(7)

    def tagged(n, tpid):
        p = bytearray(rng.randbytes(n))
        p[12:14] = tpid
        return bytes(p)

    cases = [(rng.randbytes(1514), False), (rng.randbytes(1515), True),
             (tagged(1518, b"\x81\x00"), False), (tagged(1519, b"\x81\x00"), True),
             (tagged(1518, b"\x88\xa8"), False), (tagged(1519, b"\x88\xa8"), True),
             (tagged(1518, b"\x81\x01"), True)]
    frames = [Frame(with_fcs(p), p, bad) for p, bad in cases]
    tb = RxBench(dut, valid_pcs)
    await tb.start(jumbo=0)
    await tb.run(build_lanes(frames, rng))
    check(tb, frames)
    for (p, bad), s in zip(cases, tb.stats):
        assert s["err_oversize"] == int(bad) and not s["err_fcs"]
    tb.frames, tb.stats = [], []
    await FallingEdge(dut.clk)
    dut.jumbo_en.value = 1
    cases = [(rng.randbytes(9014), False), (rng.randbytes(9015), True),
             (rng.randbytes(1515), False)]
    frames = [Frame(with_fcs(p), p, bad) for p, bad in cases]
    await tb.run(build_lanes(frames, rng))
    check(tb, frames)


@cocotb.test(timeout_time=10, timeout_unit="ms")
async def rx_runaway(dut):
    """A frame with no terminate is cut at 16376 bytes with tuser; the next
    frame is received."""
    rng = random.Random(8)
    run = rng.randbytes(17000)
    frames = [good(rng.randbytes(100)), Frame(run, run, True, no_term=True),
              good(rng.randbytes(100))]
    tb = RxBench(dut)
    await tb.start(jumbo=1)
    await tb.run(build_lanes(frames, rng, 9, 12))
    assert len(tb.frames) == 3, [len(f) for f, _ in tb.frames]
    assert tb.frames[0] == (frames[0].exp_out, 0)
    assert tb.frames[1][1] == 1 and len(tb.frames[1][0]) == 16376 - 4
    assert tb.frames[2] == (frames[2].exp_out, 0)


@cocotb.test(timeout_time=10, timeout_unit="ms")
async def rx_bcast_mcast(dut):
    """stat_is_bcast and stat_is_mcast from the destination address."""
    rng = random.Random(9)
    ps = [b"\xff" * 6 + rng.randbytes(60), b"\x01\x00\x5e\x00\x00\x01" + rng.randbytes(60),
          b"\x02" + rng.randbytes(65), b"\xfe" + b"\xff" * 5 + rng.randbytes(60)]
    frames = [good(p) for p in ps]
    tb = RxBench(dut)
    await tb.start()
    await tb.run(build_lanes(frames, rng))
    check(tb, frames)
    assert [(s["is_bcast"], s["is_mcast"]) for s in tb.stats] == \
        [(1, 0), (0, 1), (0, 0), (0, 0)]


@cocotb.test(timeout_time=10, timeout_unit="ms")
async def rx_tiny_frames(dut):
    """Frames of 0 to 12 bytes after the SFD in both start lanes, between
    good frames: no payload gives no output, short ones come out flagged,
    and none of them swallows the next frame (a lane-4 frame can end in the
    word that holds the end of its preamble)."""
    rng = random.Random(10)
    frames = []
    for k in range(260):
        if k % 2:
            frames.append(good(rng.randbytes(rng.randint(60, 80))))
        else:
            n = (k // 2) % 13
            body = rng.randbytes(n)
            frames.append(Frame(body, body[:-4] if n >= 5 else None, True))
    tb = RxBench(dut, valid_pcs)
    await tb.start()
    await tb.run(build_lanes(frames, rng, 5, 9))
    check(tb, frames)
    for f, s in zip([f for f in frames if not f.lost], tb.stats):
        assert s["len"] == len(f.body)


@cocotb.test(timeout_time=10, timeout_unit="ms")
async def rx_aborted_frames(dut):
    """A frame cut short by idles, by a local fault ordered set or by a new
    start instead of a terminate ends there with tuser, and the frame after
    it is received (a cut by a start loses the frame that start begins)."""
    rng = random.Random(11)
    lf = [(0x9C, 1), (0x00, 0), (0x00, 0), (0x01, 0)]
    frames = []
    for k in range(120):
        kind = k % 4
        if kind == 0:
            frames.append(good(rng.randbytes(rng.randint(60, 120))))
            continue
        # aborted bodies end on a column (len % 4 == 0 after the 8-byte
        # preamble) so an ordered set or start can follow in the next lane
        body = rng.randbytes(4 * rng.randint(2, 30))
        if kind == 1:
            frames.append(Frame(body, body[:-4], True, no_term=True))
        elif kind == 2:
            frames.append(Frame(body, body[:-4], True, tail=lf * 2))
        else:
            frames.append(Frame(body, body[:-4], True, no_term=True))
            p = rng.randbytes(70)
            frames.append(Frame(with_fcs(p), None, True, gap0=True, lost=True))
    tb = RxBench(dut, valid_pcs)
    await tb.start()
    await tb.run(build_lanes(frames, rng, 5, 12))
    check(tb, frames)
    for f, s in zip([f for f in frames if not f.lost], tb.stats):
        assert s["len"] == len(f.body)


@cocotb.test(timeout_time=10, timeout_unit="ms")
async def rx_unqualified_start(dut):
    """A start right after error characters (not four idles or a sequence
    ordered set) flags its frame, in either lane; a start after a sequence
    ordered set is fine."""
    rng = random.Random(12)
    seq_os = [(0x9C, 1), (0x00, 0), (0x00, 0), (0x02, 0)]
    frames = []
    for k in range(150):
        p = rng.randbytes(rng.randint(60, 100))
        if k % 3 == 1:
            frames.append(Frame(with_fcs(p), p, True, pre=[(ERR, 1)] * 4))
        elif k % 3 == 2:
            frames.append(Frame(with_fcs(p), p, False, pre=seq_os))
        else:
            frames.append(good(p))
    tb = RxBench(dut, valid_pcs)
    await tb.start()
    await tb.run(build_lanes(frames, rng, 5, 12))
    check(tb, frames)
    for k, s in enumerate(tb.stats):
        assert s["err_ctl"] == (k % 3 == 1)
