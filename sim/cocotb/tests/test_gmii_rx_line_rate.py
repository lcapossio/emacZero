# SPDX-License-Identifier: Apache-2.0
"""cocotb port of sim/tb/tb_gmii_rx_line_rate.v (build_and_test.py: GMII-RX-LINE-RATE).

eth_mac_sys with PHY_INTERFACE="GMII", MAX_FRAME=9018, CLK_FREQ_HZ=125 MHz.
sys clk runs at 125 MHz - 100 ppm (half period 4.0004 ns), the PHY clock at
125 MHz + 100 ppm (half period 3.9996 ns); the PHY clock is one net driving
clk_125, clk_125_90 and phy_gmii_rx_clk, as in the bench. Both start low at
t=0. The bench runs at 10 fs resolution; here edge n of each clock is at
n * half period rounded to the simulator's precision (exact on GHDL at 1 fs,
within 0.5 ps without drift on Icarus at 1 ps), so the average frequencies
and the 200 ppm offset are the bench's.

PHY model, as in the bench, driven at the falling edge of the PHY clock:
60 frames back to back, each 7 x 0x55 + 0xD5, the frame (broadcast DA, SA
02:00:00:00:00:01, EtherType 0x0800, payload byte k = n*7 + k), the FCS
(the bench's own reflected CRC-32), then 12 IFG bytes with RX_DV low.
Payload lengths: 9000 when n % 10 == 9, else 46 when n % 6 == 0, else 300
when n % 6 == 5, else 1500.

RX checker, as in the bench: every beat of frame n at position k against the
frame plan; length per frame; terror beats.

Checks, in bench order: frames received = 60; frames with wrong
length/content = 0; terror beats = 0; RX_FRAME_CNT (0x30) = 60; RX_ERR (0x38)
= 0; RX_ERR_ALIGN (0x4C) = 0; RX_ERR_OVERFLOW (0x50) = 0.

No suite for the bench's GMII_RX_SLOW_SYS variant (clk at 100 MHz, expected
to FAIL by design): build_and_test.py does not run it. GMII_RX_SLOW_SYS=1 in
the environment selects it for a manual run.
"""
import os

import cocotb
from cocotb.triggers import FallingEdge, Timer

from lib.axil_master import AxiLiteMaster
from lib.bench import Checks
from lib.mac_sys_b import AxisRx, clock_edges, crc32_byte, hdr_byte, tie_off

SUITES = {
    "gmii_rx_line_rate": {
        "toplevel": "eth_mac_sys",
        "sources": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                    "rtl/sync_fifo.v", "rtl/net/csum_calc.v", "rtl/eth_mac_rx.v",
                    "rtl/eth_mac_tx.v", "rtl/eth_stats.v", "rtl/eth_pause.v",
                    "rtl/axilite_regs.v", "rtl/mdio_master.v", "rtl/ddr_output.v",
                    "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                    "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v", "rtl/mii_tx_saf.v",
                    "rtl/eth_mac_sys.v"],
        "params": {"PHY_INTERFACE": "GMII", "MAX_FRAME": 9018,
                   "CLK_FREQ_HZ": 125000000},
    },
}

N_FRAMES = 60
# GMII_RX_SLOW_SYS=1 in the environment is the bench's -DGMII_RX_SLOW_SYS (clk at
# 100 MHz, expected to fail); no suite sets it.
SYS_HALF = "5.0" if os.environ.get("GMII_RX_SLOW_SYS") == "1" else "4.0004"
PHY_HALF = "3.9996"     # ns, 125 MHz + 100 ppm


def plen(n):
    if n % 10 == 9:
        return 9000          # MAX_FRAME on the wire
    if n % 6 == 0:
        return 46            # minimum frame
    if n % 6 == 5:
        return 300
    return 1500              # MTU


def frame_byte(n, k):
    return hdr_byte(k) if k < 14 else (n * 7 + k - 14) & 0xFF


async def phy_send(dut, n):
    clk = dut.phy_gmii_rx_clk
    total = 14 + plen(n)
    crc = 0xFFFFFFFF
    for k in range(8):
        await FallingEdge(clk)
        dut.phy_gmii_rx_dv.value = 1
        dut.phy_gmii_rxd.value = 0x55 if k < 7 else 0xD5
    for k in range(total):
        await FallingEdge(clk)
        b = frame_byte(n, k)
        dut.phy_gmii_rxd.value = b
        crc = crc32_byte(crc, b)
    crc ^= 0xFFFFFFFF
    for k in range(4):
        await FallingEdge(clk)
        dut.phy_gmii_rxd.value = (crc >> (8 * k)) & 0xFF
    for k in range(12):
        await FallingEdge(clk)
        dut.phy_gmii_rx_dv.value = 0
        dut.phy_gmii_rxd.value = 0


class RxCheck:
    def __init__(self, log):
        self.log = log
        self.frames = self.bad = self.err = self.pos = self.bad_bytes = 0

    def beat(self, d, last, err):
        if err:
            self.err += 1
        if d != frame_byte(self.frames, self.pos):
            self.bad_bytes += 1
        if last:
            want = 14 + plen(self.frames)
            if self.bad_bytes != 0 or self.pos + 1 != want:
                if self.bad < 4:
                    self.log.info("  frame %d: len %d (expected %d), %d bad bytes",
                                  self.frames, self.pos + 1, want, self.bad_bytes)
                self.bad += 1
            self.frames += 1
            self.pos = 0
            self.bad_bytes = 0
        else:
            self.pos += 1


@cocotb.test(timeout_time=10, timeout_unit="ms")
async def gmii_rx_line_rate(dut):
    chk = Checks(dut._log)
    tie_off(dut)
    dut.rgmii_rxd.value = 0
    dut.rgmii_rx_ctl.value = 0
    dut.rgmii_rxc.value = 0
    dut.s_axis_tdata.value = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    dut.phy_gmii_rxd.value = 0
    dut.phy_gmii_rx_dv.value = 0
    dut.phy_gmii_rx_er.value = 0
    cocotb.start_soon(clock_edges([dut.clk], SYS_HALF))
    cocotb.start_soon(clock_edges([dut.clk_125, dut.clk_125_90, dut.phy_gmii_rx_clk],
                                  PHY_HALF))

    rx = RxCheck(dut._log)
    cocotb.start_soon(AxisRx(dut, rx.beat).run())

    axi = AxiLiteMaster(dut, dut.clk)  # drives the idle values
    dut.rst_n.value = 0
    await Timer(100, unit="ns")
    dut.rst_n.value = 1
    await Timer(300, unit="ns")

    if SYS_HALF == "5.0":
        dut._log.info("GMII RX line rate: clk 100 MHz (expected to FAIL)")
    else:
        dut._log.info("GMII RX line rate: clk 125 MHz - 100 ppm, PHY 125 MHz + 100 ppm")
    # rx_en + promisc + jumbo_en; accept broadcast
    await axi.write(0x04, 0x0000_0046)
    await axi.write(0x0C, 0xFFFF_FFFF)
    await axi.write(0x10, 0x0000_FFFF)
    await Timer(200, unit="ns")

    for n in range(N_FRAMES):
        await phy_send(dut, n)

    # Drain: the reader may be a frame behind the wire.
    t = 0
    while rx.frames < N_FRAMES and t < 200:
        await Timer(1000, unit="ns")
        t += 1
    await Timer(2000, unit="ns")

    chk.eq("frames received", rx.frames, N_FRAMES)
    chk.eq("frames with wrong length/content", rx.bad, 0)
    chk.eq("terror beats", rx.err, 0)
    v = await axi.read(0x30)
    chk.eq("RX_FRAME_CNT", v, N_FRAMES)
    v = await axi.read(0x38)
    chk.eq("RX_ERR", v, 0)
    v = await axi.read(0x4C)
    chk.eq("RX_ERR_ALIGN", v, 0)
    v = await axi.read(0x50)
    chk.eq("RX_ERR_OVERFLOW", v, 0)

    await Timer(100, unit="ns")
    chk.finish()
