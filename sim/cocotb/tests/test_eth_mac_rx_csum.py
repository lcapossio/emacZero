# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""Randomized cocotb suite for eth_mac_rx's checksum checker (RX_CSUM_OFFLOAD=1).

Drives random frames (IPv4 / IPv6, TCP / UDP / ICMP / ICMPv6, other
protocols, VLAN tags, fragments, padding, right and wrong checksums, and some
bad FCS) over GMII and checks, per frame:
  - terror is set exactly when the frame has a bad FCS, or rx_csum_en was set
    and an IPv4 header or L4 checksum in scope is wrong;
  - stat_err_csum pulses with stat_done exactly when the checksum is the only
    fault;
  - the delivered bytes are the frame unchanged.
"""
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly

from lib.axis_sink import AxisSink
from lib.csum import Packet, random_packet, pad60, UDP, TCP, ICMP, ICMPV6, TPID_8021Q
from lib.gmii_rx_driver import GmiiRxDriver

N_RANDOM = int(os.environ.get("CSUM_N_RANDOM", "300"))
OUR_MAC = 0x020000000001          # lib/csum.py frames are sent to this address


class StatMon:
    """Records (err_csum, err_fcs) at every stat_done pulse."""

    def __init__(self, dut):
        self.dut = dut
        self.records = []

    async def run(self):
        dut = self.dut
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            if int(dut.stat_done.value):
                self.records.append((int(dut.stat_err_csum.value),
                                     int(dut.stat_err_fcs.value)))


def csum_bad(p: Packet) -> bool:
    e = p.expect()
    return e.done and ((e.ip4 and not e.ip_good) or (e.l4_ok and not e.l4_good))


async def _run(dut, items, rng):
    """items: list of (Packet, csum_en, corrupt_fcs)."""
    cocotb.start_soon(Clock(dut.clk, 8, unit="ns").start())
    dut.our_mac.value = OUR_MAC
    dut.promisc.value = 0
    dut.passthrough.value = 0
    dut.jumbo_en.value = 0
    dut.mcast_hash_table.value = 0
    dut.rx_csum_en.value = 0
    dut.rst_n.value = 0
    drv = GmiiRxDriver(dut)
    sink = AxisSink(dut, rng, p_stall=0.2, active_signal=dut.gmii_rx_dv)
    stats = StatMon(dut)
    for _ in range(8):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    cocotb.start_soon(sink.run())
    cocotb.start_soon(stats.run())
    await drv.idle(4)

    for p, en, bad_fcs in items:
        dut.rx_csum_en.value = int(en)
        f = pad60(p.frame())
        await drv.send_frame(f, corrupt_fcs=bad_fcs)
        # Changing rx_csum_en mid-frame must not affect the frame in flight.
        dut.rx_csum_en.value = rng.randint(0, 1)
        await drv.idle(len(f) + 32)
    for _ in range(500):
        await RisingEdge(dut.clk)

    assert len(sink.frames) == len(items), f"{len(sink.frames)} of {len(items)} frames"
    assert len(stats.records) == len(items), f"{len(stats.records)} stat pulses"
    for n, ((p, en, bad_fcs), got, st) in enumerate(zip(items, sink.frames, stats.records)):
        tag = f"[{n}] en={en} bad_fcs={bad_fcs} {p}"
        bad = en and csum_bad(p)
        assert got["payload"] == pad60(p.frame()), f"{tag}: payload differs"
        assert got["terror"] == (bad or bad_fcs), \
            f"{tag}: terror={got['terror']} want {bad or bad_fcs}"
        assert st[0] == int(bad and not bad_fcs), f"{tag}: stat_err_csum={st[0]}"
        assert st[1] == int(bad_fcs), f"{tag}: stat_err_fcs={st[1]}"


@cocotb.test(timeout_time=50, timeout_unit="ms")
async def directed(dut):
    """Good and bad checksums of each protocol, with the checker on and off."""
    rng = random.Random(9)
    cases = [
        Packet(family=4, proto=UDP, l4_len=8 + 18),
        Packet(family=4, proto=UDP, l4_len=8 + 18, bad_ip=True),
        Packet(family=4, proto=UDP, l4_len=8 + 17, bad_l4=True),
        Packet(family=4, proto=UDP, l4_len=8 + 17, udp_zero=True),   # "no checksum"
        Packet(family=4, proto=TCP, l4_len=20 + 33, ihl=6, bad_l4=True),
        Packet(family=4, proto=ICMP, l4_len=8 + 56, bad_l4=True),
        Packet(family=6, proto=UDP, l4_len=8 + 9, bad_l4=True),
        Packet(family=6, proto=TCP, l4_len=20 + 100),
        Packet(family=6, proto=ICMPV6, l4_len=8 + 3, bad_l4=True),
        Packet(family=4, proto=UDP, l4_len=8 + 4, vlan=TPID_8021Q, bad_l4=True),
        Packet(family=4, proto=UDP, l4_len=8, mf=True, bad_l4=True),  # fragment: L4 not checked
        Packet(family=0, l4_len=50),
    ]
    items = []
    for n, p in enumerate(cases):
        p.seed = 400 + n
        p.build()
        items += [(p, True, False), (p, False, False)]
    items.append((cases[1], True, True))      # bad FCS and bad checksum
    await _run(dut, items, rng)


@cocotb.test(timeout_time=500, timeout_unit="ms")
async def randomized(dut):
    """Random frames, checker mostly on, some bad FCS."""
    seed = int(os.environ.get("CSUM_SEED", random.randrange(1 << 30)))
    dut._log.info(f"randomized seed={seed}")
    rng = random.Random(seed)
    items = [(random_packet(rng), rng.random() < 0.85, rng.random() < 0.05)
             for _ in range(N_RANDOM)]
    await _run(dut, items, rng)
