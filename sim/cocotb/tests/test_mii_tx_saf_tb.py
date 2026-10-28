# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""cocotb port of sim/tb/tb_mii_tx_saf.v (build_and_test.py bench MII-TX-SAF).

Not to be confused with test_mii_tx_saf.py, the separate randomized suite.

DUT: mii_tx_saf, MAX_FRAME=1518, FIFO_ADDR_WIDTH=12, tx_start_ok tied high,
100 MHz sys clock, 25 MHz MII clock. Four frames (payload byte k = k) are
sent with the bench's falling-edge AXIS task and bubble modes: 60 bytes
continuous, 64 bytes with a one-cycle gap before every byte, 46 bytes with a
40-cycle stall at mid-frame, 100 bytes with per-byte gaps. The MII wire is
reassembled at every MII rising edge. Checks, in the bench's order:

1. per frame, when tx_en falls (4 checks): 7x 0x55 + 0xD5, payload bytes
   0..len-1, zero pad up to 60, FCS (LSB first) == ~CRC32(data+pad), and
   wire length == 8 + max(len, 60) + 4 - one check per frame, as in the bench
2. 200 us after the last frame is accepted: 4 frames seen
3. tx_byte_stb pulses counted at sys rising edges == the wire bytes of the four
   frames (8+60+4 + 8+64+4 + 8+60+4 + 8+100+4)

No randomness in this bench.
"""
import cocotb
from cocotb.triggers import Timer

from lib.bench import Checks
from lib.txpath_bench import (MiiNibbleCapture, crc_raw, is1, saf_send_frame,
                               sample_before_rise, start_clock)


SUITES = {
    "mii_tx_saf_tb": {
        "toplevel": "mii_tx_saf",
        "sources": ["rtl/async_fifo.v", "rtl/mii_tx_saf.v"],
        "params": {"MAX_FRAME": 1518, "FIFO_ADDR_WIDTH": 12},
    },
}

FRAMES = [(60, 0), (64, 1), (46, 2), (100, 1)]   # (payload length, bubble mode)


@cocotb.test()
async def mii_tx_saf_tb(dut):
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

    exp_len = [plen for plen, _ in FRAMES]
    wbuf = [None] * 2048           # never cleared between frames, as in the bench
    state = {"rx_fidx": 0}

    def on_byte(i, b):
        if i < len(wbuf):
            wbuf[i] = b

    def check_frame(wl):
        fidx = state["rx_fidx"]
        state["rx_fidx"] += 1
        plen = exp_len[fidx] if fidx < len(exp_len) else None
        if plen is None:          # exp_len[] has no entry: the bench compares X
            chk.check(f"frame {fidx}", False, f"wire_len={wl} (unexpected frame)")
            return
        dplen = max(plen, 60)
        wexp = 8 + dplen + 4
        bad = any(wbuf[k] != 0x55 for k in range(7)) or wbuf[7] != 0xD5
        bad |= any(wbuf[8 + k] != (k & 0xFF) for k in range(plen))
        bad |= any(wbuf[8 + k] != 0x00 for k in range(plen, 60))
        data = wbuf[8:8 + dplen]
        if None in data:
            bad = True
        else:
            c = ~crc_raw(bytes(data)) & 0xFFFFFFFF
            bad |= wbuf[8 + dplen:8 + dplen + 4] != list(c.to_bytes(4, "little"))
        bad |= wl != wexp
        chk.check(f"frame {fidx}", not bad,
                  f"wire_len={wl} (exp {wexp}) payload={plen}"
                  + (f" pre={wbuf[0:8]} pay={wbuf[8:12]} fcs={wbuf[8 + dplen:8 + dplen + 4]}"
                     if bad else ""))

    cap = MiiNibbleCapture(dut, dut.mii_tx_clk, on_byte=on_byte, on_frame=check_frame)
    cocotb.start_soon(cap.run())

    stb = {"n": 0}

    async def count_byte_stb():
        # always @(posedge clk) if (tx_byte_stb) byte_stb_cnt = byte_stb_cnt + 1;
        while True:
            await sample_before_rise(dut.clk)
            if is1(dut.tx_byte_stb):
                stb["n"] += 1

    cocotb.start_soon(count_byte_stb())

    await Timer(200, "ns")
    dut.rst_n.value = 1
    await Timer(200, "ns")

    for plen, bub in FRAMES:
        await saf_send_frame(dut, plen, first=0, bub=bub)

    await Timer(200_000, "ns")

    wire_bytes_total = (8 + 60 + 4) + (8 + 64 + 4) + (8 + 60 + 4) + (8 + 100 + 4)
    chk.check("frame count", state["rx_fidx"] == 4, f"got {state['rx_fidx']}, expected 4")
    chk.check("tx_byte_stb count", stb["n"] == wire_bytes_total,
              f"counted {stb['n']}, expected {wire_bytes_total}")
    chk.finish()
