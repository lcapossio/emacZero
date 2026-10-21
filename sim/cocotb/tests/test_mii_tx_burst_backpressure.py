# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""cocotb port of sim/tb/tb_mii_tx_burst_backpressure.v (build_and_test.py bench
MII-TX-BURST-BACKPRESSURE).

DUT: harness sim/cocotb/hdl/h_mii_tx_bridge.{v,vhd} with MII_DEBUG=1:
eth_mac_tx (tx_start_ok = ~tx_busy) feeding mii_if's TX path, 100 MHz clk,
25 MHz mii_clk. 96 back-to-back 1514-byte UDP frames (frame index in bytes
42..45, other bytes as the bench's frame_byte()) are streamed in right after
rising edges, starting 50 cycles after reset, with one idle cycle between
frames - far more than the 25 MHz MII side can drain, so tx_busy must hold
eth_mac_tx off. At sys rising edges the test counts dbg_tx_len_wr_en,
dbg_tx_wr_full and tx_busy; at mii_clk rising edges it reassembles the MII
bytes and, when tx_en falls, records each frame's length and the sequence
number in wire bytes 50..53. When 96 frames are seen (or after 500000
mii_clk cycles) it checks, in the bench's order:

1. length enqueue count (dbg_tx_len_wr_en pulses) == 96
2. MII frame count == 96
3. cycles with dbg_tx_wr_full high == 0
4. tx_busy was high for at least one cycle
5. per frame (96 x 2): MII length == 1514 + 12, sequence number == index

No randomness in this bench.
"""
import cocotb
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from lib.bench import Checks
from lib.txpath_bench import BridgeMiiCapture, axis_accept, is1, start_clock


SUITES = {
    "mii_tx_burst_backpressure": {
        "toplevel": "h_mii_tx_bridge",
        "sources": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                    "rtl/eth_mac_tx.v", "sim/cocotb/hdl/h_mii_tx_bridge.v"],
        "params": {"MII_DEBUG": 1},
    },
}

FRAME_LEN = 1514
TX_FRAMES = 96
MAX_RX = 8192
EXPECT_MII_BYTES = FRAME_LEN + 12

_FIXED = {0: 0x02, 1: 0xAA, 2: 0xBB, 3: 0xCC, 4: 0xDD, 5: 0xEE,
          6: 0x02, 7: 0x00, 8: 0x00, 9: 0x00, 10: 0x00, 11: 0x01,
          12: 0x08, 13: 0x00, 14: 0x45, 15: 0x00,
          16: 0x05, 17: 0xDC,                    # IP total length 1500
          34: 0x27, 35: 0x0F,                    # UDP src port 9999
          36: 0x13, 37: 0x89,                    # UDP dst port 5001
          38: 0x05, 39: 0xC8}                    # UDP len 1480


def frame_byte(fidx, bidx):
    if bidx in _FIXED:
        return _FIXED[bidx]
    if 42 <= bidx <= 45:
        return (fidx >> (8 * (45 - bidx))) & 0xFF
    return (bidx + fidx) & 0xFF


async def drive(dut):
    clk = dut.clk
    for _ in range(50):                 # @(posedge rst_n); repeat (50) @(posedge clk);
        await RisingEdge(clk)
    for f in range(TX_FRAMES):
        await RisingEdge(clk)
        dut.tx_valid.value = 1
        dut.tx_data.value = frame_byte(f, 0)
        dut.tx_last.value = 0
        for b in range(1, FRAME_LEN):
            await axis_accept(clk, dut.tx_ready)
            dut.tx_data.value = frame_byte(f, b)
            dut.tx_last.value = int(b == FRAME_LEN - 1)
        await axis_accept(clk, dut.tx_ready)
        dut.tx_valid.value = 0
        dut.tx_last.value = 0


@cocotb.test()
async def mii_tx_burst_backpressure(dut):
    chk = Checks(dut._log)
    dut.rst_n.value = 0
    dut.tx_data.value = 0
    dut.tx_valid.value = 0
    dut.tx_last.value = 0
    start_clock(dut.clk, 10)
    start_clock(dut.mii_clk, 40)

    cnt = {"len_wr": 0, "wr_full": 0, "busy": 0}

    async def sys_counters():
        # always @(posedge clk or negedge rst_n): three event counters
        while True:
            # 1.2M sys cycles: one trigger per cycle. These three outputs come
            # from sys-clock registers only and this bench drives right after
            # rising edges, so the falling-edge value is the one the next edge
            # sees.
            await FallingEdge(dut.clk)
            if not is1(dut.rst_n):
                cnt["len_wr"] = cnt["wr_full"] = cnt["busy"] = 0
                continue
            if is1(dut.dbg_tx_len_wr_en):
                cnt["len_wr"] += 1
            if is1(dut.dbg_tx_wr_full):
                cnt["wr_full"] += 1
            if is1(dut.tx_busy):
                cnt["busy"] += 1

    rx_len = [None] * TX_FRAMES
    rx_seq = [None] * TX_FRAMES
    rx = {"frames": 0}

    def on_frame_end(n, buf):
        i = rx["frames"]
        if i < TX_FRAMES:
            rx_len[i] = n
            w = buf[50:54]
            rx_seq[i] = None if None in w else (w[0] << 24 | w[1] << 16 | w[2] << 8 | w[3])
        rx["frames"] = i + 1

    mii = BridgeMiiCapture(dut, MAX_RX, on_frame_end=on_frame_end)
    cocotb.start_soon(sys_counters())
    cocotb.start_soon(mii.run())

    async def reset_and_drive():
        await Timer(100, "ns")
        dut.rst_n.value = 1
        await drive(dut)

    cocotb.start_soon(reset_and_drive())

    wait_cycles = 0
    while rx["frames"] < TX_FRAMES and wait_cycles < 500000:
        await RisingEdge(dut.mii_clk)
        wait_cycles += 1

    chk.check("length enqueue count", cnt["len_wr"] == TX_FRAMES,
              f"= {cnt['len_wr']} (expected {TX_FRAMES})")
    chk.check("mii frame count", rx["frames"] == TX_FRAMES,
              f"= {rx['frames']} (expected {TX_FRAMES})")
    chk.check("tx write full cycles", cnt["wr_full"] == 0, f"= {cnt['wr_full']} (expected 0)")
    chk.check("tx_busy asserted during the oversubscribed burst", cnt["busy"] > 0,
              f"for {cnt['busy']} sys cycles")
    for i in range(TX_FRAMES):
        if rx_len[i] != EXPECT_MII_BYTES:
            chk.check(f"frame {i} MII length", False,
                      f"= {rx_len[i]} (expected {EXPECT_MII_BYTES})")
        else:
            chk.passed += 1
        if rx_seq[i] != i:
            chk.check(f"frame {i} seq", False, f"= {rx_seq[i]} (expected {i})")
        else:
            chk.passed += 1
    chk.finish()
