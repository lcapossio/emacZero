# SPDX-License-Identifier: Apache-2.0
"""Shared pieces of the rgmii_if cocotb ports (tests/test_rgmii_if*.py).

  * start_clocks - clk_125 and clk_125_90 exactly as the Verilog benches make
    them: both 0 at time 0, clk_125 rising at 4, 12, ... ns, and clk_125_90
    either 2 ns behind (rising at 6, 14, ...) or in phase with it.
  * level / is1 / as_int - read a signal the way the benches' === / !== do:
    an X/U/Z value is never equal to a number.
  * watch_edges  - Verilog posedge / negedge semantics (0->x and x->1 are
    posedges, 1->x and x->0 negedges) on any value change of a 1-bit net.
  * now_ps       - simulation time in integer picoseconds (the benches use
    $realtime in ns with a 1 ps precision).
"""
import cocotb
from cocotb.clock import Clock
from cocotb.simtime import get_sim_time
from cocotb.triggers import Timer

CLK_PERIOD_NS = 8        # 125 MHz
CLK_90_LAG_NS = 2        # 90 degrees at 125 MHz


def start_clocks(dut, shifted=True):
    """Start clk_125 and clk_125_90 (2 ns behind when `shifted`, else in phase).

    Call at time 0; returns at once (the lagging clock starts in the background).
    """
    dut.clk_125.value = 0
    dut.clk_125_90.value = 0
    Clock(dut.clk_125, CLK_PERIOD_NS, unit="ns").start(start_high=False)

    async def _late_90():
        if shifted:
            await Timer(CLK_90_LAG_NS, "ns")
        Clock(dut.clk_125_90, CLK_PERIOD_NS, unit="ns").start(start_high=False)

    cocotb.start_soon(_late_90())


def now_ps():
    return int(round(get_sim_time("ps")))


def level(value):
    """'0', '1' or 'x' for a 1-bit value (std_logic L/H count as 0/1)."""
    s = str(value).upper()
    if s in ("0", "L"):
        return "0"
    if s in ("1", "H"):
        return "1"
    return "x"


def is1(handle):
    """handle === 1'b1."""
    return level(handle.value) == "1"


def as_int(handle):
    """The value as an int, or None if any bit is X/U/Z (never equal to a number)."""
    v = handle.value
    return int(v) if v.is_resolvable else None


async def watch_edges(sig, on_pos=None, on_neg=None):
    """Call on_pos() / on_neg() on each Verilog posedge / negedge of `sig`."""
    prev = level(sig.value)
    while True:
        await sig.value_change
        new = level(sig.value)
        if new == prev:
            continue
        if (prev == "0") or (new == "1"):          # 0->1, 0->x, x->1
            if on_pos:
                on_pos()
        else:                                      # 1->0, 1->x, x->0
            if on_neg:
                on_neg()
        prev = new


async def watch_changes(sig, on_change):
    """Call on_change() on every value change of `sig` (Verilog @(sig))."""
    while True:
        await sig.value_change
        on_change()


