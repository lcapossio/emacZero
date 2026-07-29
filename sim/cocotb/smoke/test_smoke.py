# SPDX-License-Identifier: Apache-2.0
# Toolchain smoke: confirm cocotb 2.0 + Icarus VPI drive a DUT on this host.
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


@cocotb.test()
async def smoke(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    dut.d.value = 0
    await Timer(25, unit="ns")
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

    dut.d.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    assert dut.q.value == 1, f"expected q=1, got {dut.q.value}"

    dut.d.value = 0
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    assert dut.q.value == 0, f"expected q=0, got {dut.q.value}"
    dut._log.info("cocotb+Icarus smoke PASSED")
