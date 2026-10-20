# SPDX-License-Identifier: Apache-2.0
"""cocotb port of sim/tb/tb_eth_stats.v (build_and_test.py bench ETH-STATS).

Same DUT (eth_stats), same 100 MHz clock starting low, same reset timing, the
extended rx_stat_* inputs tied to 0 as in the bench, stimulus on the falling
edge, checks 1 ns after a rising edge. The bench uses no $random.

Suite eth_stats (default STAT_CNT_W = 32), checks in bench order:

  1  tx_byte_cnt 10, tx_frame_cnt 1 after a 10-byte TX frame;
     tx_byte_cnt 15, tx_frame_cnt 2 after a further 5-byte frame
  2  rx_byte_cnt 20, rx_frame_cnt 1, rx_crc_err_cnt 0 after a good 20-byte RX
  3  rx_byte_cnt 28, rx_frame_cnt 2, rx_crc_err_cnt 1 after a bad 8-byte RX
  4  clr_tx: tx_frame_cnt 0, tx_byte_cnt 0, rx_frame_cnt still 2
  5  clr_rx: rx_frame_cnt 0, rx_byte_cnt 0, rx_crc_err_cnt 0

Not mirrored as written: the bench's Test 6 forces uut.tx_frame_cnt to
0xFFFFFFFE (skipped under TB_NO_HIER_FORCE). Forcing an internal signal does
not work on GHDL, so suite eth_stats_sat builds the DUT with STAT_CNT_W = 3
and reaches max - 1 (6) with six real tx_frame_done pulses, then makes the
bench's two checks at that width:

  6  tx_frame_cnt at max (7) after one more pulse
     tx_frame_cnt saturated (still 7) after another pulse
"""
import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer


# Suites this module backs (read by run.py; see its docstring).
SUITES = {
    "eth_stats": {
        "toplevel": "eth_stats",
        "sources": ["rtl/eth_stats.v"],
        "params": {},
    },
    "eth_stats_sat": {
        "toplevel": "eth_stats",
        "sources": ["rtl/eth_stats.v"],
        "params": {"STAT_CNT_W": 3},
        "env": {"ETH_STATS_CNT_W": "3"},
    },
}

CNT_W = int(os.environ.get("ETH_STATS_CNT_W", "32"))
CNT_MAX = (1 << CNT_W) - 1

TIED_ZERO = [
    "rx_stat_done", "rx_stat_len", "rx_stat_err_fcs", "rx_stat_err_align",
    "rx_stat_err_overflow", "rx_stat_err_oversize", "rx_stat_err_csum",
    "rx_stat_is_bcast", "rx_stat_is_mcast", "rx_stat_drop",
]


class Checks:
    """PASS/FAIL bookkeeping like the bench: log every check, fail at the end."""

    def __init__(self, log):
        self.log = log
        self.passed = 0
        self.failed = 0

    def eq(self, name, sig, expected):
        v = sig.value
        if v.is_resolvable and int(v) == expected:
            self.log.info(f"PASS: {name} = {int(v)}")
            self.passed += 1
        else:
            self.log.error(f"FAIL: {name} = {v}, expected {expected}")
            self.failed += 1

    def finish(self):
        if self.failed == 0:
            self.log.info(f"PASS: {self.passed} tests passed")
        assert self.failed == 0, f"{self.passed} passed, {self.failed} failed"


async def posedge_plus1(dut):
    """The bench's `@(posedge clk); #1;`."""
    await RisingEdge(dut.clk)
    await Timer(1, "ns")


async def reset(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start(start_high=False))
    dut.rst_n.value = 0
    dut.gmii_tx_en.value = 0
    dut.gmii_rx_dv.value = 0
    dut.tx_frame_done.value = 0
    dut.rx_frame_good.value = 0
    dut.rx_frame_bad.value = 0
    dut.clr_tx.value = 0
    dut.clr_rx.value = 0
    for name in TIED_ZERO:
        getattr(dut, name).value = 0
    await Timer(20, "ns")
    dut.rst_n.value = 1
    await posedge_plus1(dut)


async def drive_tx_frame(dut, num_bytes):
    await FallingEdge(dut.clk)
    dut.gmii_tx_en.value = 1
    for _ in range(num_bytes):
        await FallingEdge(dut.clk)
    dut.gmii_tx_en.value = 0
    dut.tx_frame_done.value = 1
    await FallingEdge(dut.clk)
    dut.tx_frame_done.value = 0


async def drive_rx_frame(dut, num_bytes, is_bad):
    await FallingEdge(dut.clk)
    dut.gmii_rx_dv.value = 1
    for _ in range(num_bytes):
        await FallingEdge(dut.clk)
    dut.gmii_rx_dv.value = 0
    if is_bad:
        dut.rx_frame_bad.value = 1
    else:
        dut.rx_frame_good.value = 1
    await FallingEdge(dut.clk)
    dut.rx_frame_bad.value = 0
    dut.rx_frame_good.value = 0


async def pulse(dut, sig):
    """One-cycle pulse from falling edge to falling edge, as the bench does."""
    await FallingEdge(dut.clk)
    sig.value = 1
    await FallingEdge(dut.clk)
    sig.value = 0


@cocotb.test(timeout_time=100, timeout_unit="us", skip=CNT_W != 32)
async def eth_stats_counts(dut):
    """Bench Tests 1..5 at STAT_CNT_W = 32."""
    chk = Checks(dut._log)
    await reset(dut)

    # Test 1: TX frame and byte counting
    await drive_tx_frame(dut, 10)
    await posedge_plus1(dut)
    chk.eq("tx_byte_cnt after 10B frame", dut.tx_byte_cnt, 10)
    chk.eq("tx_frame_cnt after 1 frame", dut.tx_frame_cnt, 1)
    await drive_tx_frame(dut, 5)
    await posedge_plus1(dut)
    chk.eq("tx_byte_cnt after 10+5B", dut.tx_byte_cnt, 15)
    chk.eq("tx_frame_cnt after 2 frames", dut.tx_frame_cnt, 2)

    # Test 2: RX good frame
    await drive_rx_frame(dut, 20, False)
    await posedge_plus1(dut)
    chk.eq("rx_byte_cnt after 20B", dut.rx_byte_cnt, 20)
    chk.eq("rx_frame_cnt after 1 good", dut.rx_frame_cnt, 1)
    chk.eq("rx_crc_err_cnt is 0", dut.rx_crc_err_cnt, 0)

    # Test 3: RX bad frame
    await drive_rx_frame(dut, 8, True)
    await posedge_plus1(dut)
    chk.eq("rx_byte_cnt after 20+8B", dut.rx_byte_cnt, 28)
    chk.eq("rx_frame_cnt after 1good+1bad", dut.rx_frame_cnt, 2)
    chk.eq("rx_crc_err_cnt after 1 bad", dut.rx_crc_err_cnt, 1)

    # Test 4: clear TX counters
    await pulse(dut, dut.clr_tx)
    await posedge_plus1(dut)
    chk.eq("tx_frame_cnt after clr_tx", dut.tx_frame_cnt, 0)
    chk.eq("tx_byte_cnt after clr_tx", dut.tx_byte_cnt, 0)
    chk.eq("rx_frame_cnt unaffected", dut.rx_frame_cnt, 2)

    # Test 5: clear RX counters
    await pulse(dut, dut.clr_rx)
    await posedge_plus1(dut)
    chk.eq("rx_frame_cnt after clr_rx", dut.rx_frame_cnt, 0)
    chk.eq("rx_byte_cnt after clr_rx", dut.rx_byte_cnt, 0)
    chk.eq("rx_crc_err_cnt after clr_rx", dut.rx_crc_err_cnt, 0)

    await Timer(10, "ns")
    chk.finish()


@cocotb.test(timeout_time=100, timeout_unit="us", skip=CNT_W == 32)
async def eth_stats_saturation(dut):
    """Bench Test 6 without the force: count up to max - 1 by real pulses."""
    chk = Checks(dut._log)
    await reset(dut)

    # Stands in for the bench's `force uut.tx_frame_cnt = max - 1`.
    for _ in range(CNT_MAX - 1):
        await pulse(dut, dut.tx_frame_done)
    await posedge_plus1(dut)
    dut._log.info(f"tx_frame_cnt = {dut.tx_frame_cnt.value} (max - 1 = {CNT_MAX - 1})")

    await pulse(dut, dut.tx_frame_done)
    await posedge_plus1(dut)
    chk.eq("tx_frame_cnt at max", dut.tx_frame_cnt, CNT_MAX)

    # One more increment must hold at max
    await pulse(dut, dut.tx_frame_done)
    await posedge_plus1(dut)
    chk.eq("tx_frame_cnt saturated", dut.tx_frame_cnt, CNT_MAX)

    await Timer(10, "ns")
    chk.finish()
