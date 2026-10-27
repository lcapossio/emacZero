# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""CTRL[0] (tx_en) changes apply only at frame boundaries of s_axis.

eth_mac_sys, PHY_INTERFACE="GMII", MAX_FRAME=1518, 125 MHz clk / clk_125,
GMII RX idle. Suites:
  eth_mac_sys_tx_en       TX_CSUM_OFFLOAD=0: eth_mac_tx is cut-through, so a
                          pause inside a frame underruns it
  eth_mac_sys_tx_en_csum  TX_CSUM_OFFLOAD=1, CTRL[7] set: tx_csum_off stores
                          each frame whole first
The GMII TX pins are read settled before each rising edge of phy_gmii_txc,
and each tx_en span is one wire frame. The source drives a beat every cycle
it is allowed to (no bubbles of its own) and holds it while tready is low.

Sequence (CTRL 0x07 = tx on, 0x06 = tx off; rx_en and promisc set, plus
0x80 in the csum suite):
  1  1000-byte frame A; TX is disabled once the source has had 300 beats
     accepted: A is still taken whole while TX is off and goes on the wire
     (the old combinational gate stalled the source mid-frame; without the
     inserter the framer then sent 0x00 with tx_er, aborted the frame and
     later sent the rest of A as a frame of its own with a good FCS)
  2  1000-byte frame B offered while TX is off: not accepted, not sent
  3  TX enabled: B is taken and sent
Checks: A fully accepted and on the wire before TX is enabled again; no
beat of B accepted while TX is off (if A was stalled instead, B is sent
only after A has finished, so the wire shows what became of A); the wire carries exactly A then B, each
whole with a good FCS, no tx_er, preamble and SFD; TX_FRAME 2.
"""
import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, RisingEdge, Timer
from cocotb.utils import get_sim_time

from lib.axil_master import AxiLiteMaster
from lib.bench import Checks
from lib.eth import fcs_ok
from lib.mac_sys_a import bit, mdio_loop, start_clock

SUITES = {
    "eth_mac_sys_tx_en": {
        "toplevel": "eth_mac_sys",
        "sources": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                    "rtl/sync_fifo.v", "rtl/eth_mac_rx.v", "rtl/eth_mac_tx.v",
                    "rtl/eth_stats.v", "rtl/eth_pause_rx.v", "rtl/eth_pause.v", "rtl/axilite_regs.v",
                    "rtl/mdio_master.v", "rtl/ddr_output.v", "rtl/ddr_input.v",
                    "rtl/rgmii_if.v", "rtl/gmii_if.v", "rtl/gmii_cdc.v",
                    "rtl/net/tx_csum_off.v", "rtl/mii_tx_saf.v", "rtl/eth_mac_sys.v"],
        "params": {"PHY_INTERFACE": "GMII", "MAX_FRAME": 1518,
                   "CLK_FREQ_HZ": 125000000, "TX_CSUM_OFFLOAD": 0},
        "env": {"TB_TX_CSUM_OFFLOAD": "0"},
    },
    "eth_mac_sys_tx_en_csum": {
        "toplevel": "eth_mac_sys",
        "sources": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                    "rtl/sync_fifo.v", "rtl/net/csum_calc.v", "rtl/eth_mac_rx.v",
                    "rtl/eth_mac_tx.v", "rtl/eth_stats.v", "rtl/eth_pause_rx.v", "rtl/eth_pause.v",
                    "rtl/axilite_regs.v", "rtl/mdio_master.v", "rtl/ddr_output.v",
                    "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                    "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v", "rtl/mii_tx_saf.v",
                    "rtl/eth_mac_sys.v"],
        "params": {"PHY_INTERFACE": "GMII", "MAX_FRAME": 1518,
                   "CLK_FREQ_HZ": 125000000, "TX_CSUM_OFFLOAD": 1},
        "env": {"TB_TX_CSUM_OFFLOAD": "1"},
    },
}

CSUM = int(os.environ.get("TB_TX_CSUM_OFFLOAD", "0"))
CTRL_TX_ON = 0x07 | (0x80 if CSUM else 0)
CTRL_TX_OFF = 0x06 | (0x80 if CSUM else 0)
FRAME_LEN = 1000


def frame(tag):
    """Broadcast, EtherType 0x88B5 (not IP: the inserter leaves it alone),
    payload: tag then the byte index."""
    f = [0xFF] * 6 + [0x02, 0x11, 0x22, 0x33, 0x44, 0x55, 0x88, 0xB5, tag]
    f += [i & 0xFF for i in range(len(f), FRAME_LEN)]
    return f


class Source:
    """Drives one frame on s_axis, a beat on each falling edge, held until
    tready is high at the rising edge; counts accepted beats."""

    def __init__(self, dut):
        self.dut = dut
        self.accepted = 0
        self.done_ns = None

    async def send(self, f):
        d = self.dut
        self.accepted = 0
        for k, b in enumerate(f):
            await FallingEdge(d.clk)
            d.s_axis_tdata.value = b
            d.s_axis_tvalid.value = 1
            d.s_axis_tlast.value = 1 if k == len(f) - 1 else 0
            while True:
                await ReadOnly()
                ready = bit(d.s_axis_tready)
                await RisingEdge(d.clk)
                if ready:
                    break
            self.accepted += 1
        self.done_ns = get_sim_time("ns")
        await FallingEdge(d.clk)
        d.s_axis_tvalid.value = 0
        d.s_axis_tlast.value = 0


class WireMonitor:
    """One entry per tx_en span: (start ns, bytes, any tx_er)."""

    def __init__(self, dut):
        self.dut = dut
        self.frames = []

    async def run(self):
        d = self.dut
        txc = d.phy_gmii_txc
        cur, er, t0 = None, False, 0
        while True:
            await FallingEdge(txc)
            await ReadOnly()
            en = bit(d.phy_gmii_tx_en)
            if en:
                if cur is None:
                    cur, er, t0 = [], False, get_sim_time("ns")
                v = d.phy_gmii_txd.value
                cur.append(int(v) if v.is_resolvable else -1)
                er = er or bool(bit(d.phy_gmii_tx_er))
            elif cur is not None:
                self.frames.append((t0, cur, er))
                cur = None


def check_wire_frame(c, name, wf, want):
    _, data, er = wf
    c.check(f"{name}: preamble and SFD", data[:8] == [0x55] * 7 + [0xD5],
            f"{data[:8]}")
    body = bytes(b & 0xFF for b in data[8:])
    c.check(f"{name}: whole", list(body[:-4]) == want,
            f"{len(body) - 4} data bytes, tag {body[14] if len(body) > 14 else None}")
    c.check(f"{name}: good FCS", fcs_ok(body[:-4], body[-4:]))
    c.eq(f"{name}: tx_er", int(er), 0)


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def tx_en_frame_boundary(dut):
    c = Checks(dut._log)
    dut._log.info(f"TX_CSUM_OFFLOAD={CSUM}")
    start_clock(dut.clk, 8)
    start_clock(dut.clk_125, 8)
    start_clock(dut.clk_125_90, 8)
    dut.phy_gmii_rx_clk.value = 0
    cocotb.start_soon(Clock(dut.phy_gmii_rx_clk, 8, unit="ns").start(start_high=False))
    dut.rst_n.value = 0
    axil = AxiLiteMaster(dut, dut.clk)
    dut.s_axis_tdata.value = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    dut.m_axis_tready.value = 1
    for s in (dut.mii_tx_clk, dut.mii_rx_clk, dut.mii_rx_er, dut.mii_col,
              dut.mii_crs, dut.clk_25, dut.clk_2_5, dut.rgmii_rx_ctl, dut.rgmii_rxc,
              dut.mii_rxd, dut.mii_rx_dv, dut.phy_gmii_rxd, dut.phy_gmii_rx_dv,
              dut.phy_gmii_rx_er):
        s.value = 0
    dut.rgmii_rxd.value = 0
    src = Source(dut)
    wire = WireMonitor(dut)
    cocotb.start_soon(mdio_loop(dut))
    cocotb.start_soon(wire.run())

    await Timer(100, "ns")
    dut.rst_n.value = 1
    await Timer(100, "ns")
    await axil.write(0x04, CTRL_TX_ON)

    fa, fb = frame(0xA1), frame(0xB2)

    dut._log.info("--- 1: TX disabled with frame A part-way accepted ---")
    cocotb.start_soon(src.send(fa))
    while src.accepted < 300:
        await RisingEdge(dut.clk)
    await axil.write(0x04, CTRL_TX_OFF)
    await ClockCycles(dut.clk, 3000)
    a_whole = src.accepted == FRAME_LEN
    c.eq("A accepted while TX off", src.accepted, FRAME_LEN)
    a_done = src.done_ns

    src2 = Source(dut)
    if a_whole:
        dut._log.info("--- 2: frame B offered while TX is off ---")
        cocotb.start_soon(src2.send(fb))
        await ClockCycles(dut.clk, 2000)
        c.eq("B beats accepted while TX off", src2.accepted, 0)
    c.eq("wire frames while TX off", len(wire.frames), 1)

    dut._log.info("--- 3: TX enabled ---")
    await axil.write(0x04, CTRL_TX_ON)
    t_on = get_sim_time("ns")
    await ClockCycles(dut.clk, 4000)
    if not a_whole:
        # A was stalled part-way (the failure this test is for): let it
        # finish, then send B, so the wire shows what became of A.
        while src.done_ns is None:
            await RisingEdge(dut.clk)
        await src2.send(fb)
        await ClockCycles(dut.clk, 4000)
    c.eq("B accepted", src2.accepted, FRAME_LEN)

    c.eq("wire frames", len(wire.frames), 2)
    if wire.frames:
        c.check("A on the wire before TX on", wire.frames[0][0] < t_on,
                f"started {wire.frames[0][0]} ns, TX on at {t_on} ns, "
                f"A accepted by {a_done} ns")
        check_wire_frame(c, "wire frame 1 (A)", wire.frames[0], fa)
    if len(wire.frames) > 1:
        c.check("B on the wire after TX on", wire.frames[1][0] > t_on)
        check_wire_frame(c, "wire frame 2 (B)", wire.frames[1], fb)
    c.eq("TX_FRAME", await axil.read(0x28), 2)
    c.finish()
