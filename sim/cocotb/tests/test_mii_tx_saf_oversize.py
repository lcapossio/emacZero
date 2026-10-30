# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""cocotb port of sim/tb/tb_mii_tx_saf_oversize.v (build_and_test.py bench
MII-TX-SAF-OVERSIZE).

Regression for the uncommitted-data deadlock in mii_tx_saf (bug #2): a single
run of bytes longer than the FIFO must not wedge the TX path. Sequence, with
the bench's falling-edge AXIS task (per-call watchdog of 200000 cycles without
a transfer, then one more falling edge with tvalid/tlast low):

- frame A: 64 bytes, first byte 0xAA, tlast; then 400 us
- oversized run: 5000 bytes (> 4096-byte FIFO), first byte 0x50, tlast on the
  last byte; then 1.5 ms
- frame B: 64 bytes, first byte 0xBB, tlast; then 1.5 ms

The MII wire is reassembled at every MII rising edge; wire byte 8 (first
payload byte) of each frame sets saw_A / saw_B when it is 0xAA / 0xBB.

DUT: mii_tx_saf, MAX_FRAME=1518, FIFO_ADDR_WIDTH=12, tx_start_ok high,
100 MHz / 25 MHz clocks. Checks, in the bench's order:

1. saw_A (TX works before the oversized run)
2. saw_B (TX recovered after it)

The bench's 8 ms hard timeout is the test's timeout. No randomness.
"""
import cocotb
from cocotb.triggers import Timer

from lib.bench import Checks
from lib.txpath_bench import MiiNibbleCapture, saf_send_frame, start_clock, val


SUITES = {
    "mii_tx_saf_oversize": {
        "toplevel": "mii_tx_saf",
        "sources": ["rtl/async_fifo.v", "rtl/mii_tx_saf.v"],
        "params": {"MAX_FRAME": 1518, "FIFO_ADDR_WIDTH": 12},
    },
}

OVERSIZE = 5000
A_TAG, B_TAG, O_TAG = 0xAA, 0xBB, 0x50


@cocotb.test(timeout_time=8_000_000, timeout_unit="ns")
async def mii_tx_saf_oversize(dut):
    chk = Checks(dut._log)
    dut.rst_n.value = 0
    dut.tx_start_ok.value = 1
    dut.ctl_axis_tdata.value = 0
    dut.ctl_axis_tvalid.value = 0
    dut.ctl_axis_tlast.value = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    start_clock(dut.clk, 10)
    start_clock(dut.mii_tx_clk, 40)

    st = {"rx_frames": 0, "saw_A": 0, "saw_B": 0}

    def on_byte(widx, b):
        if widx == 8:
            if b == A_TAG:
                st["saw_A"] = 1
            if b == B_TAG:
                st["saw_B"] = 1

    def on_frame(_):
        st["rx_frames"] += 1

    cap = MiiNibbleCapture(dut, dut.mii_tx_clk, on_byte=on_byte, on_frame=on_frame)
    cocotb.start_soon(cap.run())

    async def send(plen, tag):
        return await saf_send_frame(dut, plen, first=tag, set_last=True,
                                    watchdog=200_000, trailing_idle=True)

    await Timer(200, "ns")
    dut.rst_n.value = 1
    await Timer(200, "ns")

    await send(64, A_TAG)
    await Timer(400_000, "ns")
    await send(OVERSIZE, O_TAG)
    await Timer(1_500_000, "ns")
    await send(64, B_TAG)
    await Timer(1_500_000, "ns")

    dbg = val(dut.dbg_saf)
    dut._log.info(f"INFO: rx_frames={st['rx_frames']} saw_A={st['saw_A']} "
                  f"saw_B={st['saw_B']} tx_fifo_level={val(dut.tx_fifo_level)} "
                  f"dbg_saf={'X' if dbg is None else f'0x{dbg:04x}'}")
    chk.check("frame A transmitted", st["saw_A"] == 1,
              "(TX broken before the oversized run)" if not st["saw_A"] else "")
    chk.check("frame B transmitted", st["saw_B"] == 1,
              "(TX deadlocked by the oversized run)" if not st["saw_B"] else "")
    chk.finish()
