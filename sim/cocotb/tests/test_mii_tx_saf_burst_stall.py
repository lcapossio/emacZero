# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""cocotb port of sim/tb/tb_mii_tx_saf_burst_stall.v (build_and_test.py bench
MII-TX-SAF-BURST-STALL).

Regression for the committed-frame-counter wrap in mii_tx_saf: 80 frames of
106 bytes (80*106 = 8480 B, twice the 4096 B FIFO) are sent back to back with
the bench's falling-edge AXIS task (one idle cycle between frames, no bubbles),
so more than 15 small frames pile up ahead of the 25 MHz MII side. Byte 0 of
frame i is i & 0xFF, byte k is k. The MII wire is reassembled at every MII
rising edge and the first payload byte (wire byte 8) of each frame recorded.

DUT: mii_tx_saf, MAX_FRAME=1518, FIFO_ADDR_WIDTH=12, tx_start_ok high,
100 MHz / 25 MHz clocks. Checks, 1.2 ms after the last frame is accepted, in
the bench's order:

1. all 80 frames appeared on the MII wire
2. (only if 1 passed, as in the bench) frame i's first payload byte == i & 0xFF,
   one check per frame

The bench's 4 ms hard timeout is the test's timeout. No randomness.
"""
import cocotb
from cocotb.triggers import Timer

from lib.bench import Checks
from lib.txpath_bench import MiiNibbleCapture, saf_send_frame, start_clock, val


SUITES = {
    "mii_tx_saf_burst_stall": {
        "toplevel": "mii_tx_saf",
        "sources": ["rtl/async_fifo.v", "rtl/mii_tx_saf.v"],
        "params": {"MAX_FRAME": 1518, "FIFO_ADDR_WIDTH": 12},
    },
}

N_FRAMES = 80
FRAME_LEN = 106


@cocotb.test(timeout_time=4_000_000, timeout_unit="ns")
async def mii_tx_saf_burst_stall(dut):
    chk = Checks(dut._log)
    dut.rst_n.value = 0
    dut.tx_start_ok.value = 1
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    start_clock(dut.clk, 10)
    start_clock(dut.mii_tx_clk, 40)

    rx_first = [None] * N_FRAMES
    st = {"rx_frames": 0}

    def on_byte(widx, b):
        if widx == 8 and st["rx_frames"] < N_FRAMES:
            rx_first[st["rx_frames"]] = b

    def on_frame(_):
        st["rx_frames"] += 1

    cap = MiiNibbleCapture(dut, dut.mii_tx_clk, on_byte=on_byte, on_frame=on_frame)
    cocotb.start_soon(cap.run())

    await Timer(200, "ns")
    dut.rst_n.value = 1
    await Timer(200, "ns")

    for i in range(N_FRAMES):
        await saf_send_frame(dut, FRAME_LEN, first=i & 0xFF)

    await Timer(1_200_000, "ns")

    dut._log.info(f"INFO: sent {N_FRAMES} frames, {st['rx_frames']} appeared on the MII "
                  f"wire, tx_fifo_level={val(dut.tx_fifo_level)}")
    rx_frames = st["rx_frames"]
    chk.check("all frames transmitted", rx_frames == N_FRAMES,
              f"{rx_frames}/{N_FRAMES}" + ("" if rx_frames == N_FRAMES else
                                          " (framer stalled: committed-frame counter wrap?)"))
    if rx_frames == N_FRAMES:
        for i in range(N_FRAMES):
            chk.check(f"frame {i} first payload byte", rx_first[i] == (i & 0xFF),
                      f"= {rx_first[i]}, expected 0x{i & 0xFF:02x}")
    chk.finish()
