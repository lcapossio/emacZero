# SPDX-License-Identifier: Apache-2.0
"""cocotb port of sim/tb/tb_crc32.v (build_and_test.py bench CRC32).

Same DUT (rtl/crc32.v / rtl/vhdl/crc32.vhd), same 125 MHz clock starting low,
same reset timing, same byte feeding (data_valid for one cycle per byte, set
just after a rising edge like the bench's nonblocking assignments). The bench
uses no $random. Checks, in bench order:

  TC-CRC-01  crc_out after "123456789"                      == 0xCBF43926
  TC-CRC-02  crc_raw after "123456789" + its FCS (LSB first) == 0xDEBB20E3
  TC-CRC-03  crc_out after the single byte 0x00              == 0xD202EF8D
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer


# Suites this module backs (read by run.py; see its docstring).
SUITES = {
    "crc32": {
        "toplevel": "crc32",
        "sources": ["rtl/crc32.v"],
        "params": {},
    },
}


class Checks:
    """PASS/FAIL bookkeeping like the bench: log every check, fail at the end."""

    def __init__(self, log):
        self.log = log
        self.passed = 0
        self.failed = 0

    def eq(self, name, sig, expected, width=32):
        v = sig.value
        if v.is_resolvable and int(v) == expected:
            self.log.info(f"PASS: {name} = 0x{int(v):0{width // 4}X}")
            self.passed += 1
        else:
            self.log.error(f"FAIL: {name} = {v} expected 0x{expected:0{width // 4}X}")
            self.failed += 1

    def finish(self):
        self.log.info(f"CRC32 Test Results: {self.passed} PASS, {self.failed} FAIL")
        assert self.failed == 0, f"{self.failed} check(s) failed"


async def feed_byte(dut, b):
    await RisingEdge(dut.clk)
    dut.data_in.value = b
    dut.data_valid.value = 1
    await RisingEdge(dut.clk)
    dut.data_valid.value = 0


async def init_crc(dut):
    await RisingEdge(dut.clk)
    dut.crc_init.value = 1
    await RisingEdge(dut.clk)
    dut.crc_init.value = 0


async def settle(dut):
    """The bench's two idle edges before it reads the result."""
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    await ReadOnly()


@cocotb.test(timeout_time=100, timeout_unit="us")
async def crc32_vectors(dut):
    """TC-CRC-01..03 in bench order."""
    cocotb.start_soon(Clock(dut.clk, 8, unit="ns").start(start_high=False))
    chk = Checks(dut._log)
    dut.rst_n.value = 0
    dut.data_in.value = 0
    dut.data_valid.value = 0
    dut.crc_init.value = 0
    await Timer(100, "ns")
    dut.rst_n.value = 1
    await Timer(20, "ns")

    msg = b"123456789"

    dut._log.info("[TC-CRC-01] CRC of ASCII '123456789'")
    await init_crc(dut)
    for b in msg:
        await feed_byte(dut, b)
    await settle(dut)
    chk.eq("TC-CRC-01 crc_out", dut.crc_out, 0xCBF43926)

    dut._log.info("[TC-CRC-02] CRC residue check")
    await init_crc(dut)
    for b in msg + bytes([0x26, 0x39, 0xF4, 0xCB]):
        await feed_byte(dut, b)
    await settle(dut)
    chk.eq("TC-CRC-02 crc_raw residue", dut.crc_raw, 0xDEBB20E3)

    dut._log.info("[TC-CRC-03] CRC of single byte 0x00")
    await init_crc(dut)
    await feed_byte(dut, 0x00)
    await settle(dut)
    chk.eq("TC-CRC-03 crc_out", dut.crc_out, 0xD202EF8D)

    await Timer(100, "ns")
    chk.finish()
