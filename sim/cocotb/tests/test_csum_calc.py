# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""Randomized cocotb suite for rtl/net/csum_calc.v (checksum engine).

Feeds whole frames as a byte stream with random idle gaps and checks every
output against the Python reference in lib/csum.py, in both modes:
zero_fields=1 (TX: values to insert) and zero_fields=0 (RX: verify).
"""
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from lib.csum import (Packet, random_packet, csum, UDP, TCP, ICMP, ICMPV6,
                      TPID_8021Q, LSRR, SSRR)

N_RANDOM = int(os.environ.get("CSUM_N_RANDOM", "400"))


async def _setup(dut):
    cocotb.start_soon(Clock(dut.clk, 8, unit="ns").start())
    dut.in_valid.value = 0
    dut.in_idx.value = 0
    dut.in_data.value = 0
    dut.zero_fields.value = 0
    dut.rst_n.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def _feed(dut, frame: bytes, rng, zero_fields: int, p_gap=0.3):
    dut.zero_fields.value = zero_fields
    for i, b in enumerate(frame):
        while rng.random() < p_gap:
            dut.in_valid.value = 0
            await RisingEdge(dut.clk)
        dut.in_valid.value = 1
        dut.in_idx.value = min(i, 0x3FFF)
        dut.in_data.value = b
        await RisingEdge(dut.clk)
    dut.in_valid.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)


def _check(dut, p: Packet, zero_fields: int, tag: str):
    e = p.expect()
    # The IPv4 header verdict needs only the header, so check it first.
    assert int(dut.ip4.value) == int(e.ip4), f"{tag}: ip4={int(dut.ip4.value)} ({p})"
    ip_sum = int(dut.ip_sum.value)
    if e.ip4:
        assert int(dut.ip_csum_pos.value) == e.ip_csum_pos, f"{tag}: ip_csum_pos"
        assert int(dut.hdr_end.value) == p._l3_off() + p.ihl * 4, f"{tag}: hdr_end"
        if zero_fields:
            assert (~ip_sum) & 0xFFFF == e.ip_csum, f"{tag}: ip csum {(~ip_sum)&0xFFFF:04x} want {e.ip_csum:04x}"
        else:
            assert (ip_sum == 0xFFFF) == e.ip_good, f"{tag}: ip verdict sum={ip_sum:04x} good={e.ip_good}"
    got_done = int(dut.done.value)
    assert got_done == int(e.done), f"{tag}: done={got_done} want {int(e.done)} ({p})"
    if not e.done:
        return
    assert int(dut.l3_end.value) == e.l3_end, f"{tag}: l3_end"
    assert int(dut.l4_ok.value) == int(e.l4_ok), f"{tag}: l4_ok={int(dut.l4_ok.value)} ({p})"
    l4_sum = int(dut.l4_sum.value)
    if e.l4_ok:
        assert int(dut.l4_csum_pos.value) == e.l4_csum_pos, f"{tag}: l4_csum_pos"
        assert int(dut.l4_udp.value) == int(e.l4_udp), f"{tag}: l4_udp"
        if zero_fields:
            assert (~l4_sum) & 0xFFFF == e.l4_csum, f"{tag}: l4 csum {(~l4_sum)&0xFFFF:04x} want {e.l4_csum:04x} ({p})"
        else:
            field_val = int(dut.l4_field.value)
            if e.l4_udp and field_val == 0:
                verdict = e.ip4          # "none" over IPv4, invalid over IPv6
            else:
                verdict = l4_sum == 0xFFFF
            assert verdict == e.l4_good, f"{tag}: l4 verdict sum={l4_sum:04x} good={e.l4_good} ({p})"


@cocotb.test()
async def directed(dut):
    """One of each protocol, both modes, with and without a VLAN tag."""
    await _setup(dut)
    rng = random.Random(1)
    cases = [
        Packet(family=4, proto=UDP, l4_len=8 + 18),
        Packet(family=4, proto=UDP, l4_len=8 + 17),           # odd length
        Packet(family=4, proto=TCP, l4_len=20 + 33, ihl=6, opts=bytes([1, 1, 1, 0])),
        Packet(family=4, proto=ICMP, l4_len=8 + 56),
        Packet(family=6, proto=UDP, l4_len=8 + 9),
        Packet(family=6, proto=TCP, l4_len=20 + 100),
        Packet(family=6, proto=ICMPV6, l4_len=8 + 3),
        Packet(family=4, proto=UDP, l4_len=8 + 4, vlan=TPID_8021Q, trailer=bytes(20)),
        Packet(family=4, proto=UDP, l4_len=8, mf=True),         # fragment
        Packet(family=4, proto=UDP, l4_len=8 + 10, udp_zero=True),
        Packet(family=0, l4_len=50),
    ]
    for n, p in enumerate(cases):
        p.seed = 100 + n
        p.build()
        for zf in (1, 0):
            await _feed(dut, p.frame(), rng, zf)
            _check(dut, p, zf, f"directed[{n}] zf={zf}")


# Review cases: (packet, ip4, done, l4_ok), stated here rather than taken
# from the model, so a rule the model and RTL share cannot hide.
ROUTE = bytes([10, 0, 0, 1])
REVIEW = [
    # UDP Length shorter than the IP payload: sum and pseudo-header use it
    (Packet(family=4, proto=UDP, l4_len=16, udp_len=12), 1, 1, 1),
    (Packet(family=6, proto=UDP, l4_len=40, udp_len=9), 0, 1, 1),
    # UDP Length past the payload or below the header: not checked
    (Packet(family=4, proto=UDP, l4_len=16, udp_len=20), 1, 1, 0),
    (Packet(family=4, proto=UDP, l4_len=16, udp_len=4), 1, 1, 0),
    (Packet(family=6, proto=UDP, l4_len=16, udp_len=0), 0, 1, 0),
    # Source routes: L4 skipped, header still summed
    (Packet(family=4, proto=UDP, l4_len=20, ihl=7,
            opts=bytes([LSRR, 7, 4]) + ROUTE + bytes([1])), 1, 1, 0),
    (Packet(family=4, proto=TCP, l4_len=24, ihl=7,
            opts=bytes([1, SSRR, 7, 4]) + ROUTE), 1, 1, 0),
    # Options without a source route: L4 still checked
    (Packet(family=4, proto=UDP, l4_len=20, ihl=6,
            opts=bytes([0, LSRR, 7, 4])), 1, 1, 1),                    # after EOL
    (Packet(family=4, proto=UDP, l4_len=20, ihl=7,
            opts=bytes([7, 8, LSRR, SSRR, 0, 0, 0, 0])), 1, 1, 1),     # in RR data
    (Packet(family=4, proto=UDP, l4_len=20, ihl=6,
            opts=bytes([68, 40, 0, 0])), 1, 1, 1),                     # overruns
    # Malformed option length: L4 skipped
    (Packet(family=4, proto=UDP, l4_len=20, ihl=6,
            opts=bytes([7, 1, 0, 0])), 1, 1, 0),
    # Truncated datagram: header verdict only
    (Packet(family=4, proto=UDP, l4_len=100, truncate=60), 1, 0, 0),
    (Packet(family=4, proto=UDP, l4_len=100, truncate=60, bad_ip=True), 1, 0, 0),
    (Packet(family=4, proto=TCP, l4_len=40, ihl=15, truncate=40), 1, 0, 0),
]


@cocotb.test()
async def review_cases(dut):
    """UDP Length, IPv4 source routes and truncated datagrams."""
    await _setup(dut)
    rng = random.Random(3)
    for n, (p, ip4, done, l4_ok) in enumerate(REVIEW):
        p.seed = 700 + n
        p.build()
        e = p.expect()
        assert (int(e.ip4), int(e.done), int(e.l4_ok)) == (ip4, done, l4_ok),             f"review[{n}]: model says ip4/done/l4_ok={int(e.ip4)}/{int(e.done)}/{int(e.l4_ok)}"
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
            await _feed(dut, f, rng, zf)
            _check(dut, p, zf, f"review[{n}] zf={zf}")


@cocotb.test()
async def randomized(dut):
    """Random packets across the scope, including corrupt and skipped ones."""
    await _setup(dut)
    seed = int(os.environ.get("CSUM_SEED", random.randrange(1 << 30)))
    dut._log.info(f"randomized seed={seed}")
    rng = random.Random(seed)
    for n in range(N_RANDOM):
        p = random_packet(rng)
        zf = rng.randint(0, 1)
        await _feed(dut, p.frame(), rng, zf)
        _check(dut, p, zf, f"random[{n}] seed={seed} zf={zf}")
