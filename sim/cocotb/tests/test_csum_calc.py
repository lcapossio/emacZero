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

from lib.csum import Packet, random_packet, UDP, TCP, ICMP, ICMPV6, TPID_8021Q

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
    got_done = int(dut.done.value)
    assert got_done == int(e.done), f"{tag}: done={got_done} want {int(e.done)} ({p})"
    if not e.done:
        return
    assert int(dut.l3_end.value) == e.l3_end, f"{tag}: l3_end"
    assert int(dut.ip4.value) == int(e.ip4), f"{tag}: ip4"
    assert int(dut.l4_ok.value) == int(e.l4_ok), f"{tag}: l4_ok={int(dut.l4_ok.value)} ({p})"
    ip_sum = int(dut.ip_sum.value)
    l4_sum = int(dut.l4_sum.value)
    if e.ip4:
        assert int(dut.ip_csum_pos.value) == e.ip_csum_pos, f"{tag}: ip_csum_pos"
        if zero_fields:
            assert (~ip_sum) & 0xFFFF == e.ip_csum, f"{tag}: ip csum {(~ip_sum)&0xFFFF:04x} want {e.ip_csum:04x}"
        else:
            assert (ip_sum == 0xFFFF) == e.ip_good, f"{tag}: ip verdict sum={ip_sum:04x} good={e.ip_good}"
    if e.l4_ok:
        assert int(dut.l4_csum_pos.value) == e.l4_csum_pos, f"{tag}: l4_csum_pos"
        assert int(dut.l4_udp.value) == int(e.l4_udp), f"{tag}: l4_udp"
        if zero_fields:
            assert (~l4_sum) & 0xFFFF == e.l4_csum, f"{tag}: l4 csum {(~l4_sum)&0xFFFF:04x} want {e.l4_csum:04x} ({p})"
        else:
            field_val = int(dut.l4_field.value)
            udp_none = e.l4_udp and e.ip4 and field_val == 0
            verdict = udp_none or l4_sum == 0xFFFF
            assert verdict == e.l4_good, f"{tag}: l4 verdict sum={l4_sum:04x} good={e.l4_good} ({p})"


@cocotb.test()
async def directed(dut):
    """One of each protocol, both modes, with and without a VLAN tag."""
    await _setup(dut)
    rng = random.Random(1)
    cases = [
        Packet(family=4, proto=UDP, l4_len=8 + 18),
        Packet(family=4, proto=UDP, l4_len=8 + 17),           # odd length
        Packet(family=4, proto=TCP, l4_len=20 + 33, ihl=6),
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
