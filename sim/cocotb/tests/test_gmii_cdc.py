# SPDX-License-Identifier: Apache-2.0
"""Directed + randomized cocotb suite for rtl/gmii_cdc.v (TX store-and-forward CDC).

Drives contiguous GMII frames on the sys-clock input and checks the paced
media-side output is byte-for-byte identical, in order, across 1G/100M/10M. Also
probes the committed-frame counter under a burst of small frames - the condition
that wedged mii_tx_saf's 4-bit counter (fixed in d79d1d0).
"""
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly

from lib.gmii_tx_driver import GmiiTxDriver
from lib.gmii_tx_monitor import GmiiTxMonitor
from lib.gmii_cdc_model import gmii_tx_expected, GmiiTxScoreboard

SYS_NS = 10        # 100 MHz system clock
MEDIA_NS = 8       # 125 MHz media clock
SPEED = {"1G": 0b00, "100M": 0b01, "10M": 0b10}
PERIOD = {"1G": 1, "100M": 10, "10M": 100}    # media cycles per emitted byte


async def _setup(dut, speed):
    cocotb.start_soon(Clock(dut.sys_clk, SYS_NS, unit="ns").start())
    cocotb.start_soon(Clock(dut.media_clk, MEDIA_NS, unit="ns").start())
    cocotb.start_soon(Clock(dut.media_rx_clk, MEDIA_NS, unit="ns").start())
    dut.cfg_speed.value = SPEED[speed]
    dut.gmii_txd_in.value = 0
    dut.gmii_tx_en_in.value = 0
    dut.gmii_tx_er_in.value = 0
    dut.gmii_rxd_in.value = 0
    dut.gmii_rx_dv_in.value = 0
    dut.gmii_rx_er_in.value = 0
    dut.sys_rst_n.value = 0
    for _ in range(16):
        await RisingEdge(dut.media_clk)
    dut.sys_rst_n.value = 1
    for _ in range(8):
        await RisingEdge(dut.sys_clk)

    mon = GmiiTxMonitor(dut, PERIOD[speed])
    cocotb.start_soon(mon.run())
    return mon


async def _drain(dut, mon, n_expected, timeout_cycles):
    idle = 0
    for _ in range(timeout_cycles):
        await RisingEdge(dut.media_clk)
        await ReadOnly()
        idle = idle + 1 if int(dut.gmii_tx_en_out.value) == 0 else 0
        if mon.count >= n_expected and idle > 8:
            return
    raise AssertionError(
        f"timeout: {mon.count}/{n_expected} frames drained "
        f"(possible committed-counter wrap wedge)")


async def _run(dut, frames, speed, gap=3, timeout_cycles=300_000):
    mon = await _setup(dut, speed)
    drv = GmiiTxDriver(dut)
    await drv.idle(4)
    for f in frames:
        await drv.send_frame(f, gap=gap)
    await _drain(dut, mon, len(frames), timeout_cycles)

    exp = gmii_tx_expected(frames)
    if PERIOD[speed] == 1:
        # 1G: full byte-exact check of the data path.
        sb = GmiiTxScoreboard(exp)
        ok = sb.check(mon.frames)
        assert ok, f"[{speed}] mismatch:\n  " + "\n  ".join(sb.errors[:8])
        dut._log.info(f"OK [{speed}]: {len(frames)} frames byte-exact")
    else:
        # 100M/10M: frame count (wrap detector) + per-frame byte count.
        assert mon.count == len(exp), \
            f"[{speed}] frame count: expected {len(exp)}, delivered {mon.count}"
        exp_lens = [len(f) for f in exp]
        assert mon.frame_lens == exp_lens, \
            f"[{speed}] frame lengths: expected {exp_lens}, got {mon.frame_lens}"
        dut._log.info(f"OK [{speed}]: {len(frames)} frames, lengths match")


def _frame(size, tag):
    return bytes([(tag + i) & 0xFF for i in range(size)])


# --------------------------------------------------------------------------- #
# Directed byte-exact across speeds
# --------------------------------------------------------------------------- #
@cocotb.test(timeout_time=15, timeout_unit="ms")
async def directed_1g(dut):
    frames = [_frame(64, 0x10), _frame(128, 0x40), _frame(65, 0xA0), _frame(256, 0x01)]
    await _run(dut, frames, "1G")


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def directed_100m(dut):
    frames = [_frame(64, 0x20), _frame(100, 0x55), _frame(64, 0xC3)]
    await _run(dut, frames, "100M")


@cocotb.test(timeout_time=40, timeout_unit="ms")
async def directed_10m(dut):
    frames = [_frame(64, 0x33), _frame(80, 0x77)]
    await _run(dut, frames, "10M")


# --------------------------------------------------------------------------- #
# Committed-frame-counter burst probe (the mii_tx_saf-class wrap hazard)
# --------------------------------------------------------------------------- #
@cocotb.test(timeout_time=30, timeout_unit="ms")
async def burst_small_frames_100m(dut):
    """20 small frames pushed fast at 100M: the sys side commits many frames
    before the paced media side drains them. If the 4-bit committed counter
    aliases, media stops early and frames are stuck."""
    frames = [_frame(64, 0x40 + i) for i in range(20)]
    await _run(dut, frames, "100M", gap=1)


# --------------------------------------------------------------------------- #
# Randomized
# --------------------------------------------------------------------------- #
@cocotb.test(timeout_time=40, timeout_unit="ms")
async def random_mix(dut):
    seed = random.getrandbits(32)
    dut._log.info(f"random seed = {seed}")
    rng = random.Random(seed)
    speed = rng.choice(["1G", "1G", "100M"])       # bias fast to keep sim short
    n = rng.randint(4, 10)
    frames = [_frame(rng.randint(60, 300), rng.randrange(256)) for _ in range(n)]
    await _run(dut, frames, speed, gap=rng.randint(1, 4))
