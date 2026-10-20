# SPDX-License-Identifier: Apache-2.0
"""cocotb port of sim/tb/tb_async_fifo.v (build_and_test.py benches ASYNC-FIFO
and ASYNC-FIFO-BLOCK).

Same DUT (async_fifo, DATA_WIDTH=8, ADDR_WIDTH=4 = 16 deep), same clocks
(wr 125 MHz / rd ~45 MHz, both starting low), same reset timing, same
falling-edge driving. The bench's -DASYNC_FIFO_BLOCK build is the suite
async_fifo_block: RAM_STYLE="BLOCK" on the DUT plus ASYNC_FIFO_BLOCK=1 in the
environment, which turns on the same extra T3 steps and CAPACITY = DEPTH + 1
(the loaded output-stage word). The bench uses no $random. Checks, in bench
order:

  T1  rd_empty == 1 and wr_full == 0 after reset
  T2  push 0xA0..0xA3, pop 4: each popped byte in order (4 checks);
      rd_empty == 1 after the drain
  T3  fill DEPTH words (0x10..); BLOCK only: rd_empty == 0 (head loaded),
      wr_full == 0 (room for word DEPTH+1), then one more write;
      wr_full == 1 after CAPACITY writes; wr_full still 1 after a blocked push
  T4  drain CAPACITY words: each popped byte in order (CAPACITY checks);
      rd_empty == 1, then wr_full == 0
  T5  64-byte burst, writer and reader running concurrently: every byte the
      reader sees in order (one failure per wrong byte), then one pass
"""
import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer


# Suites this module backs (read by run.py; see its docstring).
SUITES = {
    "async_fifo": {
        "toplevel": "async_fifo",
        "sources": ["rtl/async_fifo.v"],
        "params": {"DATA_WIDTH": 8, "ADDR_WIDTH": 4, "RAM_STYLE": "DISTRIBUTED"},
    },
    "async_fifo_block": {
        "toplevel": "async_fifo",
        "sources": ["rtl/async_fifo.v"],
        "params": {"DATA_WIDTH": 8, "ADDR_WIDTH": 4, "RAM_STYLE": "BLOCK"},
        "env": {"ASYNC_FIFO_BLOCK": "1"},
    },
}

BLOCK = os.environ.get("ASYNC_FIFO_BLOCK", "0") == "1"
ADDR_WIDTH = 4
DEPTH = 1 << ADDR_WIDTH
CAPACITY = DEPTH + 1 if BLOCK else DEPTH


class Checks:
    """PASS/FAIL bookkeeping like the bench: log every check, fail at the end."""

    def __init__(self, log):
        self.log = log
        self.passed = 0
        self.failed = 0

    def ok(self, msg=None):
        if msg:
            self.log.info(f"PASS: {msg}")
        self.passed += 1

    def fail(self, msg):
        self.log.error(f"FAIL: {msg}")
        self.failed += 1

    def bool(self, name, sig, expected):
        v = sig.value
        if v.is_resolvable and int(v) == expected:
            self.ok(f"{name} = {int(v)}")
        else:
            self.fail(f"{name} = {v}, expected {expected}")

    def finish(self):
        if self.failed == 0:
            self.log.info(f"PASS: {self.passed} tests passed")
        assert self.failed == 0, f"{self.passed} passed, {self.failed} failed"


def _bit(sig):
    return int(sig.value)


async def wr_push(dut, d):
    await FallingEdge(dut.wr_clk)
    dut.wr_data.value = d
    dut.wr_en.value = 0 if _bit(dut.wr_full) else 1
    await RisingEdge(dut.wr_clk)
    await FallingEdge(dut.wr_clk)
    dut.wr_en.value = 0


async def rd_pop(dut):
    await FallingEdge(dut.rd_clk)
    while _bit(dut.rd_empty):
        await FallingEdge(dut.rd_clk)
    d = dut.rd_data.value
    dut.rd_en.value = 1
    await RisingEdge(dut.rd_clk)
    await FallingEdge(dut.rd_clk)
    dut.rd_en.value = 0
    return d


async def edges(clk, n):
    for _ in range(n):
        await RisingEdge(clk)


def _byte_ok(v, exp):
    return v.is_resolvable and int(v) == exp


@cocotb.test(timeout_time=500, timeout_unit="us")
async def async_fifo_t1_t5(dut):
    """T1..T5 in bench order."""
    cocotb.start_soon(Clock(dut.wr_clk, 8, unit="ns").start(start_high=False))
    cocotb.start_soon(Clock(dut.rd_clk, 22, unit="ns").start(start_high=False))
    chk = Checks(dut._log)
    dut._log.info(f"RAM_STYLE={'BLOCK' if BLOCK else 'DISTRIBUTED'} CAPACITY={CAPACITY}")

    dut.wr_rst_n.value = 0
    dut.rd_rst_n.value = 0
    dut.wr_data.value = 0
    dut.wr_en.value = 0
    dut.rd_en.value = 0
    await Timer(50, "ns")
    dut.wr_rst_n.value = 1
    dut.rd_rst_n.value = 1
    await Timer(50, "ns")

    # T1: empty after reset
    chk.bool("T1 rd_empty after reset", dut.rd_empty, 1)
    chk.bool("T1 wr_full after reset", dut.wr_full, 0)

    # T2: push 4 then pop 4, FIFO order
    for i in range(4):
        await wr_push(dut, 0xA0 + i)
    await edges(dut.rd_clk, 10)
    for i in range(4):
        v = await rd_pop(dut)
        if _byte_ok(v, 0xA0 + i):
            chk.ok()
        else:
            chk.fail(f"T2 byte {i} got {v} exp 0x{0xA0 + i:02x}")
    dut._log.info("PASS: T2 4-byte FIFO order")
    await edges(dut.rd_clk, 8)
    chk.bool("T2 empty after drain", dut.rd_empty, 1)

    # T3: fill to full, DEPTH writes back to back
    for i in range(DEPTH):
        await FallingEdge(dut.wr_clk)
        dut.wr_data.value = (0x10 + i) & 0xFF
        dut.wr_en.value = 0 if _bit(dut.wr_full) else 1
        await RisingEdge(dut.wr_clk)
    await FallingEdge(dut.wr_clk)
    dut.wr_en.value = 0

    if BLOCK:
        # The output stage has pulled the first word out of memory by now, so
        # one more write fits: capacity is DEPTH + 1.
        await edges(dut.rd_clk, 8)
        chk.bool("T3 head loaded", dut.rd_empty, 0)
        chk.bool("T3 room for word DEPTH+1", dut.wr_full, 0)
        await FallingEdge(dut.wr_clk)
        dut.wr_data.value = (0x10 + DEPTH) & 0xFF
        dut.wr_en.value = 1
        await RisingEdge(dut.wr_clk)
        await FallingEdge(dut.wr_clk)
        dut.wr_en.value = 0

    await edges(dut.wr_clk, 4)
    chk.bool("T3 wr_full after CAPACITY writes", dut.wr_full, 1)

    # Push one more: must not move the write pointer
    await FallingEdge(dut.wr_clk)
    dut.wr_data.value = 0xEE
    dut.wr_en.value = 1
    await RisingEdge(dut.wr_clk)
    await FallingEdge(dut.wr_clk)
    dut.wr_en.value = 0
    await edges(dut.wr_clk, 4)
    chk.bool("T3 wr_full holds across blocked push", dut.wr_full, 1)

    # T4: drain everything, check order and the flags
    for i in range(CAPACITY):
        v = await rd_pop(dut)
        exp = (0x10 + i) & 0xFF
        if _byte_ok(v, exp):
            chk.ok()
        else:
            chk.fail(f"T4 byte {i} got {v} exp 0x{exp:02x}")
    dut._log.info("PASS: T4 full-depth drain order")
    await edges(dut.rd_clk, 8)
    chk.bool("T4 empty after full drain", dut.rd_empty, 1)
    await edges(dut.wr_clk, 8)
    chk.bool("T4 wr_full deasserts after drain", dut.wr_full, 0)

    # T5: 64-byte burst with a concurrent CDC pop
    async def burst_writer():
        wcnt = 0
        while wcnt < 64:
            await FallingEdge(dut.wr_clk)
            if not _bit(dut.wr_full):
                dut.wr_data.value = wcnt & 0xFF
                dut.wr_en.value = 1
                wcnt += 1
            else:
                dut.wr_en.value = 0
            await RisingEdge(dut.wr_clk)
        await FallingEdge(dut.wr_clk)
        dut.wr_en.value = 0

    async def burst_reader():
        rcnt = 0
        while rcnt < 64:
            await FallingEdge(dut.rd_clk)
            if not _bit(dut.rd_empty):
                v = dut.rd_data.value
                if not _byte_ok(v, rcnt & 0xFF):
                    chk.fail(f"T5 byte {rcnt} got {v} exp 0x{rcnt & 0xFF:02x}")
                dut.rd_en.value = 1
                rcnt += 1
            else:
                dut.rd_en.value = 0
            await RisingEdge(dut.rd_clk)
        await FallingEdge(dut.rd_clk)
        dut.rd_en.value = 0

    w = cocotb.start_soon(burst_writer())
    r = cocotb.start_soon(burst_reader())
    await w
    await r
    chk.ok("T5 64-byte CDC burst with concurrent pop")

    chk.finish()
