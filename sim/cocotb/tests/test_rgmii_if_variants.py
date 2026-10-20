# SPDX-License-Identifier: Apache-2.0
"""cocotb port of sim/tb/tb_rgmii_if_variants.v (build_and_test.py bench
RGMII-IF-VARIANTS).

rgmii_if with each RGMII_SPEEDS value, wired as in the bench by
sim/cocotb/hdl/h_rgmii_if_variants.{v,vhd}: "1G_ONLY" at 1G, "10_100" at 100M
(TXC from clk_125, clk_125_90 tied low) and "ALL" at 1G, all fed the same
GMII byte. The three RGMII_SPEEDS strings are harness parameters / generics,
set by the suite to the bench's values. As in the bench, clk_125_90 toggles
in phase with clk_125 (no shift in this bench); both rise at 4, 12, ... ns.
The GMII inputs change on the falling edge of clk_125.

Checks, in the order of the bench (5):
  1G_ONLY @ 1G drove tx_ctl high during active    (txctl_1g_only === 1 seen)
  ALL @ 1G drove tx_ctl high during active        (txctl_all === 1 seen)
  10_100 @ 100M drove tx_ctl high during active   (txctl_10_100 === 1 seen)
  1G_ONLY TXC period 8 ns                         (last period, 7.999..8.001 ns)
  10_100 TXC period 40 ns from clk_125            (last period, 39.999..40.001 ns)
The TXC periods are measured on the 10 ps-delayed TXCs (txc_1g_s,
txc_100_s), in integer picoseconds (the bench's 1 ps precision).

Sampling: the bench latches tx_ctl on posedge clk_125 while rst_n is high, the
same edge on which the DDR cells change tx_ctl, so its read races the cell.
Here tx_ctl is read after that edge has settled (RisingEdge + ReadOnly).
tx_ctl is 1 in both halves of every cycle of the 60-cycle active window, so
either read sees it.
No randomness.
"""
import cocotb
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer

from lib.bench import Checks
from lib.rgmii_tb import is1, now_ps, start_clocks, watch_edges


# Suites this module backs (read by run.py; see its docstring).
SUITES = {
    "rgmii_if_variants": {
        "toplevel": "h_rgmii_if_variants",
        "sources": ["rtl/ddr_input.v", "rtl/ddr_output.v", "rtl/rgmii_if.v",
                    "sim/cocotb/hdl/h_rgmii_if_variants.v"],
        "params": {"RGMII_SPEEDS_1G_ONLY": "1G_ONLY",
                   "RGMII_SPEEDS_10_100": "10_100",
                   "RGMII_SPEEDS_ALL": "ALL"},
    },
}


class Bench:
    def __init__(self, dut):
        self.dut = dut
        self.saw_1g_only_active = False
        self.saw_all_active = False
        self.saw_10_100_active = False
        self.t_1g = 0
        self.t_100 = 0
        self.per_1g = 0
        self.per_100 = 0

    async def latch_active(self):
        dut = self.dut
        while True:
            await RisingEdge(dut.clk_125)
            await ReadOnly()
            if is1(dut.rst_n):
                if is1(dut.txctl_1g_only):
                    self.saw_1g_only_active = True
                if is1(dut.txctl_all):
                    self.saw_all_active = True
                if is1(dut.txctl_10_100):
                    self.saw_10_100_active = True

    def on_txc_1g_rise(self):
        now = now_ps()
        if is1(self.dut.rst_n) and self.t_1g > 0:
            self.per_1g = now - self.t_1g
        self.t_1g = now

    def on_txc_100_rise(self):
        now = now_ps()
        if is1(self.dut.rst_n) and self.t_100 > 0:
            self.per_100 = now - self.t_100
        self.t_100 = now


@cocotb.test(timeout_time=50, timeout_unit="us")
async def rgmii_if_variants(dut):
    """tb_rgmii_if_variants: each RGMII_SPEEDS value drives TX_CTL and its TXC."""
    ck = Checks(dut._log)
    start_clocks(dut, shifted=False)
    dut.rst_n.value = 0
    dut.tx_d.value = 0
    dut.tx_en.value = 0
    dut.tx_er.value = 0

    tb = Bench(dut)
    cocotb.start_soon(tb.latch_active())
    cocotb.start_soon(watch_edges(dut.txc_1g_s, on_pos=tb.on_txc_1g_rise))
    cocotb.start_soon(watch_edges(dut.txc_100_s, on_pos=tb.on_txc_100_rise))

    await Timer(100, "ns")
    dut.rst_n.value = 1
    await Timer(50, "ns")

    # An active byte, held long enough for the 100M path (a nibble every 5
    # clk_125 cycles).
    await FallingEdge(dut.clk_125)
    dut.tx_d.value = 0xA5
    dut.tx_en.value = 1
    for _ in range(60):
        await FallingEdge(dut.clk_125)
    dut.tx_en.value = 0
    dut.tx_d.value = 0x00

    await Timer(200, "ns")

    ck.check("1G_ONLY @ 1G drove tx_ctl high during active", tb.saw_1g_only_active)
    ck.check("ALL @ 1G drove tx_ctl high during active", tb.saw_all_active)
    ck.check("10_100 @ 100M drove tx_ctl high during active", tb.saw_10_100_active)
    ck.check("1G_ONLY TXC period 8 ns", 7_999 < tb.per_1g < 8_001,
             f"{tb.per_1g / 1000:.1f} ns, expected 8")
    ck.check("10_100 TXC period 40 ns from clk_125", 39_999 < tb.per_100 < 40_001,
             f"{tb.per_100 / 1000:.1f} ns, expected 40")

    ck.finish()
