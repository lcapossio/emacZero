# SPDX-License-Identifier: Apache-2.0
"""Bench-faithful helpers for the eth_mac / MII cocotb ports.

The tests in test_eth_mac_multiframe.py, test_eth_mac_jumbo.py,
test_mii_store_forward.py, test_mii_loopback.py and
test_mii_rx_replay_stress.py mirror Verilog benches in sim/tb/. These helpers
reproduce the benches' own clocking, AXIS driving and capture timing:

- bench_clock: `reg c = 0; [#delay;] always #half c = ~c;` - low at t=0 (or at
  `delay`), first rising edge half a period later. cocotb's default
  start_high=True would put the edges elsewhere.
- send_frame_posedge: the benches' `@(posedge clk); tx_valid <= 1; ...
  while (!tx_ready) @(posedge clk);` loop. The bench reads tx_ready right after
  the edge, before the DUT's nonblocking updates, i.e. the value the DUT itself
  sampled at that edge. Here tready is read in the ReadOnly phase before the
  edge, which is that same value.
- level / is1 / is0: 3-valued reads, so an 'X' / 'U' / 'Z' bit behaves as in
  a Verilog `if` (neither true nor its negation).
- Bench `always @(posedge clk)` checkers see pre-edge values. The tests sample
  on the falling edge of the same clock: every observed signal is a register
  of that clock (or a constant), so its value at the falling edge is the value
  the next rising edge sees.
"""
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer


async def bench_clock(sig, half_ns, delay_ns=0):
    """`reg c = 0; initial begin #delay; forever #half c = ~c; end`."""
    sig.value = 0
    if delay_ns:
        await Timer(delay_ns, unit="ns")
    Clock(sig, 2 * half_ns, unit="ns").start(start_high=False)


def level(sig):
    """'0', '1' or 'X' (any non-01 value) for a 1-bit signal."""
    s = str(sig.value).upper()
    return s if s in ("0", "1") else "X"


def is1(sig):
    return level(sig) == "1"


def is0(sig):
    return level(sig) == "0"


def byte_or_none(sig):
    """int value of a vector, or None when any bit is not 0/1 (Verilog X)."""
    v = sig.value
    if not v.is_resolvable:
        return None
    return int(v)


async def ready_edge(clk, ready):
    """Wait for `@(posedge clk); while (!ready) @(posedge clk);`."""
    while True:
        await ReadOnly()
        r = is1(ready)
        await RisingEdge(clk)
        if r:
            return


async def send_frame_posedge(clk, ready, tdata, tvalid, tlast, data, idle_after=2):
    """The benches' per-frame AXIS loop (tb_eth_mac_multiframe.v and others).

        @(posedge clk);
        tx_valid <= 1; tx_data <= d[0]; tx_last <= (len == 1);
        for (i = 1; i < len; i++) begin
            @(posedge clk); while (!tx_ready) @(posedge clk);
            tx_data <= d[i]; tx_last <= (i == len - 1);
        end
        @(posedge clk); while (!tx_ready) @(posedge clk);
        tx_valid <= 0; tx_last <= 0;
        repeat (idle_after) @(posedge clk);

    (tb_mii_loopback.v does not write tx_last on the first beat; it is still 0
    there, so writing 0 is the same.)
    """
    n = len(data)
    await RisingEdge(clk)
    tvalid.value = 1
    tdata.value = data[0]
    tlast.value = 1 if n == 1 else 0
    for i in range(1, n):
        await ready_edge(clk, ready)
        tdata.value = data[i]
        tlast.value = 1 if i == n - 1 else 0
    await ready_edge(clk, ready)
    tvalid.value = 0
    tlast.value = 0
    for _ in range(idle_after):
        await RisingEdge(clk)


async def eth_mac_bench_start(dut, our_mac=0x020000000001):
    """eth_mac benches (tb_eth_mac_multiframe.v, tb_eth_mac_jumbo.v,
    tb_mii_store_forward.v): their constant inputs, clocks (clk #5, mii_clk #20,
    both low at t=0) and reset (rst_n = 0, #100 -> 1). Returns at t=100 ns."""
    dut.rst_n.value = 0
    dut.mii_rxd.value = 0
    dut.mii_rx_dv.value = 0
    dut.mii_rx_er.value = 0
    dut.mii_col.value = 0
    dut.mii_crs.value = 0
    dut.our_mac.value = our_mac
    dut.promisc.value = 0
    dut.s_axis_tkeep.value = 1
    dut.m_axis_tready.value = 1
    dut.s_axis_tdata.value = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    await bench_clock(dut.clk, 5)
    # mii_tx_clk and mii_rx_clk are one bench net (mii_clk).
    await bench_clock(dut.mii_tx_clk, 20)
    await bench_clock(dut.mii_rx_clk, 20)
    await Timer(100, unit="ns")
    dut.rst_n.value = 1
