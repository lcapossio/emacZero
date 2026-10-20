# SPDX-License-Identifier: Apache-2.0
"""Shared pieces for the eth_mac_sys loopback / line-rate cocotb suites
(test_rgmii_loopback, test_rgmii_10_100_loopback, test_gmii_loopback,
test_gmii_rx_line_rate).

- tie_off():      every eth_mac_sys input the Verilog benches tie to a constant
- hdr_byte():     the benches' fixed 14-byte header (broadcast DA, SA
                  02:00:00:00:00:01, EtherType 0x0800)
- crc32_byte():   the reflected CRC-32 step of tb_gmii_rx_line_rate.v
- clock_edges():  a clock whose n-th edge is at n * half period, rounded to
                  the simulator's precision (for periods such as 8.0008 ns
                  that a fixed-step clock cannot represent at 1 ps)
- SettledWatch:   waits for a settled change of a signal (zero-width glitches
                  inside one time step are not changes), like an inertial
                  #0.01 delay in a Verilog bench
"""
from decimal import Decimal
from fractions import Fraction

import cocotb
from cocotb.triggers import Edge, FallingEdge, ReadOnly, RisingEdge, Timer
from cocotb.utils import get_sim_time


def tie_off(dut):
    """Inputs every one of these benches ties off (MII, unused clocks, MDIO).
    The bench-specific PHY pins are driven by each test."""
    dut.mii_tx_clk.value = 0
    dut.mii_rxd.value = 0
    dut.mii_rx_dv.value = 0
    dut.mii_rx_er.value = 0
    dut.mii_rx_clk.value = 0
    dut.mii_col.value = 0
    dut.mii_crs.value = 0
    dut.clk_25.value = 0
    dut.clk_2_5.value = 0
    dut.mdio_i.value = 1
    dut.m_axis_tready.value = 1


def hdr_byte(k):
    """Byte k (< 14) of the header every bench sends."""
    if k < 6:
        return 0xFF
    if k < 12:
        return 0x02 if k == 6 else (0x01 if k == 11 else 0x00)
    return 0x08 if k == 12 else 0x00


async def send_axis(dut, data):
    """The benches' send_frame: one byte per falling edge of clk, held until
    s_axis_tready reads high at a later falling edge; tlast on the last byte."""
    clk = dut.clk
    await FallingEdge(clk)
    last = len(data) - 1
    for i, b in enumerate(data):
        dut.s_axis_tdata.value = b
        dut.s_axis_tvalid.value = 1
        dut.s_axis_tlast.value = 1 if i == last else 0
        await FallingEdge(clk)
        while not int(dut.s_axis_tready.value):
            await FallingEdge(clk)
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0


def crc32_byte(crc, b):
    c = crc ^ b
    for _ in range(8):
        c = (c >> 1) ^ 0xEDB88320 if c & 1 else c >> 1
    return c


def is1(sig) -> bool:
    """True if a 1-bit signal reads '1' (X / U / Z read as not 1)."""
    return str(sig.value) == "1"


class AxisRx:
    """Calls `beat(tdata, tlast, terror)` for every m_axis beat (tready = 1),
    with the values the bench's always @(posedge clk) block sees there:
    sampled settled at the falling edge before that rising edge. Idle time
    is skipped on the tvalid edge, so long gaps cost no per-cycle callbacks."""

    def __init__(self, dut, beat):
        self.dut = dut
        self.beat = beat

    async def run(self):
        d = self.dut
        while True:
            await FallingEdge(d.clk)
            if not is1(d.m_axis_tvalid):
                await RisingEdge(d.m_axis_tvalid)
                continue
            self.beat(int(d.m_axis_tdata.value), is1(d.m_axis_tlast),
                      is1(d.m_axis_terror))


def _steps_per_ns() -> int:
    """Simulator steps per ns (1000 on Icarus at 1 ps, 1e6 on GHDL at 1 fs)."""
    from cocotb import simulator
    return 10 ** (-9 - simulator.get_precision())


async def clock_edges(signals, half_ns, start_high=False):
    """Toggle every signal in `signals` together; edge n is at n * half_ns,
    rounded to the simulator precision (no drift accumulates)."""
    spn = _steps_per_ns()
    half = Fraction(half_ns) * spn
    level = 1 if start_high else 0
    for s in signals:
        s.value = level
    n, t = 0, 0
    while True:
        n += 1
        nxt = round(n * half)
        await Timer(nxt - t, unit="step")
        t = nxt
        level ^= 1
        for s in signals:
            s.value = level


def now_ns() -> float:
    return get_sim_time(unit="ns")


class SettledWatch:
    """Calls `cb(time_ns, value)` for each settled change of `sig` (the value
    at the end of a time step differs from the last settled value)."""

    def __init__(self, sig, cb):
        self.sig = sig
        self.cb = cb
        self.last = None

    async def run(self):
        await ReadOnly()
        self.last = self.sig.value
        while True:
            await Edge(self.sig)
            await ReadOnly()
            v = self.sig.value
            if v != self.last:
                self.last = v
                self.cb(now_ns(), v)


class InertialDelay:
    """dst follows the settled value of src `delay_ns` later; a newer change
    cancels a pending one (Verilog `assign #d`)."""

    def __init__(self, src, dst, delay_ns, on_change=None):
        self.dst = dst
        self.delay_ns = Decimal(str(delay_ns))
        self.on_change = on_change
        self.gen = 0
        self.watch = SettledWatch(src, self._changed)

    def _changed(self, t, v):
        self.gen += 1
        cocotb.start_soon(self._apply(self.gen, v))
        if self.on_change is not None:
            self.on_change(t, v)

    async def _apply(self, gen, v):
        await Timer(self.delay_ns, unit="ns")
        if gen == self.gen:
            self.dst.value = v

    def start(self):
        return cocotb.start_soon(self.watch.run())
