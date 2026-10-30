# SPDX-License-Identifier: Apache-2.0
"""cocotb port of sim/tb/tb_gmii_loopback.v (build_and_test.py: GMII-LOOPBACK).

eth_mac_sys with PHY_INTERFACE="GMII", MAX_FRAME=9018, CLK_FREQ_HZ=125 MHz.
sys_clk and clk_125 are 125 MHz with aligned edges (first rise at 4 ns);
the PHY RX clock is 125 MHz offset 2 ns (first rise at 6 ns); clk_125_90 is
the clk_125 waveform (unused on the GMII branch).

Stand-in PHY, as in the bench: TXD / TX_EN / TX_ER are registered on the
rising edge of GTX_CLK (phy_gmii_txc) and driven onto the GMII RX pins
(reset to 0 while rst_n is low). The register is a Python coroutine on the
GTX_CLK edge; GTX_CLK rises mid-way between the clk_125 edges that launch
TXD, so the sample is race-free.

GTX_CLK monitors, as in the bench, on every GTX_CLK edge while rst_n is high:
rising-edge count; offset of each rising edge from the last clk_125 rising
edge in [2.5, 7.5] ns; high and low times in [2.8, 6.0] ns; TX_EN-low run
between frames in GTX_CLK cycles. clk_125 is this test's own clock (rising
at 4 + 8k ns), so its last rising edge and its rising-edge count since reset
are computed from that schedule instead of with a second per-cycle monitor;
the values are the ones the bench's always @(posedge clk_125) blocks hold.

Checks, in bench order:
  1  VERSION CSR
  3  small frame (50-byte payload): frame count 1; length 64; header+payload
  4  MTU frame (1500): count 2; length; header+payload
  5  jumbo (4000): count 3; length; header+payload
  5b max jumbo (9000 = MAX_FRAME on the wire): count 4; length; header+payload
  6  rx error beats = 0
  7  TX_FRAME_CNT = 4, RX_FRAME_CNT = 4
  8  GTX_CLK rising edges within +-2 of clk_125's (and > 1000);
     phase violations = 0; pulse-width violations = 0
  8b 1500 + 60 + 46 back to back: count 7; rx error beats 0; 7 frames on
     the TX pins; shortest inter-frame gap >= 12 byte times
  9  RX_ERR_OVERSIZE = 0; jumbo_en cleared, 4000-byte frame resent: flagged
     with terror; RX_ERR_OVERSIZE nonzero
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Edge, Timer

from lib.axil_master import AxiLiteMaster
from lib.bench import Checks, VERSION
from lib.mac_sys_b import AxisRx, hdr_byte, is1, now_ns, send_axis, tie_off

SUITES = {
    "gmii_loopback": {
        "toplevel": "eth_mac_sys",
        "sources": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                    "rtl/sync_fifo.v", "rtl/net/csum_calc.v", "rtl/eth_mac_rx.v",
                    "rtl/eth_mac_tx.v", "rtl/eth_stats.v", "rtl/eth_pause_rx.v", "rtl/eth_pause.v",
                    "rtl/axilite_regs.v", "rtl/mdio_master.v", "rtl/ddr_output.v",
                    "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                    "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v", "rtl/mii_tx_saf.v",
                    "rtl/eth_mac_sys.v"],
        "params": {"PHY_INTERFACE": "GMII", "MAX_FRAME": 9018,
                   "CLK_FREQ_HZ": 125000000},
    },
}

MAX_FRAME = 9018
CLK125_FIRST_RISE = 4.0     # ns; clk_125 starts low, half period 4 ns
CLK125_PERIOD = 8.0


def clk125_last_rise(t):
    """Time of the last clk_125 rising edge at or before t (ns)."""
    if t < CLK125_FIRST_RISE:
        return -1000.0       # the bench's initial last_txclk_edge
    k = int((t - CLK125_FIRST_RISE + 1e-6) // CLK125_PERIOD)
    return CLK125_FIRST_RISE + k * CLK125_PERIOD


def clk125_rises(t0, t1):
    """clk_125 rising edges in [t0, t1] (ns)."""
    def upto(t):
        if t < CLK125_FIRST_RISE:
            return 0
        return int((t - CLK125_FIRST_RISE + 1e-6) // CLK125_PERIOD) + 1
    return upto(t1) - upto(t0 - 1e-3)


class GmiiPhy:
    """The bench's stand-in PHY register and GTX_CLK monitors."""

    def __init__(self, dut):
        self.dut = dut
        self.txc_edges = 0
        self.txc_phase_viol = 0
        self.txc_last_rise = -1000.0
        self.txc_last_fall = -1000.0
        self.txc_width_viol = 0
        self.gap_cycles, self.min_gap, self.tx_bursts, self.tx_en_d = 0, 1_000_000, 0, 0
        dut.phy_gmii_rxd.value = 0       # register reset (rst_n is low at t=0)
        dut.phy_gmii_rx_dv.value = 0
        dut.phy_gmii_rx_er.value = 0

    async def run(self):
        d = self.dut
        txc = d.phy_gmii_txc
        while True:
            await Edge(txc)
            t = now_ns()
            v = str(txc.value)
            rst = is1(d.rst_n)
            if v == "1":
                en = int(d.phy_gmii_tx_en.value)
                # always @(posedge gmii_txc or negedge rst_n): the PHY register
                if rst:
                    d.phy_gmii_rxd.value = int(d.phy_gmii_txd.value)
                    d.phy_gmii_rx_dv.value = en
                    d.phy_gmii_rx_er.value = int(d.phy_gmii_tx_er.value)
                    # phase monitor
                    self.txc_edges += 1
                    off = t - clk125_last_rise(t)
                    if off < 2.5 or off > 7.5:
                        self.txc_phase_viol += 1
                    # low time
                    if self.txc_last_fall > 0.0:
                        low = t - self.txc_last_fall
                        if low < 2.8 or low > 6.0:
                            self.txc_width_viol += 1
                    # inter-frame gap
                    if en:
                        if not self.tx_en_d:
                            if self.tx_bursts > 0 and self.gap_cycles < self.min_gap:
                                self.min_gap = self.gap_cycles
                            self.tx_bursts += 1
                        self.gap_cycles = 0
                    else:
                        self.gap_cycles += 1
                    self.tx_en_d = en
                self.txc_last_rise = t
            elif v == "0":
                if rst and self.txc_last_rise > 0.0:
                    high = t - self.txc_last_rise
                    if high < 2.8 or high > 6.0:
                        self.txc_width_viol += 1
                self.txc_last_fall = t


class RxCapture:
    """The bench's RX capture: rx_buf (bytes of the latest frames, never
    cleared), last completed length, frame count, terror beats."""

    def __init__(self):
        self.buf = [None] * MAX_FRAME
        self.len = 0
        self.last_len = 0
        self.frames = 0
        self.err = 0

    def beat(self, d, last, err):
        if self.len < MAX_FRAME:
            self.buf[self.len] = d
        if err:
            self.err += 1
        if last:
            self.last_len = self.len + 1
            self.len = 0
            self.frames += 1
        else:
            self.len += 1


def frame(payload_len):
    return bytes(hdr_byte(k) for k in range(14)) + \
        bytes(k & 0xFF for k in range(payload_len))


@cocotb.test(timeout_time=50, timeout_unit="ms")
async def gmii_loopback(dut):
    chk = Checks(dut._log)
    tie_off(dut)
    dut.rgmii_rxd.value = 0
    dut.rgmii_rx_ctl.value = 0
    dut.rgmii_rxc.value = 0
    dut.phy_gmii_rx_clk.value = 0
    cocotb.start_soon(Clock(dut.clk, 8, unit="ns").start(start_high=False))
    cocotb.start_soon(Clock(dut.clk_125, 8, unit="ns").start(start_high=False))
    cocotb.start_soon(Clock(dut.clk_125_90, 8, unit="ns").start(start_high=False))

    async def rx_clk():
        await Timer(2, unit="ns")
        await Clock(dut.phy_gmii_rx_clk, 8, unit="ns").start(start_high=False)
    cocotb.start_soon(rx_clk())

    phy = GmiiPhy(dut)
    cocotb.start_soon(phy.run())
    rx = RxCapture()
    cocotb.start_soon(AxisRx(dut, rx.beat).run())

    axi = AxiLiteMaster(dut, dut.clk)  # drives the idle values
    dut.s_axis_tdata.value = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    dut.rst_n.value = 0
    await Timer(100, unit="ns")
    dut.rst_n.value = 1
    t_rst = now_ns()
    await Timer(200, unit="ns")

    def check_frame(name, payload_len):
        total = 14 + payload_len
        chk.eq(f"{name} len", rx.last_len, total)
        exp = frame(payload_len)
        bad = sum(1 for k in range(total) if rx.buf[k] != exp[k])
        chk.check(f"{name} header + payload ({payload_len} bytes): "
                            f"{bad} mismatched bytes", bad == 0)

    # Test 1: VERSION
    v = await axi.read(0x00)
    chk.check(f"VERSION = 0x{v:08x} (expected 0x{VERSION:08x})", v == VERSION)

    # Test 2: tx_en + rx_en + promisc + jumbo_en, accept broadcast
    await axi.write(0x04, 0x0000_0047)
    await axi.write(0x0C, 0xFFFF_FFFF)
    await axi.write(0x10, 0x0000_FFFF)

    # Test 3: small frame
    await send_axis(dut, frame(50))
    await Timer(200_000, unit="ns")
    chk.eq("small frame count", rx.frames, 1)
    check_frame("small", 50)

    # Test 4: standard MTU frame
    await send_axis(dut, frame(1500))
    await Timer(2_000_000, unit="ns")
    chk.eq("mtu frame count", rx.frames, 2)
    check_frame("mtu", 1500)

    # Test 5: jumbo frame
    await send_axis(dut, frame(4000))
    await Timer(5_000_000, unit="ns")
    chk.eq("jumbo frame count", rx.frames, 3)
    check_frame("jumbo", 4000)

    # Test 5b: full-size jumbo (MAX_FRAME on the wire)
    await send_axis(dut, frame(9000))
    await Timer(5_000_000, unit="ns")
    chk.eq("max jumbo frame count", rx.frames, 4)
    check_frame("max jumbo", 9000)

    # Test 6: no CRC errors anywhere in the loopback
    chk.eq("rx error beats", rx.err, 0)

    # Test 7: stats counters
    v = await axi.read(0x28)
    chk.eq("TX_FRAME_CNT", v, 4)
    v = await axi.read(0x30)
    chk.eq("RX_FRAME_CNT", v, 4)

    # Test 8: GTX_CLK alive, edge-for-edge with clk_125, correctly phased
    clk125_edges = clk125_rises(t_rst, now_ns())
    chk.check(f"GTX_CLK tracks clk_125 ({phy.txc_edges} vs {clk125_edges} rising edges)",
              phy.txc_edges <= clk125_edges + 2 and phy.txc_edges + 2 >= clk125_edges
              and clk125_edges > 1000)
    chk.eq("GTX_CLK phase violations", phy.txc_phase_viol, 0)
    chk.eq("GTX_CLK pulse-width violations", phy.txc_width_viol, 0)

    # Test 8b: frames queued back to back
    await send_axis(dut, frame(1500))
    await send_axis(dut, frame(60))
    await send_axis(dut, frame(46))
    await Timer(200_000, unit="ns")
    chk.eq("back-to-back frame count", rx.frames, 7)
    chk.eq("back-to-back rx error beats", rx.err, 0)
    chk.eq("frames seen on the TX pins", phy.tx_bursts, 7)
    chk.check(f"shortest inter-frame gap {phy.min_gap} byte times (>= 12)",
              12 <= phy.min_gap < 1_000_000)

    # Test 9: oversize gate on the GMII path
    v = await axi.read(0x54)
    chk.eq("RX_ERR_OVERSIZE before", v, 0)
    await axi.write(0x04, 0x0000_0007)      # jumbo_en = 0
    await send_axis(dut, frame(4000))
    await Timer(5_000_000, unit="ns")
    chk.check(f"oversize frame flagged with terror ({rx.err} beat(s))", rx.err > 0)
    v = await axi.read(0x54)
    chk.check(f"RX_ERR_OVERSIZE = {v} (nonzero)", v != 0)

    await Timer(100, unit="ns")
    chk.finish()
