# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""Randomized cocotb suite for rtl/csum_calc64.v (64-bit checksum engine).

Feeds frames as 64-bit beats, back to back or with random idle cycles inside
and between them, and checks every result against the Python reference in
lib/csum.py (scan=True: the engine's IPv4 options rule), in both modes:
zero_fields=1 (TX: values to insert) and zero_fields=0 (RX: verify). Each
result must come exactly LATENCY cycles after its frame's last beat, in
order, with the tag that beat carried.
"""
import os
import random
from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly
from cocotb.utils import get_sim_time

from lib.csum import (Packet, random_packet, csum, UDP, TCP, ICMP, ICMPV6,
                      TPID_8021Q, TPID_8021AD, LSRR, SSRR)


# Suites this module backs (read by run.py; see its docstring).
SUITES = {
    "csum_calc64": {
        "toplevel": "csum_calc64",
        "sources": ["rtl/csum_calc64.v"],
        "params": {"TAG_W": 3},
        "skip_vhdl": "csum_calc64 is Verilog only (10G path)",
    },
}

N_RANDOM = int(os.environ.get("CSUM_N_RANDOM", "400"))
PERIOD = 8
LATENCY = 6                 # cycles from the last beat's cycle to res_valid


class Bench:
    def __init__(self, dut):
        self.dut = dut
        self.q = deque()            # (sample time, packet or None, frame, tag, label)
        self.checked = 0
        self.zf = 0

    async def setup(self):
        dut = self.dut
        cocotb.start_soon(Clock(dut.clk, PERIOD, unit="ns").start())
        dut.in_valid.value = 0
        dut.in_data.value = 0
        dut.in_keep.value = 0
        dut.in_last.value = 0
        dut.in_tag.value = 0
        dut.zero_fields.value = 0
        dut.rst_n.value = 0
        for _ in range(4):
            await RisingEdge(dut.clk)
        dut.rst_n.value = 1
        await RisingEdge(dut.clk)
        cocotb.start_soon(self._monitor())

    async def feed(self, frame: bytes, rng, p, label, p_gap=0.0, tag=None):
        """Drive `frame` as beats; idle cycles inside with probability p_gap."""
        dut = self.dut
        n = (len(frame) + 7) // 8
        tag = rng.randrange(8) if tag is None else tag
        for i in range(n):
            while p_gap and rng.random() < p_gap:
                dut.in_valid.value = 0
                dut.in_tag.value = rng.randrange(8)
                await RisingEdge(dut.clk)
            chunk = frame[8 * i:8 * i + 8]
            last = i == n - 1
            dut.in_valid.value = 1
            dut.in_data.value = int.from_bytes(chunk + bytes(8 - len(chunk)), "little")
            dut.in_keep.value = (1 << len(chunk)) - 1
            dut.in_last.value = int(last)
            dut.in_tag.value = tag if last else rng.randrange(8)
            if last:
                # sampled at the next edge
                self.q.append((get_sim_time("ns") + PERIOD, p, frame, tag, label))
            await RisingEdge(dut.clk)
        dut.in_valid.value = 0
        dut.in_last.value = 0

    async def gap(self, cycles):
        self.dut.in_valid.value = 0
        for _ in range(cycles):
            await RisingEdge(self.dut.clk)

    async def drain(self):
        await self.gap(LATENCY + 4)
        assert not self.q, f"{len(self.q)} results missing, first {self.q[0][4]}"

    async def _monitor(self):
        dut = self.dut
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            if not int(dut.res_valid.value):
                continue
            assert self.q, "res_valid with no frame outstanding"
            t, p, frame, tag, label = self.q.popleft()
            now = get_sim_time("ns")
            lat = round((now - t) / PERIOD) + 1
            assert lat == LATENCY, f"{label}: result {lat} cycles after the last beat"
            assert int(dut.res_tag.value) == tag, f"{label}: tag"
            self._check(p, frame, label)
            self.checked += 1

    def _check(self, p, frame, label):
        dut = self.dut
        zf = self.zf
        got = (int(dut.res_ip4.value), int(dut.res_done.value), int(dut.res_l4_ok.value))
        if p is None:                      # oversize: no flags
            assert got == (0, 0, 0), f"{label}: oversize flags {got}"
            return
        e = p.expect(frame, scan=True)
        tag = f"{label} zf={zf} ({p})"
        assert got[0] == int(e.ip4), f"{tag}: ip4={got[0]}"
        ip_sum = int(dut.res_ip_sum.value)
        if e.ip4:
            assert int(dut.res_ip_pos.value) == e.ip_csum_pos, f"{tag}: ip_pos"
            if zf:
                assert (~ip_sum) & 0xFFFF == e.ip_csum, \
                    f"{tag}: ip csum {(~ip_sum) & 0xFFFF:04x} want {e.ip_csum:04x}"
            else:
                assert (ip_sum == 0xFFFF) == e.ip_good, \
                    f"{tag}: ip verdict sum={ip_sum:04x} good={e.ip_good}"
        assert got[1] == int(e.done), f"{tag}: done={got[1]}"
        if not e.done:
            assert got[2] == 0, f"{tag}: l4_ok without done"
            return
        assert got[2] == int(e.l4_ok), f"{tag}: l4_ok={got[2]}"
        if not e.l4_ok:
            return
        l4_sum = int(dut.res_l4_sum.value)
        assert int(dut.res_l4_pos.value) == e.l4_csum_pos, f"{tag}: l4_pos"
        assert int(dut.res_l4_udp.value) == int(e.l4_udp), f"{tag}: l4_udp"
        fld = int(dut.res_l4_field.value)
        assert fld == int.from_bytes(frame[e.l4_csum_pos:e.l4_csum_pos + 2], "big"), \
            f"{tag}: l4_field {fld:04x}"
        if zf:
            assert (~l4_sum) & 0xFFFF == e.l4_csum, \
                f"{tag}: l4 csum {(~l4_sum) & 0xFFFF:04x} want {e.l4_csum:04x}"
        else:
            verdict = True if (e.l4_udp and fld == 0) else l4_sum == 0xFFFF
            assert verdict == e.l4_good, \
                f"{tag}: l4 verdict sum={l4_sum:04x} good={e.l4_good}"

    async def mode(self, zf):
        """Change zero_fields with the pipeline empty (it is static)."""
        await self.drain()
        self.zf = zf
        self.dut.zero_fields.value = zf
        await RisingEdge(self.dut.clk)


DIRECTED = [
    Packet(family=4, proto=UDP, l4_len=8 + 18),
    Packet(family=4, proto=UDP, l4_len=8 + 17),           # odd length
    Packet(family=4, proto=TCP, l4_len=20 + 33, ihl=6, opts=bytes([1, 1, 1, 0])),
    Packet(family=4, proto=ICMP, l4_len=8 + 56),
    Packet(family=6, proto=UDP, l4_len=8 + 9),
    Packet(family=6, proto=TCP, l4_len=20 + 100),
    Packet(family=6, proto=ICMPV6, l4_len=8 + 3),
    Packet(family=4, proto=UDP, l4_len=8 + 4, vlan=TPID_8021Q, trailer=bytes(20)),
    Packet(family=6, proto=TCP, l4_len=20 + 7, vlan=TPID_8021AD),
    Packet(family=4, proto=TCP, l4_len=20 + 1, vlan=TPID_8021Q, ihl=15),
    Packet(family=4, proto=UDP, l4_len=8, mf=True),         # fragment
    Packet(family=4, proto=UDP, l4_len=8 + 10, udp_zero=True),
    Packet(family=6, proto=UDP, l4_len=8 + 10, udp_zero=True),
    Packet(family=0, l4_len=50),
    Packet(family=0, l4_len=0),                             # 14 bytes, 2 beats
]

# Review cases: (packet, ip4, done, l4_ok), stated here rather than taken
# from the model, so a rule the model and RTL share cannot hide.
ROUTE = bytes([10, 0, 0, 1])
REVIEW = [
    # UDP Length shorter than the IP payload: sum and pseudo-header use it
    (Packet(family=4, proto=UDP, l4_len=16, udp_len=12), 1, 1, 1),
    (Packet(family=6, proto=UDP, l4_len=40, udp_len=9), 0, 1, 1),
    (Packet(family=4, proto=UDP, l4_len=40, udp_len=9, vlan=TPID_8021Q, ihl=6,
            opts=bytes([1, 1, 1, 1])), 1, 1, 1),
    # UDP Length past the payload or below the header: not checked
    (Packet(family=4, proto=UDP, l4_len=16, udp_len=20), 1, 1, 0),
    (Packet(family=4, proto=UDP, l4_len=16, udp_len=4), 1, 1, 0),
    (Packet(family=6, proto=UDP, l4_len=16, udp_len=0), 0, 1, 0),
    # Source routes: L4 skipped, header still summed
    (Packet(family=4, proto=UDP, l4_len=20, ihl=7,
            opts=bytes([LSRR, 7, 4]) + ROUTE + bytes([1])), 1, 1, 0),
    (Packet(family=4, proto=TCP, l4_len=24, ihl=7,
            opts=bytes([1, SSRR, 7, 4]) + ROUTE), 1, 1, 0),
    # The byte scan: 0x83 / 0x89 anywhere in the options skips L4 ...
    (Packet(family=4, proto=UDP, l4_len=20, ihl=6,
            opts=bytes([0, LSRR, 7, 4])), 1, 1, 0),                    # after EOL
    (Packet(family=4, proto=UDP, l4_len=20, ihl=7,
            opts=bytes([7, 8, LSRR, SSRR, 0, 0, 0, 0])), 1, 1, 0),     # in RR data
    (Packet(family=4, proto=UDP, l4_len=20, ihl=15, vlan=TPID_8021Q,
            opts=bytes(39) + bytes([SSRR])), 1, 1, 0),                 # last byte
    # ... and an unwalkable list without them is summed
    (Packet(family=4, proto=UDP, l4_len=20, ihl=6,
            opts=bytes([68, 40, 0, 0])), 1, 1, 1),                     # overruns
    (Packet(family=4, proto=UDP, l4_len=20, ihl=6,
            opts=bytes([7, 1, 0, 0])), 1, 1, 1),                       # length 1
    # Truncated datagram: header verdict only
    (Packet(family=4, proto=UDP, l4_len=100, truncate=60), 1, 0, 0),
    (Packet(family=4, proto=UDP, l4_len=100, truncate=60, bad_ip=True), 1, 0, 0),
    (Packet(family=4, proto=TCP, l4_len=40, ihl=15, truncate=40), 1, 0, 0),
    (Packet(family=4, proto=TCP, l4_len=40, ihl=15, truncate=70), 0, 0, 0),
]


@cocotb.test()
async def directed(dut):
    """One of each protocol, both modes, back to back and with gaps."""
    b = Bench(dut)
    await b.setup()
    rng = random.Random(1)
    for zf in (1, 0):
        await b.mode(zf)
        for p_gap in (0.0, 0.3):
            for n, p in enumerate(DIRECTED):
                p.seed = 100 + n
                p.build()
                await b.feed(p.frame(), rng, p, f"directed[{n}]", p_gap)
    await b.drain()
    assert b.checked == 4 * len(DIRECTED)


@cocotb.test()
async def review_cases(dut):
    """UDP Length, IPv4 options under the byte scan, truncated datagrams."""
    b = Bench(dut)
    await b.setup()
    rng = random.Random(3)
    for n, (p, ip4, done, l4_ok) in enumerate(REVIEW):
        p.seed = 700 + n
        p.build()
        e = p.expect(scan=True)
        assert (int(e.ip4), int(e.done), int(e.l4_ok)) == (ip4, done, l4_ok), \
            f"review[{n}]: model says ip4/done/l4_ok=" \
            f"{int(e.ip4)}/{int(e.done)}/{int(e.l4_ok)}"
        f = p.frame()
        if p.udp_len is not None and l4_ok:
            # Independent UDP sum: pseudo-header length and data from UDP Length
            l3 = p._l3_off()
            l4s = l3 + p._ip_hdr_len()
            udp = bytearray(f[l4s:l4s + p.udp_len])
            udp[6:8] = bytes(2)
            if p.family == 4:
                ph = f[l3 + 12:l3 + 20] + bytes([0, UDP]) + p.udp_len.to_bytes(2, "big")
            else:
                ph = f[l3 + 8:l3 + 40] + p.udp_len.to_bytes(4, "big") + bytes([0, 0, 0, UDP])
            assert csum(ph + bytes(udp)) == e.l4_csum, f"review[{n}]: model UDP sum"
    for zf in (1, 0):
        await b.mode(zf)
        for n, (p, _, _, _) in enumerate(REVIEW):
            await b.feed(p.frame(), rng, p, f"review[{n}]", 0.2)
    await b.drain()


@cocotb.test()
async def randomized(dut):
    """Random packets across the scope, back to back and with gaps."""
    b = Bench(dut)
    await b.setup()
    seed = int(os.environ.get("CSUM_SEED", random.randrange(1 << 30)))
    dut._log.info(f"randomized seed={seed}")
    rng = random.Random(seed)
    for zf in (1, 0):
        await b.mode(zf)
        for n in range(N_RANDOM):
            p = random_packet(rng, max_l4=rng.choice([64, 300, 300, 1500]))
            p_gap = rng.choice([0.0, 0.0, 0.1, 0.5])
            await b.feed(p.frame(), rng, p, f"random[{n}] seed={seed}", p_gap)
            if rng.random() < 0.3:
                await b.gap(rng.randint(1, 9))
    await b.drain()
    assert b.checked == 2 * N_RANDOM


@cocotb.test()
async def long_frames(dut):
    """Jumbo datagrams, the 2048-beat limit (a datagram ending at its last
    byte included) and a frame past it."""
    b = Bench(dut)
    await b.setup()
    rng = random.Random(9)
    big = [
        Packet(family=4, proto=UDP, l4_len=9000 - 20, seed=1),
        Packet(family=6, proto=TCP, l4_len=9000 - 40, seed=2, vlan=TPID_8021Q),
        # 2048 beats exactly: datagram to byte 16383, one trailer byte
        Packet(family=4, proto=TCP, l4_len=16383 - 14 - 20, seed=3, trailer=b"\x55"),
        # 2048 beats exactly, the datagram ending at the last byte (byte 16384)
        Packet(family=4, proto=TCP, l4_len=16384 - 14 - 20, seed=6),
        Packet(family=6, proto=UDP, l4_len=16384 - 18 - 40, seed=7, vlan=TPID_8021Q),
    ]
    for zf in (1, 0):
        await b.mode(zf)
        for n, p in enumerate(big):
            p.build()
            f = p.frame()
            assert len(f) <= 16384
            e = p.expect(scan=True)
            assert e.done and e.l4_ok, f"big[{n}]: the model must cover it"
            await b.feed(f, rng, p, f"big[{n}]", 0.05)
        # 2049 beats: no flags, and the next frame is unaffected
        p = Packet(family=4, proto=UDP, l4_len=16000, seed=4, trailer=bytes(400)).build()
        f = p.frame()
        assert (len(f) + 7) // 8 > 2048
        await b.feed(f, rng, None, "oversize")
        q = Packet(family=4, proto=UDP, l4_len=30, seed=5).build()
        await b.feed(q.frame(), rng, q, "after oversize")
    await b.drain()
