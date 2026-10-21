# SPDX-License-Identifier: Apache-2.0
"""cocotb port of sim/tb/tb_axilite_regs.v (build_and_test.py bench AXILITE-REGS).

Same DUT (axilite_regs, ADDR_WIDTH=8), same 100 MHz clock starting low, same
reset timing, same tie-offs (dbg_saf, the extended stat inputs and the pause
counters at 0) and the same AXI4-Lite tasks: inputs change on the falling
edge, handshakes complete on the rising edge where the bench sees
valid/ready. The bench reads bvalid/rvalid/awready/wready at the rising edge
before the DUT updates them; here they are read settled (ReadOnly) in the low
half of the clock just before that rising edge, which is the same value. The
expected VERSION comes from rtl/version.vh, like the bench's `include. The
bench uses no $random. Checks, in bench order:

  1   VERSION == {MAJOR, MINOR, ID}
  2   SCRATCH write/read 0xDEADBEEF, overwrite 0x12345678
  2b  IP_ADDR reset default 0xC0A889C8, write/read 0xC0A8EDC8, cfg_ip_addr
  3   CTRL default 0x23, cfg_tx_en/rx_en/promisc defaults 1/1/0;
      after CTRL=0x6: cfg_tx_en/rx_en/promisc 0/1/1 (then CTRL=0x3)
  4   MAC_LO 0xAABBCCDD, MAC_HI 0x1122, cfg_mac_addr 0x1122AABBCCDD
  5   mdio_go cleared, mdio_write 1, MDIO_CMD go bit reads 0, MDIO_RDATA 0xBEEF
  6   STATUS == 0x7 with sts_tx_active, sts_tx_fifo_busy, mdio_busy set
  7   IRQ_STATUS tx_done set, irq 1; after W1C: tx_done clear, irq 0
  8   TX_FRAME_CNT 100, RX_FRAME_CNT 50; writes to TX_FRAME and RX_ERR (the
      bench checks nothing after them)
  9   SCRATCH AW-first 0xCAFEBABE
  10  SCRATCH W-first 0x12345678
  11  SCRATCH partial strb byte0 0xAAAAAABB
  12  SCRATCH partial strb byte3 0xCCAAAABB
  13  SCRATCH partial strb byte1+2 0xCCDDEEBB
  14  SCRATCH back-to-back 0x33333333
  15  SCRATCH AW-first partial strb 0xFFFFFF42
"""
import re
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer


# Suites this module backs (read by run.py; see its docstring).
SUITES = {
    "axilite_regs": {
        "toplevel": "axilite_regs",
        "sources": ["rtl/axilite_regs.v"],
        "params": {"ADDR_WIDTH": 8},
    },
}

REPO = Path(__file__).resolve().parents[3]

A_VERSION = 0x00
A_CTRL = 0x04
A_STATUS = 0x08
A_MAC_LO = 0x0C
A_MAC_HI = 0x10
A_MDIO_CMD = 0x14
A_MDIO_WDATA = 0x18
A_MDIO_RDATA = 0x1C
A_IRQ_EN = 0x20
A_IRQ_STATUS = 0x24
A_TX_FRAME = 0x28
A_RX_FRAME = 0x30
A_RX_ERR = 0x38
A_SCRATCH = 0x3C
A_IP_ADDR = 0x40

# Inputs the bench ties to a constant 0.
TIED_ZERO = [
    "dbg_saf",
    "stat_rx_err_align_cnt", "stat_rx_err_overflow_cnt", "stat_rx_err_oversize_cnt",
    "stat_rx_bcast_cnt", "stat_rx_mcast_cnt",
    "stat_rx_size_64_cnt", "stat_rx_size_65_127_cnt", "stat_rx_size_128_255_cnt",
    "stat_rx_size_256_511_cnt", "stat_rx_size_512_1023_cnt",
    "stat_rx_size_1024_1518_cnt", "stat_rx_size_jumbo_cnt",
    "stat_rx_drop_cnt", "stat_rx_err_csum_cnt",
    "stat_pause_rx_cnt", "stat_pause_tx_cnt",
]


def expected_version():
    """{MAJOR, MINOR, ID} from rtl/version.vh, as the bench's `include gives it."""
    text = (REPO / "rtl" / "version.vh").read_text(encoding="utf-8")

    def define(name):
        m = re.search(rf"`define\s+{name}\s+\d+'h([0-9A-Fa-f_]+)", text)
        assert m, f"{name} not found in rtl/version.vh"
        return int(m.group(1).replace("_", ""), 16)

    return ((define("EMZ_VERSION_MAJOR") << 24) | (define("EMZ_VERSION_MINOR") << 16)
            | define("EMZ_VERSION_ID"))


class Checks:
    """PASS/FAIL bookkeeping like the bench: log every check, fail at the end."""

    def __init__(self, log):
        self.log = log
        self.passed = 0
        self.failed = 0

    def eq(self, name, actual, expected, digits=8):
        """actual: a LogicArray/Logic (from .value) or an int."""
        if hasattr(actual, "is_resolvable") and not actual.is_resolvable:
            self.log.error(f"FAIL: {name} = {actual}, expected 0x{expected:0{digits}x}")
            self.failed += 1
            return
        a = int(actual)
        if a == expected:
            self.log.info(f"PASS: {name} = 0x{a:0{digits}x}")
            self.passed += 1
        else:
            self.log.error(f"FAIL: {name} = 0x{a:0{digits}x}, expected 0x{expected:0{digits}x}")
            self.failed += 1

    def finish(self):
        if self.failed == 0:
            self.log.info(f"PASS: {self.passed} tests passed")
        assert self.failed == 0, f"{self.passed} passed, {self.failed} failed"


class AxiLite:
    """The bench's axi_write / axi_write_aw_first / axi_write_w_first /
    axi_write_strb / axi_read tasks."""

    def __init__(self, dut):
        self.dut = dut
        self.clk = dut.s_axi_aclk

    async def _wait_high_then_edge(self, sig, capture=None):
        """Bench: `@(posedge clk); while (!sig) @(posedge clk);` then `@(negedge clk)`.
        Called right after driving on a falling edge. Returns `capture`'s value
        at the rising edge where sig was seen high."""
        while True:
            await ReadOnly()          # settled value the next rising edge samples
            if int(sig.value):
                got = capture.value if capture is not None else None
                break
            await RisingEdge(self.clk)
            await FallingEdge(self.clk)
        await RisingEdge(self.clk)    # the edge where the bench sees it high
        await FallingEdge(self.clk)   # the bench's @(negedge clk)
        return got

    async def write(self, addr, data, strobe=0xF):
        d = self.dut
        await FallingEdge(self.clk)
        d.s_axi_awaddr.value = addr
        d.s_axi_awvalid.value = 1
        d.s_axi_wdata.value = data
        d.s_axi_wstrb.value = strobe
        d.s_axi_wvalid.value = 1
        d.s_axi_bready.value = 1
        await self._wait_high_then_edge(d.s_axi_bvalid)
        d.s_axi_awvalid.value = 0
        d.s_axi_wvalid.value = 0
        d.s_axi_bready.value = 0

    async def write_strb(self, addr, data, strobe):
        await self.write(addr, data, strobe)

    async def write_aw_first(self, addr, data, strobe):
        d = self.dut
        await FallingEdge(self.clk)
        d.s_axi_awaddr.value = addr
        d.s_axi_awvalid.value = 1
        d.s_axi_wvalid.value = 0
        d.s_axi_bready.value = 1
        await self._wait_high_then_edge(d.s_axi_awready)
        d.s_axi_awvalid.value = 0
        await FallingEdge(self.clk)
        d.s_axi_wdata.value = data
        d.s_axi_wstrb.value = strobe
        d.s_axi_wvalid.value = 1
        await self._wait_high_then_edge(d.s_axi_bvalid)
        d.s_axi_wvalid.value = 0
        d.s_axi_bready.value = 0

    async def write_w_first(self, addr, data, strobe):
        d = self.dut
        await FallingEdge(self.clk)
        d.s_axi_wdata.value = data
        d.s_axi_wstrb.value = strobe
        d.s_axi_wvalid.value = 1
        d.s_axi_awvalid.value = 0
        d.s_axi_bready.value = 1
        await self._wait_high_then_edge(d.s_axi_wready)
        d.s_axi_wvalid.value = 0
        await FallingEdge(self.clk)
        d.s_axi_awaddr.value = addr
        d.s_axi_awvalid.value = 1
        await self._wait_high_then_edge(d.s_axi_bvalid)
        d.s_axi_awvalid.value = 0
        d.s_axi_bready.value = 0

    async def read(self, addr):
        d = self.dut
        await FallingEdge(self.clk)
        d.s_axi_araddr.value = addr
        d.s_axi_arvalid.value = 1
        d.s_axi_rready.value = 1
        data = await self._wait_high_then_edge(d.s_axi_rvalid, capture=d.s_axi_rdata)
        d.s_axi_arvalid.value = 0
        d.s_axi_rready.value = 0
        return data


async def posedge_plus1(dut):
    """The bench's `@(posedge clk); #1;`."""
    await RisingEdge(dut.s_axi_aclk)
    await Timer(1, "ns")


@cocotb.test(timeout_time=100, timeout_unit="us")
async def axilite_regs_tests(dut):
    """Tests 1..15 in bench order."""
    cocotb.start_soon(Clock(dut.s_axi_aclk, 10, unit="ns").start(start_high=False))
    chk = Checks(dut._log)
    axi = AxiLite(dut)

    dut.s_axi_aresetn.value = 0
    dut.s_axi_awaddr.value = 0
    dut.s_axi_awvalid.value = 0
    dut.s_axi_wdata.value = 0
    dut.s_axi_wstrb.value = 0
    dut.s_axi_wvalid.value = 0
    dut.s_axi_bready.value = 0
    dut.s_axi_araddr.value = 0
    dut.s_axi_arvalid.value = 0
    dut.s_axi_rready.value = 0
    dut.mdio_rdata.value = 0xBEEF
    dut.mdio_done.value = 0
    dut.mdio_busy.value = 0
    dut.stat_tx_frame_cnt.value = 100
    dut.stat_tx_byte_cnt.value = 2000
    dut.stat_rx_frame_cnt.value = 50
    dut.stat_rx_byte_cnt.value = 1000
    dut.stat_rx_err_cnt.value = 3
    dut.sts_tx_active.value = 0
    dut.sts_tx_fifo_busy.value = 0
    dut.evt_tx_done.value = 0
    dut.evt_rx_frame.value = 0
    for name in TIED_ZERO:
        getattr(dut, name).value = 0

    await Timer(30, "ns")
    dut.s_axi_aresetn.value = 1
    await posedge_plus1(dut)

    # Test 1: VERSION (read-only)
    chk.eq("VERSION", await axi.read(A_VERSION), expected_version())

    # Test 2: SCRATCH write/read
    await axi.write(A_SCRATCH, 0xDEADBEEF)
    chk.eq("SCRATCH write/read", await axi.read(A_SCRATCH), 0xDEADBEEF)
    await axi.write(A_SCRATCH, 0x12345678)
    chk.eq("SCRATCH overwrite", await axi.read(A_SCRATCH), 0x12345678)

    # Test 2b: IP_ADDR reset default, RW, output
    chk.eq("IP_ADDR reset default", await axi.read(A_IP_ADDR), 0xC0A889C8)
    await axi.write(A_IP_ADDR, 0xC0A8EDC8)
    chk.eq("IP_ADDR write/read", await axi.read(A_IP_ADDR), 0xC0A8EDC8)
    chk.eq("cfg_ip_addr output", dut.cfg_ip_addr.value, 0xC0A8EDC8)

    # Test 3: CTRL + config outputs
    chk.eq("CTRL default", await axi.read(A_CTRL), 0x00000023)
    chk.eq("cfg_tx_en default", dut.cfg_tx_en.value, 1, 1)
    chk.eq("cfg_rx_en default", dut.cfg_rx_en.value, 1, 1)
    chk.eq("cfg_promisc default", dut.cfg_promisc.value, 0, 1)
    await axi.write(A_CTRL, 0x00000006)
    await posedge_plus1(dut)
    chk.eq("cfg_tx_en after write", dut.cfg_tx_en.value, 0, 1)
    chk.eq("cfg_rx_en after write", dut.cfg_rx_en.value, 1, 1)
    chk.eq("cfg_promisc after write", dut.cfg_promisc.value, 1, 1)
    await axi.write(A_CTRL, 0x00000003)

    # Test 4: MAC address
    await axi.write(A_MAC_LO, 0xAABBCCDD)
    await axi.write(A_MAC_HI, 0x00001122)
    await posedge_plus1(dut)
    chk.eq("MAC_LO", await axi.read(A_MAC_LO), 0xAABBCCDD)
    chk.eq("MAC_HI", await axi.read(A_MAC_HI), 0x00001122)
    chk.eq("cfg_mac_addr", dut.cfg_mac_addr.value, 0x1122AABBCCDD, 12)

    # Test 5: MDIO command, go bit self-clearing
    await axi.write(A_MDIO_WDATA, 0x0000FACE)
    await axi.write(A_MDIO_CMD, 0x00000C63)   # go=1, write=1, phy=3, reg=3
    await posedge_plus1(dut)
    chk.eq("mdio_go cleared", dut.mdio_go.value, 0, 1)
    chk.eq("mdio_write", dut.mdio_write.value, 1, 1)
    chk.eq("MDIO_CMD go reads 0", int(await axi.read(A_MDIO_CMD)) & 0x800, 0)
    chk.eq("MDIO_RDATA", await axi.read(A_MDIO_RDATA), 0x0000BEEF)

    # Test 6: STATUS
    dut.sts_tx_active.value = 1
    dut.sts_tx_fifo_busy.value = 1
    dut.mdio_busy.value = 1
    await posedge_plus1(dut)
    chk.eq("STATUS all set", await axi.read(A_STATUS), 0x00000007)
    dut.sts_tx_active.value = 0
    dut.sts_tx_fifo_busy.value = 0
    dut.mdio_busy.value = 0

    # Test 7: IRQ event capture, enable, W1C
    await axi.write(A_IRQ_EN, 0x00000005)
    await FallingEdge(dut.s_axi_aclk)
    dut.evt_tx_done.value = 1
    await FallingEdge(dut.s_axi_aclk)
    dut.evt_tx_done.value = 0
    await posedge_plus1(dut)
    chk.eq("IRQ_STATUS tx_done set", int(await axi.read(A_IRQ_STATUS)) & 1, 1)
    chk.eq("irq asserted", dut.irq.value, 1, 1)
    await axi.write(A_IRQ_STATUS, 0x00000001)
    await posedge_plus1(dut)
    chk.eq("IRQ_STATUS tx_done cleared", int(await axi.read(A_IRQ_STATUS)) & 1, 0)
    chk.eq("irq deasserted", dut.irq.value, 0, 1)

    # Test 8: stats read + clear-on-write (the bench checks only the reads)
    chk.eq("TX_FRAME_CNT", await axi.read(A_TX_FRAME), 100)
    chk.eq("RX_FRAME_CNT", await axi.read(A_RX_FRAME), 50)
    await axi.write(A_TX_FRAME, 0)
    await posedge_plus1(dut)
    await axi.write(A_RX_ERR, 0)
    await posedge_plus1(dut)

    # Test 9: AW before W
    await axi.write_aw_first(A_SCRATCH, 0xCAFEBABE, 0xF)
    chk.eq("SCRATCH AW-first", await axi.read(A_SCRATCH), 0xCAFEBABE)

    # Test 10: W before AW
    await axi.write_w_first(A_SCRATCH, 0x12345678, 0xF)
    chk.eq("SCRATCH W-first", await axi.read(A_SCRATCH), 0x12345678)

    # Test 11: partial WSTRB, byte 0
    await axi.write(A_SCRATCH, 0xAAAAAAAA)
    await axi.write_strb(A_SCRATCH, 0x000000BB, 0x1)
    chk.eq("SCRATCH partial strb byte0", await axi.read(A_SCRATCH), 0xAAAAAABB)

    # Test 12: partial WSTRB, byte 3
    await axi.write_strb(A_SCRATCH, 0xCC000000, 0x8)
    chk.eq("SCRATCH partial strb byte3", await axi.read(A_SCRATCH), 0xCCAAAABB)

    # Test 13: partial WSTRB, bytes 1 and 2
    await axi.write_strb(A_SCRATCH, 0x00DDEE00, 0x6)
    chk.eq("SCRATCH partial strb byte1+2", await axi.read(A_SCRATCH), 0xCCDDEEBB)

    # Test 14: back-to-back writes
    await axi.write(A_SCRATCH, 0x11111111)
    await axi.write(A_SCRATCH, 0x22222222)
    await axi.write(A_SCRATCH, 0x33333333)
    chk.eq("SCRATCH back-to-back", await axi.read(A_SCRATCH), 0x33333333)

    # Test 15: AW-first with partial WSTRB
    await axi.write(A_SCRATCH, 0xFFFFFFFF)
    await axi.write_aw_first(A_SCRATCH, 0x00000042, 0x1)
    chk.eq("SCRATCH AW-first partial strb", await axi.read(A_SCRATCH), 0xFFFFFF42)

    await Timer(20, "ns")
    chk.finish()
