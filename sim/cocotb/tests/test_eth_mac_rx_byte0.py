# SPDX-License-Identifier: Apache-2.0
"""cocotb port of sim/tb/tb_eth_mac_rx_byte0.v (build_and_test.py: ETH-MAC-RX-BYTE0).

The first data byte after the SFD must reach the AXIS output (regression of a
delay-pipe tap that missed byte 0). eth_mac_tx -> negedge GMII loopback ->
eth_mac_rx (harness h_eth_mac_rx_loop, default parameters; our_mac
FE:FF:FF:FF:FF:FF, promisc 0, passthrough 0, jumbo_en 1, rx_csum_en 0,
m_axis_tready 1). One 70-byte frame: FE FF FF FF FF FF, src
02:00:00:00:00:01, type 0x0800, then bytes i. The RX capture stores bytes
while rx_tvalid until the first TLAST.

Checks, in the bench's order, 200 cycles after the frame is sent:
  1. rx_buf[0] == 0xFE
  2. rx_cnt == 70
  3. rx_buf[i] == frame[i] for i < min(70, rx_cnt)
The bench uses no $random.
"""
import cocotb
from cocotb.triggers import RisingEdge, Timer

from lib.rx_loop import NegedgeLoop, start_clock, send_negedge_style, is1


# Suites this module backs (read by run.py; see its docstring).
SUITES = {
    "eth_mac_rx_byte0": {
        "toplevel": "h_eth_mac_rx_loop",
        "sources": ["rtl/crc32.v", "rtl/eth_mac_tx.v", "rtl/sync_fifo.v",
                    "rtl/net/csum_calc.v", "rtl/eth_mac_rx.v",
                    "sim/cocotb/hdl/h_eth_mac_rx_loop.v"],
        "params": {},
    },
}

FRAME_LEN = 70


@cocotb.test(timeout_time=200, timeout_unit="us")
async def rx_byte0(dut):
    start_clock(dut)
    dut.tx_tvalid.value = 0
    dut.tx_tlast.value = 0
    dut.tx_tdata.value = 0
    dut.rx_tready.value = 1
    dut.our_mac.value = 0xFEFFFFFFFFFF
    dut.promisc.value = 0
    dut.passthrough.value = 0
    dut.jumbo_en.value = 1
    dut.rx_csum_en.value = 0
    dut.mcast_hash_table.value = 0
    dut.rst_n.value = 0

    frame = ([0xFE] + [0xFF] * 5 + [0x02, 0x00, 0x00, 0x00, 0x00, 0x01, 0x08, 0x00]
             + [i & 0xFF for i in range(14, FRAME_LEN)])

    cap = {"buf": [None] * FRAME_LEN, "cnt": 0, "done": False}

    def capture():
        if is1(dut.rx_tvalid) and not cap["done"]:
            if cap["cnt"] < FRAME_LEN:
                cap["buf"][cap["cnt"]] = int(dut.rx_tdata.value)
            cap["cnt"] += 1
            if is1(dut.rx_tlast):
                cap["done"] = True

    loop = NegedgeLoop(dut)
    loop.samplers.append(capture)
    loop.start()

    await Timer(100, "ns")
    dut.rst_n.value = 1
    await Timer(100, "ns")

    await send_negedge_style(dut, frame)
    for _ in range(200):
        await RisingEdge(dut.clk)

    failures = []
    buf, cnt = cap["buf"], cap["cnt"]

    def check(name, ok, msg):
        if ok:
            dut._log.info(f"PASS: {name}")
        else:
            dut._log.error(f"FAIL: {name}: {msg}")
            failures.append(name)

    check("rx_buf[0] = 0xFE (first byte preserved)", buf[0] == 0xFE,
          f"rx_buf[0] = {buf[0]!r}, expected 0xFE")
    check(f"rx_cnt = {cnt}", cnt == FRAME_LEN, f"expected {FRAME_LEN}")
    n = min(FRAME_LEN, cnt)
    mism = sum(1 for i in range(n) if buf[i] != frame[i])
    check(f"all {FRAME_LEN} bytes match", mism == 0,
          f"{mism} byte mismatches. RX: {buf[:20]} EXPECTED: {frame[:20]}")

    assert not failures, f"failed: {failures}"
