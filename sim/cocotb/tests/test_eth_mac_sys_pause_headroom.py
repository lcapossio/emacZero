# SPDX-License-Identifier: Apache-2.0
"""eth_mac_sys automatic PAUSE headroom: the PAUSE_XOFF limit that
docs/registers.md recommends for standard frames with an 8 KB RX FIFO
(RX_AXIS_ADDR_WIDTH = 13) loses nothing in the worst case it budgets for.

The partner sends maximum-size frames (1518 bytes) back to back and obeys
our PAUSE frames; we keep maximum-size frames queued on s_axis, so every
PAUSE frame can wait behind one of ours already going out. With m_axis
stalled, the RX FIFO must never overflow and the partner must stay paused;
once m_axis is released every partner frame arrives intact.

HEADROOM_XOFF overrides PAUSE_XOFF (e.g. 3300 to see the overflow the old
recommendation allowed).
"""
import os

import cocotb
from cocotb.triggers import FallingEdge, ReadOnly, Timer

from test_eth_mac_sys_pause_rx import (BIT_NS, BYTE_NS, Partner, Sink, TxPins,
                                       bring_up, ctl_quanta, data_frame,
                                       is_ctl)
from lib.bench import Checks
from lib.mac_sys_a import bit

SUITES = {
    "eth_mac_sys_pause_headroom_gmii": {
        "toplevel": "eth_mac_sys",
        "sources": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                    "rtl/sync_fifo.v", "rtl/net/csum_calc.v", "rtl/eth_mac_rx.v",
                    "rtl/eth_mac_tx.v", "rtl/eth_stats.v", "rtl/eth_pause_rx.v", "rtl/eth_pause.v",
                    "rtl/axilite_regs.v", "rtl/mdio_master.v", "rtl/ddr_output.v",
                    "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                    "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v", "rtl/mii_tx_saf.v",
                    "rtl/eth_mac_sys.v"],
        "params": {"PHY_INTERFACE": "GMII", "MAX_FRAME": 1518,
                   "RX_AXIS_ADDR_WIDTH": 13, "CLK_FREQ_HZ": 125000000},
        "env": {"PAUSE_RX_MODE": "gmii"},
    },
    "eth_mac_sys_pause_headroom_mii": {
        "toplevel": "eth_mac_sys",
        "sources": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                    "rtl/sync_fifo.v", "rtl/net/csum_calc.v", "rtl/eth_mac_rx.v",
                    "rtl/eth_mac_tx.v", "rtl/eth_stats.v", "rtl/eth_pause_rx.v", "rtl/eth_pause.v",
                    "rtl/axilite_regs.v", "rtl/mdio_master.v", "rtl/ddr_output.v",
                    "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                    "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v", "rtl/mii_tx_saf.v",
                    "rtl/eth_mac_sys.v"],
        "params": {"PHY_INTERFACE": "MII", "MAX_FRAME": 1518,
                   "RX_AXIS_ADDR_WIDTH": 13, "CLK_FREQ_HZ": 100000000},
        "env": {"PAUSE_RX_MODE": "mii"},
    },
}

SIZE = 1514                                     # + FCS = 1518 bytes


async def send_big(dut):
    """One maximum-size data frame on s_axis."""
    clk = dut.clk
    f = data_frame(SIZE)
    for k, b in enumerate(f):
        await FallingEdge(clk)
        dut.s_axis_tdata.value = b
        dut.s_axis_tvalid.value = 1
        dut.s_axis_tlast.value = 1 if k == len(f) - 1 else 0
        await ReadOnly()
        while not bit(dut.s_axis_tready):
            await FallingEdge(clk)
            await ReadOnly()
    await FallingEdge(clk)
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0


class BigFeeder:
    """Keeps maximum-size frames queued on s_axis, at most two ahead of the
    TX pins, until stopped."""

    def __init__(self, dut, tx):
        self.dut, self.tx = dut, tx
        self.go = True
        self.sent = 0

    async def run(self):
        while self.go:
            while self.sent - sum(not is_ctl(f[1]) for f in self.tx.frames) >= 2:
                await Timer(8 * BYTE_NS, "ns")
            await send_big(self.dut)
            self.sent += 1


@cocotb.test(timeout_time=2000, timeout_unit="ms")
async def pause_headroom(dut):
    c = Checks(dut._log)
    pins, axil = await bring_up(dut)
    tx = TxPins(dut)
    cocotb.start_soon(tx.run())
    sink = Sink(dut)
    cocotb.start_soon(sink.run())
    q_ns = 512 * BIT_NS
    QUANTA = 64
    XOFF = int(os.environ.get("HEADROOM_XOFF", "1500"))
    XON = XOFF // 2

    def ctls(t_from=0):
        return [(t0, ctl_quanta(b)) for t0, b in tx.frames
                if is_ctl(b) and t0 > t_from]

    c.eq("CAPS[8:4]: RX FIFO 2**13", ((await axil.read(0x98)) >> 4) & 0x1F, 13)
    await axil.write(0x88, QUANTA)
    await axil.write(0x9C, XOFF)
    await axil.write(0xA0, XON)
    await axil.write(0xA4, 0)
    dut.m_axis_tready.value = 0
    await axil.write(0x84, 0x06)                  # rx_en + auto_en
    c.eq("PAUSE_CTRL after enable", await axil.read(0x84), 0x06)

    # Our frames start this many byte times after the partner's first one.
    tx_delay = int(os.environ.get("HEADROOM_TX_DELAY", "0"))
    partner = Partner(pins, tx, SIZE)
    p_task = cocotb.start_soon(partner.run())
    await Timer(tx_delay * BYTE_NS + 1, "ns")
    feeder = BigFeeder(dut, tx)
    f_task = cocotb.start_soon(feeder.run())

    # The stall: three full quanta windows after the first XOFF.
    while not ctls():
        await Timer(64 * BYTE_NS, "ns")
    t_xoff = ctls()[0][0]
    sent_at_xoff = partner.sent
    await Timer(int(3 * QUANTA * q_ns), "ns")
    dut._log.info("XOFF %d delay %d: %d PAUSE frames, %d partner frames, %d ours",
                  XOFF, tx_delay, len(ctls()), partner.sent, feeder.sent)
    c.check(f"partner held: {partner.sent - sent_at_xoff} frames after the first XOFF (<= 1)",
            partner.sent - sent_at_xoff <= 1)
    c.eq("RX_ERR_OVERFLOW", await axil.read(0x50), 0)
    c.eq("RX_DROP", await axil.read(0x7C), 0)

    # Release: everything the partner sent arrives intact.
    dut.m_axis_tready.value = 1
    t_rel = tx.frames[-1][0] if tx.frames else 0
    for _ in range(400):
        if any(q == 0 for _, q in ctls(t_rel)):
            break
        await Timer(64 * BYTE_NS, "ns")
    c.check("XON once the RX FIFO drained", any(q == 0 for _, q in ctls(t_rel)))
    await Timer(int(4 * (SIZE + 24) * BYTE_NS), "ns")
    partner.go = False
    feeder.go = False
    await p_task
    await f_task
    await Timer(int(4 * (SIZE + 24) * BYTE_NS), "ns")
    c.check(f"partner resumed: {partner.sent - sent_at_xoff} frames since the first XOFF",
            partner.sent - sent_at_xoff >= 2)
    c.eq("every partner frame delivered", sink.frames, partner.sent)
    c.eq("none with terror", sink.errors, 0)
    c.finish()
