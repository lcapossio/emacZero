# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""Randomized cocotb suite for rtl/net/tx_csum_off.v (TX checksum offload).

Streams random frames (IPv4 / IPv6, TCP / UDP / ICMP / ICMPv6, other
protocols, VLAN tags, fragments, trailers, wrong checksums in the input)
through the stage with random source bubbles and sink backpressure, `enable`
toggled per frame, and checks every output frame byte for byte against the
reference in lib/csum.py. Also checks the MAX_FRAME cut and that a stream of
back-to-back frames drains at close to one byte per clock.
"""
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly

from lib.axis_driver import AxisMaster
from lib.csum import (Packet, random_packet, force_zero_l4_csum, csum, ones_sum,
                      UDP, TCP, ICMP, ICMPV6, TPID_8021AD, LSRR)

N_RANDOM = int(os.environ.get("CSUM_N_RANDOM", "300"))
MAX_FRAME = 600          # matches the run.py parameter


class Sink:
    """AXIS slave: collects frames, optional random tready stalls."""

    def __init__(self, dut, rng, p_stall=0.0, max_stall=6):
        self.dut = dut
        self.rng = rng
        self.p_stall = p_stall
        self.max_stall = max_stall
        self.frames = []
        self.beats = []          # cycle number of every accepted beat
        dut.m_axis_tready.value = 0

    async def run(self):
        dut = self.dut
        cur = bytearray()
        stall = 0
        cyc = 0
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
                cur.append(int(dut.m_axis_tdata.value) & 0xFF)
                self.beats.append(cyc)
                if int(dut.m_axis_tlast.value):
                    self.frames.append(bytes(cur))
                    cur = bytearray()
            await RisingEdge(dut.clk)
            cyc += 1


def expected(p: Packet, enable: bool) -> bytes:
    """What the stage should send for packet `p`."""
    f = bytearray(p.frame())
    if not enable:
        return bytes(f)
    e = p.expect()
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
    dut.rst_n.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def _send(dut, m: AxisMaster, frame: bytes, enable: bool):
    dut.enable.value = int(enable)
    await m.send_segment(frame, last=True)


async def _drain(dut, sink: Sink, n_frames: int, limit: int = 200000):
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


@cocotb.test()
async def directed(dut):
    """One of each protocol, enabled and disabled, wrong input checksums."""
    await _setup(dut)
    rng = random.Random(7)
    m = AxisMaster(dut, rng, p_bubble=0.0)
    sink = Sink(dut, rng)
    cocotb.start_soon(sink.run())
    cases = [
        Packet(family=4, proto=UDP, l4_len=8 + 18, bad_ip=True, bad_l4=True),
        Packet(family=4, proto=UDP, l4_len=8 + 17, udp_zero=True),
        Packet(family=4, proto=TCP, l4_len=20 + 33, ihl=7, bad_l4=True),
        Packet(family=4, proto=ICMP, l4_len=8 + 56, bad_l4=True),
        Packet(family=6, proto=UDP, l4_len=8 + 9, bad_l4=True),
        Packet(family=6, proto=TCP, l4_len=20 + 100),
        Packet(family=6, proto=ICMPV6, l4_len=8 + 3, bad_l4=True),
        Packet(family=4, proto=UDP, l4_len=8 + 4, vlan=TPID_8021AD,
               trailer=bytes(range(20)), bad_ip=True),
        Packet(family=4, proto=UDP, l4_len=8, mf=True, bad_ip=True),
        Packet(family=0, l4_len=50),
    ]
    for n, p in enumerate(cases):
        p.seed = 200 + n
        p.build()
    # UDP checksums that compute to 0 (sent as 0xFFFF), and a TCP one (sent
    # as 0x0000)
    for n, (fam, proto) in enumerate(((4, UDP), (6, UDP), (4, TCP))):
        cases.append(force_zero_l4_csum(
            Packet(family=fam, proto=proto, l4_len=40, seed=250 + n).build()))
    sent = []
    for p in cases:
        for en in (True, False):
            await _send(dut, m, p.frame(), en)
            sent.append((p, en))
    await _drain(dut, sink, len(sent))
    for n, ((p, en), got) in enumerate(zip(sent, sink.frames)):
        _compare(got, expected(p, en), f"directed[{n}] en={en} {p}")


@cocotb.test()
async def review_cases(dut):
    """UDP Length below the IP payload, and frames whose L4 checksum must be
    left as software wrote it (source route, bad UDP Length), checked against
    values computed here rather than by the model."""
    await _setup(dut)
    rng = random.Random(8)
    m = AxisMaster(dut, rng, p_bubble=0.1)
    sink = Sink(dut, rng, p_stall=0.1)
    cocotb.start_soon(sink.run())
    sw = bytes([0xDB, 0xCC])                     # what software left in the field
    route = bytes([LSRR, 7, 4, 203, 0, 113, 99, 1])
    cases = [   # (packet, L4 field left alone?)
        (Packet(family=4, proto=UDP, l4_len=16, udp_len=12, seed=601), False),
        (Packet(family=6, proto=UDP, l4_len=30, udp_len=11, seed=602), False),
        (Packet(family=4, proto=UDP, l4_len=20, ihl=7, opts=route, seed=603), True),
        (Packet(family=4, proto=TCP, l4_len=24, ihl=7, opts=route, seed=604), True),
        (Packet(family=4, proto=UDP, l4_len=16, udp_len=20, seed=605), True),
    ]
    frames = []
    for p, _ in cases:
        p.build()
        f = bytearray(p.frame())
        l4s = p._l3_off() + p._ip_hdr_len()
        off = l4s + (6 if p.proto == UDP else 16)
        f[off:off + 2] = sw
        frames.append((bytes(f), l4s, off))
        await _send(dut, m, bytes(f), True)
    await _drain(dut, sink, len(cases))
    for n, ((p, keep), (f, l4s, off), got) in enumerate(zip(cases, frames, sink.frames)):
        tag = f"review[{n}] {p}"
        l3 = p._l3_off()
        if p.family == 4:
            assert ones_sum(got[l3:l4s]) == 0xFFFF, f"{tag}: IPv4 header checksum"
        if keep:
            assert got[off:off + 2] == sw, f"{tag}: L4 field changed to {got[off:off + 2].hex()}"
            continue
        n_l4 = p.udp_len
        seg = bytearray(f[l4s:l4s + n_l4])
        seg[6:8] = bytes(2)
        if p.family == 4:
            ph = f[l3 + 12:l3 + 20] + bytes([0, UDP]) + n_l4.to_bytes(2, "big")
        else:
            ph = f[l3 + 8:l3 + 40] + n_l4.to_bytes(4, "big") + bytes([0, 0, 0, UDP])
        c = csum(ph + bytes(seg)) or 0xFFFF
        assert int.from_bytes(got[off:off + 2], "big") == c, \
            f"{tag}: UDP checksum {got[off:off + 2].hex()} want {c:04x}"


@cocotb.test()
async def randomized(dut):
    """Random frames, random bubbles and stalls, enable random per frame."""
    await _setup(dut)
    seed = int(os.environ.get("CSUM_SEED", random.randrange(1 << 30)))
    dut._log.info(f"randomized seed={seed}")
    rng = random.Random(seed)
    m = AxisMaster(dut, rng, p_bubble=0.2, max_gap=4)
    sink = Sink(dut, rng, p_stall=0.2)
    cocotb.start_soon(sink.run())
    sent = []
    for _ in range(N_RANDOM):
        p = random_packet(rng)
        en = rng.random() < 0.85
        await _send(dut, m, p.frame(), en)
        sent.append((p, en))
    await _drain(dut, sink, len(sent))
    assert len(sink.frames) == len(sent)
    for n, ((p, en), got) in enumerate(zip(sent, sink.frames)):
        _compare(got, expected(p, en), f"random[{n}] seed={seed} en={en} {p}")


@cocotb.test()
async def oversize_cut(dut):
    """A frame over MAX_FRAME is cut there, unpatched; the next is intact."""
    await _setup(dut)
    rng = random.Random(3)
    m = AxisMaster(dut, rng, p_bubble=0.1)
    sink = Sink(dut, rng, p_stall=0.1)
    cocotb.start_soon(sink.run())
    big = Packet(family=4, proto=UDP, l4_len=MAX_FRAME, seed=11, bad_ip=True).build()
    exact = Packet(family=4, proto=UDP, l4_len=MAX_FRAME - 34, seed=12, bad_l4=True).build()
    small = Packet(family=6, proto=TCP, l4_len=40, seed=13, bad_l4=True).build()
    assert len(exact.frame()) == MAX_FRAME
    await _send(dut, m, big.frame(), True)
    await _send(dut, m, exact.frame(), True)
    await _send(dut, m, small.frame(), True)
    await _drain(dut, sink, 3)
    _compare(sink.frames[0], big.frame()[:MAX_FRAME], "oversize cut")
    _compare(sink.frames[1], expected(exact, True), "exactly MAX_FRAME")
    _compare(sink.frames[2], expected(small, True), "frame after cut")


@cocotb.test()
async def throughput(dut):
    """Back-to-back frames with no bubbles or stalls drain at ~1 byte/clk."""
    await _setup(dut)
    rng = random.Random(5)
    m = AxisMaster(dut, rng, p_bubble=0.0)
    sink = Sink(dut, rng, p_stall=0.0)
    cocotb.start_soon(sink.run())
    pkts = [Packet(family=4, proto=UDP, l4_len=rng.randint(100, 500),
                   seed=300 + i).build() for i in range(20)]
    for p in pkts:
        await _send(dut, m, p.frame(), True)
    await _drain(dut, sink, len(pkts))
    for n, (p, got) in enumerate(zip(pkts, sink.frames)):
        _compare(got, expected(p, True), f"throughput[{n}]")
    beats = len(sink.beats)
    span = sink.beats[-1] - sink.beats[0] + 1
    # Per frame the stage pauses ingest 5 cycles after TLAST; allow 8.
    assert span <= beats + 8 * len(pkts), f"{beats} beats took {span} cycles"
    dut._log.info(f"throughput: {beats} beats in {span} cycles")
