# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""cocotb port of sim/tb/tb_mii_tx_bridge.v (build_and_test.py bench MII-TX-BRIDGE).

DUT: harness sim/cocotb/hdl/h_mii_tx_bridge.{v,vhd} with MII_DEBUG=0:
eth_mac_tx (default MAX_FRAME, tx_start_ok = ~tx_busy) feeding mii_if's GMII
TX input, 100 MHz clk, 25 MHz mii_clk on both MII clocks, RX inputs idle.
One 74-byte frame (broadcast dst, src 02:00:00:00:00:01, type 0x0800, then
byte i = i) is streamed in right after rising edges, starting 500 ns after
reset. Every GMII byte (gmii_tx_en high at a clk rising edge) is recorded,
and the MII nibbles are reassembled (low first) at mii_clk rising edges.
At 300 us it checks, in the bench's order:

1. GMII byte count == MII byte count
2. every GMII byte == the MII byte at the same index (4-state compare)
3. gmii_tx_er low at the end (the bench prints TESTS FAILED otherwise)

No randomness in this bench.
"""
import cocotb
from cocotb.triggers import RisingEdge, Timer

from lib.bench import Checks
from lib.txpath_bench import (BridgeMiiCapture, axis_accept, is1, sample_before_rise,
                               start_clock, val)


SUITES = {
    "mii_tx_bridge": {
        "toplevel": "h_mii_tx_bridge",
        "sources": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                    "rtl/eth_mac_tx.v", "sim/cocotb/hdl/h_mii_tx_bridge.v"],
        "params": {"MII_DEBUG": 0},
    },
}

FRAME_LEN = 74
FRAME = bytes([0xFF] * 6 + [0x02, 0x00, 0x00, 0x00, 0x00, 0x01, 0x08, 0x00]
              + [i & 0xFF for i in range(14, FRAME_LEN)])


async def drive(dut):
    await Timer(500, "ns")                # @(posedge rst_n); #500;
    await RisingEdge(dut.clk)
    dut.tx_valid.value = 1
    dut.tx_data.value = FRAME[0]
    for idx in range(1, FRAME_LEN):
        await axis_accept(dut.clk, dut.tx_ready)
        dut.tx_data.value = FRAME[idx]
        dut.tx_last.value = int(idx == FRAME_LEN - 1)
    await axis_accept(dut.clk, dut.tx_ready)
    dut.tx_valid.value = 0
    dut.tx_last.value = 0


@cocotb.test()
async def mii_tx_bridge(dut):
    chk = Checks(dut._log)
    dut.rst_n.value = 0
    dut.tx_data.value = 0
    dut.tx_valid.value = 0
    dut.tx_last.value = 0
    start_clock(dut.clk, 10)
    start_clock(dut.mii_clk, 40)

    gmii_buf = [None] * 128
    gmii = {"count": 0}

    async def gmii_capture():
        # always @(posedge clk) if (gmii_tx_en && gmii_count < 128) ...
        while True:
            await sample_before_rise(dut.clk)
            if is1(dut.gmii_tx_en) and gmii["count"] < 128:
                gmii_buf[gmii["count"]] = val(dut.gmii_txd)
                gmii["count"] += 1

    mii = BridgeMiiCapture(dut, 128)
    cocotb.start_soon(gmii_capture())
    cocotb.start_soon(mii.run())

    await Timer(100, "ns")
    dut.rst_n.value = 1
    cocotb.start_soon(drive(dut))

    await Timer(300_000 - 100, "ns")     # #300000 from time 0

    gc, mc = gmii["count"], mii.idx
    dut._log.info(f"GMII bytes: {gc}")
    dut._log.info(f"MII reconstructed bytes: {mc}")
    chk.check("byte count match", gc == mc, f"gmii={gc} mii={mc}")
    for i in range(min(gc, mc)):
        if gmii_buf[i] != mii.buf[i]:
            chk.check(f"byte {i}", False, f"gmii={gmii_buf[i]} mii={mii.buf[i]}")
    chk.check("gmii_tx_er low at the end", val(dut.gmii_tx_er) == 0)
    chk.finish()
