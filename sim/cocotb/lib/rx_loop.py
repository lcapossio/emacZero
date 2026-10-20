# SPDX-License-Identifier: Apache-2.0
"""Bench plumbing shared by the cocotb ports of the eth_mac_tx -> eth_mac_rx
loopback benches (tb_eth_mac_rx_mcast/backpressure/byte0/jumbo_gate and
tb_eth_mac_sys_jumbo), on the harnesses h_eth_mac_rx_loop and
h_eth_mac_rx_jumbo_gate.

The Verilog benches share this structure:

  * a 100 MHz clock that starts low (`always #5 clk = ~clk`, first rising
    edge at 5 ns);
  * a loopback register clocked on the falling edge,
        always @(negedge clk) lb_* <= gmii_tx*;
    which `NegedgeLoop` reproduces from Python (it is bench logic, so it is
    not in the harness);
  * posedge-clocked counters / capture registers. `NegedgeLoop` calls the
    test's samplers in the ReadOnly phase after each falling edge: every
    harness output changes only on the rising edge and every input the test
    drives changes on the falling edge, so the values read there are the ones
    the next rising edge samples. Like the benches' counters (async reset or
    `if (rst_n)`), samplers run only while rst_n is high.

Two AXIS drivers mirror the benches' two `send_frame` styles.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

CLK_NS = 10


def start_clock(dut):
    """`reg clk = 0; always #5 clk = ~clk;`: low first, rising edge at 5 ns."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start(start_high=False))


class NegedgeLoop:
    """The benches' negedge GMII loopback register plus per-cycle samplers."""

    def __init__(self, dut):
        self.dut = dut
        self.samplers = []
        self._pairs = [(dut.gmii_txd, dut.lb_rxd),
                       (dut.gmii_tx_en, dut.lb_rx_dv),
                       (dut.gmii_tx_er, dut.lb_rx_er)]
        for _, lb in self._pairs:
            lb.value = 0
        self._last = [None] * len(self._pairs)

    def start(self):
        cocotb.start_soon(self._run())
        return self

    async def _run(self):
        dut = self.dut
        while True:
            await FallingEdge(dut.clk)
            for i, (src, lb) in enumerate(self._pairs):
                v = src.value
                if v != self._last[i]:
                    lb.value = v
                    self._last[i] = v
            await ReadOnly()
            if str(dut.rst_n.value) == "1":
                for fn in self.samplers:
                    fn()


async def send_posedge_style(dut, data):
    """tb_eth_mac_rx_mcast / _backpressure `send_frame`:

        for each byte: @(negedge clk) drive; @(posedge clk);
                       while (!tx_tready) @(posedge clk);
        @(negedge clk) tx_tvalid = 0; tx_tlast = 0;

    tx_tready is read in ReadOnly before each rising edge (the value that edge
    samples, as the bench's read right after @(posedge) does).
    """
    n = len(data)
    for k, b in enumerate(data):
        await FallingEdge(dut.clk)
        dut.tx_tdata.value = b
        dut.tx_tvalid.value = 1
        dut.tx_tlast.value = 1 if k == n - 1 else 0
        while True:
            await ReadOnly()
            ready = str(dut.tx_tready.value) == "1"
            await RisingEdge(dut.clk)
            if ready:
                break
    await FallingEdge(dut.clk)
    dut.tx_tvalid.value = 0
    dut.tx_tlast.value = 0


async def send_negedge_style(dut, data):
    """tb_eth_mac_rx_byte0 / _jumbo_gate / tb_eth_mac_sys_jumbo frame loop:

        @(negedge clk);
        for each byte: drive; @(negedge clk); while (!tx_tready) @(negedge clk);
        tx_tvalid = 0; tx_tlast = 0;

    tx_tready is read at each falling edge (settled since the rising edge
    before it; nothing in the harness changes on the falling edge).
    """
    n = len(data)
    await FallingEdge(dut.clk)
    for k, b in enumerate(data):
        dut.tx_tdata.value = b
        dut.tx_tvalid.value = 1
        dut.tx_tlast.value = 1 if k == n - 1 else 0
        await FallingEdge(dut.clk)
        while str(dut.tx_tready.value) != "1":
            await FallingEdge(dut.clk)
    dut.tx_tvalid.value = 0
    dut.tx_tlast.value = 0


def is1(sig):
    """True when a 1-bit signal reads '1' (X/U/Z read as not 1, like `if (x)`)."""
    return str(sig.value) == "1"
