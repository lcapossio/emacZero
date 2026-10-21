# SPDX-License-Identifier: Apache-2.0
"""Shared pieces for the eth_mac_sys suites ported from tb_eth_mac_sys.v,
tb_eth_mac_sys_csum.v, tb_eth_mac_sys_csum_loop.v, tb_eth_mac_sys_max_frame.v
and tb_eth_mac_sys_pause.v.

- val():         an int, or the string form when it has X/Z/U bits
- bit():         a 1-bit control read where X/Z/U counts as 0, like Verilog's
                 `if (x)`; for bench-side control only, never for a checked value
- start_clock(): a clock that is 0 at its start and rises half a period
                 later, like `initial clk = 0; always #h clk = ~clk;`
- mdio_loop():   the benches' `.mdio_i(mdio_o)` wire
- sample_pre():  the value a flop clocked by `clk` would sample at its next
                 rising edge, read settled in the low phase before that edge
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly


def bit(sig) -> int:
    v = sig.value
    return int(v) if v.is_resolvable else 0


def val(sig):
    """Integer value, or the string form when it has X/Z/U bits (so a
    comparison with an int fails, as `===` does in the bench)."""
    v = sig.value
    return int(v) if v.is_resolvable else str(v)


def start_clock(sig, period_ns):
    return cocotb.start_soon(Clock(sig, period_ns, unit="ns").start(start_high=False))


async def mdio_loop(dut):
    """mdio_i follows mdio_o (the benches wire them together)."""
    dut.mdio_i.value = dut.mdio_o.value
    while True:
        await dut.mdio_o.value_change
        dut.mdio_i.value = dut.mdio_o.value


async def sample_pre(clk, *sigs):
    """From any point in the high phase of `clk`: wait for its falling edge
    and return the settled values (bit() of each) seen there, which a flop
    samples at the next rising edge."""
    await FallingEdge(clk)
    await ReadOnly()
    return tuple(bit(s) for s in sigs)
