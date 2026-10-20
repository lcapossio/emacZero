# SPDX-License-Identifier: Apache-2.0
"""cocotb port of sim/tb/tb_rgmii_loopback.v (build_and_test.py: RGMII-LOOPBACK).

eth_mac_sys with PHY_INTERFACE="RGMII", CLK_FREQ_HZ=125 MHz, at 1G. sys_clk
and clk_125 are both 125 MHz with aligned edges; clk_125_90 and rgmii_rxc are
the clk_125 net, as in the bench.

The loop: the Verilog bench registers gmii_cdc's media-side TX outputs
(gmii_txd_out / gmii_tx_en_out / gmii_tx_er_out) on clk_125 and FORCES the
register onto gmii_cdc's RX inputs, overriding rgmii_if. Forcing does not work
on GHDL (a written internal value sticks), so this port reaches the same
condition by stimulus: a stand-in PHY reads the same media-side TX outputs and
drives them back on the RGMII RX pins, DDR-encoded the way an RGMII PHY does at
1G (RXD[3:0] + RX_DV around the rising RXC edge, RXD[7:4] + RX_DV^RX_ER around
the falling edge, each nibble set 2 ns before its edge). gmii_cdc then sees the
looped-back TX stream on its RX inputs, as in the bench, through rgmii_if's
1G RX path (two more clk_125 cycles of latency than the bench's one-cycle
register; nothing in the bench checks latency). The RX DDR path is thereby
exercised as well, which the bench bypasses. The PHY starts when rst_n rises,
as the bench's force loop does; until then the RX pins are held at 0 (the
bench's tie-off).

Checks, in bench order:
  1. VERSION CSR = {EMZ_VERSION_MAJOR, EMZ_VERSION_MINOR, EMZ_VERSION_ID}
  2. (CTRL = 0x07, MAC = ff:ff:ff:ff:ff:ff, no check)
  4. send_frame(50), wait 100 us: at least one frame left the RX AXIS
     (counted on each tvalid high -> low, as the bench's rx_cap does)
  5. TX_FRAME_CNT (0x28) nonzero
  6. RX_FRAME_CNT (0x30) nonzero, if a frame arrived (as in the bench)
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer

from lib.axil_master import AxiLiteMaster
from lib.hier import hier
from lib.bench import Checks, VERSION
from lib.mac_sys_b import clock_edges, hdr_byte, send_axis, tie_off

SUITES = {
    "rgmii_loopback": {
        "toplevel": "eth_mac_sys",
        "sources": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                    "rtl/sync_fifo.v", "rtl/net/csum_calc.v", "rtl/eth_mac_rx.v",
                    "rtl/eth_mac_tx.v", "rtl/eth_stats.v", "rtl/eth_pause.v",
                    "rtl/axilite_regs.v", "rtl/mdio_master.v", "rtl/ddr_output.v",
                    "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                    "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v", "rtl/mii_tx_saf.v",
                    "rtl/eth_mac_sys.v"],
        "params": {"PHY_INTERFACE": "RGMII", "CLK_FREQ_HZ": 125000000},
    },
}


async def rgmii_phy(dut, txd, tx_en, tx_er):
    """Media TX (gmii_cdc outputs, read at mid-cycle where they are settled:
    the value the bench's lb register takes at the next rising edge) back onto
    the RGMII RX pins, one DDR cycle per byte."""
    while True:
        await FallingEdge(dut.clk_125)
        d, en, er = int(txd.value), int(tx_en.value), int(tx_er.value)
        await Timer(2, unit="ns")
        dut.rgmii_rxd.value = d & 0xF
        dut.rgmii_rx_ctl.value = en
        await Timer(4, unit="ns")
        dut.rgmii_rxd.value = d >> 4
        dut.rgmii_rx_ctl.value = en ^ er


class RxCount:
    """The bench's rx_cap / rx_frame_cnt: a frame counts when tvalid drops."""

    def __init__(self, dut):
        self.dut = dut
        self.frames = 0

    async def run(self):
        cap = 0
        while True:
            await FallingEdge(self.dut.clk)   # = the value at the next rising edge
            if int(self.dut.m_axis_tvalid.value):
                cap = 1
            elif cap:
                self.frames += 1
                cap = 0


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def rgmii_loopback(dut):
    chk = Checks(dut._log)
    tie_off(dut)
    dut.rgmii_rxd.value = 0
    dut.rgmii_rx_ctl.value = 0
    dut.phy_gmii_rx_clk.value = 0
    dut.phy_gmii_rxd.value = 0
    dut.phy_gmii_rx_dv.value = 0
    dut.phy_gmii_rx_er.value = 0
    cocotb.start_soon(Clock(dut.clk, 8, unit="ns").start(start_high=False))
    # clk_125, clk_125_90 and rgmii_rxc are one net in the bench.
    cocotb.start_soon(clock_edges([dut.clk_125, dut.clk_125_90, dut.rgmii_rxc], 4))

    axi = AxiLiteMaster(dut, dut.clk)  # drives the idle values
    dut.s_axis_tdata.value = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    dut.rst_n.value = 0
    await Timer(100, unit="ns")
    dut.rst_n.value = 1

    rx = RxCount(dut)
    cocotb.start_soon(rx.run())
    cocotb.start_soon(rgmii_phy(
        dut,
        hier(dut, "gen_rgmii.u_gmii_cdc.gmii_txd_out", "gen_rgmii.media_gmii_txd"),
        hier(dut, "gen_rgmii.u_gmii_cdc.gmii_tx_en_out", "gen_rgmii.media_gmii_tx_en"),
        hier(dut, "gen_rgmii.u_gmii_cdc.gmii_tx_er_out", "gen_rgmii.media_gmii_tx_er")))
    await Timer(200, unit="ns")

    # Test 1: VERSION
    v = await axi.read(0x00)
    chk.check(f"VERSION = 0x{v:08x} (expected 0x{VERSION:08x})", v == VERSION)

    # Tests 2-3: enable MAC + promisc, MAC address = broadcast
    await axi.write(0x04, 0x0000_0007)
    await axi.write(0x0C, 0xFFFF_FFFF)
    await axi.write(0x10, 0x0000_FFFF)

    # Test 4: one frame through the loop
    rx.frames = 0
    await send_axis(dut, bytes(hdr_byte(k) for k in range(14)) + bytes(range(50)))
    await Timer(100_000, unit="ns")
    chk.check(f"RGMII loopback received {rx.frames} frame(s) (expected >= 1)", rx.frames >= 1)

    # Test 5: TX stats
    v = await axi.read(0x28)
    chk.check(f"TX_FRAME_CNT = {v} (nonzero)", v != 0)

    # Test 6: RX stats
    v = await axi.read(0x30)
    if rx.frames >= 1:
        chk.check(f"RX_FRAME_CNT = {v} (nonzero)", v != 0)

    await Timer(100, unit="ns")
    chk.finish()
