# SPDX-License-Identifier: Apache-2.0
"""Multicast-hash-filter suite for rtl/eth_mac_rx.v built with MCAST_HASH_FILTER=1.

The default suite runs MCAST_HASH_FILTER=0 and rx_model.py declines to model the
hash path, so this focused suite covers it directly. It pins the admit gate to the
I/G bit (dst byte 0 LSB = mac_chk[40]), NOT the LSB of the last octet (mac_chk[0]):
- a group address whose hash bucket is set is admitted, even when its last octet is
  even (the case the mac_chk[0] gate wrongly rejected);
- a group address whose bucket is clear is dropped (the hash actually gates);
- a unicast whose bucket happens to be set is NOT leaked (the case the mac_chk[0]
  gate wrongly admitted when the last octet was odd).
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from lib.gmii_rx_driver import GmiiRxDriver
from lib.axis_sink import AxisSink
import random

CLK_NS = 10
OUR_MAC = 0x020000000001
SRC = 0x0A0B0C0D0E0F
ETYPE = b"\x08\x00"

# Group addr, I/G=1, last octet 0x02 (even): mac_chk[0]=0 -> the buggy gate drops it.
MCAST_EVEN = 0x01005E000002
# Group addr with a different hash bucket, used for the "bucket clear -> drop" case.
MCAST_OTHER = 0x01005E00A0C4
# Foreign unicast, I/G=0, last octet 0x55 (odd): mac_chk[0]=1 -> the buggy gate leaks it.
UNI_ODD = 0x020011223355


def _hash_idx(dst_int):
    """Replicate the RTL fold: XOR of the eight 6-bit slices of the 48-bit dst."""
    idx = 0
    for k in range(8):
        idx ^= (dst_int >> (6 * k)) & 0x3F
    return idx


def _payload(dst_int, size=64):
    dst = dst_int.to_bytes(6, "big")
    src = SRC.to_bytes(6, "big")
    data = bytes([(0xC0 + i) & 0xFF for i in range(max(0, size - 14))])
    return dst + src + ETYPE + data


async def _setup(dut, hash_table):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    dut.our_mac.value = OUR_MAC
    dut.promisc.value = 0
    dut.passthrough.value = 0
    dut.jumbo_en.value = 0
    dut.mcast_hash_table.value = hash_table
    dut.gmii_rxd.value = 0
    dut.gmii_rx_dv.value = 0
    dut.gmii_rx_er.value = 0
    dut.m_axis_tready.value = 0
    dut.rst_n.value = 0
    for _ in range(8):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    for _ in range(4):
        await RisingEdge(dut.clk)


async def _send_and_collect(dut, hash_table, dsts):
    await _setup(dut, hash_table)
    sink = AxisSink(dut, random.Random(1), p_stall=0.0, active_signal=dut.gmii_rx_dv)
    cocotb.start_soon(sink.run())
    drv = GmiiRxDriver(dut)
    await drv.idle(4)
    for d in dsts:
        await drv.send_frame(_payload(d))
        await drv.idle(len(_payload(d)) + 32)
    for _ in range(500):
        await RisingEdge(dut.clk)
    return [f["payload"][:6] for f in sink.frames]


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def mcast_group_admitted(dut):
    """Group addr with its bucket set is admitted - even with an even last octet
    (the mac_chk[0] gate dropped this; the mac_chk[40] I/G gate admits it)."""
    table = 1 << _hash_idx(MCAST_EVEN)
    got = await _send_and_collect(dut, table, [MCAST_EVEN])
    assert got == [MCAST_EVEN.to_bytes(6, "big")], \
        f"group with bucket set must be delivered, got {got}"
    dut._log.info("OK: hashed multicast admitted")


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def mcast_group_filtered(dut):
    """Group addr whose bucket is clear is dropped: the hash actually gates
    (table holds a different bucket, so this is not a promisc pass-through)."""
    table = 1 << _hash_idx(MCAST_OTHER)
    assert _hash_idx(MCAST_OTHER) != _hash_idx(MCAST_EVEN), "pick distinct buckets"
    got = await _send_and_collect(dut, table, [MCAST_EVEN])
    assert got == [], f"group with clear bucket must be dropped, got {got}"
    dut._log.info("OK: unhashed multicast dropped")


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def unicast_not_leaked(dut):
    """A foreign unicast whose bucket happens to be set must NOT be admitted by
    the multicast path (I/G=0). The buggy mac_chk[0] gate leaked it because the
    last octet was odd. A matching-unicast control confirms delivery still works."""
    table = 1 << _hash_idx(UNI_ODD)
    got = await _send_and_collect(dut, table, [UNI_ODD, OUR_MAC])
    assert got == [OUR_MAC.to_bytes(6, "big")], \
        f"foreign unicast must not leak via mcast hash; got {got}"
    dut._log.info("OK: unicast not leaked through mcast hash")
