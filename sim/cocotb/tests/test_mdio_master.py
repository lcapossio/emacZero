# SPDX-License-Identifier: Apache-2.0
"""cocotb port of sim/tb/tb_mdio_master.v (build_and_test.py bench MDIO-MASTER).

Same DUT (mdio_master, default CLK_FREQ_HZ = 100 MHz so MDC = clk/100), same
100 MHz clock starting low, same reset timing, cmd_c45_en/cmd_c45_op tied to 0
as in the bench, commands driven 1 ns after a rising edge (the bench's `#1`).
The PHY model is the bench's `always @(negedge mdc)` block: armed by each read,
it counts MDC falling edges and drives 0 on edge 48 (TA[2]), D[15..0] on edges
49..64, and releases mdio_i to Z on edge 65. The 700000-cycle cmd_done timeout
counts as a failure like the bench's. The bench uses no $random. Checks, in
bench order (cmd_rdata after each read):

  1  PHYID1   read phy=1 reg=2, PHY sends 0x2000
  2  PHYID2   read phy=1 reg=3, PHY sends 0x5C90
  3  ALL-ZERO read phy=1 reg=0, PHY sends 0x0000
  4  ALL-ONES 0xFFFF
  5  LSB-SET  0x0001
  6  ALT-AA   0xAAAA
  7  ALT-55   0x5555
  8  WR->RD   write 0xBEEF to phy=1 reg=0, then read 0xBEEF
  9  BBR-1    read phy=1 reg=2 0x1234, BBR-2 read phy=1 reg=3 0x5678
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer
from cocotb.types import Logic


# Suites this module backs (read by run.py; see its docstring).
SUITES = {
    "mdio_master": {
        "toplevel": "mdio_master",
        "sources": ["rtl/mdio_master.v"],
        "params": {},
    },
}

TIMEOUT_CYCLES = 700000


class Checks:
    """PASS/FAIL bookkeeping like the bench: log every check, fail at the end."""

    def __init__(self, log):
        self.log = log
        self.passed = 0
        self.failed = 0

    def eq16(self, tag, sig, expected):
        v = sig.value
        if v.is_resolvable and int(v) == expected:
            self.log.info(f"  PASS: {tag} = 0x{int(v):04X} (expected 0x{expected:04X})")
            self.passed += 1
        else:
            self.log.error(f"  FAIL: {tag} = {v} (expected 0x{expected:04X})")
            self.failed += 1

    def fail(self, msg):
        self.log.error(msg)
        self.failed += 1

    def finish(self):
        self.log.info(f"MDIO Master Results: {self.passed} PASS, {self.failed} FAIL")
        assert self.failed == 0, f"{self.failed} check(s) failed"


class PhyModel:
    """The bench's `always @(negedge mdc)` PHY read responder."""

    def __init__(self, dut):
        self.dut = dut
        self.active = False
        self.fall_cnt = 0
        self.shift = 0

    def arm(self, data):
        self.shift = data & 0xFFFF
        self.fall_cnt = 0
        self.active = True

    async def run(self):
        dut = self.dut
        while True:
            await FallingEdge(dut.mdc)
            if not self.active:
                continue
            self.fall_cnt += 1
            if self.fall_cnt == 48:
                dut.mdio_i.value = 0                       # TA[2]
            elif 49 <= self.fall_cnt <= 64:
                dut.mdio_i.value = (self.shift >> 15) & 1  # D[15] .. D[0]
                self.shift = (self.shift << 1) & 0xFFFF
            elif self.fall_cnt > 64:
                dut.mdio_i.value = Logic("Z")              # release after D[0]
                self.active = False


async def posedge_plus1(dut):
    """The bench's `@(posedge clk); #1;`."""
    await RisingEdge(dut.clk)
    await Timer(1, "ns")


async def wait_done(dut, chk, what):
    timeout = TIMEOUT_CYCLES
    while not int(dut.cmd_done.value) and timeout > 0:
        await posedge_plus1(dut)
        timeout -= 1
    if timeout == 0:
        chk.fail(f"  ERROR: cmd_done{what} never asserted (timeout)")
    await posedge_plus1(dut)   # one extra cycle so cmd_rdata is stable


async def mdio_read(dut, chk, phy_model, phy, reg, phy_data):
    await posedge_plus1(dut)
    phy_model.arm(phy_data)
    dut.cmd_valid.value = 1
    dut.cmd_write.value = 0
    dut.cmd_phy.value = phy
    dut.cmd_reg.value = reg
    dut.cmd_wdata.value = 0
    await posedge_plus1(dut)
    dut.cmd_valid.value = 0
    await wait_done(dut, chk, "")


async def mdio_write_op(dut, chk, phy, reg, wdata):
    await posedge_plus1(dut)
    dut.cmd_valid.value = 1
    dut.cmd_write.value = 1
    dut.cmd_phy.value = phy
    dut.cmd_reg.value = reg
    dut.cmd_wdata.value = wdata
    await posedge_plus1(dut)
    dut.cmd_valid.value = 0
    await wait_done(dut, chk, " (write)")


@cocotb.test(timeout_time=50, timeout_unit="ms")
async def mdio_master_reads(dut):
    """Tests 1..9 in bench order."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start(start_high=False))
    chk = Checks(dut._log)
    phy_model = PhyModel(dut)

    dut.rst_n.value = 0
    dut.cmd_valid.value = 0
    dut.cmd_write.value = 0
    dut.cmd_phy.value = 0
    dut.cmd_reg.value = 0
    dut.cmd_wdata.value = 0
    dut.cmd_c45_en.value = 0
    dut.cmd_c45_op.value = 0
    dut.mdio_i.value = 1          # pull-up when idle
    cocotb.start_soon(phy_model.run())

    await Timer(50, "ns")
    dut.rst_n.value = 1
    await Timer(20, "ns")

    reads = [
        ("PHYID1  ", 1, 2, 0x2000),
        ("PHYID2  ", 1, 3, 0x5C90),
        ("ALL-ZERO", 1, 0, 0x0000),
        ("ALL-ONES", 1, 0, 0xFFFF),
        ("LSB-SET ", 1, 0, 0x0001),
        ("ALT-AA  ", 1, 0, 0xAAAA),
        ("ALT-55  ", 1, 0, 0x5555),
    ]
    for n, (tag, phy, reg, data) in enumerate(reads, start=1):
        dut._log.info(f"-- Test {n}: read phy={phy} reg={reg} expect 0x{data:04X} --")
        await mdio_read(dut, chk, phy_model, phy, reg, data)
        chk.eq16(tag, dut.cmd_rdata, data)

    dut._log.info("-- Test 8: Write then read (write bypass check) --")
    await mdio_write_op(dut, chk, 1, 0, 0xBEEF)
    await mdio_read(dut, chk, phy_model, 1, 0, 0xBEEF)
    chk.eq16("WR->RD  ", dut.cmd_rdata, 0xBEEF)

    dut._log.info("-- Test 9: Back-to-back reads --")
    await mdio_read(dut, chk, phy_model, 1, 2, 0x1234)
    chk.eq16("BBR-1   ", dut.cmd_rdata, 0x1234)
    await mdio_read(dut, chk, phy_model, 1, 3, 0x5678)
    chk.eq16("BBR-2   ", dut.cmd_rdata, 0x5678)

    chk.finish()
