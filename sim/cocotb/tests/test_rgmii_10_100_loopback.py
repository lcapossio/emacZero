# SPDX-License-Identifier: Apache-2.0
"""cocotb port of sim/tb/tb_rgmii_10_100_loopback.v
(build_and_test.py: RGMII-100M-LOOPBACK and RGMII-10M-LOOPBACK).

eth_mac_sys with PHY_INTERFACE="RGMII", RGMII_SPEEDS="10_100", MAX_FRAME=9018,
sys clk 100 MHz, clk_125 125 MHz (edges aligned at t=0), clk_125_90 tied 0.
Suite rgmii_10_100_loopback_100m is the bench as built by default (100M);
rgmii_10_100_loopback_10m is the bench built with -DRGMII_10M, selected here
by the RGMII_10M environment variable.

Stand-in PHY, as in the bench: the RGMII TX pins come back on the RX pins
after the bench's two inertial delays (#0.01, then #PIN_DLY: 10 ns at 100M,
100 ns at 10M), TXC included, so RXC is the forwarded TXC. Here one inertial
delay of PIN_DLY + 0.01 ns acts on the settled pin value (a zero-width glitch
of the behavioural DDR model within one time step is not a change, which is
what the bench's 10 ps inertial stage removes).

Wire monitors (on the settled TX pins, the bench's txd_s / ctl_s / txc_s are
the same signals 10 ps later): shortest TX_CTL-low run between frames in TXC
cycles; from mon_on on, TXC period (2*HALF_PER) and high time (HALF_PER) to
1 ps, and the smallest distance between a TXC edge and a TXD / TX_CTL change.

Checks, in bench order (T4 at 100M only):
  T1 one 46-byte-payload frame:          frames received = 1
  T2 one 1500-byte-payload frame:        frames received = 2
  T3 three frames queued back to back:   frames received = 5
  T4 9000-byte jumbo (100M):             frames received = 6
  bad length or content = 0 (per frame: length, header, payload seed + k)
  rx error beats = 0
  frames seen on the TX pins = frames sent
  TXC periods not 2*HALF_PER = 0;  TXC high times not HALF_PER = 0
  TXC edges >= 8 ns from TXD/TX_CTL changes (min distance > 7.999 ns)
  shortest inter-frame gap >= 24 TXC cycles (and a gap was seen)
  TX_FRAME_CNT = RX_FRAME_CNT = frames sent; RX_ERR = 0
"""
import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer

from lib.axil_master import AxiLiteMaster
from lib.bench import Checks
from lib.mac_sys_b import AxisRx, InertialDelay, hdr_byte, is1, send_axis, tie_off

SUITES = {
    "rgmii_10_100_loopback_100m": {
        "toplevel": "eth_mac_sys",
        "sources": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                    "rtl/sync_fifo.v", "rtl/net/csum_calc.v", "rtl/eth_mac_rx.v",
                    "rtl/eth_mac_tx.v", "rtl/eth_stats.v", "rtl/eth_pause.v",
                    "rtl/axilite_regs.v", "rtl/mdio_master.v", "rtl/ddr_output.v",
                    "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                    "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v", "rtl/mii_tx_saf.v",
                    "rtl/eth_mac_sys.v"],
        "params": {"PHY_INTERFACE": "RGMII", "MAX_FRAME": 9018,
                   "RGMII_SPEEDS": "10_100"},
    },
    "rgmii_10_100_loopback_10m": {
        "toplevel": "eth_mac_sys",
        "sources": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                    "rtl/sync_fifo.v", "rtl/net/csum_calc.v", "rtl/eth_mac_rx.v",
                    "rtl/eth_mac_tx.v", "rtl/eth_stats.v", "rtl/eth_pause.v",
                    "rtl/axilite_regs.v", "rtl/mdio_master.v", "rtl/ddr_output.v",
                    "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                    "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v", "rtl/mii_tx_saf.v",
                    "rtl/eth_mac_sys.v"],
        "params": {"PHY_INTERFACE": "RGMII", "MAX_FRAME": 9018,
                   "RGMII_SPEEDS": "10_100"},
        "env": {"RGMII_10M": "1"},
    },
}

RGMII_10M = os.environ.get("RGMII_10M", "0") == "1"
if RGMII_10M:
    SPEED, HALF_PER, PIN_DLY, BYTE_NS = 0b10, 200, 100, 800
else:
    SPEED, HALF_PER, PIN_DLY, BYTE_NS = 0b01, 20, 10, 80


class StandInPhy:
    """Pin loopback plus the bench's wire monitors (gap, TXC timing)."""

    def __init__(self, dut):
        self.dut = dut
        self.mon_on = False
        # gap monitor
        self.gap_cycles, self.min_gap, self.tx_bursts, self.ctl_d = 0, 1_000_000, 0, 0
        # TXC timing monitor
        self.t_rise = self.t_edge = self.t_data = 0.0
        self.min_margin = 1.0e9
        self.txc_rises = self.bad_period = self.bad_high = 0
        self.ctl = 0
        dly = PIN_DLY + 0.01
        dut.rgmii_rxd.value = 0
        dut.rgmii_rx_ctl.value = 0
        dut.rgmii_rxc.value = 0
        self.lanes = [
            InertialDelay(dut.rgmii_txd, dut.rgmii_rxd, dly, self._data),
            InertialDelay(dut.rgmii_tx_ctl, dut.rgmii_rx_ctl, dly, self._ctl),
            InertialDelay(dut.rgmii_txc, dut.rgmii_rxc, dly, self._txc),
        ]

    def start(self):
        for lane in self.lanes:
            lane.start()

    @staticmethod
    def _off_by(a, b):
        return abs(a - b) > 0.001

    def _data(self, t, v):
        # always @(txd_s or ctl_s)
        if self.mon_on and (t - self.t_edge) < self.min_margin:
            self.min_margin = t - self.t_edge
        self.t_data = t

    def _ctl(self, t, v):
        self.ctl = 1 if str(v) == "1" else 0
        self._data(t, v)

    def _txc(self, t, v):
        s = str(v)
        if s == "1":
            # gap monitor: always @(posedge txc_s) if (rst_n)
            if is1(self.dut.rst_n):
                if self.ctl:
                    if not self.ctl_d:
                        if self.tx_bursts > 0 and self.gap_cycles < self.min_gap:
                            self.min_gap = self.gap_cycles
                        self.tx_bursts += 1
                    self.gap_cycles = 0
                else:
                    self.gap_cycles += 1
                self.ctl_d = self.ctl
            # timing monitor: posedge
            if self.mon_on:
                if (t - self.t_data) < self.min_margin:
                    self.min_margin = t - self.t_data
                if self.txc_rises > 0 and self._off_by(t - self.t_rise, 2.0 * HALF_PER):
                    self.bad_period += 1
                self.txc_rises += 1
            self.t_rise = t
            self.t_edge = t
        elif s == "0":
            if self.mon_on and self.txc_rises > 0:
                if (t - self.t_data) < self.min_margin:
                    self.min_margin = t - self.t_data
                if self._off_by(t - self.t_rise, HALF_PER):
                    self.bad_high += 1
            self.t_edge = t


class RxCheck:
    """The bench's RX capture: per-frame length and content."""

    def __init__(self, dut):
        self.exp_len, self.exp_seed = [], []
        self.frames = self.err = self.bad_frames = self.pos = self.bad_bytes = 0
        self.log = dut._log

    def beat(self, d, last, err):
        if err:
            self.err += 1
        p, n = self.pos, self.frames
        if p < 14:
            exp = hdr_byte(p)
        elif n < len(self.exp_seed):
            exp = (self.exp_seed[n] + p - 14) & 0xFF
        else:
            exp = None                       # no such frame was sent
        if d != exp:
            self.bad_bytes += 1
        if last:
            want = 14 + self.exp_len[n] if n < len(self.exp_len) else None
            if self.bad_bytes != 0 or p + 1 != want:
                self.log.info("  frame %d: len %d (expected %s), %d bad bytes",
                              n, p + 1, want, self.bad_bytes)
                self.bad_frames += 1
            self.frames += 1
            self.pos = 0
            self.bad_bytes = 0
        else:
            self.pos += 1


@cocotb.test(timeout_time=20 if RGMII_10M else 5, timeout_unit="ms")
async def rgmii_10_100_loopback(dut):
    chk = Checks(dut._log)
    tie_off(dut)
    dut.clk_125_90.value = 0
    dut.phy_gmii_rx_clk.value = 0
    dut.phy_gmii_rxd.value = 0
    dut.phy_gmii_rx_dv.value = 0
    dut.phy_gmii_rx_er.value = 0
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start(start_high=False))
    cocotb.start_soon(Clock(dut.clk_125, 8, unit="ns").start(start_high=False))

    phy = StandInPhy(dut)
    phy.start()
    rx = RxCheck(dut)
    cocotb.start_soon(AxisRx(dut, rx.beat).run())

    axi = AxiLiteMaster(dut, dut.clk)  # drives the idle values
    dut.s_axis_tdata.value = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    dut.rst_n.value = 0
    await Timer(100, unit="ns")
    dut.rst_n.value = 1
    await Timer(500, unit="ns")

    dut._log.info("RGMII 10/100 loopback at %s", "10M" if RGMII_10M else "100M")

    async def send_frame(payload_len, seed):
        rx.exp_len.append(payload_len)
        rx.exp_seed.append(seed)
        data = bytes(hdr_byte(k) for k in range(14)) + \
            bytes((seed + k) & 0xFF for k in range(payload_len))
        await send_axis(dut, data)

    async def wait_frames(n, timeout_ns):
        t = 0
        while rx.frames < n and t < timeout_ns:
            await Timer(1000, unit="ns")
            t += 1000
        await Timer(40 * BYTE_NS, unit="ns")   # let any spurious extra frame surface

    # tx_en | rx_en | promisc | speed | jumbo_en; accept broadcast
    await axi.write(0x04, 0x0000_0047 | (SPEED << 3))
    await axi.write(0x0C, 0xFFFF_FFFF)
    await axi.write(0x10, 0x0000_FFFF)
    await Timer(20 * BYTE_NS, unit="ns")       # cfg_speed crosses into the media domain
    phy.mon_on = True

    # T1: one minimum-size frame
    await send_frame(46, 0x10)
    await wait_frames(1, 200 * BYTE_NS)
    chk.eq("min frame: frames received", rx.frames, 1)

    # T2: one standard-MTU frame
    await send_frame(1500, 0x20)
    await wait_frames(2, 1700 * BYTE_NS)
    chk.eq("MTU frame: frames received", rx.frames, 2)

    # T3: three frames queued back to back
    await send_frame(60, 0x30)
    await send_frame(100, 0x40)
    await send_frame(46, 0x50)
    await wait_frames(5, 600 * BYTE_NS)
    chk.eq("back-to-back: frames received", rx.frames, 5)

    if not RGMII_10M:
        # T4: jumbo frame at 100M (MAX_FRAME on the wire)
        await send_frame(9000, 0x60)
        await wait_frames(6, 9300 * BYTE_NS)
        chk.eq("jumbo frame: frames received", rx.frames, 6)

    tx_frames = len(rx.exp_len)
    chk.eq("bad length or content", rx.bad_frames, 0)
    chk.eq("rx error beats", rx.err, 0)
    chk.eq("frames seen on the TX pins", phy.tx_bursts, tx_frames)
    chk.eq("TXC periods not 2*HALF_PER", phy.bad_period, 0)
    chk.eq("TXC high times not HALF_PER", phy.bad_high, 0)
    dut._log.info("INFO: %d TXC rises, min TXC-to-data distance %.1f ns",
                  phy.txc_rises, phy.min_margin)
    chk.check(f"TXC edges >= 8 ns from TXD/TX_CTL changes (min {phy.min_margin:.1f} ns)",
              phy.min_margin > 7.999)
    chk.check(f"shortest inter-frame gap {phy.min_gap} TXC cycles (>= 24)",
              24 <= phy.min_gap < 1_000_000)

    v = await axi.read(0x28)
    chk.eq("TX_FRAME_CNT", v, tx_frames)
    v = await axi.read(0x30)
    chk.eq("RX_FRAME_CNT", v, tx_frames)
    v = await axi.read(0x38)
    chk.eq("RX_ERR", v, 0)

    await Timer(100, unit="ns")
    chk.finish()
