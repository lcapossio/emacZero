# SPDX-License-Identifier: Apache-2.0
"""cocotb port of sim/tb/tb_rgmii_if.v (build_and_test.py bench RGMII-IF).

Two rgmii_if at 1G, wired as in the bench by sim/cocotb/hdl/h_rgmii_if.{v,vhd}:
u_tx's RGMII pins go straight into u_rx, which takes them on clk_125_90 as
RXC. clk_125 rises at 4, 12, ... ns and clk_125_90 2 ns later, as in the
bench. The GMII inputs change on the falling edge of clk_125, as in the bench.

Checks, in the order of the bench (13 when the frames are found):
  Test 1  gmii 0xA5, en=1 er=0; 1 ns after the next rising / falling edge:
          TX rising nibble (0xA5) = 5, TX_CTL rising (en=1,er=0) = 1,
          TX falling nibble (0xA5) = A, TX_CTL falling (en=1,er=0) = 1
  Test 2  gmii 0x3C, en=1 er=1: TX rising nibble (0x3C) = C,
          TX_CTL rising (en=1,er=1) = 1, TX falling nibble (0x3C) = 3,
          TX_CTL falling (en=1,er=1) = 0
  Test 3  en=0: TX_CTL rising (idle) = 0
  Test 4  8 bytes 01 23 .. EF looped back, captured on each clk_125 rising
          edge: loopback frame length = 8, loopback data integrity (8 bytes),
          no rx_er during frame (or one FAIL "loopback frame not found")
  Test 5  2 bytes with tx_er=1: rx_er propagated through DDR loopback (one
          check)

Sampling: the bench's capture block reads the RX outputs on the rising edge
of clk_125; they change on clk_125_90 edges, 2 ns away, so reading at the
rising edge (after ReadOnly) sees the same values in both languages.
No randomness.
"""
import cocotb
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer

from lib.bench import Checks
from lib.rgmii_tb import as_int, is1, start_clocks


# Suites this module backs (read by run.py; see its docstring).
SUITES = {
    "rgmii_if": {
        "toplevel": "h_rgmii_if",
        "sources": ["rtl/ddr_output.v", "rtl/ddr_input.v", "rtl/rgmii_if.v",
                    "sim/cocotb/hdl/h_rgmii_if.v"],
        "params": {},
    },
}


class RxCapture:
    """The bench's `always @(posedge clk_125)` capture of the RX GMII outputs."""

    def __init__(self, dut):
        self.dut = dut
        self.capturing = False
        self.rxd, self.dv, self.er = [], [], []

    def restart(self):
        self.rxd, self.dv, self.er = [], [], []
        self.capturing = True

    async def run(self):
        dut = self.dut
        while True:
            await RisingEdge(dut.clk_125)
            await ReadOnly()
            if not is1(dut.rst_n):
                self.rxd, self.dv, self.er = [], [], []
                self.capturing = False
            elif self.capturing:
                self.rxd.append(as_int(dut.rx_gmii_rxd))
                self.dv.append(is1(dut.rx_gmii_rx_dv))
                self.er.append(is1(dut.rx_gmii_rx_er))


@cocotb.test(timeout_time=100, timeout_unit="us")
async def rgmii_if_1g(dut):
    """tb_rgmii_if: TX nibble / TX_CTL encoding, 1G DDR loopback, TX_ER."""
    ck = Checks(dut._log)
    start_clocks(dut, shifted=True)
    dut.rst_n.value = 0
    dut.tx_gmii_txd.value = 0
    dut.tx_gmii_tx_en.value = 0
    dut.tx_gmii_tx_er.value = 0
    cap = RxCapture(dut)
    cocotb.start_soon(cap.run())

    await Timer(50, "ns")
    dut.rst_n.value = 1
    await Timer(50, "ns")

    def nib():
        return as_int(dut.rgmii_txd)

    def ctl():
        return as_int(dut.rgmii_tx_ctl)

    async def drive(txd, en, er):
        await FallingEdge(dut.clk_125)
        dut.tx_gmii_txd.value = txd
        dut.tx_gmii_tx_en.value = en
        dut.tx_gmii_tx_er.value = er

    def chk(name, actual, expected):
        ck.check(name, actual == expected,
                 f"0x{actual:x}, expected 0x{expected:x}" if actual is not None
                 else f"X, expected 0x{expected:x}")

    # Test 1: TX nibble encoding, 0xA5, en=1 er=0
    await drive(0xA5, 1, 0)
    await RisingEdge(dut.clk_125)
    await Timer(1, "ns")
    chk("TX rising nibble (0xA5)", nib(), 0x5)
    chk("TX_CTL rising (en=1,er=0)", ctl(), 0x1)
    await FallingEdge(dut.clk_125)
    await Timer(1, "ns")
    chk("TX falling nibble (0xA5)", nib(), 0xA)
    chk("TX_CTL falling (en=1,er=0)", ctl(), 0x1)

    # Test 2: TX_CTL with error, en=1 er=1
    await drive(0x3C, 1, 1)
    await RisingEdge(dut.clk_125)
    await Timer(1, "ns")
    chk("TX rising nibble (0x3C)", nib(), 0xC)
    chk("TX_CTL rising (en=1,er=1)", ctl(), 0x1)
    await FallingEdge(dut.clk_125)
    await Timer(1, "ns")
    chk("TX falling nibble (0x3C)", nib(), 0x3)
    chk("TX_CTL falling (en=1,er=1)", ctl(), 0x0)

    # Test 3: TX idle
    await drive(0x00, 0, 0)
    await RisingEdge(dut.clk_125)
    await Timer(1, "ns")
    chk("TX_CTL rising (idle)", ctl(), 0x0)

    # Test 4: full loopback, 8 bytes
    expected = [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF]
    await Timer(20, "ns")
    cap.restart()
    await FallingEdge(dut.clk_125)
    dut.tx_gmii_tx_en.value = 1
    dut.tx_gmii_tx_er.value = 0
    for b in expected:
        dut.tx_gmii_txd.value = b
        await FallingEdge(dut.clk_125)
    dut.tx_gmii_tx_en.value = 0
    dut.tx_gmii_txd.value = 0
    for _ in range(6):
        await RisingEdge(dut.clk_125)
    cap.capturing = False

    starts = [j for j, dv in enumerate(cap.dv) if dv]
    start_idx = starts[0] if starts else -1
    frame_len = len(starts)
    if start_idx >= 0 and frame_len == 8:
        ck.check("loopback frame length", True)
        got = cap.rxd[start_idx:start_idx + 8]
        bad = [f"byte[{k}]: got {g if g is None else hex(g)}, expected 0x{e:02x}"
               for k, (g, e) in enumerate(zip(got + [None] * (8 - len(got)), expected))
               if g != e]
        ck.check("loopback data integrity (8 bytes)", not bad, "; ".join(bad))
        ck.check("no rx_er during frame", not any(cap.er[start_idx:start_idx + 8]))
    else:
        ck.check("loopback frame found", False,
                 f"start={start_idx} len={frame_len} cap={len(cap.dv)}")

    # Test 5: TX_ER through the loopback
    await Timer(20, "ns")
    cap.restart()
    await FallingEdge(dut.clk_125)
    dut.tx_gmii_tx_en.value = 1
    dut.tx_gmii_tx_er.value = 1
    dut.tx_gmii_txd.value = 0xFF
    await FallingEdge(dut.clk_125)
    dut.tx_gmii_txd.value = 0x00
    await FallingEdge(dut.clk_125)
    dut.tx_gmii_tx_en.value = 0
    dut.tx_gmii_tx_er.value = 0
    dut.tx_gmii_txd.value = 0x00
    for _ in range(6):
        await RisingEdge(dut.clk_125)
    cap.capturing = False

    starts = [j for j, dv in enumerate(cap.dv) if dv]
    if starts:
        ck.check("rx_er propagated through DDR loopback", cap.er[starts[0]],
                 f"start={starts[0]}, er={int(cap.er[starts[0]])}")
    else:
        ck.check("rx_er propagated through DDR loopback", False,
                 "tx_er frame not received")

    await Timer(20, "ns")
    ck.finish()
