# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""Randomized cocotb suite for rtl/tx_csum_off64.v (64-bit TX checksum offload).

Streams random frames (IPv4 / IPv6, TCP / UDP / ICMP / ICMPv6, other
protocols, VLAN tags, fragments, trailers, wrong checksums in the input) as
64-bit beats through the stage with random source bubbles and sink
backpressure, `enable` changed per frame (and on later beats, which must not
count), random tuser on every beat, and checks every output frame byte for
byte against the reference in lib/csum.py (scan=True), plus tuser per beat
and m_drop. Two suites: the default buffer, where a back-to-back stream must
pass without the source ever stalling, and a 64-word buffer with 4 metadata
slots, for the cut of a frame that does not fit and a full metadata FIFO.
"""
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly

from lib.csum import (Packet, random_packet, force_zero_l4_csum,
                      UDP, TCP, ICMP, ICMPV6, TPID_8021Q, TPID_8021AD, LSRR)


# Suites this module backs (read by run.py; see its docstring).
SUITES = {
    "tx_csum_off64": {
        "toplevel": "tx_csum_off64",
        "sources": ["rtl/sync_fifo.v", "rtl/csum_calc64.v", "rtl/tx_csum_off64.v"],
        "params": {},
        "env": {"TXCS64_BUF_AW": "11"},
        "skip_vhdl": "tx_csum_off64 is Verilog only (10G path)",
    },
    "tx_csum_off64_small": {
        "toplevel": "tx_csum_off64",
        "sources": ["rtl/sync_fifo.v", "rtl/csum_calc64.v", "rtl/tx_csum_off64.v"],
        "params": {"BUF_ADDR_WIDTH": 6, "META_ADDR_WIDTH": 2},
        "env": {"TXCS64_BUF_AW": "6"},
        "skip_vhdl": "tx_csum_off64 is Verilog only (10G path)",
    },
}

N_RANDOM = int(os.environ.get("CSUM_N_RANDOM", "300"))
BUF_AW = int(os.environ.get("TXCS64_BUF_AW", "11"))
MAX_BEATS = 1 << BUF_AW


def beats_of(frame: bytes):
    """(data, keep) per beat."""
    out = []
    for i in range(0, len(frame), 8):
        c = frame[i:i + 8]
        out.append((int.from_bytes(c + bytes(8 - len(c)), "little"), (1 << len(c)) - 1))
    return out


class Source:
    """AXIS 64-bit master with random bubbles; records per-frame tuser."""

    def __init__(self, dut, rng, p_bubble=0.0, max_gap=5):
        self.dut = dut
        self.rng = rng
        self.p_bubble = p_bubble
        self.max_gap = max_gap
        self.stalls = 0          # cycles with tvalid high and tready low
        dut.s_axis_tvalid.value = 0
        dut.s_axis_tlast.value = 0
        dut.s_axis_tdata.value = 0
        dut.s_axis_tkeep.value = 0
        dut.s_axis_tuser.value = 0

    async def send(self, frame: bytes, enable: bool):
        """Send one frame; return its tuser bits, one per beat."""
        dut = self.dut
        bl = beats_of(frame)
        users = []
        for i, (d, k) in enumerate(bl):
            if self.p_bubble and self.rng.random() < self.p_bubble:
                dut.s_axis_tvalid.value = 0
                for _ in range(self.rng.randint(1, self.max_gap)):
                    await RisingEdge(dut.clk)
            u = self.rng.randint(0, 1) if self.rng.random() < 0.1 else 0
            users.append(u)
            # enable counts on the first beat only
            dut.enable.value = int(enable) if i == 0 else self.rng.randint(0, 1)
            dut.s_axis_tdata.value = d
            dut.s_axis_tkeep.value = k
            dut.s_axis_tuser.value = u
            dut.s_axis_tlast.value = int(i == len(bl) - 1)
            dut.s_axis_tvalid.value = 1
            while True:
                await ReadOnly()
                ready = int(dut.s_axis_tready.value)
                await RisingEdge(dut.clk)
                if ready:
                    break
                self.stalls += 1
        dut.s_axis_tvalid.value = 0
        dut.s_axis_tlast.value = 0
        return users


class Sink:
    """AXIS slave: collects frames (bytes, tuser per beat, m_drop per beat)."""

    def __init__(self, dut, rng, p_stall=0.0, max_stall=6):
        self.dut = dut
        self.rng = rng
        self.p_stall = p_stall
        self.max_stall = max_stall
        self.frames = []         # (bytes, [tuser], [m_drop])
        self.cyc = 0
        self.last_cyc = []       # cycle of each frame's last beat
        dut.m_axis_tready.value = 0

    async def run(self):
        dut = self.dut
        cur, us, ds = bytearray(), [], []
        stall = 0
        while True:
            if stall:
                dut.m_axis_tready.value = 0
                stall -= 1
            else:
                dut.m_axis_tready.value = 1
                if self.p_stall and self.rng.random() < self.p_stall:
                    stall = self.rng.randint(1, self.max_stall)
            await ReadOnly()
            if int(dut.m_axis_tvalid.value) and int(dut.m_axis_tready.value):
                d = int(dut.m_axis_tdata.value)
                k = int(dut.m_axis_tkeep.value)
                last = int(dut.m_axis_tlast.value)
                assert k in [(1 << n) - 1 for n in range(1, 9)], f"tkeep {k:02x}"
                assert last or k == 0xFF, f"tkeep {k:02x} before tlast"
                n = bin(k).count("1")
                cur += d.to_bytes(8, "little")[:n]
                us.append(int(dut.m_axis_tuser.value))
                ds.append(int(dut.m_drop.value))
                if last:
                    self.frames.append((bytes(cur), us, ds))
                    self.last_cyc.append(self.cyc)
                    cur, us, ds = bytearray(), [], []
            await RisingEdge(dut.clk)
            self.cyc += 1


def expected(p: Packet, enable: bool) -> bytes:
    """What the stage should send for packet `p`."""
    f = bytearray(p.frame())
    if not enable:
        return bytes(f)
    e = p.expect(scan=True)
    if not e.done:
        return bytes(f)
    if e.ip4:
        f[e.ip_csum_pos:e.ip_csum_pos + 2] = e.ip_csum.to_bytes(2, "big")
    if e.l4_ok:
        c = e.l4_csum
        if e.l4_udp and c == 0:
            c = 0xFFFF
        f[e.l4_csum_pos:e.l4_csum_pos + 2] = c.to_bytes(2, "big")
    return bytes(f)


async def _setup(dut):
    cocotb.start_soon(Clock(dut.clk, 8, unit="ns").start())
    dut.enable.value = 0
    dut.s_axis_tvalid.value = 0       # also clears a previous test's beat
    dut.s_axis_tlast.value = 0
    dut.s_axis_tdata.value = 0
    dut.s_axis_tkeep.value = 0
    dut.s_axis_tuser.value = 0
    dut.m_axis_tready.value = 0
    dut.rst_n.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def _drain(dut, sink: Sink, n_frames: int, limit: int = 400000):
    for _ in range(limit):
        if len(sink.frames) >= n_frames:
            return
        await RisingEdge(dut.clk)
    raise AssertionError(f"timeout: got {len(sink.frames)} of {n_frames} frames")


def _compare(got: bytes, want: bytes, tag: str):
    if got == want:
        return
    diffs = [i for i in range(max(len(got), len(want)))
             if i >= len(got) or i >= len(want) or got[i] != want[i]]
    raise AssertionError(
        f"{tag}: len {len(got)} want {len(want)}, first diffs at {diffs[:8]}: "
        + ", ".join(f"[{i}] {got[i] if i < len(got) else None} want "
                    f"{want[i] if i < len(want) else None}" for i in diffs[:4]))


def _check(sink, idx, want, users, tag, cut=False):
    got, us, ds = sink.frames[idx]
    _compare(got, want, tag)
    assert us == users, f"{tag}: tuser {us} want {users}"
    assert ds == [int(cut)] * len(ds), f"{tag}: m_drop {ds}"


async def _stream(dut, src, sink, items, tag):
    """Send (packet or frame, enable) items; check each output frame."""
    sent = []
    for n, (p, en) in enumerate(items):
        f = p.frame() if isinstance(p, Packet) else p
        users = await src.send(f, en)
        want = expected(p, en) if isinstance(p, Packet) else f
        sent.append((want, users))
    await _drain(dut, sink, len(sent))
    for n, (want, users) in enumerate(sent):
        _check(sink, n, want, users, f"{tag}[{n}] ({items[n][0]})")


DIRECTED = [
    Packet(family=4, proto=UDP, l4_len=8 + 18, bad_ip=True, bad_l4=True),
    Packet(family=4, proto=UDP, l4_len=8 + 17, udp_zero=True),
    Packet(family=4, proto=TCP, l4_len=20 + 33, ihl=7, bad_l4=True),
    Packet(family=4, proto=ICMP, l4_len=8 + 56, bad_l4=True),
    Packet(family=6, proto=UDP, l4_len=8 + 9, bad_l4=True),
    Packet(family=6, proto=TCP, l4_len=20 + 100),
    Packet(family=6, proto=ICMPV6, l4_len=8 + 3, bad_l4=True),
    Packet(family=4, proto=UDP, l4_len=8 + 4, vlan=TPID_8021Q, trailer=bytes(20),
           bad_ip=True),
    Packet(family=4, proto=TCP, l4_len=20 + 5, vlan=TPID_8021AD, ihl=15, bad_l4=True),
    Packet(family=4, proto=UDP, l4_len=8 + 10, ihl=6, bad_l4=True,
           opts=bytes([7, 3, LSRR, 0])),                  # scan: L4 left alone
    Packet(family=4, proto=UDP, l4_len=8, mf=True, bad_ip=True),   # fragment
    Packet(family=4, proto=UDP, l4_len=100, truncate=60, bad_ip=True),
    Packet(family=0, l4_len=50),
]


@cocotb.test()
async def directed(dut):
    """One of each protocol, enabled and disabled, wrong input checksums."""
    await _setup(dut)
    rng = random.Random(7)
    src = Source(dut, rng)
    sink = Sink(dut, rng)
    cocotb.start_soon(sink.run())
    items = []
    for n, p in enumerate(DIRECTED):
        p.seed = 300 + n
        p.build()
        items += [(p, True), (p, False)]
    # UDP checksum computing to 0 goes out as 0xFFFF
    z = force_zero_l4_csum(Packet(family=4, proto=UDP, l4_len=40, seed=5).build())
    items.append((z, True))
    await _stream(dut, src, sink, items, "directed")
    got = sink.frames[-1][0]
    pos = z.expect(scan=True).l4_csum_pos
    assert got[pos:pos + 2] == b"\xff\xff", "UDP 0 not sent as 0xFFFF"


@cocotb.test()
async def randomized(dut):
    """Random packets, enable per frame, bubbles and backpressure."""
    await _setup(dut)
    seed = int(os.environ.get("CSUM_SEED", random.randrange(1 << 30)))
    dut._log.info(f"randomized seed={seed}")
    rng = random.Random(seed)
    src = Source(dut, rng, p_bubble=0.15)
    sink = Sink(dut, rng, p_stall=0.2)
    cocotb.start_soon(sink.run())
    max_l4 = 300 if BUF_AW < 8 else 1500
    items = [(random_packet(rng, max_l4=rng.choice([64, max_l4])), rng.random() < 0.8)
             for _ in range(N_RANDOM)]
    await _stream(dut, src, sink, items, f"random seed={seed}")


@cocotb.test()
async def back_to_back(dut):
    """Back to back with the sink always ready: the source never stalls
    (default buffer). Egress waits for each frame's metadata, so after a
    long frame and shorter ones it runs behind by up to the difference;
    the last frame leaves within the longest frame of being in."""
    await _setup(dut)
    rng = random.Random(11)
    src = Source(dut, rng)
    sink = Sink(dut, rng)
    cocotb.start_soon(sink.run())
    max_l4 = 300 if BUF_AW < 8 else 1500
    items = [(random_packet(rng, max_l4=max_l4), True) for _ in range(120)]
    sent = []
    for p, en in items:
        users = await src.send(p.frame(), en)
        sent.append((expected(p, en), users))
    in_end = sink.cyc
    await _drain(dut, sink, len(sent))
    for n, (want, users) in enumerate(sent):
        _check(sink, n, want, users, f"b2b[{n}] ({items[n][0]})")
    max_beats = max((len(w) + 7) // 8 for w, _ in sent)
    lag = sink.last_cyc[-1] - in_end
    dut._log.info(f"source stalls {src.stalls}, last frame out {lag} cycles after in")
    if BUF_AW >= 11:
        assert src.stalls == 0, f"source stalled {src.stalls} cycles"
        assert lag <= max_beats + 12, f"last frame out {lag} cycles after in"


@cocotb.test()
async def mixed_sizes(dut):
    """Jumbo frames with runs of minimum frames between them, back to back
    with the sink always ready: while a jumbo frame is on its way out the
    minimum frames queue behind it, and the source is never held (default
    buffer: metadata for every 8-beat frame it can hold)."""
    if BUF_AW < 11:
        dut._log.info("mixed_sizes: needs the default buffer")
        return
    await _setup(dut)
    rng = random.Random(19)
    src = Source(dut, rng)
    sink = Sink(dut, rng)
    cocotb.start_soon(sink.run())
    items = []
    for run in (40, 150, 230):
        items.append((Packet(family=4, proto=UDP, l4_len=9014 - 34, bad_l4=True,
                             seed=rng.randrange(1 << 30)).build(), True))
        items += [(Packet(family=4, proto=UDP, l4_len=26, bad_l4=True,
                          seed=rng.randrange(1 << 30)).build(), True)
                  for _ in range(run)]
    items.append((Packet(family=6, proto=TCP, l4_len=9014 - 54, bad_l4=True,
                         seed=1).build(), True))
    sent = []
    for p, en in items:
        users = await src.send(p.frame(), en)
        sent.append((expected(p, en), users))
    await _drain(dut, sink, len(sent))
    for n, (want, users) in enumerate(sent):
        _check(sink, n, want, users, f"mixed[{n}]")
    assert src.stalls == 0, f"source stalled {src.stalls} cycles"


@cocotb.test()
async def cut(dut):
    """A frame longer than the buffer is cut, flagged with m_drop, and the
    frames around it are unharmed."""
    if MAX_BEATS > 256:
        dut._log.info("cut: covered by the small-buffer suite")
        return
    await _setup(dut)
    rng = random.Random(13)
    src = Source(dut, rng, p_bubble=0.1)
    sink = Sink(dut, rng, p_stall=0.1)
    cocotb.start_soon(sink.run())
    before = Packet(family=4, proto=UDP, l4_len=60, bad_l4=True, seed=1).build()
    after = Packet(family=6, proto=TCP, l4_len=80, bad_l4=True, seed=2).build()
    exact = Packet(family=4, proto=UDP, l4_len=MAX_BEATS * 8 - 34, bad_l4=True,
                   seed=3).build()                       # fills the buffer exactly
    for extra in (1, 8, 9, 300):
        big = Packet(family=4, proto=UDP, l4_len=MAX_BEATS * 8 - 34 + extra,
                     bad_l4=True, seed=4).build()
        fb, fe = big.frame(), exact.frame()
        assert len(fe) == MAX_BEATS * 8
        base = len(sink.frames)
        u0 = await src.send(before.frame(), True)
        u1 = await src.send(fb, True)
        u2 = await src.send(after.frame(), True)
        u3 = await src.send(fe, True)
        await _drain(dut, sink, base + 4)
        _check(sink, base, expected(before, True), u0, f"cut+{extra} before")
        _check(sink, base + 1, fb[:MAX_BEATS * 8], u1[:MAX_BEATS],
               f"cut+{extra} big", cut=True)
        _check(sink, base + 2, expected(after, True), u2, f"cut+{extra} after")
        _check(sink, base + 3, expected(exact, True), u3, f"cut+{extra} exact")


@cocotb.test()
async def meta_full(dut):
    """Many short frames against a stalled sink: the metadata FIFO fills
    (frames of 1 to 3 beats, so before the buffer), the source is held, and
    nothing is lost or reordered."""
    await _setup(dut)
    rng = random.Random(17)
    src = Source(dut, rng)
    sink = Sink(dut, rng, p_stall=0.9, max_stall=40)
    cocotb.start_soon(sink.run())
    n = 2 * (1 << (BUF_AW - 3)) if BUF_AW >= 11 else 80
    items = []
    for _ in range(n):
        if rng.random() < 0.1:
            items.append((Packet(family=rng.choice([4, 6]), proto=rng.choice([UDP, TCP]),
                                 l4_len=rng.randint(20, 40), bad_l4=True,
                                 seed=rng.randrange(1 << 30)).build(), True))
        else:
            items.append((bytes(rng.randrange(256) for _ in range(rng.randint(1, 24))),
                          True))
    await _stream(dut, src, sink, items, "meta_full")
    assert src.stalls > 0, "the source was never held"
