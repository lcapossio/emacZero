# SPDX-License-Identifier: Apache-2.0
"""cocotb port of sim/tb/tb_eth_mac_sys_csum_loop.v (build_and_test.py bench
ETH-MAC-SYS-CSUM-LOOP).

eth_mac_sys, PHY_INTERFACE="MII", MAX_FRAME=1518, TX_CSUM_OFFLOAD=1,
RX_CSUM_OFFLOAD=1; 100 MHz clk, one 25 MHz clock on mii_tx_clk and
mii_rx_clk (two clocks of the same period and phase here), MII TX looped back
to MII RX through a one-cycle register on the MII clock, m_axis_tready tied 1,
mdio_i follows mdio_o. The bench's RX capture (rising edge of clk) records
bytes 24-25 (IP checksum), 40-41 (UDP checksum) and 60-61 (IPv6 UDP
checksum) of each received frame, its terror on TLAST, and the frame count.
send_frame drives each byte on the falling edge and holds it until
s_axis_tready is high at a rising edge.
A to D send a 60-byte IPv4/UDP frame with IP checksum 0xDEAD (correct 0xA440)
and UDP checksum 0xBEEF (correct 0x4EF6); E and F a 72-byte IPv6/UDP frame
(fd00::1 -> fd00::2, UDP length 18, correct checksum 0x51C9) whose UDP
checksum is 0 (E) or 0xBEEF (F).

Checks, in bench order (23):
  CTRL readback with [9] == 0x2A7
  A  (CTRL 0x2A7): frames received 1; ip csum 0xA440; udp csum 0x4EF6;
     terror 0; RX_ERR_CSUM 0
  B  (CTRL 0x227): frames received 1; ip csum 0xDEAD; udp csum 0xBEEF;
     terror 1; RX_ERR_CSUM 1; RX_ERR 1
  C  (CTRL 0x027): frames received 1; terror 0; RX_ERR_CSUM 1
  D  write RX_ERR_CSUM; RX_ERR_CSUM 0
  E  (CTRL 0x227): frames received 1; IPv6 udp csum 0x0000; terror 0;
     RX_ERR_CSUM 0
  F  (CTRL 0x227): frames received 1; terror 1; RX_ERR_CSUM 1
No $random in the bench.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, RisingEdge, Timer

from lib.axil_master import AxiLiteMaster
from lib.bench import Checks
from lib.mac_sys_a import bit, mdio_loop, start_clock

SUITES = {
    "eth_mac_sys_csum_loop": {
        "toplevel": "eth_mac_sys",
        "sources": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                    "rtl/sync_fifo.v", "rtl/net/csum_calc.v", "rtl/eth_mac_rx.v",
                    "rtl/eth_mac_tx.v", "rtl/eth_stats.v", "rtl/eth_pause_rx.v", "rtl/eth_pause.v",
                    "rtl/axilite_regs.v", "rtl/mdio_master.v", "rtl/ddr_output.v",
                    "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                    "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v", "rtl/mii_tx_saf.v",
                    "rtl/eth_mac_sys.v"],
        "params": {"PHY_INTERFACE": "MII", "MAX_FRAME": 1518,
                   "TX_CSUM_OFFLOAD": 1, "RX_CSUM_OFFLOAD": 1},
    },
}

FRAME_LEN = 60
FRAME = ([0xFF] * 6 + [0x02, 0x11, 0x22, 0x33, 0x44, 0x55] + [0x08, 0x00]
         + [0x45, 0x00, 0x00, 0x2E, 0x12, 0x34, 0x40, 0x00, 0x40, 0x11,
            0xDE, 0xAD,
            0xC0, 0xA8, 0x01, 0x32, 0xC0, 0xA8, 0x01, 0xC8]
         + [0x12, 0x34, 0x56, 0x78, 0x00, 0x1A, 0xBE, 0xEF]
         + [i & 0xFF for i in range(42, FRAME_LEN)])
assert len(FRAME) == FRAME_LEN


def ipv6_frame(udp_csum):
    """The bench's load_ipv6_frame: IPv4 frame's MAC addresses, IPv6/UDP."""
    ip6 = [0x60, 0, 0, 0, 0x00, 0x12, 0x11, 0x40]
    ip6 += [0xFD] + [0] * 14 + [0x01]               # fd00::1
    ip6 += [0xFD] + [0] * 14 + [0x02]               # fd00::2
    udp = [0x12, 0x34, 0x56, 0x78, 0x00, 0x12, udp_csum >> 8, udp_csum & 0xFF]
    f = FRAME[:12] + [0x86, 0xDD] + ip6 + udp + list(range(62, 72))
    assert len(f) == 72
    return f


async def mii_loopback(dut):
    """always @(posedge mii_clk) {rxd, rx_dv} <= {txd, tx_en} (values settled
    since the falling edge before; mii_txd changes on the rising edge only).
    A value with X/U bits is not copied."""
    clk = dut.mii_rx_clk
    await ReadOnly()
    d, e = dut.mii_txd.value, dut.mii_tx_en.value
    while True:
        await RisingEdge(clk)
        if d.is_resolvable:
            dut.mii_rxd.value = d
        if e.is_resolvable:
            dut.mii_rx_dv.value = e
        await FallingEdge(clk)
        await ReadOnly()
        d, e = dut.mii_txd.value, dut.mii_tx_en.value


class RxCapture:
    """The bench's always @(posedge clk) RX capture."""

    def __init__(self, dut):
        self.dut = dut
        self.pos = 0
        self.frames = 0
        self.ip = [None, None]       # rx_ip_csum[15:8], [7:0]
        self.udp = [None, None]
        self.udp6 = [None, None]
        self.err = None

    @staticmethod
    def _word(pair):
        return None if None in pair else (pair[0] << 8) | pair[1]

    @property
    def ip_csum(self):
        return self._word(self.ip)

    @property
    def udp_csum(self):
        return self._word(self.udp)

    @property
    def udp6_csum(self):
        return self._word(self.udp6)

    async def run(self):
        d = self.dut
        while True:
            await FallingEdge(d.clk)
            await ReadOnly()
            rst_n, tv, tl = bit(d.rst_n), bit(d.m_axis_tvalid), bit(d.m_axis_tlast)
            td, te = d.m_axis_tdata.value, d.m_axis_terror.value
            await RisingEdge(d.clk)
            if not rst_n:
                self.pos = 0
                self.frames = 0
            elif tv:
                b = int(td) if td.is_resolvable else None
                if self.pos == 24:
                    self.ip[0] = b
                if self.pos == 25:
                    self.ip[1] = b
                if self.pos == 40:
                    self.udp[0] = b
                if self.pos == 41:
                    self.udp[1] = b
                if self.pos == 60:
                    self.udp6[0] = b
                if self.pos == 61:
                    self.udp6[1] = b
                if tl:
                    self.err = int(te) if te.is_resolvable else None
                    self.frames += 1
                    self.pos = 0
                else:
                    self.pos += 1


async def send_frame(dut, frame):
    """Each byte driven on the falling edge, then held until s_axis_tready is
    high at a rising edge (read settled just before that edge)."""
    for k in range(len(frame)):
        await FallingEdge(dut.clk)
        dut.s_axis_tdata.value = frame[k]
        dut.s_axis_tvalid.value = 1
        dut.s_axis_tlast.value = 1 if k == len(frame) - 1 else 0
        while True:
            await ReadOnly()
            ready = bit(dut.s_axis_tready)
            await RisingEdge(dut.clk)
            if ready:
                break
    await FallingEdge(dut.clk)
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def tb_eth_mac_sys_csum_loop(dut):
    c = Checks(dut._log)
    start_clock(dut.clk, 10)
    for s in (dut.mii_tx_clk, dut.mii_rx_clk):
        cocotb.start_soon(Clock(s, 40, unit="ns").start(start_high=False))
    dut.rst_n.value = 0
    axil = AxiLiteMaster(dut, dut.clk)
    dut.s_axis_tdata.value = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    dut.m_axis_tready.value = 1
    for s in (dut.mii_rx_er, dut.mii_col, dut.mii_crs, dut.clk_125, dut.clk_125_90,
              dut.clk_25, dut.clk_2_5, dut.rgmii_rx_ctl, dut.rgmii_rxc):
        s.value = 0
    dut.rgmii_rxd.value = 0
    rx = RxCapture(dut)
    cocotb.start_soon(mii_loopback(dut))
    cocotb.start_soon(mdio_loop(dut))
    cocotb.start_soon(rx.run())

    await Timer(100, "ns")
    dut.rst_n.value = 1
    await Timer(100, "ns")

    async def run_frame(ctrl, frame=FRAME):
        await axil.write(0x04, ctrl)
        n0 = rx.frames
        await send_frame(dut, frame)
        await ClockCycles(dut.clk, 4000)
        c.eq("frames received", rx.frames - n0, 1)

    await axil.write(0x04, 0x000002A7)
    c.eq("CTRL readback with [9]", await axil.read(0x04), 0x000002A7)

    dut._log.info("--- A: TX insert + RX verify ---")
    await run_frame(0x000002A7)
    c.eq("A ip csum", rx.ip_csum, 0xA440)
    c.eq("A udp csum", rx.udp_csum, 0x4EF6)
    c.eq("A terror", rx.err, 0)
    c.eq("A RX_ERR_CSUM", await axil.read(0x80), 0)

    dut._log.info("--- B: wrong checksums, RX verify on ---")
    await run_frame(0x00000227)
    c.eq("B ip csum", rx.ip_csum, 0xDEAD)
    c.eq("B udp csum", rx.udp_csum, 0xBEEF)
    c.eq("B terror", rx.err, 1)
    c.eq("B RX_ERR_CSUM", await axil.read(0x80), 1)
    c.eq("B RX_ERR", await axil.read(0x38), 1)

    dut._log.info("--- C: wrong checksums, RX verify off ---")
    await run_frame(0x00000027)
    c.eq("C terror", rx.err, 0)
    c.eq("C RX_ERR_CSUM", await axil.read(0x80), 1)

    dut._log.info("--- D: write clears RX_ERR_CSUM ---")
    await axil.write(0x80, 0)
    c.eq("D RX_ERR_CSUM", await axil.read(0x80), 0)

    dut._log.info("--- E: IPv6 UDP checksum 0, RX verify on ---")
    await run_frame(0x00000227, ipv6_frame(0x0000))
    c.eq("E udp csum", rx.udp6_csum, 0x0000)
    c.eq("E terror", rx.err, 0)
    c.eq("E RX_ERR_CSUM", await axil.read(0x80), 0)

    dut._log.info("--- F: IPv6 UDP checksum wrong, RX verify on ---")
    await run_frame(0x00000227, ipv6_frame(0xBEEF))
    c.eq("F terror", rx.err, 1)
    c.eq("F RX_ERR_CSUM", await axil.read(0x80), 1)

    c.finish()
