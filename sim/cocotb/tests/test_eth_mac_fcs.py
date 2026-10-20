# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""cocotb port of sim/tb/tb_eth_mac_fcs.v (build_and_test.py bench ETH-MAC-FCS).

DUT: eth_mac_tx (default MAX_FRAME), tx_start_ok tied high. One 74-byte frame
(dst DA:02:03:04:05:06, src 02:00:00:00:00:01, type 0x0800, then
byte i = 3*i & 0xFF) is streamed in right after rising edges, as the bench
does; the GMII wire is captured at every rising edge into a 256-byte buffer
(count reset when gmii_tx_en rises). 2000 ns after the last beat it checks,
in the bench's order:

1. wire length == FRAME_LEN + 12 (preamble/SFD 8 + 74 + FCS 4)
2. the emitted FCS (wire bytes 82..85, LSB first) == ~CRC32(frame)
3. CRC32 residue over wire bytes 8..end (raw) == 0xDEBB20E3
4. complemented residue == 0x2144DF1C
5. gmii_tx_er low at the end (the bench prints TESTS FAILED otherwise)

No randomness in this bench.
"""
import cocotb
from cocotb.triggers import RisingEdge, Timer

from lib.bench import Checks
from lib.txpath_bench import axis_accept, crc_raw, is1, sample_before_rise, start_clock, val


SUITES = {
    "eth_mac_fcs": {
        "toplevel": "eth_mac_tx",
        "sources": ["rtl/crc32.v", "rtl/eth_mac_tx.v"],
        "params": {},
    },
}

FRAME_LEN = 74
FRAME = bytes([0xDA, 0x02, 0x03, 0x04, 0x05, 0x06,
               0x02, 0x00, 0x00, 0x00, 0x00, 0x01,
               0x08, 0x00] + [(i * 3) & 0xFF for i in range(14, FRAME_LEN)])


class WireCapture:
    """always @(posedge clk or negedge rst_n): prev_tx_en / wire_count / wire_buf."""

    def __init__(self, dut):
        self.dut = dut
        self.buf = [None] * 256
        self.count = 0
        self.prev_en = 0

    async def run(self):
        dut = self.dut
        while True:
            await sample_before_rise(dut.clk)
            if not is1(dut.rst_n):
                self.prev_en = 0
                self.count = 0
                continue
            en = is1(dut.gmii_tx_en)
            txd = val(dut.gmii_txd)
            count = self.count
            if not self.prev_en and en:
                count = 0
            if en and self.count < 256:
                self.buf[self.count] = txd
                count = self.count + 1
            self.count = count
            self.prev_en = int(en)


@cocotb.test()
async def eth_mac_fcs(dut):
    chk = Checks(dut._log)
    dut.rst_n.value = 0
    dut.tx_start_ok.value = 1
    dut.s_axis_tkeep.value = 1
    dut.s_axis_tdata.value = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    start_clock(dut.clk, 10)
    cap = WireCapture(dut)
    cocotb.start_soon(cap.run())

    await Timer(100, "ns")
    dut.rst_n.value = 1
    await Timer(100, "ns")

    await RisingEdge(dut.clk)
    dut.s_axis_tvalid.value = 1
    dut.s_axis_tdata.value = FRAME[0]
    dut.s_axis_tlast.value = int(FRAME_LEN == 1)
    for idx in range(1, FRAME_LEN):
        await axis_accept(dut.clk, dut.s_axis_tready)
        dut.s_axis_tdata.value = FRAME[idx]
        dut.s_axis_tlast.value = int(idx == FRAME_LEN - 1)
    await axis_accept(dut.clk, dut.s_axis_tready)
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0

    await Timer(2000, "ns")

    wc = cap.count
    chk.check("wire length", wc == FRAME_LEN + 12, f"= {wc} (expected {FRAME_LEN + 12})")

    crc_out = ~crc_raw(FRAME) & 0xFFFFFFFF
    b = cap.buf
    got = [b[FRAME_LEN + 8 + i] for i in range(4)]
    got_ok = None not in got
    got_fcs = (got[3] << 24 | got[2] << 16 | got[1] << 8 | got[0]) if got_ok else None
    chk.check("emitted FCS", got_fcs == crc_out,
              f"exp=0x{crc_out:08X} got={got}")

    residue = 0xFFFFFFFF
    resid_ok = all(x is not None for x in b[8:wc])
    if resid_ok:
        residue = crc_raw(bytes(b[8:wc]))
    chk.check("full-frame residue raw", resid_ok and residue == 0xDEBB20E3,
              f"= 0x{residue:08X} (expected 0xDEBB20E3)")
    chk.check("complemented residue",
              resid_ok and (~residue & 0xFFFFFFFF) == 0x2144DF1C,
              f"= 0x{~residue & 0xFFFFFFFF:08X} (expected 0x2144DF1C)")
    chk.check("gmii_tx_er low at the end", val(dut.gmii_tx_er) == 0)
    chk.finish()
