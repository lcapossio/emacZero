# SPDX-License-Identifier: Apache-2.0
"""cocotb port of sim/tb/tb_mii_store_forward.v (build_and_test.py bench
MII-STORE-FORWARD): eth_mac (defaults: MAX_FRAME 9018, MII_DEBUG 0) sends two
frames (74 and 1450 bytes) through mii_if's store-and-forward TX FIFO; the
test counts what enters the FIFO (mii_if internals tx_wr_en, tx_wr_full,
tx_len_wr_en, tx_len_wr_data, read through lib.hier) and what leaves on MII.

Same clocks (sys 100 MHz, MII 25 MHz, both low at t=0; mii_rx_clk is the same
clock as mii_tx_clk), reset release at 100 ns, frame start 500 ns later, the
bench's AXIS loop with 2 idle cycles between frames. The two counters mirror
the bench's posedge-clk and posedge-mii_clk always blocks (pre-edge values,
sampled here on the falling edge of the same clock). Waiting for each frame
uses the bench's bound of 20000 mii_clk cycles; the Python counter is visible
one edge earlier than the bench's nonblocking one, so the wait may end one
cycle sooner (the bound is not approached).

Checks, in the bench's order (any failure fails the single test):
  1. frame 0 drained to MII within 20000 mii_clk cycles.
  2. frame 1 drained to MII within 20000 mii_clk cycles.
  (then 1 us)
  3. tx_len_wr_en pulsed exactly 2 times.
  4. frame 0 queued length (tx_len_wr_data) == 86.
  5. frame 1 queued length == 1462.
  6. bytes accepted on the FIFO write side (tx_wr_en && !tx_wr_full) == 1548.
  7. bytes read out on MII (nibble pairs while mii_tx_en) == 1548.
No random stimulus.
"""
import cocotb
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from lib.hier import hier
from lib.mii_bench import eth_mac_bench_start, is0, is1, byte_or_none, send_frame_posedge

# Suites this module backs (read by run.py; see its docstring).
SUITES = {
    "mii_store_forward": {
        "toplevel": "eth_mac",
        "sources": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v", "rtl/sync_fifo.v",
                    "rtl/net/csum_calc.v", "rtl/eth_mac_rx.v", "rtl/eth_mac_tx.v",
                    "rtl/eth_mac.v"],
        "params": {},
    },
}

FRAME_LEN = [74, 1450]
FRAME_COUNT = len(FRAME_LEN)
EXPECTED_LEN = [86, 1462]


def frame_byte(fidx, bidx):
    hdr = {0: 0xDA, 1: 0x02, 2: 0x03, 3: 0x04, 4: 0x05, 5: 0x06,
           6: 0x02, 7: 0x00, 8: 0x00, 9: 0x00, 10: 0x00, 11: fidx & 0xFF,
           12: 0x08, 13: 0x00}
    if bidx in hdr:
        return hdr[bidx]
    return (bidx + fidx * 23) & 0xFF


class Counters:
    def __init__(self, dut):
        self.dut = dut
        self.wr_byte_count = 0
        self.len_pulse_count = 0
        self.len_values = [None] * FRAME_COUNT
        self.rd_byte_count = 0
        self.mii_frame_count = 0
        # mii_if internals; same names in rtl/mii_if.v and rtl/vhdl/mii_if.vhd
        self.tx_wr_en = hier(dut, "u_mii_if.tx_wr_en")
        self.tx_wr_full = hier(dut, "u_mii_if.tx_wr_full")
        self.tx_len_wr_en = hier(dut, "u_mii_if.tx_len_wr_en")
        self.tx_len_wr_data = hier(dut, "u_mii_if.tx_len_wr_data")

    async def run_wr(self):
        """always @(posedge clk): FIFO write-side byte and length-pulse counts."""
        while True:
            await FallingEdge(self.dut.clk)
            if is1(self.tx_wr_en) and is0(self.tx_wr_full):
                self.wr_byte_count += 1
            if is1(self.tx_len_wr_en):
                if self.len_pulse_count < FRAME_COUNT:
                    self.len_values[self.len_pulse_count] = byte_or_none(self.tx_len_wr_data)
                self.len_pulse_count += 1

    async def run_rd(self):
        """always @(posedge mii_clk): MII byte (nibble pair) and frame counts."""
        dut = self.dut
        prev_en = False
        nib_sel = False
        while True:
            await FallingEdge(dut.mii_tx_clk)
            en = is1(dut.mii_tx_en)
            new_nib_sel = nib_sel
            if not prev_en and en:
                new_nib_sel = False
            if en:
                if not nib_sel:
                    new_nib_sel = True
                else:
                    self.rd_byte_count += 1
                    new_nib_sel = False
            if prev_en and not en:
                self.mii_frame_count += 1
            prev_en, nib_sel = en, new_nib_sel


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def store_forward(dut):
    """Two frames through the TX store-and-forward FIFO: drain, lengths, byte counts."""
    await eth_mac_bench_start(dut)
    cnt = Counters(dut)
    cocotb.start_soon(cnt.run_wr())
    cocotb.start_soon(cnt.run_rd())

    await Timer(500, unit="ns")
    for f, n in enumerate(FRAME_LEN):
        await send_frame_posedge(dut.clk, dut.s_axis_tready, dut.s_axis_tdata,
                                 dut.s_axis_tvalid, dut.s_axis_tlast,
                                 [frame_byte(f, i) for i in range(n)])

    passes, fails = [], []
    for p in range(FRAME_COUNT):
        wait_cycles = 0
        while cnt.mii_frame_count <= p and wait_cycles < 20000:
            await RisingEdge(dut.mii_tx_clk)
            wait_cycles += 1
        if cnt.mii_frame_count > p:
            passes.append(f"frame {p} drained to MII within bound")
        else:
            fails.append(f"frame {p} never drained to MII")

    await Timer(1000, unit="ns")

    if cnt.len_pulse_count == FRAME_COUNT:
        passes.append(f"saw {FRAME_COUNT} frame length enqueue pulses")
    else:
        fails.append(f"length enqueue count {cnt.len_pulse_count} != {FRAME_COUNT}")

    for p in range(FRAME_COUNT):
        if cnt.len_values[p] == EXPECTED_LEN[p]:
            passes.append(f"frame {p} queued length {cnt.len_values[p]}")
        else:
            fails.append(f"frame {p} queued length {cnt.len_values[p]} != {EXPECTED_LEN[p]}")

    expected_mac_bytes = EXPECTED_LEN[0] + EXPECTED_LEN[1]
    if cnt.wr_byte_count == expected_mac_bytes:
        passes.append(f"write-side accepted {cnt.wr_byte_count} bytes")
    else:
        fails.append(f"write-side byte count {cnt.wr_byte_count} != {expected_mac_bytes}")

    if cnt.rd_byte_count == expected_mac_bytes:
        passes.append(f"read-side drained {cnt.rd_byte_count} bytes")
    else:
        fails.append(f"read-side byte count {cnt.rd_byte_count} != {expected_mac_bytes}")

    for msg in passes:
        dut._log.info("PASS: " + msg)
    for msg in fails:
        dut._log.error("FAIL: " + msg)
    assert not fails, f"{len(passes)} passed, {len(fails)} failed: {fails}"
