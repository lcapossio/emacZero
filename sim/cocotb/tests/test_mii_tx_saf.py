# SPDX-License-Identifier: Apache-2.0
"""Directed + randomized cocotb suite for rtl/mii_tx_saf.v (store-and-forward MII TX).

Each test drives an AXIS stimulus (with randomized bubbles and occasional dropped
tlast), predicts the transmitted frames with the SAF reference model, and checks
the MII wire against that prediction (payload bytes + recomputed FCS). Random
tests log their sub-seed so any failure replays deterministically.
"""
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer

from lib.axis_driver import AxisMaster
from lib.mii_monitor import MiiMonitor
from lib.model import saf_expected, Scoreboard
from lib import frame_gen

MAX_FRAME = int(os.environ.get("SAF_MAX_FRAME", "1518"))
FIFO_BYTES = 1 << int(os.environ.get("SAF_FIFO_ADDR_WIDTH", "12"))
SYS_PERIOD_NS = 10     # 100 MHz AXIS/write clock
MII_PERIOD_NS = 40     # 25 MHz media clock (100 Mbps)


async def _setup(dut):
    """Start both clocks, reset the DUT, enable frame starts, launch the monitor."""
    cocotb.start_soon(Clock(dut.clk, SYS_PERIOD_NS, unit="ns").start())
    cocotb.start_soon(Clock(dut.mii_tx_clk, MII_PERIOD_NS, unit="ns").start())
    dut.tx_start_ok.value = 1
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    dut.s_axis_tdata.value = 0
    dut.rst_n.value = 0
    for _ in range(8):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.mii_tx_clk)
    dut.rst_n.value = 1
    for _ in range(4):
        await RisingEdge(dut.clk)

    mon = MiiMonitor(dut)
    cocotb.start_soon(mon.run())
    return mon


async def _drain(dut, mon, n_expected, timeout_ns=40_000_000):
    """Wait until n_expected frames are on the wire and the media side is idle."""
    idle = 0
    elapsed = 0
    while elapsed < timeout_ns:
        await FallingEdge(dut.mii_tx_clk)
        elapsed += MII_PERIOD_NS
        quiet = int(dut.mii_tx_en.value) == 0 and int(dut.tx_active.value) == 0
        idle = idle + 1 if quiet else 0
        if len(mon.payloads) >= n_expected and idle > 24:
            return
    raise AssertionError(
        f"timeout: saw {len(mon.payloads)}/{n_expected} frames after {timeout_ns} ns")


async def _run(dut, segments, rng, p_bubble):
    mon = await _setup(dut)
    expected = saf_expected(segments, MAX_FRAME)
    master = AxisMaster(dut, rng, p_bubble=p_bubble)
    await master.send_all(segments)
    await _drain(dut, mon, len(expected))
    # A little extra quiet time to catch any spurious extra frame.
    await Timer(2_000, unit="ns")

    sb = Scoreboard(expected)
    ok = sb.check(mon.payloads)
    assert mon.fcs_errors == 0, f"{mon.fcs_errors} FCS errors: {mon.framing_errors[:5]}"
    assert not mon.framing_errors, f"framing errors: {mon.framing_errors[:5]}"
    assert ok, "scoreboard mismatch:\n  " + "\n  ".join(sb.errors[:8])
    dut._log.info(f"OK: {len(expected)} frames matched (bubble={p_bubble})")


# --------------------------------------------------------------------------- #
# Directed
# --------------------------------------------------------------------------- #
@cocotb.test(timeout_time=10, timeout_unit="ms")
async def directed_boundaries(dut):
    """Every boundary size (min-frame, MAX_FRAME+/-1, FIFO depth) + merge/oversize."""
    rng = random.Random(0xD1EC7ED)
    segs = frame_gen.directed_segments(MAX_FRAME, FIFO_BYTES)
    await _run(dut, segs, rng, p_bubble=0.0)


@cocotb.test(timeout_time=10, timeout_unit="ms")
async def directed_boundaries_bubbled(dut):
    """Same directed corners but with heavy AXIS bubbling (the S&F promise)."""
    rng = random.Random(0xB0BB1E5)
    segs = frame_gen.directed_segments(MAX_FRAME, FIFO_BYTES)
    await _run(dut, segs, rng, p_bubble=0.5)


# --------------------------------------------------------------------------- #
# Randomized (seed logged for replay)
# --------------------------------------------------------------------------- #
async def _random_case(dut, n_frames, p_bubble, p_drop_last):
    seed = random.getrandbits(32)
    dut._log.info(f"random seed = {seed} (n={n_frames}, bubble={p_bubble}, "
                  f"drop_last={p_drop_last})")
    rng = random.Random(seed)
    segs = frame_gen.random_segments(rng, n_frames, MAX_FRAME, FIFO_BYTES,
                                     p_drop_last=p_drop_last)
    await _run(dut, segs, rng, p_bubble=p_bubble)


@cocotb.test(timeout_time=10, timeout_unit="ms")
async def random_light_bubble(dut):
    await _random_case(dut, n_frames=20, p_bubble=0.15, p_drop_last=0.10)


@cocotb.test(timeout_time=10, timeout_unit="ms")
async def random_heavy_bubble(dut):
    await _random_case(dut, n_frames=18, p_bubble=0.6, p_drop_last=0.15)


@cocotb.test(timeout_time=10, timeout_unit="ms")
async def random_merge_stress(dut):
    """Higher tlast-drop rate: many merged / oversized runs exercising the cap."""
    await _random_case(dut, n_frames=22, p_bubble=0.3, p_drop_last=0.35)
