# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""cocotb port of sim/tb/tb_eth_mac_tx_pad.v (build_and_test.py bench ETH-MAC-TX-PAD).

Minimum-frame padding in both TX framers. DUT: harness
sim/cocotb/hdl/h_eth_mac_tx_pad.{v,vhd} = eth_mac_tx (GMII, 125 MHz clk) and
mii_tx_saf (MII, 25 MHz mclk) on one AXIS source, sel_gmii choosing the one
that sees tvalid and returns tready, both with RTL default parameters as in
the bench. 14, 58, 59, 60 and 61-byte frames (byte k = 0xA0 + k, no zero
bytes) go first through eth_mac_tx, then through mii_tx_saf, driven on the
falling edge of clk. The wire is captured at rising edges of clk (GMII) or
mclk (MII, low nibble first) into one shared buffer, from the byte after
the SFD; a burst counts as finished when tx_en falls. After each frame the
test waits for the burst to end plus 50 cycles and checks, per framer and
length (3 x 10 checks, in the bench's order):

1. wire length after the SFD == max(len, 60) + 4
2. pad bytes (len .. max(len, 60) - 1) all zero
3. CRC32 residue over the captured bytes == 0xDEBB20E3 (valid FCS)

The bench's 20 ms timeout is the test's timeout. No randomness.
"""
import cocotb
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer

from lib.bench import Checks
from lib.txpath_bench import crc_step, is1, start_clock, val


SUITES = {
    "eth_mac_tx_pad": {
        "toplevel": "h_eth_mac_tx_pad",
        "sources": ["rtl/async_fifo.v", "rtl/eth_mac_tx.v", "rtl/mii_tx_saf.v",
                    "sim/cocotb/hdl/h_eth_mac_tx_pad.v"],
        "params": {},
    },
}

LENS = [14, 58, 59, 60, 61]


class Wire:
    """wire_buf / wire_len / wire_frames / seen_sfd and the two capture blocks."""

    def __init__(self, dut):
        self.dut = dut
        self.buf = [None] * 128
        self.len = 0
        self.frames = 0
        self.seen_sfd = False

    def byte(self, b):
        if self.seen_sfd:
            if self.len < 128:
                self.buf[self.len] = b
            self.len += 1
        elif b == 0xD5:
            self.seen_sfd = True

    async def run_gmii(self):
        """always @(posedge clk): if (sel_gmii) {...}; g_en_d <= gmii_tx_en;"""
        dut = self.dut
        g_en_d = False
        while True:
            await FallingEdge(dut.clk)
            await ReadOnly()
            en = is1(dut.gmii_tx_en)
            txd = val(dut.gmii_txd)
            await RisingEdge(dut.clk)
            if is1(dut.sel_gmii):
                if en:
                    self.byte(txd)
                if g_en_d and not en:
                    self.frames += 1
            g_en_d = en

    async def run_mii(self):
        """always @(posedge mclk): if (!sel_gmii) {...}; m_en_d <= mii_tx_en;"""
        dut = self.dut
        m_en_d = False
        m_hi = False
        m_lo = None
        while True:
            await FallingEdge(dut.mclk)
            await ReadOnly()
            en = is1(dut.mii_tx_en)
            txd = val(dut.mii_txd)
            await RisingEdge(dut.mclk)
            if not is1(dut.sel_gmii):
                if en:
                    if not m_hi:
                        m_lo = txd
                    else:
                        self.byte(None if txd is None or m_lo is None else (txd << 4) | m_lo)
                    m_hi = not m_hi
                else:
                    m_hi = False
                if m_en_d and not en:
                    self.frames += 1
            m_en_d = en


async def send_and_check(dut, wire, chk, gmii, n):
    name = "eth_mac_tx" if gmii else "mii_tx_saf"
    clk = dut.clk
    dut.sel_gmii.value = int(gmii)
    wire.len = 0
    wire.seen_sfd = False
    frames0 = wire.frames
    for k in range(n):
        await FallingEdge(clk)
        dut.s_tdata.value = (0xA0 + k) & 0xFF
        dut.s_tvalid.value = 1
        dut.s_tlast.value = int(k == n - 1)
        # @(posedge clk); while (!s_tready) @(posedge clk);
        while True:
            await ReadOnly()
            ready = is1(dut.s_tready)
            await RisingEdge(clk)
            if ready:
                break
            await FallingEdge(clk)
    await FallingEdge(clk)
    dut.s_tvalid.value = 0
    dut.s_tlast.value = 0
    t = 0
    while wire.frames == frames0 and t < 200000:
        await FallingEdge(clk)
        t += 1
    for _ in range(50):
        await FallingEdge(clk)

    exp_len = max(n, 60) + 4
    c = 0xFFFFFFFF
    pad_bad = 0
    for k in range(min(wire.len, 128)):
        b = wire.buf[k]
        c = None if c is None or b is None else crc_step(c, b)
        if n <= k < exp_len - 4 and b is not None and b != 0x00:
            pad_bad += 1
    dut._log.info(f"INFO: {name} {n} bytes in -> {wire.len} after SFD (expect {exp_len})")
    chk.check(f"{name}: wire length", wire.len == exp_len, f"(len {n})")
    chk.check(f"{name}: pad bytes zero", pad_bad == 0, f"(len {n})")
    chk.check(f"{name}: FCS valid", c == 0xDEBB20E3, f"(len {n})")


@cocotb.test(timeout_time=20_000_000, timeout_unit="ns")
async def eth_mac_tx_pad(dut):
    chk = Checks(dut._log)
    dut.rst_n.value = 0
    dut.sel_gmii.value = 1
    dut.s_tdata.value = 0
    dut.s_tvalid.value = 0
    dut.s_tlast.value = 0
    start_clock(dut.clk, 8)
    start_clock(dut.mclk, 40)
    wire = Wire(dut)
    cocotb.start_soon(wire.run_gmii())
    cocotb.start_soon(wire.run_mii())

    await Timer(100, "ns")
    dut.rst_n.value = 1
    await Timer(200, "ns")
    for gmii in (True, False):
        for n in LENS:
            await send_and_check(dut, wire, chk, gmii, n)
    chk.finish()
