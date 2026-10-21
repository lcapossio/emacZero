# SPDX-License-Identifier: Apache-2.0
"""cocotb port of sim/tb/tb_eth_mac_multiframe.v (build_and_test.py bench
ETH-MAC-MULTIFRAME): eth_mac (defaults: MAX_FRAME 9018, MII_DEBUG 0) sends
three frames (74, 1450, 512 bytes) back to back over MII TX; the MII nibble
stream is reassembled and checked.

Same clocks (sys 100 MHz, MII 25 MHz, both low at t=0; mii_rx_clk is the same
clock as mii_tx_clk), reset release at 100 ns, frame start 500 ns later, the
bench's AXIS loop with 2 idle cycles between frames, then 700 us of drain.
The capture mirrors the bench's posedge-mii_clk always block (pre-edge values,
sampled here on the falling edge).

Checks, in the bench's order (any failure fails the single test):
  1. MII frame count == 3.
  2. per frame: wire length (bytes from preamble to FCS) == frame_len + 12.
  3. per frame: bytes 0..6 are 0x55 (first mismatch only).
  4. per frame: byte 7 is the SFD 0xD5.
  5. per frame: wire bytes 8..21 == frame bytes 0..13 (first mismatch only).
No random stimulus.
"""
import cocotb
from cocotb.triggers import FallingEdge, Timer

from lib.mii_bench import eth_mac_bench_start, is1, byte_or_none, send_frame_posedge

# Suites this module backs (read by run.py; see its docstring).
SUITES = {
    "eth_mac_multiframe": {
        "toplevel": "eth_mac",
        "sources": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v", "rtl/sync_fifo.v",
                    "rtl/net/csum_calc.v", "rtl/eth_mac_rx.v", "rtl/eth_mac_tx.v",
                    "rtl/eth_mac.v"],
        "params": {},
    },
}

FRAME_LEN = [74, 1450, 512]
FRAME_COUNT = len(FRAME_LEN)


def frame_byte(fidx, bidx):
    hdr = {0: 0xDA, 1: 0x02, 2: 0x03, 3: 0x04, 4: 0x05, 5: 0x06,
           6: 0x02, 7: 0x00, 8: 0x00, 9: 0x00, 10: 0x00, 11: fidx & 0xFF,
           12: 0x08, 13: 0x00}
    if bidx in hdr:
        return hdr[bidx]
    return (bidx + fidx * 17) & 0xFF


class MiiWireCapture:
    """The bench's posedge-mii_clk capture: per frame, bytes and length."""

    def __init__(self, dut, n_frames):
        self.dut = dut
        self.n_frames = n_frames
        self.frames = [dict() for _ in range(n_frames)]   # idx -> byte (None = X)
        self.lens = [None] * n_frames
        self.frame_idx = 0

    async def run(self):
        dut = self.dut
        prev_en = False
        nib_sel = False
        low = 0
        count = 0
        while True:
            await FallingEdge(dut.mii_tx_clk)
            en = is1(dut.mii_tx_en)
            txd = byte_or_none(dut.mii_txd)
            new_nib_sel, new_count = nib_sel, count
            if not prev_en and en:
                new_nib_sel, new_count = False, 0
            if en:
                if not nib_sel:
                    low = txd
                    new_nib_sel = True
                else:
                    if self.frame_idx < self.n_frames:
                        b = None if (txd is None or low is None) else (txd << 4) | low
                        self.frames[self.frame_idx][count] = b
                    new_count = count + 1
                    new_nib_sel = False
            if prev_en and not en:
                if self.frame_idx < self.n_frames:
                    self.lens[self.frame_idx] = count
                self.frame_idx += 1
            prev_en, nib_sel, count = en, new_nib_sel, new_count


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def multiframe(dut):
    """Three back-to-back frames on MII TX: count, length, preamble, SFD, header."""
    await eth_mac_bench_start(dut)
    cap = MiiWireCapture(dut, FRAME_COUNT)
    cocotb.start_soon(cap.run())

    await Timer(500, unit="ns")
    for f, n in enumerate(FRAME_LEN):
        await send_frame_posedge(dut.clk, dut.s_axis_tready, dut.s_axis_tdata,
                                 dut.s_axis_tvalid, dut.s_axis_tlast,
                                 [frame_byte(f, i) for i in range(n)])
    await Timer(700_000, unit="ns")

    fails = []
    if cap.frame_idx != FRAME_COUNT:
        fails.append(f"MII frame count mismatch {cap.frame_idx} != {FRAME_COUNT}")
    for f in range(FRAME_COUNT):
        wlen = cap.lens[f]
        buf = cap.frames[f]
        dut._log.info(f"Frame {f}: MII bytes={wlen}")
        if wlen is None:
            # Never captured: the bench's wire_frame_len is X there, so its
            # length / preamble / SFD / header comparisons are all false and
            # only the frame-count check above reports the missing frame.
            continue
        if wlen != FRAME_LEN[f] + 12:
            fails.append(f"frame {f} length mismatch expected {FRAME_LEN[f] + 12} got {wlen}")
        wl = wlen
        for i in range(min(7, wl)):
            if buf.get(i) != 0x55:
                fails.append(f"frame {f} preamble byte {i} mismatch {buf.get(i)}")
                break
        if wl > 7 and buf.get(7) != 0xD5:
            fails.append(f"frame {f} missing SFD {buf.get(7)}")
        for i in range(14):
            if 8 + i >= wl:
                break
            if buf.get(8 + i) != frame_byte(f, i):
                fails.append(f"frame {f} payload/header byte {i} mismatch "
                             f"exp={frame_byte(f, i):02x} got={buf.get(8 + i)}")
                break
    for msg in fails:
        dut._log.error("FAIL: " + msg)
    assert not fails, f"{len(fails)} check(s) failed: {fails}"
