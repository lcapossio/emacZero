# SPDX-License-Identifier: Apache-2.0
"""cocotb mirror of sim/tb/tb_gmii_cdc_100m.v and sim/tb/tb_gmii_cdc_10m.v.

build_and_test.py benches GMII-CDC-100M (suite gmii_cdc_100m) and GMII-CDC-10M
(suite gmii_cdc_10m). The two benches are the same apart from the constants
below, which the suite's env selects (GMII_CDC_RATE = 100M or 10M):

               cfg_speed  bytes  wait after send  tx_en-high range  watchdog
    100M          01        32       5000 ns          280..340       500 us
    10M           10         8      20000 ns          790..810         2 ms

gmii_cdc TX path only (media RX tied off): one frame of byte[i] = i | 0x80 is
sent on the sys side, and a media_clk monitor counts tx_en-high cycles and
"distinct bytes" (a new byte whenever txd changes, or on the first tx_en
cycle), capturing each distinct byte.

Checks, in the order of the bench (one cocotb test):
  1. distinct_bytes == bytes sent
  2. data integrity: captured[i] == i | 0x80 for every byte sent
  3. pacing: media tx_en-high cycles within the range above
  (plus the bench's simulation watchdog -> the test's timeout_time)

Differences from the bench, none of which changes what is checked:
  * The media-side monitor samples after each media_clk rising edge has
    settled (RisingEdge + ReadOnly), i.e. one edge earlier than the bench's
    always block sees the same values; it accumulates the same counts.
  * media_clk and media_rx_clk (one net in the bench) are toggled by one
    coroutine in the same delta.
"""
import os

import cocotb
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer


SUITES = {
    "gmii_cdc_100m": {
        "toplevel": "gmii_cdc",
        "sources": ["rtl/async_fifo.v", "rtl/gmii_cdc.v"],
        "params": {},
        "env": {"GMII_CDC_RATE": "100M"},
    },
    "gmii_cdc_10m": {
        "toplevel": "gmii_cdc",
        "sources": ["rtl/async_fifo.v", "rtl/gmii_cdc.v"],
        "params": {},
        "env": {"GMII_CDC_RATE": "10M"},
    },
}

RATE = os.environ.get("GMII_CDC_RATE", "100M")
CFG = {
    #        cfg_speed, n_bytes, cap size, wait ns, lo, hi, watchdog ns
    "100M": (0b01, 32, 64, 5000, 280, 340, 500_000),
    "10M": (0b10, 8, 32, 20000, 790, 810, 2_000_000),
}[RATE]
CFG_SPEED, N_BYTES, CAP_SIZE, WAIT_NS, CYC_LO, CYC_HI, WATCHDOG_NS = CFG
SYS_HALF_NS = 5     # always #5 sys_clk   = ~sys_clk;  (100 MHz)
MEDIA_HALF_NS = 4   # always #4 media_clk = ~media_clk; (125 MHz)


async def _clock(sigs, half_ns):
    """reg clk = 0; always #half clk = ~clk; (drives every sig in `sigs`)."""
    level = 0
    for s in sigs:
        s.value = 0
    while True:
        await Timer(half_ns, "ns")
        level ^= 1
        for s in sigs:
            s.value = level


class _MediaMonitor:
    """The bench's media_clk always block (async reset on sys_rst_n)."""

    def __init__(self, dut):
        self.dut = dut
        self.media_tx_cycles_high = 0
        self.distinct_bytes = 0
        self.last_byte = 0
        self.saw_first = False
        self.captured = [None] * CAP_SIZE
        self.cap_idx = 0

    async def run(self):
        dut = self.dut
        while True:
            await RisingEdge(dut.media_clk)
            await ReadOnly()
            if not int(dut.sys_rst_n.value):
                self.media_tx_cycles_high = 0
                self.distinct_bytes = 0
                self.saw_first = False
                self.last_byte = 0
                self.cap_idx = 0
            elif int(dut.gmii_tx_en_out.value):
                self.media_tx_cycles_high += 1
                txd = int(dut.gmii_txd_out.value)
                if not self.saw_first or txd != self.last_byte:
                    if self.cap_idx < CAP_SIZE:
                        self.captured[self.cap_idx] = txd
                    self.cap_idx += 1
                    self.distinct_bytes += 1
                    self.last_byte = txd
                    self.saw_first = True
            else:
                self.saw_first = False


@cocotb.test(timeout_time=WATCHDOG_NS, timeout_unit="ns")
async def tb_gmii_cdc_rate(dut):
    results = []

    def check(name, cond):
        dut._log.info(f"{'PASS' if cond else 'FAIL'}: {name}")
        results.append((name, bool(cond)))

    dut._log.info(f"rate {RATE}: cfg_speed={CFG_SPEED:02b}, {N_BYTES} bytes")
    dut.sys_rst_n.value = 0
    cocotb.start_soon(_clock([dut.sys_clk], SYS_HALF_NS))
    cocotb.start_soon(_clock([dut.media_clk, dut.media_rx_clk], MEDIA_HALF_NS))
    dut.cfg_speed.value = CFG_SPEED
    # Media RX tied off (only TX behaviour is checked).
    dut.gmii_rxd_in.value = 0
    dut.gmii_rx_dv_in.value = 0
    dut.gmii_rx_er_in.value = 0
    dut.gmii_rx_ce_in.value = 1

    dut.gmii_txd_in.value = 0
    dut.gmii_tx_en_in.value = 0
    dut.gmii_tx_er_in.value = 0
    dut.gmii_ctl_txd_in.value = 0
    dut.gmii_ctl_tx_en_in.value = 0
    dut.gmii_ctl_tx_er_in.value = 0
    dut.tx_hold.value = 0
    mon = _MediaMonitor(dut)
    cocotb.start_soon(mon.run())
    await Timer(100, "ns")
    dut.sys_rst_n.value = 1
    await Timer(200, "ns")

    # Send one frame of byte[i] = i | 0x80 (non-zero, so the distinct-byte
    # detector is robust).
    await FallingEdge(dut.sys_clk)
    for i in range(N_BYTES):
        dut.gmii_txd_in.value = (i & 0xFF) | 0x80
        dut.gmii_tx_en_in.value = 1
        dut.gmii_tx_er_in.value = 0
        await FallingEdge(dut.sys_clk)
    dut.gmii_tx_en_in.value = 0
    dut.gmii_txd_in.value = 0

    # Wait for the media-side TX to fully drain.
    await Timer(WAIT_NS, "ns")

    check(f"{mon.distinct_bytes} distinct bytes seen on media side "
          f"(expected {N_BYTES})", mon.distinct_bytes == N_BYTES)

    bad = False
    for i in range(N_BYTES):
        exp = (i & 0xFF) | 0x80
        if mon.captured[i] != exp:
            dut._log.info(f"  byte[{i}] got {mon.captured[i]}, expected 0x{exp:02x}")
            bad = True
    check("data integrity through rate adapter", not bad)

    check(f"media TX active {mon.media_tx_cycles_high} cycles "
          f"(expected {CYC_LO}..{CYC_HI})",
          CYC_LO <= mon.media_tx_cycles_high <= CYC_HI)

    failed = [n for n, ok in results if not ok]
    dut._log.info(f"{len(results) - len(failed)} passed, {len(failed)} failed")
    assert not failed, "failed checks: " + "; ".join(failed)
