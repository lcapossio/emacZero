# SPDX-License-Identifier: Apache-2.0
"""eth_mac_sys TXRX_EN_AT_RESET: CTRL's tx_en/rx_en reset value, and the
s_axis/m_axis enable gates that apply them per frame, leave reset together.

eth_mac_sys, PHY_INTERFACE="MII", MAX_FRAME 1518, MII TX looped back to MII
RX (a one-cycle register on the MII clock), 100 MHz clk, 25 MHz MII clocks.
A frame's first beat is offered on s_axis from before reset is released. A
watcher reads s_axis_tvalid/tready settled in each low phase of clk (what
the next rising edge samples) and counts handshakes; it also records whether
mii_tx_en and m_axis_tvalid were ever high, and every byte the RX sink
accepts.

Both suites first check the gates themselves (tx_en_eff, rx_en_eff) during
reset and in the low phase before the first rising edge out of it: they
must equal TXRX_EN_AT_RESET (R0). An RX gate with the wrong reset value
corrects itself on the first idle clock, so no frame could show it.

Suite eth_mac_sys_reset_txrx_off (TXRX_EN_AT_RESET=0):
  R1  CTRL reads 0x20 after reset
  R2  the frame offered across the reset release and for 2000 cycles after
      it: no s_axis handshake, mii_tx_en never high, TX_FRAME 0 (the gates
      used to leave reset open for one cycle, so the first beat was taken
      and the frame then went through whole)
  R3  CTRL = tx_en only (0x21): the frame goes out (mii_tx_en high, TX_FRAME
      1) and loops back, but m_axis_tvalid never rises
  R4  CTRL = tx_en | rx_en (0x23): a second frame is delivered byte-exact,
      with TLAST and without terror
Suite eth_mac_sys_reset_txrx_on (TXRX_EN_AT_RESET=1, the default):
  R1  CTRL reads 0x23 after reset
  R4  without any CTRL write, the frame offered across the reset release is
      delivered byte-exact
"""
import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer

from lib.axil_master import AxiLiteMaster
from lib.bench import Checks
from lib.mac_sys_a import bit, start_clock, val

SUITES = {
    "eth_mac_sys_reset_txrx_off": {
        "toplevel": "eth_mac_sys",
        "sources": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                    "rtl/sync_fifo.v", "rtl/net/csum_calc.v", "rtl/eth_mac_rx.v",
                    "rtl/eth_mac_tx.v", "rtl/eth_stats.v", "rtl/eth_pause_rx.v", "rtl/eth_pause.v",
                    "rtl/axilite_regs.v", "rtl/mdio_master.v", "rtl/ddr_output.v",
                    "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                    "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v", "rtl/mii_tx_saf.v",
                    "rtl/eth_mac_sys.v"],
        "params": {"PHY_INTERFACE": "MII", "MAX_FRAME": 1518,
                   "TXRX_EN_AT_RESET": 0},
        "env": {"TB_TXRX_EN_AT_RESET": "0"},
    },
    "eth_mac_sys_reset_txrx_on": {
        "toplevel": "eth_mac_sys",
        "sources": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                    "rtl/sync_fifo.v", "rtl/net/csum_calc.v", "rtl/eth_mac_rx.v",
                    "rtl/eth_mac_tx.v", "rtl/eth_stats.v", "rtl/eth_pause_rx.v", "rtl/eth_pause.v",
                    "rtl/axilite_regs.v", "rtl/mdio_master.v", "rtl/ddr_output.v",
                    "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                    "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v", "rtl/mii_tx_saf.v",
                    "rtl/eth_mac_sys.v"],
        "params": {"PHY_INTERFACE": "MII", "MAX_FRAME": 1518},
        "env": {"TB_TXRX_EN_AT_RESET": "1"},
    },
}

TXRX_EN = int(os.environ.get("TB_TXRX_EN_AT_RESET", "1"))

A_CTRL = 0x04
A_TX_FRAME = 0x28


def frame(seq):
    """Broadcast IPv4-typed frame with a 50-byte payload tagged by seq."""
    return bytes([0xFF] * 6 + [0x02, 0, 0, 0, 0, 0x01, 0x08, 0x00]
                 + [(seq + k) & 0xFF for k in range(50)])


class Watch:
    """Observations of clk-domain signals settled in each low phase of clk,
    i.e. the values the next rising edge samples. Handshakes are counted
    only once rst_n is high; the RX sink holds m_axis_tready high and
    collects accepted bytes per frame."""

    def __init__(self, dut):
        self.dut = dut
        self.tx_hs = 0
        self.tx_en_seen = self.rx_valid_seen = False
        self.cur = []
        self.frames = []          # (bytes, terror)

    async def run(self):
        d = self.dut
        while True:
            await FallingEdge(d.clk)
            await ReadOnly()
            if bit(d.rst_n) == 0:
                continue
            if bit(d.s_axis_tvalid) == 1 and bit(d.s_axis_tready) == 1:
                self.tx_hs += 1
            self.tx_en_seen |= bit(d.mii_tx_en) == 1
            if bit(d.m_axis_tvalid) == 1:
                self.rx_valid_seen = True
                if bit(d.m_axis_tready) == 1:
                    self.cur.append(int(d.m_axis_tdata.value))
                    if bit(d.m_axis_tlast) == 1:
                        self.frames.append((bytes(self.cur), val(d.m_axis_terror)))
                        self.cur = []


async def mii_loopback(dut):
    """{mii_rxd, mii_rx_dv} <= {mii_txd, mii_tx_en} on each rising edge of the
    MII clock: the value copied is the one settled since the falling edge
    before it."""
    clk = dut.mii_rx_clk
    await ReadOnly()
    d, e = dut.mii_txd.value, dut.mii_tx_en.value
    while True:
        await RisingEdge(clk)
        if d.is_resolvable:
            dut.mii_rxd.value = d
        if e.is_resolvable:
            dut.mii_rx_dv.value = e
        await FallingEdge(clk)
        await ReadOnly()
        d, e = dut.mii_txd.value, dut.mii_tx_en.value


async def offer(dut, data, max_cycles):
    """Drive data on s_axis, one byte per beat, changing it in the high phase
    after each rising edge at which tready was high in the low phase before
    it. The first beat is driven in the next high phase (also during
    reset). Returns True when the whole frame was accepted within max_cycles
    clk cycles."""
    k, cycles = 0, 0
    await RisingEdge(dut.clk)
    await Timer(1, "ns")
    while k < len(data) and cycles < max_cycles:
        dut.s_axis_tdata.value = data[k]
        dut.s_axis_tvalid.value = 1
        dut.s_axis_tlast.value = 1 if k == len(data) - 1 else 0
        await FallingEdge(dut.clk)
        await ReadOnly()
        take = bit(dut.rst_n) == 1 and bit(dut.s_axis_tready) == 1
        await RisingEdge(dut.clk)
        await Timer(1, "ns")
        if take:
            k += 1
        cycles += 1
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    return k == len(data)


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def reset_enables(dut):
    c = Checks(dut._log)
    start_clock(dut.clk, 10)
    for s in (dut.mii_tx_clk, dut.mii_rx_clk):
        cocotb.start_soon(Clock(s, 40, unit="ns").start(start_high=False))
    dut.rst_n.value = 0
    axil = AxiLiteMaster(dut, dut.clk)
    dut.s_axis_tdata.value = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    dut.m_axis_tready.value = 1
    dut.mii_rxd.value = 0
    dut.mii_rx_dv.value = 0
    dut.mii_rx_er.value = 0
    dut.mii_col.value = 0
    dut.mii_crs.value = 0
    dut.mdio_i.value = 1
    for s in (dut.clk_125, dut.clk_125_90, dut.clk_25, dut.clk_2_5,
              dut.rgmii_rx_ctl, dut.rgmii_rxc):
        s.value = 0
    dut.rgmii_rxd.value = 0
    w = Watch(dut)
    cocotb.start_soon(mii_loopback(dut))
    cocotb.start_soon(w.run())

    # Offer a frame from inside reset; release reset in a high phase of clk,
    # so the first rising edge out of reset samples the enable gates' reset
    # values.
    first = frame(0x40 if TXRX_EN else 0)
    await Timer(100, "ns")
    offering = cocotb.start_soon(offer(dut, first, 2000))
    for _ in range(3):
        await RisingEdge(dut.clk)
    await ReadOnly()
    c.eq("R0 tx_en_eff in reset", val(dut.tx_en_eff), TXRX_EN)
    c.eq("R0 rx_en_eff in reset", val(dut.rx_en_eff), TXRX_EN)
    await Timer(1, "ns")
    dut.rst_n.value = 1
    await FallingEdge(dut.clk)
    await ReadOnly()
    c.eq("R0 tx_en_eff before the first edge", val(dut.tx_en_eff), TXRX_EN)
    c.eq("R0 rx_en_eff before the first edge", val(dut.rx_en_eff), TXRX_EN)
    accepted = await offering
    await Timer(40, "us")

    c.eq("R1 CTRL after reset", await axil.read(A_CTRL), 0x23 if TXRX_EN else 0x20)

    if not TXRX_EN:
        c.check("R2 frame not accepted while TX is disabled", not accepted)
        c.eq("R2 s_axis handshakes", w.tx_hs, 0)
        c.check("R2 mii_tx_en never high", not w.tx_en_seen)
        c.eq("R2 TX_FRAME", await axil.read(A_TX_FRAME), 0)

        await axil.write(A_CTRL, 0x21)
        accepted = await offer(dut, frame(0), 2000)
        await Timer(40, "us")
        c.check("R3 frame accepted with tx_en", accepted)
        c.check("R3 frame sent on MII", w.tx_en_seen)
        c.eq("R3 TX_FRAME", await axil.read(A_TX_FRAME), 1)
        c.check("R3 looped-back frame not delivered while RX is disabled",
                not w.rx_valid_seen)

        await axil.write(A_CTRL, 0x23)
        sent = frame(0x40)
        accepted = await offer(dut, sent, 2000)
        await Timer(40, "us")
    else:
        sent = first

    c.check("R4 frame accepted", accepted)
    c.eq("R4 frames delivered", len(w.frames), 1)
    if w.frames:
        got, terr = w.frames[0]
        c.check(f"R4 delivered frame byte-exact ({len(got)} bytes)", got == sent)
        c.eq("R4 terror", terr, 0)
    c.finish()
