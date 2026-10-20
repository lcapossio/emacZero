# SPDX-License-Identifier: Apache-2.0
"""cocotb port of sim/tb/tb_eth_mac_sys_max_frame.v (build_and_test.py bench
ETH-MAC-SYS-MAX-FRAME).

eth_mac_sys, PHY_INTERFACE="GMII", MAX_FRAME=2000, CLK_FREQ_HZ=125 MHz.
sys_clk and clk_125 are 125 MHz clocks in phase (clk_125_90 is tied to
clk_125 in the bench; here a third clock of the same period and phase, and
the GMII branch does not use it); phy_gmii_rx_clk is the same clock 2 ns
later. Stand-in PHY: phy_gmii_rxd / rx_dv / rx_er <= phy_gmii_txd / tx_en /
tx_er on each rising edge of phy_gmii_txc (0 in reset). phy_gmii_txc is the
inverted clk_125 under SIM, so the TX pins are read settled in the half cycle
before that edge. m_axis_tready tied 1, mdio_i tied 1, MII / RGMII inputs
tied to 0. The bench's RX capture (rising edge of sys_clk) keeps the last
frame's length, terror and the frame count. send_frame drives a broadcast
frame of `wire_len - 4` bytes (bytes 12-13 = EtherType, others = index) on
the falling edge, tready tested at the next falling edge, then waits 100 us.

Checks, in bench order (7):
  CTRL 0x47 (jumbo_en=1):
    2000-byte frame (type 0800) accepted: +1 frame, length 1996, no terror
    2001-byte frame (type 0800) oversize: +1 frame, length 1997, terror
    RX_ERR_OVERSIZE, jumbo == 1
  CTRL 0x07 (jumbo_en=0):
    1518-byte frame (type 0800) accepted
    1522-byte frame (type 8100, VLAN tag) accepted
    1522-byte frame (type 0800) oversize (terror)
    RX_ERR_OVERSIZE, std == 2
No $random in the bench.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer

from lib.axil_master import AxiLiteMaster
from lib.bench import Checks
from lib.mac_sys_a import bit, start_clock

SUITES = {
    "eth_mac_sys_max_frame": {
        "toplevel": "eth_mac_sys",
        "sources": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                    "rtl/sync_fifo.v", "rtl/eth_mac_rx.v", "rtl/eth_mac_tx.v",
                    "rtl/eth_stats.v", "rtl/eth_pause.v", "rtl/axilite_regs.v",
                    "rtl/mdio_master.v", "rtl/ddr_output.v", "rtl/ddr_input.v",
                    "rtl/rgmii_if.v", "rtl/gmii_if.v", "rtl/gmii_cdc.v",
                    "rtl/net/tx_csum_off.v", "rtl/mii_tx_saf.v", "rtl/eth_mac_sys.v"],
        # csum_calc.vhd: VHDL entity instantiation needs it analysed even
        # where the generate using it is off (the Verilog list leaves it out).
        "params": {"PHY_INTERFACE": "GMII", "MAX_FRAME": 2000,
                   "CLK_FREQ_HZ": 125000000},
    },
}

MAX_FRAME = 2000


async def start_rx_clk(dut):
    """initial begin #2; forever #4 rx_clk = ~rx_clk; end  (rx_clk starts 0)"""
    await Timer(2, "ns")
    cocotb.start_soon(Clock(dut.phy_gmii_rx_clk, 8, unit="ns").start(start_high=False))


async def gmii_phy(dut):
    """always @(posedge gmii_txc or negedge rst_n): RX pins <= TX pins."""
    for s in (dut.phy_gmii_rxd, dut.phy_gmii_rx_dv, dut.phy_gmii_rx_er):
        s.value = 0
    txc = dut.phy_gmii_txc
    while True:
        await FallingEdge(txc)
        await ReadOnly()
        vals = (dut.phy_gmii_txd.value, dut.phy_gmii_tx_en.value, dut.phy_gmii_tx_er.value)
        await RisingEdge(txc)
        if not bit(dut.rst_n):
            vals = (0, 0, 0)
        for s, v in zip((dut.phy_gmii_rxd, dut.phy_gmii_rx_dv, dut.phy_gmii_rx_er), vals):
            s.value = v


class RxCapture:
    """always @(posedge sys_clk): last frame's length / terror, frame count."""

    def __init__(self, dut):
        self.dut = dut
        self.rx_len = 0
        self.rx_last_len = 0
        self.rx_frame_cnt = 0
        self.rx_last_terror = 0

    async def run(self):
        d = self.dut
        while True:
            await FallingEdge(d.clk)
            await ReadOnly()
            rst_n, tv, tl = bit(d.rst_n), bit(d.m_axis_tvalid), bit(d.m_axis_tlast)
            te = d.m_axis_terror.value
            await RisingEdge(d.clk)
            if not rst_n:
                self.rx_len = self.rx_last_len = self.rx_frame_cnt = 0
                self.rx_last_terror = 0
            elif tv:
                if tl:
                    self.rx_last_len = self.rx_len + 1
                    self.rx_last_terror = int(te) if te.is_resolvable else None
                    self.rx_len = 0
                    self.rx_frame_cnt += 1
                else:
                    self.rx_len += 1


async def send_frame(dut, wire_len, etype):
    total = wire_len - 4
    await FallingEdge(dut.clk)
    for k in range(total):
        if k < 6:
            b = 0xFF
        elif k < 12:
            b = 0x02 if k == 6 else (0x01 if k == 11 else 0x00)
        elif k == 12:
            b = etype >> 8
        elif k == 13:
            b = etype & 0xFF
        else:
            b = k & 0xFF
        dut.s_axis_tdata.value = b
        dut.s_axis_tvalid.value = 1
        dut.s_axis_tlast.value = 1 if k == total - 1 else 0
        # @(negedge); while (!tready) @(negedge): tready settled after the
        # rising edge is the value at the following falling edge.
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            ready = bit(dut.s_axis_tready)
            await FallingEdge(dut.clk)
            if ready:
                break
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    await Timer(100000, "ns")


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tb_eth_mac_sys_max_frame(dut):
    c = Checks(dut._log)
    start_clock(dut.clk, 8)
    start_clock(dut.clk_125, 8)
    start_clock(dut.clk_125_90, 8)
    dut.phy_gmii_rx_clk.value = 0
    cocotb.start_soon(start_rx_clk(dut))
    dut.rst_n.value = 0
    axil = AxiLiteMaster(dut, dut.clk)
    dut.s_axis_tdata.value = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    dut.m_axis_tready.value = 1
    dut.mii_rxd.value = 0
    for s in (dut.mii_tx_clk, dut.mii_rx_dv, dut.mii_rx_er, dut.mii_rx_clk,
              dut.mii_col, dut.mii_crs, dut.clk_25, dut.clk_2_5,
              dut.rgmii_rx_ctl, dut.rgmii_rxc):
        s.value = 0
    dut.rgmii_rxd.value = 0
    dut.mdio_i.value = 1
    rx = RxCapture(dut)
    cocotb.start_soon(gmii_phy(dut))
    cocotb.start_soon(rx.run())

    await Timer(100, "ns")
    dut.rst_n.value = 1
    await Timer(200, "ns")

    async def check_frame(wire_len, etype, want_terror):
        frames_before = rx.rx_frame_cnt
        await send_frame(dut, wire_len, etype)
        ok = (rx.rx_frame_cnt == frames_before + 1
              and rx.rx_last_len == wire_len - 4
              and rx.rx_last_terror == want_terror)
        c.check(f"{wire_len}-byte frame, type {etype:04x}: "
                    f"{'oversize (terror)' if want_terror else 'accepted'} "
                    f"(frames +{rx.rx_frame_cnt - frames_before} len {rx.rx_last_len} "
                    f"terror {rx.rx_last_terror})", ok)

    # TX + RX + promisc + jumbo_en (CTRL[6])
    await axil.write(0x04, 0x00000047)

    # jumbo_en=1: the limit is MAX_FRAME
    await check_frame(MAX_FRAME, 0x0800, 0)
    await check_frame(MAX_FRAME + 1, 0x0800, 1)
    c.eq("RX_ERR_OVERSIZE, jumbo", await axil.read(0x54), 1)

    # jumbo_en=0: 1518, or 1522 with a VLAN tag
    await axil.write(0x04, 0x00000007)
    await check_frame(1518, 0x0800, 0)
    await check_frame(1522, 0x8100, 0)
    await check_frame(1522, 0x0800, 1)
    c.eq("RX_ERR_OVERSIZE, std", await axil.read(0x54), 2)

    c.finish()
