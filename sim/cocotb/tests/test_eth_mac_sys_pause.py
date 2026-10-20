# SPDX-License-Identifier: Apache-2.0
"""cocotb port of sim/tb/tb_eth_mac_sys_pause.v (build_and_test.py bench
ETH-MAC-SYS-PAUSE).

eth_mac_sys, PHY_INTERFACE="GMII", MAX_FRAME=1518, CLK_FREQ_HZ=125 MHz.
sys_clk and clk_125 are 125 MHz clocks in phase (clk_125_90 is tied to
clk_125 in the bench; here a third clock of the same period and phase, and
the GMII branch does not use it); phy_gmii_rx_clk is the same clock 2 ns
later. m_axis_tready tied 1, mdio_i tied 1, MII / RGMII inputs tied to 0.
Bench processes mirrored here, all on the rising edge of phy_gmii_txc (the
inverted clk_125 under SIM; the TX pins are read settled in the half cycle
before that edge):
  - Stand-in PHY: RX pins <= TX pins, or the injected bytes while `inject`.
  - TX wire monitor: bytes per tx_en burst and the time each burst starts.
send_frame drives a broadcast frame of `len` bytes (FF x6, byte 12 = 08,
others = index) on the falling edge of sys_clk, testing tready 1 ns later
(read settled, the same value) and at each later falling edge until high.
inject_frame drives preamble, SFD, the frame and its FCS (optionally one bit
flipped, optionally rx_er on one byte) on the falling edges of phy_gmii_txc.

Checks, in bench order (18):
  1  PAUSE frame is 72 wire bytes; PAUSE_TX_CNT = 1; looped-back PAUSE frame
     counted in PAUSE_RX_CNT; rx_en: next frame held off (> 40 us)
  2  rx_en off: PAUSE frame still counted (2); next frame not held off (< 5 us)
  3  PAUSE then queued frame: PAUSE frame 72 bytes; user frame separate (112)
  3b PAUSE mid user frame: user frame intact (312); PAUSE frame follows (72)
  4  write to PAUSE_RX_CNT clears it; clears PAUSE_TX_CNT too; injected valid
     PAUSE counted (1); bad FCS ignored (1); rx_er ignored (1); 56-byte frame
     ignored (1); 100-byte PAUSE frame counted (2); EtherType 0x8809 ignored (2)
No $random in the bench.
"""
import zlib

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, RisingEdge, Timer
from cocotb.utils import get_sim_time

from lib.axil_master import AxiLiteMaster
from lib.bench import Checks
from lib.mac_sys_a import bit, start_clock

SUITES = {
    "eth_mac_sys_pause": {
        "toplevel": "eth_mac_sys",
        "sources": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                    "rtl/sync_fifo.v", "rtl/net/csum_calc.v", "rtl/eth_mac_rx.v",
                    "rtl/eth_mac_tx.v", "rtl/eth_stats.v", "rtl/eth_pause.v",
                    "rtl/axilite_regs.v", "rtl/mdio_master.v", "rtl/ddr_output.v",
                    "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                    "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v", "rtl/mii_tx_saf.v",
                    "rtl/eth_mac_sys.v"],
        "params": {"PHY_INTERFACE": "GMII", "MAX_FRAME": 1518,
                   "CLK_FREQ_HZ": 125000000},
    },
}

QUANTA = 100        # 1G pause quantum = 512 ns; 100 quanta = 51.2 us


def now_ns():
    return get_sim_time(unit="ns")


async def start_rx_clk(dut):
    """initial begin #2; forever #4 rx_clk = ~rx_clk; end  (rx_clk starts 0)"""
    await Timer(2, "ns")
    cocotb.start_soon(Clock(dut.phy_gmii_rx_clk, 8, unit="ns").start(start_high=False))


class Phy:
    """The bench's stand-in PHY (with injection) and TX wire monitor."""

    def __init__(self, dut):
        self.dut = dut
        self.inject = 0
        self.inj_d = 0
        self.inj_dv = 0
        self.inj_er = 0
        self.wire_n = 0
        self.cur_len = 0
        self.wire_len = [None] * 32
        self.wire_start = [None] * 32

    async def run(self):
        d = self.dut
        rx = (d.phy_gmii_rxd, d.phy_gmii_rx_dv, d.phy_gmii_rx_er)
        for s in rx:
            s.value = 0
        txc = d.phy_gmii_txc
        while True:
            await FallingEdge(txc)
            await ReadOnly()
            tx = (d.phy_gmii_txd.value, d.phy_gmii_tx_en.value, d.phy_gmii_tx_er.value)
            await RisingEdge(txc)
            t = now_ns()
            if not bit(d.rst_n):
                for s in rx:
                    s.value = 0
                self.wire_n = 0
                self.cur_len = 0
                continue
            vals = (self.inj_d, self.inj_dv, self.inj_er) if self.inject else tx
            for s, v in zip(rx, vals):
                s.value = v
            en = tx[1]
            if en.is_resolvable and int(en):
                if self.cur_len == 0 and self.wire_n < 32:
                    self.wire_start[self.wire_n] = t
                self.cur_len += 1
            elif self.cur_len != 0:
                if self.wire_n < 32:
                    self.wire_len[self.wire_n] = self.cur_len
                self.wire_n += 1
                self.cur_len = 0


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def tb_eth_mac_sys_pause(dut):
    c = Checks(dut._log)
    clk = dut.clk
    start_clock(clk, 8)
    start_clock(dut.clk_125, 8)
    start_clock(dut.clk_125_90, 8)
    dut.phy_gmii_rx_clk.value = 0
    cocotb.start_soon(start_rx_clk(dut))
    dut.rst_n.value = 0
    axil = AxiLiteMaster(dut, clk)
    dut.s_axis_tdata.value = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    dut.m_axis_tready.value = 1
    dut.mii_rxd.value = 0
    for s in (dut.mii_tx_clk, dut.mii_rx_dv, dut.mii_rx_er, dut.mii_rx_clk,
              dut.mii_col, dut.mii_crs, dut.clk_25, dut.clk_2_5,
              dut.rgmii_rx_ctl, dut.rgmii_rxc):
        s.value = 0
    dut.rgmii_rxd.value = 0
    dut.mdio_i.value = 1
    phy = Phy(dut)
    cocotb.start_soon(phy.run())
    txc = dut.phy_gmii_txc

    state = {"tx_start_t": None}

    async def send_frame(length):
        await FallingEdge(clk)
        state["tx_start_t"] = now_ns()
        for k in range(length):
            dut.s_axis_tdata.value = 0xFF if k < 6 else (0x08 if k == 12 else k & 0xFF)
            dut.s_axis_tvalid.value = 1
            dut.s_axis_tlast.value = 1 if k == length - 1 else 0
            await ReadOnly()                        # #1: tready, settled
            while not bit(dut.s_axis_tready):
                await FallingEdge(clk)
                await ReadOnly()
            await FallingEdge(clk)
        dut.s_axis_tvalid.value = 0
        dut.s_axis_tlast.value = 0

    fr = [0] * 128

    def build_pause(length, quanta):
        for k in range(128):
            fr[k] = 0
        fr[0:6] = [0x01, 0x80, 0xC2, 0x00, 0x00, 0x01]
        fr[6:12] = [0x02, 0x11, 0x22, 0x33, 0x44, 0x55]
        fr[12:16] = [0x88, 0x08, 0x00, 0x01]
        fr[16] = quanta >> 8
        fr[17] = quanta & 0xFF

    async def inject_frame(length, bad_fcs, er_at):
        fcs = zlib.crc32(bytes(fr[:length])) & 0xFFFFFFFF
        if bad_fcs:
            fcs ^= 0x00000100
        phy.inject = 1
        await FallingEdge(txc)
        for _ in range(7):
            phy.inj_d, phy.inj_dv, phy.inj_er = 0x55, 1, 0
            await FallingEdge(txc)
        phy.inj_d = 0xD5
        await FallingEdge(txc)
        for k in range(length + 4):
            phy.inj_d = fr[k] if k < length else (fcs >> (8 * (k - length))) & 0xFF
            phy.inj_er = 1 if k == er_at else 0
            await FallingEdge(txc)
        phy.inj_dv, phy.inj_er, phy.inj_d = 0, 0, 0
        for _ in range(20):
            await FallingEdge(txc)
        phy.inject = 0
        await ClockCycles(clk, 200)                 # through the RX CDC FIFO

    async def wait_wire(n):
        guard = 0
        while phy.wire_n < n and guard < 200000:
            await RisingEdge(clk)
            guard += 1

    await Timer(100, "ns")
    dut.rst_n.value = 1
    await Timer(200, "ns")

    await axil.write(0x04, 0x00000007)            # TX + RX + promiscuous
    await axil.write(0x88, QUANTA)

    # ---- 1. PAUSE sent with rx_en: looped back, counted, holds off TX ----
    await axil.write(0x84, 0x00000003)            # rx_en + tx_send
    await wait_wire(1)
    c.check(f"PAUSE frame is 72 wire bytes (preamble, SFD, 60 + FCS): {phy.wire_len[0]}",
            phy.wire_len[0] == 72)
    await ClockCycles(clk, 200)
    v = await axil.read(0x90)
    c.check(f"PAUSE_TX_CNT = 1: {v}", v == 1)
    v = await axil.read(0x8C)
    c.check(f"looped-back PAUSE frame counted in PAUSE_RX_CNT: {v}", v == 1)
    n0 = phy.wire_n
    await send_frame(60)
    await wait_wire(n0 + 1)
    delay_t = phy.wire_start[n0] - state["tx_start_t"]
    dut._log.info("      next frame started %d ns after it was offered", delay_t)
    c.check(f"rx_en: next frame held off by the received quanta (> 40 us): {delay_t} ns",
            delay_t > 40000)

    # ---- 2. Same without rx_en: counted, no hold-off ----
    await axil.write(0x84, 0x00000001)            # tx_send only
    await wait_wire(n0 + 2)
    await ClockCycles(clk, 200)
    v = await axil.read(0x8C)
    c.check(f"rx_en off: PAUSE frame still counted: {v}", v == 2)
    n0 = phy.wire_n
    await send_frame(60)
    await wait_wire(n0 + 1)
    delay_t = phy.wire_start[n0] - state["tx_start_t"]
    c.check(f"rx_en off: next frame not held off (< 5 us): {delay_t} ns", delay_t < 5000)

    # ---- 3. User frame queued behind a PAUSE frame: two frames on the wire ----
    n0 = phy.wire_n

    async def queued():
        await ClockCycles(clk, 3)
        await send_frame(100)

    t1 = cocotb.start_soon(axil.write(0x84, 0x00000001))
    t2 = cocotb.start_soon(queued())
    await t1
    await t2
    await wait_wire(n0 + 2)
    await ClockCycles(clk, 200)
    c.check(f"PAUSE then queued frame: PAUSE frame ends at 72 bytes: {phy.wire_len[n0]}",
            phy.wire_len[n0] == 72)
    c.check(f"PAUSE then queued frame: user frame is separate (112 bytes): "
            f"{phy.wire_len[n0 + 1]}",
            phy.wire_len[n0 + 1] == 112)

    # ---- 3b. PAUSE requested mid user frame: waits for the frame to end ----
    n0 = phy.wire_n

    async def mid():
        await ClockCycles(clk, 40)
        await axil.write(0x84, 0x00000001)

    t1 = cocotb.start_soon(send_frame(300))
    t2 = cocotb.start_soon(mid())
    await t1
    await t2
    await wait_wire(n0 + 2)
    # The RX CDC drains the 312-byte frame before the looped-back PAUSE frame,
    # so wait long enough for it to be counted before section 4.
    await ClockCycles(clk, 600)
    c.check(f"PAUSE mid user frame: user frame intact (312 bytes): {phy.wire_len[n0]}",
            phy.wire_len[n0] == 312)
    c.check(f"PAUSE mid user frame: PAUSE frame follows (72 bytes): {phy.wire_len[n0 + 1]}",
            phy.wire_len[n0 + 1] == 72)

    # ---- 4. Injected frames: only a valid PAUSE frame counts ----
    await axil.write(0x8C, 0)                     # clears both counters
    v = await axil.read(0x8C)
    c.check(f"write to PAUSE_RX_CNT clears it: {v}", v == 0)
    v = await axil.read(0x90)
    c.check(f"write to PAUSE_RX_CNT clears PAUSE_TX_CNT too: {v}", v == 0)

    build_pause(60, 5)
    await inject_frame(60, 0, -1)
    v = await axil.read(0x8C)
    c.check(f"injected valid PAUSE frame counted: {v}", v == 1)
    await inject_frame(60, 1, -1)
    v = await axil.read(0x8C)
    c.check(f"PAUSE frame with a bad FCS ignored: {v}", v == 1)
    await inject_frame(60, 0, 30)
    v = await axil.read(0x8C)
    c.check(f"PAUSE frame with rx_er ignored: {v}", v == 1)
    build_pause(56, 5)
    await inject_frame(56, 0, -1)
    v = await axil.read(0x8C)
    c.check(f"PAUSE frame shorter than 64 bytes ignored: {v}", v == 1)
    build_pause(100, 5)
    await inject_frame(100, 0, -1)
    v = await axil.read(0x8C)
    c.check(f"PAUSE frame longer than 64 bytes counted: {v}", v == 2)
    build_pause(60, 5)
    fr[13] = 0x09                                 # EtherType 0x8809: not MAC Control
    await inject_frame(60, 0, -1)
    v = await axil.read(0x8C)
    c.check(f"other EtherType ignored: {v}", v == 2)

    c.finish()
