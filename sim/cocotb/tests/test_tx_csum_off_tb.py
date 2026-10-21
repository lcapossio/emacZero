# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""cocotb port of sim/tb/tb_tx_csum_off.v (build_and_test.py bench TX-CSUM-OFF).

Not to be confused with test_tx_csum_off.py, the separate randomized suite.

DUT: tx_csum_off, MAX_FRAME=64, enable=1, m_axis_tready=1. One 42-byte
UDP-over-IPv4 frame (header checksum 0x0000, UDP checksum 0xDEAD, no payload)
is streamed in right after rising edges with the bench's driver loop (drive
a byte, then wait while s_tready was low at that edge). After the frame the
first 42 output beats (m_tvalid high at a rising edge) are captured, and the
bench's checks run in its order:

1. bytes 24..25 (IPv4 header checksum) == 0xDBB7
2. bytes 40..41 (UDP checksum) == 0x4BFE
3. every other byte equals the input
4. the ones' complement sum of the captured IPv4 header folds to 0xFFFF

The bench's 100 us safety timeout is the test's timeout. No randomness.
"""
import cocotb
from cocotb.triggers import ReadOnly, RisingEdge, Timer

from lib.bench import Checks
from lib.txpath_bench import is1, start_clock, val


SUITES = {
    "tx_csum_off_tb": {
        "toplevel": "tx_csum_off",
        "sources": ["rtl/sync_fifo.v", "rtl/net/csum_calc.v", "rtl/net/tx_csum_off.v"],
        "params": {"MAX_FRAME": 64},
    },
}

FRAME = bytes([
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,     # dst MAC
    0x02, 0x00, 0x00, 0x00, 0x00, 0x01,     # src MAC
    0x08, 0x00,                             # type IPv4
    0x45, 0x00, 0x00, 0x1C, 0xCA, 0xFE,     # ver/IHL, DSCP, total length 28, id
    0x40, 0x00, 0x40, 0x11, 0x00, 0x00,     # flags, TTL 64, UDP, header csum 0
    0xC0, 0xA8, 0x89, 0x01,                 # src IP 192.168.137.1
    0xC0, 0xA8, 0x89, 0xC8,                 # dst IP 192.168.137.200
    0x00, 0x35, 0x1F, 0x90,                 # src port 53, dst port 8080
    0x00, 0x08, 0xDE, 0xAD,                 # UDP length 8, UDP csum (replaced)
])


async def edge_sample(dut, sig):
    """Value of `sig` as an `@(posedge clk)` block reads it at the next edge;
    returns after that edge."""
    await ReadOnly()
    v = val(sig)
    await RisingEdge(dut.clk)
    return v


@cocotb.test(timeout_time=100_000, timeout_unit="ns")
async def tx_csum_off_tb(dut):
    chk = Checks(dut._log)
    dut.enable.value = 1
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tdata.value = 0
    dut.s_axis_tlast.value = 0
    dut.m_axis_tready.value = 1
    dut.rst_n.value = 0
    start_clock(dut.clk, 10)
    await Timer(50, "ns")
    dut.rst_n.value = 1
    await Timer(20, "ns")

    # Stream the frame in:
    #   @(posedge clk); s_tdata <= frame[i]; ...; while (!s_tready) @(posedge clk);
    # The while reads s_tready as sampled at the edge it just waited for.
    for i, b in enumerate(FRAME):
        rdy = (await edge_sample(dut, dut.s_axis_tready)) == 1
        dut.s_axis_tdata.value = b
        dut.s_axis_tvalid.value = 1
        dut.s_axis_tlast.value = int(i == len(FRAME) - 1)
        while not rdy:
            rdy = (await edge_sample(dut, dut.s_axis_tready)) == 1
    await RisingEdge(dut.clk)
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0

    # Capture the egress: @(posedge clk); while (!m_tvalid) @(posedge clk); cap = m_tdata
    cap = []
    for _ in range(len(FRAME)):
        while True:
            await ReadOnly()
            v = is1(dut.m_axis_tvalid)
            d = val(dut.m_axis_tdata)
            await RisingEdge(dut.clk)
            if v:
                cap.append(d)
                break

    chk.check("IP checksum inserted", cap[24] == 0xDB and cap[25] == 0xB7,
              f"= {cap[24]}, {cap[25]} (expected 0xDB, 0xB7)")
    chk.check("UDP checksum inserted", cap[40] == 0x4B and cap[41] == 0xFE,
              f"= {cap[40]}, {cap[41]} (expected 0x4B, 0xFE)")
    bad = [j for j in range(len(FRAME))
           if j not in (24, 25, 40, 41) and cap[j] != FRAME[j]]
    chk.check("payload pass-through intact", not bad,
              "; ".join(f"byte[{j}] got {cap[j]} want 0x{FRAME[j]:02x}" for j in bad[:8]))
    if None in cap[14:34]:
        f2 = None
    else:
        s = sum((cap[k] << 8) | cap[k + 1] for k in range(14, 34, 2))
        f1 = (s & 0xFFFF) + (s >> 16)
        f2 = ((f1 & 0xFFFF) + (f1 >> 16)) & 0xFFFF
    chk.check("IP checksum verifies (fold = 0xFFFF)", f2 == 0xFFFF, f"fold = {f2}")
    chk.finish()
