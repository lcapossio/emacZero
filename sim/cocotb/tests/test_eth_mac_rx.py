# SPDX-License-Identifier: Apache-2.0
"""Directed + randomized cocotb suite for rtl/eth_mac_rx.v (RX datapath).

Drives whole GMII wire frames, predicts delivery/terror/stats with the RX
reference model, and checks the AXIS output + per-frame stat pulses against it.
Covers filtering (unicast/broadcast/multicast/foreign, promisc, passthrough),
the error paths (bad FCS, rx_er alignment, oversize) and backpressure. Random
tests log their sub-seed for deterministic replay.
"""
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from lib.gmii_rx_driver import GmiiRxDriver
from lib.axis_sink import AxisSink
from lib.rx_model import RxFrame, RxScoreboard, StatsMonitor, rx_expected, BROADCAST

CLK_NS = 10
OUR_MAC = 0x020000000001
FOREIGN = 0x020000000002
MCAST = 0x01005E000001          # I/G bit set
MAX_STD = int(os.environ.get("RX_MAX_FRAME_STD", "1518"))


def _mac(v):
    return v.to_bytes(6, "big")


def _frame(dst_int, size=64, corrupt_fcs=False, align_err=False, tag=0xC0):
    """Build a payload dst+src+type+data of `size` bytes (>=14)."""
    src = _mac(0x0A0B0C0D0E0F)
    etype = b"\x08\x00"
    data = bytes([(tag + i) & 0xFF for i in range(max(0, size - 14))])
    return RxFrame(_mac(dst_int) + src + etype + data,
                   corrupt_fcs=corrupt_fcs, align_err=align_err)


async def _setup(dut, promisc=0, passthrough=0, jumbo=0):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    dut.our_mac.value = OUR_MAC
    dut.promisc.value = promisc
    dut.passthrough.value = passthrough
    dut.jumbo_en.value = jumbo
    dut.mcast_hash_table.value = 0
    dut.gmii_rxd.value = 0
    dut.gmii_rx_dv.value = 0
    dut.gmii_rx_er.value = 0
    dut.m_axis_tready.value = 0
    dut.rst_n.value = 0
    for _ in range(8):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    for _ in range(4):
        await RisingEdge(dut.clk)


async def _run(dut, frames, promisc=0, passthrough=0, jumbo=0,
               p_stall=0.2, rng=None):
    await _setup(dut, promisc, passthrough, jumbo)
    rng = rng or random.Random(1)
    sink = AxisSink(dut, rng, p_stall=p_stall, active_signal=dut.gmii_rx_dv)
    stats = StatsMonitor(dut)
    cocotb.start_soon(sink.run())
    cocotb.start_soon(stats.run())

    drv = GmiiRxDriver(dut)
    await drv.idle(4)
    for fr in frames:
        await drv.send_frame(fr.payload, fr.corrupt_fcs, fr.align_err)
        # Drain the RX FIFO before the next frame so a single frame never
        # exceeds the FIFO depth (deterministic: no overflow to model).
        await drv.idle(len(fr.payload) + 32)
    # Let the FIFO drain under backpressure.
    for _ in range(2000):
        await RisingEdge(dut.clk)

    exp_axis, exp_stats = rx_expected(frames, OUR_MAC, promisc, passthrough, jumbo,
                                      max_std=MAX_STD)
    sb = RxScoreboard(exp_axis, exp_stats)
    ok = sb.check(sink.frames, stats.records)
    assert ok, "RX mismatch:\n  " + "\n  ".join(sb.errors[:10])
    dut._log.info(f"OK: {len(exp_axis)} delivered / {len(frames)} sent "
                  f"(promisc={promisc}, pass={passthrough})")


# --------------------------------------------------------------------------- #
# Directed
# --------------------------------------------------------------------------- #
@cocotb.test(timeout_time=20, timeout_unit="ms")
async def directed_filtering(dut):
    """Unicast-match delivered; broadcast delivered+classified; foreign & mcast
    dropped (default filter)."""
    frames = [_frame(OUR_MAC, 64), _frame(BROADCAST, 64),
              _frame(FOREIGN, 64), _frame(MCAST, 64), _frame(OUR_MAC, 128)]
    await _run(dut, frames, p_stall=0.0)


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def directed_promisc(dut):
    """Promiscuous: every frame delivered, classification still correct."""
    frames = [_frame(FOREIGN, 64), _frame(MCAST, 96), _frame(BROADCAST, 64),
              _frame(OUR_MAC, 200)]
    await _run(dut, frames, promisc=1, p_stall=0.2)


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def directed_errors(dut):
    """Bad FCS, rx_er alignment, and oversize all deliver with terror + stat."""
    frames = [_frame(OUR_MAC, 64, corrupt_fcs=True),
              _frame(OUR_MAC, 64, align_err=True),
              _frame(OUR_MAC, 1600),                 # > MAX_FRAME_STD -> oversize
              _frame(OUR_MAC, 64)]                   # clean control
    await _run(dut, frames, p_stall=0.1)


@cocotb.test(timeout_time=30, timeout_unit="ms")
async def directed_backpressure(dut):
    """Heavy tready stalls: frames stay intact through the RX FIFO."""
    frames = [_frame(OUR_MAC, s) for s in (64, 128, 256, 512, 1000, 1518)]
    await _run(dut, frames, p_stall=0.7, rng=random.Random(7))


# --------------------------------------------------------------------------- #
# Randomized
# --------------------------------------------------------------------------- #
@cocotb.test(timeout_time=40, timeout_unit="ms")
async def random_mix(dut):
    seed = random.getrandbits(32)
    dut._log.info(f"random seed = {seed}")
    rng = random.Random(seed)
    dsts = [OUR_MAC, BROADCAST, FOREIGN, MCAST]
    frames = []
    for _ in range(24):
        dst = rng.choice(dsts)
        size = rng.choice([64, 64, 65, 100, 300, 800, 1518, 1600])
        frames.append(_frame(dst, size,
                             corrupt_fcs=rng.random() < 0.2,
                             align_err=rng.random() < 0.15,
                             tag=rng.randrange(256)))
    promisc = rng.random() < 0.3
    await _run(dut, frames, promisc=int(promisc),
               p_stall=rng.choice([0.0, 0.2, 0.5]), rng=rng)
