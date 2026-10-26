# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""CTRL[1] (rx_en) changes apply only at frame boundaries of m_axis.

eth_mac_sys, PHY_INTERFACE="GMII", MAX_FRAME=1518, 125 MHz clk / clk_125,
phy_gmii_rx_clk the same clock 2 ns later, GMII TX looped back to GMII RX
on phy_gmii_txc (as in test_eth_mac_sys_max_frame.py). gmii_cdc stores each
received frame whole, then the MAC streams it out at one byte per clk, so a
1000-byte frame is on m_axis for about 1000 clk after it has arrived and
CTRL can be written part-way through it.

Sequence (CTRL 0x07 = rx on, 0x05 = rx off; tx_en and promisc set):
  1  frame A, rx on; after the sink has taken 40 beats it holds tready low,
     RX is disabled, and tready comes back 200 clk later: A arrives whole
     (the old combinational gate drained the rest inside the core, leaving
     the sink a prefix with no tlast)
  2  frame B, rx off: nothing reaches the sink
  3  frame C, rx off; RX is enabled 100 clk after C has arrived: C is
     drained whole and the sink sees none of it (the old gate gave it C's
     tail, which a sink still holding A's prefix merged into one frame)
  4  frame D, rx on: arrives whole
Checks: C was still on its way out when RX was enabled (RX_FRAME 2 then);
the sink got exactly A and D, each whole (bytes, tlast, tsof on the
first beat only, no terror), and no unfinished frame; RX_FRAME counts all
four (frames drained while RX is off are counted, docs/registers.md) and
RX_DROP none.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, RisingEdge, Timer

from lib.axil_master import AxiLiteMaster
from lib.bench import Checks
from lib.mac_sys_a import bit, mdio_loop, start_clock

SUITES = {
    "eth_mac_sys_rx_en": {
        "toplevel": "eth_mac_sys",
        "sources": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                    "rtl/sync_fifo.v", "rtl/eth_mac_rx.v", "rtl/eth_mac_tx.v",
                    "rtl/eth_stats.v", "rtl/eth_pause.v", "rtl/axilite_regs.v",
                    "rtl/mdio_master.v", "rtl/ddr_output.v", "rtl/ddr_input.v",
                    "rtl/rgmii_if.v", "rtl/gmii_if.v", "rtl/gmii_cdc.v",
                    "rtl/net/tx_csum_off.v", "rtl/mii_tx_saf.v", "rtl/eth_mac_sys.v"],
        "params": {"PHY_INTERFACE": "GMII", "MAX_FRAME": 1518,
                   "CLK_FREQ_HZ": 125000000},
    },
}

CTRL_RX_ON = 0x07
CTRL_RX_OFF = 0x05
FRAME_LEN = 1000


def frame(tag):
    """Broadcast, EtherType 0x88B5, payload: tag then the byte index."""
    f = [0xFF] * 6 + [0x02, 0x11, 0x22, 0x33, 0x44, 0x55, 0x88, 0xB5, tag]
    f += [i & 0xFF for i in range(len(f), FRAME_LEN)]
    return f


async def start_rx_clk(dut):
    """phy_gmii_rx_clk: clk_125 delayed by 2 ns."""
    await Timer(2, "ns")
    cocotb.start_soon(Clock(dut.phy_gmii_rx_clk, 8, unit="ns").start(start_high=False))


async def gmii_phy(dut):
    """RX pins <= TX pins on each rising edge of phy_gmii_txc (0 in reset)."""
    rx = (dut.phy_gmii_rxd, dut.phy_gmii_rx_dv, dut.phy_gmii_rx_er)
    for s in rx:
        s.value = 0
    txc = dut.phy_gmii_txc
    while True:
        await FallingEdge(txc)
        await ReadOnly()
        vals = (dut.phy_gmii_txd.value, dut.phy_gmii_tx_en.value, dut.phy_gmii_tx_er.value)
        await RisingEdge(txc)
        if not bit(dut.rst_n) or not all(v.is_resolvable for v in vals):
            vals = (0, 0, 0)
        for s, v in zip(rx, vals):
            s.value = v


class Sink:
    """Collects m_axis beats on each handshake into frames."""

    def __init__(self, dut):
        self.dut = dut
        self.frames = []     # (bytes, terror, tsof flags)
        self.cur = []
        self.sof = []

    async def run(self):
        d = self.dut
        while True:
            await FallingEdge(d.clk)
            await ReadOnly()
            hs = bit(d.m_axis_tvalid) and bit(d.m_axis_tready)
            if hs:
                self.cur.append(int(d.m_axis_tdata.value))
                self.sof.append(bit(d.m_axis_tsof))
                if bit(d.m_axis_tlast):
                    self.frames.append((self.cur, bit(d.m_axis_terror), self.sof))
                    self.cur, self.sof = [], []
            await RisingEdge(d.clk)


async def send_frame(dut, f):
    for k, b in enumerate(f):
        await FallingEdge(dut.clk)
        dut.s_axis_tdata.value = b
        dut.s_axis_tvalid.value = 1
        dut.s_axis_tlast.value = 1 if k == len(f) - 1 else 0
        while True:
            await ReadOnly()
            ready = bit(dut.s_axis_tready)
            await RisingEdge(dut.clk)
            if ready:
                break
    await FallingEdge(dut.clk)
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def rx_en_frame_boundary(dut):
    c = Checks(dut._log)
    start_clock(dut.clk, 8)
    start_clock(dut.clk_125, 8)
    start_clock(dut.clk_125_90, 8)
    dut.phy_gmii_rx_clk.value = 0
    cocotb.start_soon(start_rx_clk(dut))
    dut.rst_n.value = 0
    axil = AxiLiteMaster(dut, dut.clk)
    dut.s_axis_tdata.value = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    dut.m_axis_tready.value = 1
    for s in (dut.mii_tx_clk, dut.mii_rx_clk, dut.mii_rx_er, dut.mii_col,
              dut.mii_crs, dut.clk_25, dut.clk_2_5, dut.rgmii_rx_ctl, dut.rgmii_rxc,
              dut.mii_rxd, dut.mii_rx_dv):
        s.value = 0
    dut.rgmii_rxd.value = 0
    sink = Sink(dut)
    cocotb.start_soon(gmii_phy(dut))
    cocotb.start_soon(mdio_loop(dut))
    cocotb.start_soon(sink.run())

    await Timer(100, "ns")
    dut.rst_n.value = 1
    await Timer(100, "ns")
    await axil.write(0x04, CTRL_RX_ON)

    fa, fb, fc, fd = (frame(t) for t in (0xA1, 0xB2, 0xC3, 0xD4))

    dut._log.info("--- 1: RX disabled with frame A part-way to the sink ---")
    cocotb.start_soon(send_frame(dut, fa))
    while len(sink.cur) < 40:
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.m_axis_tready.value = 0
    await axil.write(0x04, CTRL_RX_OFF)
    await ClockCycles(dut.clk, 200)
    await FallingEdge(dut.clk)
    dut.m_axis_tready.value = 1
    await ClockCycles(dut.clk, 4000)

    dut._log.info("--- 2: frame B with RX disabled ---")
    await send_frame(dut, fb)
    await ClockCycles(dut.clk, 4000)

    dut._log.info("--- 3: RX enabled with frame C part-way out of the MAC ---")
    cocotb.start_soon(send_frame(dut, fc))
    while not bit(dut.phy_gmii_rx_dv):
        await RisingEdge(dut.phy_gmii_rx_clk)
    while bit(dut.phy_gmii_rx_dv):
        await RisingEdge(dut.phy_gmii_rx_clk)
    await ClockCycles(dut.clk, 100)               # C part-way out of the MAC
    await axil.write(0x04, CTRL_RX_ON)
    # The stimulus is only valid if C was still on its way out: RX_FRAME
    # counts its TLAST, so it must not have reached 3 yet.
    c.eq("C still in flight at the enable", await axil.read(0x30), 2)
    await ClockCycles(dut.clk, 4000)

    dut._log.info("--- 4: frame D with RX enabled ---")
    await send_frame(dut, fd)
    await ClockCycles(dut.clk, 4000)

    got = [f for f, _, _ in sink.frames]
    c.eq("frames delivered", len(got), 2)
    c.check("unfinished frame at the sink", not sink.cur,
            f"{len(sink.cur)} beats without tlast")
    for name, want, n in (("A", fa, 0), ("D", fd, 1)):
        if n < len(sink.frames):
            data, err, sof = sink.frames[n]
            c.check(f"frame {name} whole", data == want,
                    f"{len(data)} bytes, tag {data[14] if len(data) > 14 else None}")
            c.eq(f"frame {name} terror", err, 0)
            c.check(f"frame {name} tsof on first beat only",
                    sof == [1] + [0] * (len(sof) - 1))
    c.eq("RX_FRAME", await axil.read(0x30), 4)
    c.eq("RX_DROP", await axil.read(0x7C), 0)
    c.finish()
