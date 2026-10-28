# SPDX-License-Identifier: Apache-2.0
"""gmii_cdc with tx_hold: the TX FIFO fills while the media side is held.

While tx_hold is high the media side starts no data frame, so nothing leaves
the TX FIFO and the sys side may fill it up to TX_START_LIMIT. The sys side
(eth_mac_tx) checks tx_busy only between frames, so a frame started at the
limit must still fit whole: MAX_FRAME (at least 9018) plus 12 preamble / SFD /
FCS bytes.

Checks, at 1G with tx_hold high from the start:
  1 find the limit: the highest FIFO count (sum of the bytes written) at which
    tx_busy is still low
  2 after a reset, fill to exactly that count with whole frames, then send
    the largest frame the framer can emit (MAX_FRAME + 12 bytes, at least
    9030); tx_busy is high after it
  3 a control frame sent while held goes out alone, ahead of the held data
    frames, and no data frame starts while tx_hold is high
  4 tx_hold low: every data frame comes out whole and in order (an overrun
    would drop bytes of the last frame)

Checks at 10M (a 9.6 us start gap), with a data frame loaded and in its start
gap:
  5 a control frame committed then goes out ahead of it
  6 tx_hold raised then holds it until tx_hold falls
"""
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer

from lib.bench import Checks
from lib.gmii_tx_monitor import GmiiTxMonitor


SUITES = {
    "gmii_cdc_hold": {
        "toplevel": "gmii_cdc",
        "sources": ["rtl/async_fifo.v", "rtl/gmii_cdc.v"],
        "params": {},
        "env": {"GMII_CDC_MAX_FRAME": "9018"},
    },
    "gmii_cdc_hold_big": {
        "toplevel": "gmii_cdc",
        "sources": ["rtl/async_fifo.v", "rtl/gmii_cdc.v"],
        "params": {"MAX_FRAME": 12000},
        "env": {"GMII_CDC_MAX_FRAME": "12000"},
    },
}

SYS_NS = 8
MEDIA_NS = 8
MAX_FRAME = int(os.environ.get("GMII_CDC_MAX_FRAME", "9018"))
BIG = max(MAX_FRAME, 9018) + 12      # preamble + SFD + MAX_FRAME + FCS
GAP = 12                             # idle sys cycles between frames (IFG)


class Tx:
    """Drives the data and control GMII inputs on sys_clk."""

    def __init__(self, dut):
        self.dut = dut
        self.count = 0               # bytes written to the data FIFO

    async def frame(self, data):
        d = self.dut
        for b in data:
            d.gmii_txd_in.value = b
            d.gmii_tx_en_in.value = 1
            await RisingEdge(d.sys_clk)
        d.gmii_tx_en_in.value = 0
        d.gmii_txd_in.value = 0
        self.count += len(data)
        for _ in range(GAP):
            await RisingEdge(d.sys_clk)

    async def ctl_frame(self, data):
        d = self.dut
        for b in data:
            d.gmii_ctl_txd_in.value = b
            d.gmii_ctl_tx_en_in.value = 1
            await RisingEdge(d.sys_clk)
        d.gmii_ctl_tx_en_in.value = 0
        d.gmii_ctl_txd_in.value = 0
        for _ in range(GAP):
            await RisingEdge(d.sys_clk)

    async def busy(self):
        await ReadOnly()
        v = int(self.dut.tx_busy.value)
        await RisingEdge(self.dut.sys_clk)
        return v


async def reset(dut):
    for s in (dut.gmii_txd_in, dut.gmii_tx_en_in, dut.gmii_tx_er_in,
              dut.gmii_ctl_txd_in, dut.gmii_ctl_tx_en_in, dut.gmii_ctl_tx_er_in,
              dut.gmii_rxd_in, dut.gmii_rx_dv_in, dut.gmii_rx_er_in):
        s.value = 0
    dut.gmii_rx_ce_in.value = 1
    dut.cfg_speed.value = 0b00
    dut.tx_hold.value = 1
    dut.sys_rst_n.value = 0
    for _ in range(16):
        await RisingEdge(dut.media_clk)
    dut.sys_rst_n.value = 1
    for _ in range(16):
        await RisingEdge(dut.sys_clk)


def payload(rng, n):
    return bytes(rng.randrange(256) for _ in range(n))


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def hold_fill(dut):
    c = Checks(dut._log)
    cocotb.start_soon(Clock(dut.sys_clk, SYS_NS, unit="ns").start())
    cocotb.start_soon(Clock(dut.media_clk, MEDIA_NS, unit="ns").start())
    cocotb.start_soon(Clock(dut.media_rx_clk, MEDIA_NS, unit="ns").start())
    rng = random.Random(31)

    # 1. Find the limit: 1-byte frames near it (never sent; reset after).
    await reset(dut)
    tx = Tx(dut)
    while tx.count < 16384 - BIG - 600:
        await tx.frame(bytes(64))
    while not await tx.busy():
        await tx.frame(b"\x00")
    limit = tx.count - 1
    dut._log.info("MAX_FRAME %d: tx_busy rises above %d bytes; largest frame %d bytes",
                  MAX_FRAME, limit, BIG)

    # 2. Refill to exactly `limit` with whole frames, then the largest frame.
    await reset(dut)
    mon = GmiiTxMonitor(dut, 1)
    cocotb.start_soon(mon.run())
    tx = Tx(dut)
    frames = []
    while limit - tx.count >= 192:
        f = payload(rng, 64)
        frames.append(f)
        await tx.frame(f)
    f = payload(rng, limit - tx.count)        # 128..191 bytes
    frames.append(f)
    await tx.frame(f)
    c.eq("FIFO count before the largest frame", tx.count, limit)
    c.eq("tx_busy at the limit", await tx.busy(), 0)
    f = payload(rng, BIG)
    frames.append(f)
    await tx.frame(f)
    c.eq("tx_busy after the largest frame", await tx.busy(), 1)

    # 3. A control frame overtakes the held data frames.
    ctl = payload(rng, 72)
    await tx.ctl_frame(ctl)
    for _ in range(400):
        await RisingEdge(dut.media_clk)
    c.eq("frames out while held", mon.count, 1)
    c.check("the frame out while held is the control frame",
            mon.count >= 1 and mon.frames[0] == ctl)

    # 4. Release: every data frame whole and in order.
    dut.tx_hold.value = 0
    guard = 0
    while mon.count < 1 + len(frames) and guard < 400_000:
        await RisingEdge(dut.media_clk)
        guard += 1
    await Timer(1, "us")
    got = mon.frames[1:]
    c.eq("data frames out after release", len(got), len(frames))
    bad = [i for i, (g, e) in enumerate(zip(got, frames)) if g != e]
    c.check(f"data frames whole and in order (mismatches at {bad[:4]})", not bad)
    if got:
        c.eq("largest frame length", len(got[-1]), BIG)
    c.check("no tx_er on the media side", all(not any(e) for e in mon.frame_ers))
    c.finish()


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def withdraw_loaded(dut):
    c = Checks(dut._log)
    cocotb.start_soon(Clock(dut.sys_clk, SYS_NS, unit="ns").start())
    cocotb.start_soon(Clock(dut.media_clk, MEDIA_NS, unit="ns").start())
    cocotb.start_soon(Clock(dut.media_rx_clk, MEDIA_NS, unit="ns").start())
    await reset(dut)
    dut.cfg_speed.value = 0b10                    # 10M: one byte per 100 cycles
    dut.tx_hold.value = 0
    for _ in range(64):
        await RisingEdge(dut.sys_clk)
    mon = GmiiTxMonitor(dut, 100)
    cocotb.start_soon(mon.run())
    tx = Tx(dut)

    async def wait_count(n, limit_us):
        for _ in range(limit_us * 1000 // MEDIA_NS):
            if mon.count >= n:
                return
            await RisingEdge(dut.media_clk)

    # 5. A (64) and B (100) queued; a control frame (72) committed while B
    #    is in its start gap after A goes out ahead of B.
    await tx.frame(bytes(64))
    await tx.frame(bytes(100))
    await wait_count(1, 200)
    await Timer(2, "us")
    await tx.ctl_frame(bytes(72))
    await wait_count(3, 200)
    c.eq("frame order after a control frame in the start gap (lengths)",
         mon.frame_lens[:3], [64, 72, 100])

    # 6. C (80) and D (120) queued; tx_hold raised while D is in its start gap
    #    holds D until tx_hold falls.
    await tx.frame(bytes(80))
    await tx.frame(bytes(120))
    await wait_count(4, 200)
    await Timer(2, "us")
    dut.tx_hold.value = 1
    await Timer(40, "us")
    c.eq("frames out while held", mon.count, 4)
    c.eq("tx_en while held", int(dut.gmii_tx_en_out.value), 0)
    dut.tx_hold.value = 0
    await wait_count(5, 200)
    c.eq("held frame out after release (lengths)", mon.frame_lens[3:5], [80, 120])
    c.finish()
