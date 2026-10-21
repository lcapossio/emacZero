# SPDX-License-Identifier: Apache-2.0
"""cocotb port of sim/tb/tb_rgmii_if_100m.v (build_and_test.py bench RGMII-IF-100M).

rgmii_if at 100M (cfg_speed 01), then at 10M (cfg_speed 10), through a TX ->
RX pin loopback in which u_rx is clocked by the forwarded TXC, as a PHY would
be. The pair is wired as in the bench by sim/cocotb/hdl/h_rgmii_if_100m.{v,vhd}
(10 ps inertial delay on the pins, then 3 ns board delay on clock and data).
clk_125 rises at 4, 12, ... ns and clk_125_90 2 ns later, as in the bench.
The GMII inputs change on the falling edge of clk_125; each byte is held for
two TXC periods (10 / 100 clk_125 cycles), as gmii_cdc's pacer does.

Checks, in the order of the bench, for "100M" and then "10M" (12 in all):
  <speed>: RX received every byte                       (6 bytes, dv && ce)
  <speed>: bytes round-trip exactly (low nibble first)
  <speed>: gmii_rx_dv is one unbroken envelope           (one dv burst)
  <speed>: no RX_ER on any byte
  <speed>: TXC period and 50% duty cycle                 (> 4 rises, +-1 ps)
  <speed>: TXC edges >= 8 ns from TXD/TX_CTL changes     (min distance > 7.999 ns)
The TXC monitor watches the 10 ps-delayed pins (txd_s, ctl_s, txc_s) and keeps
the bench's $realtime arithmetic in integer picoseconds (the bench's 1 ps
precision): t_rise / t_edge / t_data update on every edge whether or not the
monitor is armed, as in the bench.

Sampling: the bench's RX capture runs on posedge rgmii_rxc and reads the RX
outputs (registered on that same edge) before they update. Here they are read
after the edge has settled (RisingEdge + ReadOnly), which is race-free on both
simulators; every captured signal moves by the same one RXC cycle, so the byte
list, the dv burst count and the RX_ER count are unchanged.
No randomness.
"""
import cocotb
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer

from lib.bench import Checks
from lib.rgmii_tb import as_int, is1, now_ps, start_clocks, watch_changes, watch_edges


# Suites this module backs (read by run.py; see its docstring).
SUITES = {
    "rgmii_if_100m": {
        "toplevel": "h_rgmii_if_100m",
        "sources": ["rtl/ddr_input.v", "rtl/ddr_output.v", "rtl/rgmii_if.v",
                    "sim/cocotb/hdl/h_rgmii_if_100m.v"],
        "params": {},
    },
}

PATTERN = [0x12, 0x34, 0x56, 0x78, 0xA5, 0x0F]
N = len(PATTERN)


class Bench:
    """The bench's module-level state: RX capture and TXC timing monitor."""

    def __init__(self, dut):
        self.dut = dut
        # RX capture
        self.rx_buf = [None] * 32       # reg [7:0] rx_buf [0:31], X at start
        self.rx_idx = 0
        self.dv_bursts = 0
        self.er_bytes = 0
        self.dv_d = False
        # TXC timing monitor (ps)
        self.mon_on = False
        self.t_rise = 0
        self.t_edge = 0
        self.t_data = 0
        self.min_margin = 10 ** 18
        self.txc_rises = 0
        self.bad_period = 0
        self.bad_high = 0
        self.exp_half = 20_000

    async def rx_capture(self):
        dut = self.dut
        while True:
            await RisingEdge(dut.rgmii_rxc)
            await ReadOnly()
            if not is1(dut.rst_n):
                continue
            dv = is1(dut.rx_gmii_rx_dv)
            if dv and is1(dut.rx_gmii_rx_ce):
                if self.rx_idx < 32:
                    self.rx_buf[self.rx_idx] = as_int(dut.rx_gmii_rxd)
                self.rx_idx += 1
                if is1(dut.rx_gmii_rx_er):
                    self.er_bytes += 1
            if dv and not self.dv_d:
                self.dv_bursts += 1
            self.dv_d = dv

    @staticmethod
    def _off_by(a, b):          # |a - b| above 1 ps
        return abs(a - b) > 1

    def on_data(self):
        now = now_ps()
        if self.mon_on and (now - self.t_edge) < self.min_margin:
            self.min_margin = now - self.t_edge
        self.t_data = now

    def on_txc_rise(self):
        now = now_ps()
        if self.mon_on:
            if (now - self.t_data) < self.min_margin:
                self.min_margin = now - self.t_data
            if self.txc_rises > 0 and self._off_by(now - self.t_rise, 2 * self.exp_half):
                self.bad_period += 1
            self.txc_rises += 1
        self.t_rise = now
        self.t_edge = now

    def on_txc_fall(self):
        now = now_ps()
        if self.mon_on:
            if (now - self.t_data) < self.min_margin:
                self.min_margin = now - self.t_data
            if self.txc_rises > 0 and self._off_by(now - self.t_rise, self.exp_half):
                self.bad_high += 1
        self.t_edge = now


async def _negedges(dut, n):
    for _ in range(n):
        await FallingEdge(dut.clk_125)


@cocotb.test(timeout_time=200, timeout_unit="us")
async def rgmii_if_100m_10m(dut):
    """tb_rgmii_if_100m: 100M then 10M loopback, dv envelope, TXC timing."""
    ck = Checks(dut._log)
    start_clocks(dut, shifted=True)
    dut.rst_n.value = 0
    dut.cfg_speed.value = 0b01
    dut.tx_gmii_txd.value = 0
    dut.tx_gmii_tx_en.value = 0
    dut.tx_gmii_tx_er.value = 0

    tb = Bench(dut)
    cocotb.start_soon(tb.rx_capture())
    cocotb.start_soon(watch_changes(dut.txd_s, tb.on_data))
    cocotb.start_soon(watch_changes(dut.ctl_s, tb.on_data))
    cocotb.start_soon(watch_edges(dut.txc_s, tb.on_txc_rise, tb.on_txc_fall))

    await Timer(100, "ns")
    dut.rst_n.value = 1
    await Timer(100, "ns")

    async def send_burst(hold):
        await FallingEdge(dut.clk_125)
        dut.tx_gmii_tx_en.value = 1
        for b in PATTERN:
            dut.tx_gmii_txd.value = b
            await _negedges(dut, hold)
        dut.tx_gmii_tx_en.value = 0
        dut.tx_gmii_txd.value = 0

    async def run_speed(speed, cycles_per_byte, label):
        dut.cfg_speed.value = speed
        tb.exp_half = cycles_per_byte * 2000          # TXC half period, ps
        await _negedges(dut, 4 * cycles_per_byte)

        tb.rx_idx = 0
        tb.dv_bursts = 0
        tb.er_bytes = 0
        tb.txc_rises = 0
        tb.bad_period = 0
        tb.bad_high = 0
        tb.min_margin = 10 ** 18
        tb.mon_on = True

        await send_burst(cycles_per_byte)
        await _negedges(dut, 8 * cycles_per_byte)
        tb.mon_on = False

        ck.check(f"{label}: RX received every byte", tb.rx_idx == N,
                 f"{tb.rx_idx} bytes")
        bad = []
        for k in range(min(N, tb.rx_idx)):
            if tb.rx_buf[k] != PATTERN[k]:
                got = "x" if tb.rx_buf[k] is None else f"{tb.rx_buf[k]:02x}"
                bad.append(f"byte {k}: got {got} expected {PATTERN[k]:02x}")
        ck.check(f"{label}: bytes round-trip exactly (low nibble first)",
                 not bad and tb.rx_idx == N, "; ".join(bad))
        ck.check(f"{label}: gmii_rx_dv is one unbroken envelope", tb.dv_bursts == 1,
                 f"{tb.dv_bursts} bursts")
        ck.check(f"{label}: no RX_ER on any byte", tb.er_bytes == 0,
                 f"{tb.er_bytes} RX_ER bytes")
        dut._log.info(f"INFO: {label} TXC rises {tb.txc_rises}, min TXC-to-data "
                      f"distance {tb.min_margin / 1000:.1f} ns")
        ck.check(f"{label}: TXC period and 50% duty cycle",
                 tb.txc_rises > 4 and tb.bad_period == 0 and tb.bad_high == 0,
                 f"rises {tb.txc_rises}, bad period {tb.bad_period}, bad high {tb.bad_high}")
        ck.check(f"{label}: TXC edges >= 8 ns from TXD/TX_CTL changes",
                 tb.min_margin > 7999, f"{tb.min_margin} ps")

    await run_speed(0b01, 10, "100M")
    await run_speed(0b10, 100, "10M")

    ck.finish()
