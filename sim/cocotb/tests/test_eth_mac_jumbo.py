# SPDX-License-Identifier: Apache-2.0
"""cocotb port of sim/tb/tb_eth_mac_jumbo.v (build_and_test.py bench
ETH-MAC-JUMBO): eth_mac with MAX_FRAME 9018 and MII_DEBUG 1 sends one
5000-byte frame (byte i = i & 0xFF); the internal GMII TX byte stream,
exported on dbg_gmii_txd / dbg_gmii_tx_en (sys-clock domain, MII_DEBUG=1), is
captured and checked.

Same clocks (sys 100 MHz, MII 25 MHz, both low at t=0), reset release at
100 ns. As in the bench the frame is driven on the falling edge: after the
first rising edge past reset, from the next falling edge each beat is set,
held until tx_ready is high at a falling edge, then held one more falling edge
(the following rising edge consumes it). Then 1 ms of drain. The bench's 5 ms
watchdog is the test timeout. The capture mirrors the bench's posedge-clk
always block (pre-edge values, sampled here on the falling edge).

Checks, in the bench's order (any failure fails the single test):
  1. captured GMII bytes >= 7 + 1 + 5000 + 4.
  2. bytes 0..6 are 0x55 (preamble).
  3. byte 7 is 0xD5 (SFD).
  4. bytes 8..23 == frame bytes 0..15.
  5. bytes 8+4984 .. 8+4999 == frame bytes 4984..4999 (jumbo end).
No random stimulus.
"""
import cocotb
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer

from lib.mii_bench import eth_mac_bench_start, is1, byte_or_none

# Suites this module backs (read by run.py; see its docstring).
SUITES = {
    "eth_mac_jumbo": {
        "toplevel": "eth_mac",
        "sources": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v", "rtl/sync_fifo.v",
                    "rtl/net/csum_calc.v", "rtl/eth_mac_rx.v", "rtl/eth_mac_tx.v",
                    "rtl/eth_mac.v"],
        "params": {"MAX_FRAME": 9018, "MII_DEBUG": 1},
    },
}

JUMBO_LEN = 5000
CAP_DEPTH = 8192


class GmiiCapture:
    """always @(posedge clk): if (!rst_n) cap_idx <= 0;
    else if (dbg_gmii_tx_en) begin cap[cap_idx] <= dbg_gmii_txd; cap_idx++; end"""

    def __init__(self, dut):
        self.dut = dut
        self.cap = {}
        self.cap_idx = 0

    async def run(self):
        dut = self.dut
        while True:
            await FallingEdge(dut.clk)
            if not is1(dut.rst_n):
                self.cap_idx = 0
            elif is1(dut.dbg_gmii_tx_en):
                if self.cap_idx < CAP_DEPTH:
                    self.cap[self.cap_idx] = byte_or_none(dut.dbg_gmii_txd)
                self.cap_idx += 1


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def jumbo(dut):
    """One 5000-byte frame: GMII TX length, preamble, SFD, first and last 16 bytes."""
    await eth_mac_bench_start(dut)          # returns at rst_n rising (100 ns)
    cap = GmiiCapture(dut)
    cocotb.start_soon(cap.run())

    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    for i in range(JUMBO_LEN):
        dut.s_axis_tdata.value = i & 0xFF
        dut.s_axis_tvalid.value = 1
        dut.s_axis_tlast.value = 1 if i == JUMBO_LEN - 1 else 0
        # while (!tx_ready) @(negedge clk); @(negedge clk);
        while True:
            await ReadOnly()
            if is1(dut.s_axis_tready):
                break
            await FallingEdge(dut.clk)
        await FallingEdge(dut.clk)
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0

    await Timer(1_000_000, unit="ns")

    passes, fails = [], []
    need = 7 + 1 + JUMBO_LEN + 4
    if cap.cap_idx >= need:
        passes.append(f"GMII TX captured {cap.cap_idx} bytes (>= {need} expected)")
    else:
        fails.append(f"GMII TX captured {cap.cap_idx} bytes (expected >= {need})")

    if all(cap.cap.get(j) == 0x55 for j in range(7)):
        passes.append("preamble (7x 0x55)")
    else:
        fails.append("preamble corrupted")

    if cap.cap.get(7) == 0xD5:
        passes.append("SFD = 0xD5")
    else:
        fails.append(f"SFD = {cap.cap.get(7)} (expected 0xD5)")

    bad = [(j, cap.cap.get(8 + j)) for j in range(16) if cap.cap.get(8 + j) != (j & 0xFF)]
    if not bad:
        passes.append("first 16 frame bytes match input")
    else:
        fails.append(f"frame body corrupted at start: {bad}")

    bad = [(j, cap.cap.get(8 + j)) for j in range(JUMBO_LEN - 16, JUMBO_LEN)
           if cap.cap.get(8 + j) != (j & 0xFF)]
    if not bad:
        passes.append("last 16 frame bytes match input (jumbo end)")
    else:
        fails.append(f"frame body corrupted at end of jumbo: {bad}")

    for msg in passes:
        dut._log.info("PASS: " + msg)
    for msg in fails:
        dut._log.error("FAIL: " + msg)
    assert not fails, f"{len(passes)} passed, {len(fails)} failed: {fails}"
