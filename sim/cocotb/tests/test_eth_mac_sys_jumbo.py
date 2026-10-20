# SPDX-License-Identifier: Apache-2.0
"""cocotb port of sim/tb/tb_eth_mac_sys_jumbo.v (build_and_test.py: ETH-MAC-SYS-JUMBO).

Despite the name, the bench (and this port) drives the bare eth_mac_tx
(MAX_FRAME 9018) -> negedge GMII loopback -> eth_mac_rx pair, harness
h_eth_mac_rx_loop with TX_MAX_FRAME 9018 and RX defaults; our_mac
FF:FF:FF:FF:FF:FF, promisc 1, passthrough 0, rx_csum_en 0,
mcast_hash_table 0, m_axis_tready 1; jumbo_en driven by the test.

A 2000-byte frame (broadcast dst, src 02:02:02:02:02:02, type 0x0800, then
bytes idx) is sent, then 100 us of wait. The RX capture (cleared on the
falling edge before each frame) counts bytes while rx_tvalid until the first
TLAST and keeps that TLAST's terror. Checks, in the bench's order:
  T1  jumbo_en=0: the frame reaches TLAST, with terror
  T2  jumbo_en=1: the frame reaches TLAST, without terror
The bench uses no $random.
"""
import cocotb
from cocotb.triggers import FallingEdge, Timer

from lib.rx_loop import NegedgeLoop, start_clock, send_negedge_style, is1


# Suites this module backs (read by run.py; see its docstring).
SUITES = {
    "eth_mac_sys_jumbo": {
        "toplevel": "h_eth_mac_rx_loop",
        "sources": ["rtl/crc32.v", "rtl/eth_mac_tx.v", "rtl/sync_fifo.v",
                    "rtl/net/csum_calc.v", "rtl/eth_mac_rx.v",
                    "sim/cocotb/hdl/h_eth_mac_rx_loop.v"],
        "params": {"TX_MAX_FRAME": 9018},
    },
}

FRAME_LEN = 2000       # > 1518 standard but < 9018 jumbo


def frame_byte(idx):
    if idx < 6:
        return 0xFF
    if idx < 12:
        return 0x02
    if idx == 12:
        return 0x08
    if idx == 13:
        return 0x00
    return idx & 0xFF


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def sys_jumbo(dut):
    start_clock(dut)
    dut.tx_tvalid.value = 0
    dut.tx_tlast.value = 0
    dut.tx_tdata.value = 0
    dut.rx_tready.value = 1
    dut.our_mac.value = 0xFFFFFFFFFFFF
    dut.promisc.value = 1
    dut.passthrough.value = 0
    dut.rx_csum_en.value = 0
    dut.mcast_hash_table.value = 0
    dut.jumbo_en.value = 0
    dut.rst_n.value = 0

    cap = {"cnt": 0, "done": False, "err": False}

    def capture():
        if is1(dut.rx_tvalid) and not cap["done"]:
            cap["cnt"] += 1
            if is1(dut.rx_tlast):
                cap["done"] = True
                cap["err"] = is1(dut.rx_terror)

    loop = NegedgeLoop(dut)
    loop.samplers.append(capture)
    loop.start()

    await Timer(100, "ns")
    dut.rst_n.value = 1
    await Timer(100, "ns")

    frame = [frame_byte(k) for k in range(FRAME_LEN)]

    async def send_frame():
        # reset_capture: @(negedge clk) clear
        await FallingEdge(dut.clk)
        cap.update(cnt=0, done=False, err=False)
        await send_negedge_style(dut, frame)
        await Timer(100_000, "ns")

    failures = []

    # T1: jumbo_en = 0 -> terror
    dut.jumbo_en.value = 0
    await send_frame()
    if cap["done"] and cap["err"]:
        dut._log.info("PASS: jumbo_en=0 marks 2000-byte frame as terror")
    elif not cap["done"]:
        dut._log.error("FAIL: jumbo_en=0 frame never reached RX last")
        failures.append("T1")
    else:
        dut._log.error("FAIL: jumbo_en=0 2000-byte frame did NOT raise terror")
        failures.append("T1")

    # T2: jumbo_en = 1 -> clean
    dut.jumbo_en.value = 1
    await send_frame()
    if cap["done"] and not cap["err"]:
        dut._log.info("PASS: jumbo_en=1 accepts 2000-byte frame cleanly")
    elif not cap["done"]:
        dut._log.error("FAIL: jumbo_en=1 frame never reached RX last")
        failures.append("T2")
    else:
        dut._log.error("FAIL: jumbo_en=1 2000-byte frame had terror set")
        failures.append("T2")

    assert not failures, f"failed: {failures}"
