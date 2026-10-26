# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""eth_mac_tx: tx_start_ok falling on the cycle a first byte is handshaken.

DUT: rtl/eth_mac_tx.v (or its VHDL port) alone, RTL default parameters,
125 MHz clk. s_axis_tready is registered from tx_start_ok, so when
tx_start_ok falls (in eth_mac_sys: an inbound PAUSE loads the pause timer)
the framer can still be offering tready for one cycle. A first byte handshaken in that cycle has been accepted as far
as the source can tell. Before the fix the framer dropped it and, once
tx_start_ok rose, sent the frame from byte 2 with a valid FCS.

For each frame length (1, 2, 59, 60, 61 and 200 bytes, byte k = 0x30 + k)
and each case:

- "same cycle": tx_start_ok falls in the cycle the first byte is offered
  with tready high, and stays low for HOLD cycles (1, 3 and 50);
- "before": tx_start_ok falls a cycle before the first byte is offered, for
  50 cycles (tready must stay low, so no byte is taken while it is low);

the source drives the frame on falling edges of clk, holding each byte
until a rising edge sees tready high. The wire is captured at rising edges
from the byte after the SFD until tx_en falls. Checks per frame:

1. tx_en stays low while tx_start_ok is low (no frame starts while blocked)
2. the bytes after the SFD are the frame, zero padded to 60, then its FCS
3. "before" only: no handshake while tx_start_ok is low

No randomness.
"""
import cocotb
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer

from lib.bench import Checks
from lib.txpath_bench import crc_raw, is1, start_clock, val


SUITES = {
    "eth_mac_tx_start": {
        "toplevel": "eth_mac_tx",
        "sources": ["rtl/eth_mac_tx.v"],
        "params": {},
    },
}

LENS = [1, 2, 59, 60, 61, 200]
HOLDS = [1, 3, 50]


class Wire:
    """Bytes after the SFD of each burst, and tx_en seen while blocked."""

    def __init__(self, dut):
        self.dut = dut
        self.buf = []
        self.frames = 0
        self.seen_sfd = False
        self.en_while_blocked = 0

    async def run(self):
        dut = self.dut
        en_d = False
        while True:
            await FallingEdge(dut.clk)
            await ReadOnly()
            en = is1(dut.gmii_tx_en)
            txd = val(dut.gmii_txd)
            blocked = val(dut.tx_start_ok) == 0
            await RisingEdge(dut.clk)
            if en and blocked and not en_d:
                self.en_while_blocked += 1
            if en:
                if self.seen_sfd:
                    self.buf.append(txd)
                elif txd == 0xD5:
                    self.seen_sfd = True
            if en_d and not en:
                self.frames += 1
                self.seen_sfd = False
            en_d = en


async def release_after(dut, cycles):
    for _ in range(cycles):
        await FallingEdge(dut.clk)
    dut.tx_start_ok.value = 1


async def send(dut, wire, chk, n, case, hold):
    clk = dut.clk
    tag = f"(len {n}, {case}, hold {hold})"
    data = [(0x30 + k) & 0xFF for k in range(n)]
    # settle in S_IDLE with tready high
    while True:
        await FallingEdge(clk)
        await ReadOnly()
        if is1(dut.s_axis_tready):
            break
    wire.buf = []
    wire.en_while_blocked = 0
    frames0 = wire.frames
    taken_blocked = 0

    if case == "before":
        await FallingEdge(clk)
        dut.tx_start_ok.value = 0
        cocotb.start_soon(release_after(dut, hold))

    for k, b in enumerate(data):
        await FallingEdge(clk)
        dut.s_axis_tdata.value = b
        dut.s_axis_tvalid.value = 1
        dut.s_axis_tlast.value = int(k == n - 1)
        if k == 0 and case == "same cycle":
            dut.tx_start_ok.value = 0
            cocotb.start_soon(release_after(dut, hold))
        while True:
            await ReadOnly()
            ready = is1(dut.s_axis_tready)
            blocked = val(dut.tx_start_ok) == 0
            await RisingEdge(clk)
            if ready:
                if blocked and case == "before":
                    taken_blocked += 1
                break
            await FallingEdge(clk)
    await FallingEdge(clk)
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    t = 0
    while wire.frames == frames0 and t < 20000:
        await FallingEdge(clk)
        t += 1
    for _ in range(30):
        await FallingEdge(clk)

    body = data + [0] * max(0, 60 - n)
    fcs = crc_raw(body) ^ 0xFFFFFFFF
    exp = body + [(fcs >> (8 * i)) & 0xFF for i in range(4)]
    dut._log.info(f"INFO: {tag}: {len(wire.buf)} bytes after SFD (expect {len(exp)})")
    chk.check("no frame starts while tx_start_ok is low", wire.en_while_blocked == 0, tag)
    chk.check("frame on the wire = frame + pad + FCS", wire.buf == exp, tag)
    if case == "before":
        chk.check("no handshake while tx_start_ok is low", taken_blocked == 0, tag)


@cocotb.test(timeout_time=20_000_000, timeout_unit="ns")
async def eth_mac_tx_start(dut):
    chk = Checks(dut._log)
    dut.rst_n.value = 0
    dut.tx_start_ok.value = 1
    dut.s_axis_tdata.value = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    dut.s_axis_tkeep.value = 1
    start_clock(dut.clk, 8)
    wire = Wire(dut)
    cocotb.start_soon(wire.run())

    await Timer(100, "ns")
    dut.rst_n.value = 1
    await Timer(200, "ns")
    for n in LENS:
        for hold in HOLDS:
            await send(dut, wire, chk, n, "same cycle", hold)
        await send(dut, wire, chk, n, "before", 50)
    chk.finish()
