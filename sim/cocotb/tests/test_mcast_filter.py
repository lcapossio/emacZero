# SPDX-License-Identifier: Apache-2.0
"""cocotb port of sim/tb/tb_eth_mac_rx_mcast.v (build_and_test.py: MCAST-FILTER).

MCAST_HASH_FILTER in eth_mac_rx, with eth_mac_tx generating preamble/SFD/CRC
and the negedge GMII loopback of the bench (harness h_eth_mac_rx_loop, TX
MAX_FRAME default, RX MCAST_HASH_FILTER=1; our_mac 02:00:00:00:00:01,
promisc 0, passthrough 0, jumbo_en 1, rx_csum_en 0, m_axis_tready 1).

Each case sends a 15-byte frame (dst, src 02:00:00:00:00:02, type 0x0800,
one 0xAA byte; eth_mac_tx pads) and waits up to 300 cycles for a new good
frame (rx_tvalid && rx_tlast && !rx_terror). Checks, in the bench's order:
  T1  unicast to our_mac                                  -> accepted
  T2  broadcast                                           -> accepted
  T3  01:00:5E:00:00:01, hash 14, table bit 14 set        -> accepted
  T4  01:00:5E:00:00:02, hash 13, bit 13 not set          -> dropped
  T5  01:00:5E:00:00:01 after the table is cleared        -> dropped
The bench uses no $random.
"""
import cocotb
from cocotb.triggers import RisingEdge, Timer

from lib.rx_loop import NegedgeLoop, start_clock, send_posedge_style, is1


# Suites this module backs (read by run.py; see its docstring).
SUITES = {
    "mcast_filter": {
        "toplevel": "h_eth_mac_rx_loop",
        "sources": ["rtl/crc32.v", "rtl/eth_mac_tx.v", "rtl/sync_fifo.v",
                    "rtl/net/csum_calc.v", "rtl/eth_mac_rx.v",
                    "sim/cocotb/hdl/h_eth_mac_rx_loop.v"],
        "params": {"MCAST_HASH_FILTER": 1},
    },
}

OUR_MAC = 0x020000000001
SRC_MAC = 0x020000000002
# bit 14 set: accepts 01:00:5E:00:00:01 (hash 14), rejects ..:02 (hash 13)
MCAST_TABLE_01 = 0x0000_0000_0000_4000


def load_frame(dst, src):
    return (dst.to_bytes(6, "big") + src.to_bytes(6, "big")
            + bytes([0x08, 0x00, 0xAA]))


@cocotb.test()
async def mcast_filter(dut):
    start_clock(dut)
    dut.tx_tvalid.value = 0
    dut.tx_tlast.value = 0
    dut.tx_tdata.value = 0
    dut.our_mac.value = OUR_MAC
    dut.promisc.value = 0
    dut.passthrough.value = 0
    dut.jumbo_en.value = 1
    dut.rx_csum_en.value = 0
    dut.rx_tready.value = 1
    dut.mcast_hash_table.value = MCAST_TABLE_01
    dut.rst_n.value = 0

    good = [0]   # rx_good_cnt

    def count_good():
        if is1(dut.rx_tvalid) and is1(dut.rx_tlast) and not is1(dut.rx_terror):
            good[0] += 1

    loop = NegedgeLoop(dut)
    loop.samplers.append(count_good)
    loop.start()

    await Timer(100, "ns")
    dut.rst_n.value = 1
    await Timer(50, "ns")

    async def wait_for_rx_frame():
        prev = good[0]
        for _ in range(300):
            await RisingEdge(dut.clk)
            if good[0] > prev:
                return True
        return False

    failures = []

    def check_bool(name, actual, expected):
        if actual == expected:
            dut._log.info(f"PASS: {name}")
        else:
            dut._log.error(f"FAIL: {name} (got {int(actual)}, exp {int(expected)})")
            failures.append(name)

    # T1: unicast to our MAC
    await send_posedge_style(dut, load_frame(OUR_MAC, SRC_MAC))
    check_bool("T1: unicast accept", await wait_for_rx_frame(), True)
    await Timer(20, "ns")

    # T2: broadcast
    await send_posedge_style(dut, load_frame(0xFFFFFFFFFFFF, SRC_MAC))
    check_bool("T2: broadcast accept", await wait_for_rx_frame(), True)
    await Timer(20, "ns")

    # T3: hash hit
    dut.mcast_hash_table.value = MCAST_TABLE_01
    await send_posedge_style(dut, load_frame(0x01005E000001, SRC_MAC))
    check_bool("T3: mcast hash hit accept", await wait_for_rx_frame(), True)
    await Timer(20, "ns")

    # T4: hash miss
    await send_posedge_style(dut, load_frame(0x01005E000002, SRC_MAC))
    check_bool("T4: mcast hash miss drop", await wait_for_rx_frame(), False)
    await Timer(20, "ns")

    # T5: table cleared
    dut.mcast_hash_table.value = 0
    await send_posedge_style(dut, load_frame(0x01005E000001, SRC_MAC))
    check_bool("T5: mcast table clear drop", await wait_for_rx_frame(), False)
    await Timer(20, "ns")

    assert not failures, f"failed: {failures}"
