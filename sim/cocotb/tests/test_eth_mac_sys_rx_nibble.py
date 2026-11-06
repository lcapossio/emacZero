# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""Receive nibble pairing and RX_ER at 10/100 (#24, #25).

The tests drive the PHY receive pins nibble by nibble and check what comes
out of m_axis: the frame bytes (FCS removed) and terror.

  eth_mac_sys_rx_nibble_mii        MII, 100M (mii_if)
  eth_mac_sys_rx_nibble_rgmii100   RGMII 10/100 at 100M (rgmii_if)
  eth_mac_sys_rx_nibble_rgmii10    RGMII 10/100 at 10M (rgmii_if)

rx_nibble checks, per suite:
  1 a frame with the full preamble comes out intact, without terror
  2 rx_er on the low nibble only, and on the high nibble only, of a byte in
    the middle of the frame: the frame comes out with terror
  3 a clean frame right after an rx_er frame comes out without terror
  MII only (mii_if pairs nibbles from the SFD):
  4 the SFD after 14, 2 and 15 preamble 5s (an odd and an even number of
    nibbles before the SFD): the frame comes out intact, without terror;
    with rx_er on the 5 right before the D only, with terror
  5 one extra nibble after the FCS: without rx_er the frame comes out
    intact, without terror; with rx_er on it, with terror
"""
import os
import zlib

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer

from lib.axil_master import AxiLiteMaster
from lib.bench import Checks
from lib.mac_sys_a import bit


SUITES = {
    "eth_mac_sys_rx_nibble_mii": {
        "toplevel": "eth_mac_sys",
        "sources": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                    "rtl/sync_fifo.v", "rtl/net/csum_calc.v", "rtl/eth_mac_rx.v",
                    "rtl/eth_mac_tx.v", "rtl/eth_stats.v", "rtl/eth_pause_rx.v", "rtl/eth_pause.v",
                    "rtl/axilite_regs.v", "rtl/mdio_master.v", "rtl/ddr_output.v",
                    "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                    "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v", "rtl/mii_tx_saf.v",
                    "rtl/eth_mac_sys.v"],
        "params": {"PHY_INTERFACE": "MII", "MAX_FRAME": 1518,
                   "CLK_FREQ_HZ": 100000000},
        "env": {"RX_NIBBLE_MODE": "mii"},
    },
    "eth_mac_sys_rx_nibble_rgmii100": {
        "toplevel": "eth_mac_sys",
        "sources": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                    "rtl/sync_fifo.v", "rtl/net/csum_calc.v", "rtl/eth_mac_rx.v",
                    "rtl/eth_mac_tx.v", "rtl/eth_stats.v", "rtl/eth_pause_rx.v", "rtl/eth_pause.v",
                    "rtl/axilite_regs.v", "rtl/mdio_master.v", "rtl/ddr_output.v",
                    "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                    "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v", "rtl/mii_tx_saf.v",
                    "rtl/eth_mac_sys.v"],
        "params": {"PHY_INTERFACE": "RGMII", "MAX_FRAME": 1518,
                   "RGMII_SPEEDS": "10_100", "CLK_FREQ_HZ": 100000000},
        "env": {"RX_NIBBLE_MODE": "rgmii100"},
    },
    "eth_mac_sys_rx_nibble_rgmii10": {
        "toplevel": "eth_mac_sys",
        "sources": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                    "rtl/sync_fifo.v", "rtl/net/csum_calc.v", "rtl/eth_mac_rx.v",
                    "rtl/eth_mac_tx.v", "rtl/eth_stats.v", "rtl/eth_pause_rx.v", "rtl/eth_pause.v",
                    "rtl/axilite_regs.v", "rtl/mdio_master.v", "rtl/ddr_output.v",
                    "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                    "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v", "rtl/mii_tx_saf.v",
                    "rtl/eth_mac_sys.v"],
        "params": {"PHY_INTERFACE": "RGMII", "MAX_FRAME": 1518,
                   "RGMII_SPEEDS": "10_100", "CLK_FREQ_HZ": 100000000},
        "env": {"RX_NIBBLE_MODE": "rgmii10"},
    },
}

MODE = os.environ.get("RX_NIBBLE_MODE", "mii")

# Per mode: PHY RX clock period (ns), CTRL[4:3] speed.
RXC_NS, SPEED = (400, 0b10) if MODE == "rgmii10" else (40, 0b01)
SYS_NS = 10


def frame(n):
    """Broadcast frame of n bytes (FCS not included), numbered n."""
    f = [0xFF] * 6 + [0x02, 0x11, 0x22, 0x33, 0x44, 0x55, 0x08, 0x00]
    return f + [(i + n) & 0xFF for i in range(n - len(f))]


def nibs(byts):
    return [n for b in byts for n in (b & 0xF, b >> 4)]


def wire_nibs(f, fives=15):
    """Preamble (`fives` 5s), SFD nibble D, then frame + FCS, low nibble first."""
    fcs = zlib.crc32(bytes(f)) & 0xFFFFFFFF
    return [5] * fives + [0xD] + nibs(list(f) + [(fcs >> (8 * i)) & 0xFF for i in range(4)])


class RxPins:
    """Drives one PHY's receive pins, one nibble per RX clock."""

    def __init__(self, dut):
        self.dut = dut
        self.clk = dut.mii_rx_clk if MODE == "mii" else dut.rgmii_rxc

    async def _slot(self):
        await FallingEdge(self.clk)
        if MODE != "mii":
            # RGMII 10/100: the same nibble on both RXC edges; change it a
            # quarter cycle after the falling edge.
            await Timer(RXC_NS // 4, "ns")

    def _drive(self, n, dv, er):
        d = self.dut
        if MODE == "mii":
            d.mii_rxd.value = n
            d.mii_rx_dv.value = dv
            d.mii_rx_er.value = er
        else:
            d.rgmii_rxd.value = n
            d.rgmii_rx_ctl.value = dv

    async def send_nibs(self, ns, er_at=()):
        """Drive nibbles as given, rx_er on the indices in er_at."""
        for i, n in enumerate(ns):
            er = 1 if i in er_at else 0
            await self._slot()
            self._drive(n, 1, er)
            if er and MODE != "mii":
                # RGMII: RX_CTL carries RX_DV xor RX_ER on the falling edge,
                # so RX_ER on this nibble is RX_CTL low on that edge only.
                await RisingEdge(self.clk)
                await Timer(RXC_NS // 4, "ns")
                self.dut.rgmii_rx_ctl.value = 0
        await self._slot()
        self._drive(0, 0, 0)
        for _ in range(23):
            await self._slot()


class AxisSink:
    """Collects m_axis frames as (bytes, terror seen on any beat)."""

    def __init__(self, dut):
        self.dut = dut
        self.frames = []

    async def run(self):
        d = self.dut
        cur, err = [], False
        while True:
            await RisingEdge(d.clk)
            await ReadOnly()
            if bit(d.m_axis_tvalid) and bit(d.m_axis_tready):
                cur.append(int(d.m_axis_tdata.value))
                err = err or bool(bit(d.m_axis_terror))
                if bit(d.m_axis_tlast):
                    self.frames.append((cur, err))
                    cur, err = [], False


async def bring_up(dut):
    """Clocks, reset, CTRL (TX + RX + promiscuous, speed)."""
    clk = dut.clk
    cocotb.start_soon(Clock(clk, SYS_NS, unit="ns").start(start_high=False))
    cocotb.start_soon(Clock(dut.clk_125, 8, unit="ns").start(start_high=False))
    cocotb.start_soon(Clock(dut.clk_125_90, 8, unit="ns").start(start_high=False))
    for s in (dut.mii_tx_clk, dut.mii_rx_dv, dut.mii_rx_er, dut.mii_rx_clk,
              dut.mii_col, dut.mii_crs, dut.clk_25, dut.clk_2_5,
              dut.rgmii_rx_ctl, dut.rgmii_rxc, dut.phy_gmii_rx_clk,
              dut.phy_gmii_rx_dv, dut.phy_gmii_rx_er):
        s.value = 0
    dut.mii_rxd.value = 0
    dut.rgmii_rxd.value = 0
    dut.phy_gmii_rxd.value = 0
    dut.mdio_i.value = 1
    dut.s_axis_tdata.value = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    dut.m_axis_tready.value = 1
    pins = RxPins(dut)
    if MODE == "mii":
        cocotb.start_soon(Clock(dut.mii_tx_clk, RXC_NS, unit="ns").start(start_high=False))
    await Timer(2, "ns")
    cocotb.start_soon(Clock(pins.clk, RXC_NS, unit="ns").start(start_high=False))
    axil = AxiLiteMaster(dut, clk)
    dut.rst_n.value = 0
    await Timer(200, "ns")
    dut.rst_n.value = 1
    await Timer(500, "ns")
    await axil.write(0x04, 0x07 | (SPEED << 3))   # TX + RX + promiscuous, speed
    await Timer(40 * RXC_NS, "ns")                # speed settles in the media domain
    return pins


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def rx_nibble(dut):
    c = Checks(dut._log)
    pins = await bring_up(dut)
    sink = AxisSink(dut)
    cocotb.start_soon(sink.run())

    async def expect(label, f, ns, er_at=(), terror=False):
        n0 = len(sink.frames)
        await pins.send_nibs(ns, er_at=er_at)
        await Timer(4 * len(ns) * SYS_NS + 2000, "ns")   # replay and drain
        got = sink.frames[n0:]
        if not c.check(f"{label}: one frame out", len(got) == 1, f"got {len(got)}"):
            return
        byts, err = got[0]
        if not terror:
            c.check(f"{label}: frame bytes", byts == f,
                    f"{len(byts)} bytes, expected {len(f)}")
        c.eq(f"{label}: terror", int(err), int(terror))

    f = frame(60)
    w = wire_nibs(f)
    mid = 16 + 2 * 30                                  # low nibble of frame byte 30

    # 1. Full preamble.
    await expect("full preamble", f, w)

    # 2. rx_er on one nibble of a mid-frame byte.
    await expect("rx_er on a low nibble", f, w, er_at=(mid,), terror=True)
    # 3. The error does not carry over to the next frame.
    await expect("clean frame after rx_er", f, w)
    await expect("rx_er on a high nibble", f, w, er_at=(mid + 1,), terror=True)
    await expect("clean frame after rx_er", f, w)

    if MODE == "mii":
        # 4. Odd and even nibble counts before the SFD.
        for fives in (14, 2, 15):
            g = frame(61 + fives)
            await expect(f"{fives} preamble 5s", g, wire_nibs(g, fives))
            await expect(f"{fives} preamble 5s, rx_er on the last 5", g,
                         wire_nibs(g, fives), er_at=(fives - 1,), terror=True)

        # 5. A trailing odd nibble, without and with rx_er.
        t = w + [0]
        await expect("trailing nibble", f, t)
        await expect("rx_er on a trailing nibble", f, t, er_at=(len(t) - 1,),
                     terror=True)
        await expect("clean frame after rx_er", f, w)
        g = frame(70)
        t = wire_nibs(g, 14) + [0]
        await expect("14 preamble 5s, rx_er on a trailing nibble", g, t,
                     er_at=(len(t) - 1,), terror=True)

    c.finish()
