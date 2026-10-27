# SPDX-License-Identifier: Apache-2.0
"""cocotb port of sim/tb/tb_eth_mac_sys_csum.v (build_and_test.py benches
ETH-MAC-SYS-CSUM and ETH-MAC-SYS-CSUM-BYPASS).

The bench's -DTB_TX_CSUM_OFFLOAD define sets the DUT parameter
TX_CSUM_OFFLOAD (1 with the define, 0 without) and selects which checksum
checks run. Here each variant is a suite: the parameter goes to the DUT and
the same value reaches the test as TB_TX_CSUM_OFFLOAD in the environment.
  eth_mac_sys_csum         ETH-MAC-SYS-CSUM          TX_CSUM_OFFLOAD=1
  eth_mac_sys_csum_bypass  ETH-MAC-SYS-CSUM-BYPASS   TX_CSUM_OFFLOAD=0

eth_mac_sys, PHY_INTERFACE="MII", MAX_FRAME=2048, 100 MHz clk, one 25 MHz
clock on mii_tx_clk and mii_rx_clk (two clocks of the same period and phase
here), MII RX pins tied idle, m_axis_tready tied 1, mdio_i follows mdio_o.
CTRL is written 0xA7 (tx_en, rx_en, promisc, full_duplex, tx_csum_off). One
60-byte IPv4/UDP frame with IP checksum 0xDEAD and UDP checksum 0xBEEF is sent
(bytes driven on the falling edge, tready tested at the next falling edge).
The bench's MII wire capture is mirrored on the rising edge of the MII clock:
nibbles low-then-high into a 128-byte buffer until mii_tx_en falls.

Checks, in bench order:
  0  CAPS (0x98) == {MAX_FRAME 2048, RX_CSUM 0, TX_CSUM_OFFLOAD, MCAST 0}: the
     wrapper reports its parameters (not in the Verilog bench)
  1  SFD (0xD5) found in the capture (the bench stops here if not)
  2  data_len (bytes after SFD minus 4 FCS bytes) >= 60
  TX_CSUM_OFFLOAD=1:
  3  IP checksum == the one recomputed over the captured IP header
  4  IP checksum != 0xDEAD
  5  UDP checksum == 0x4EF6
  TX_CSUM_OFFLOAD=0:
  3  IP checksum still 0xDEAD
  4  UDP checksum still 0xBEEF
  last  bytes 0, 12, 13, 14, 26, 33, 42 unmodified
No $random in the bench.
"""
import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer

from lib.axil_master import AxiLiteMaster
from lib.bench import Checks
from lib.mac_sys_a import bit, mdio_loop, start_clock

SUITES = {
    "eth_mac_sys_csum": {
        "toplevel": "eth_mac_sys",
        "sources": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                    "rtl/sync_fifo.v", "rtl/net/csum_calc.v", "rtl/eth_mac_rx.v",
                    "rtl/eth_mac_tx.v", "rtl/eth_stats.v", "rtl/eth_pause_rx.v", "rtl/eth_pause.v",
                    "rtl/axilite_regs.v", "rtl/mdio_master.v", "rtl/ddr_output.v",
                    "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                    "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v", "rtl/mii_tx_saf.v",
                    "rtl/eth_mac_sys.v"],
        "params": {"PHY_INTERFACE": "MII", "MAX_FRAME": 2048, "TX_CSUM_OFFLOAD": 1},
        "env": {"TB_TX_CSUM_OFFLOAD": "1"},
    },
    "eth_mac_sys_csum_bypass": {
        "toplevel": "eth_mac_sys",
        "sources": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                    "rtl/sync_fifo.v", "rtl/net/csum_calc.v", "rtl/eth_mac_rx.v",
                    "rtl/eth_mac_tx.v", "rtl/eth_stats.v", "rtl/eth_pause_rx.v", "rtl/eth_pause.v",
                    "rtl/axilite_regs.v", "rtl/mdio_master.v", "rtl/ddr_output.v",
                    "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                    "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v", "rtl/mii_tx_saf.v",
                    "rtl/eth_mac_sys.v"],
        "params": {"PHY_INTERFACE": "MII", "MAX_FRAME": 2048, "TX_CSUM_OFFLOAD": 0},
        "env": {"TB_TX_CSUM_OFFLOAD": "0"},
    },
}

TX_CSUM_PARAM = int(os.environ.get("TB_TX_CSUM_OFFLOAD", "1"))
FRAME_LEN = 60


def build_frame():
    f = [0xFF] * 6
    f += [0x02, 0x11, 0x22, 0x33, 0x44, 0x55]
    f += [0x08, 0x00]
    f += [0x45, 0x00, 0x00, 0x2E, 0x12, 0x34, 0x40, 0x00, 0x40, 0x11,
          0xDE, 0xAD,                                   # bogus IP csum
          0xC0, 0xA8, 0x01, 0x32, 0xC0, 0xA8, 0x01, 0xC8]
    f += [0x12, 0x34, 0x56, 0x78, 0x00, 0x1A,
          0xBE, 0xEF]                                   # bogus UDP csum
    f += [i & 0xFF for i in range(42, FRAME_LEN)]
    assert len(f) == FRAME_LEN
    return f


class MiiCapture:
    """The bench's always @(posedge mii_clk) wire capture (values as sampled
    at that edge, i.e. settled since the falling edge before it)."""

    def __init__(self, dut):
        self.dut = dut
        self.buf = [None] * 128
        self.byte_cnt = 0
        self.done = 0
        self.en_d1 = 0
        self.nsel = 0
        self.lown = 0

    async def run(self):
        d = self.dut
        clk = d.mii_tx_clk
        await ReadOnly()
        rst_n, en = bit(d.rst_n), bit(d.mii_tx_en)
        txd = d.mii_txd.value
        while True:
            await RisingEdge(clk)
            if not rst_n:
                self.byte_cnt = self.done = self.en_d1 = self.nsel = self.lown = 0
            else:
                cnt, done, en_d1 = self.byte_cnt, self.done, self.en_d1
                self.en_d1 = en
                if en and not done:
                    nib = int(txd) if txd.is_resolvable else None
                    if not self.nsel:
                        self.lown = nib
                        self.nsel = 1
                    else:
                        if cnt < 128:
                            self.buf[cnt] = (None if nib is None or self.lown is None
                                             else (nib << 4) | self.lown)
                        self.byte_cnt = cnt + 1
                        self.nsel = 0
                if en_d1 and not en and cnt > 0:
                    self.done = 1
            await FallingEdge(clk)
            await ReadOnly()
            rst_n, en = bit(d.rst_n), bit(d.mii_tx_en)
            txd = d.mii_txd.value


def ip_csum_compute(b):
    """The bench's ip_csum_compute over bytes 14..23 and 26..33 of `b`."""
    words = [(b[i] << 8) | b[i + 1] for i in (14, 16, 18, 20, 22, 26, 28, 30, 32)]
    s = sum(words)
    f1 = (s & 0xFFFF) + (s >> 16)
    f2 = ((f1 & 0xFFFF) + (f1 >> 16)) & 0xFFFF
    return ~f2 & 0xFFFF


@cocotb.test(timeout_time=200, timeout_unit="us")
async def tb_eth_mac_sys_csum(dut):
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
    dut.mii_rxd.value = 0
    for s in (dut.mii_rx_dv, dut.mii_rx_er, dut.mii_col, dut.mii_crs,
              dut.clk_125, dut.clk_125_90, dut.clk_25, dut.clk_2_5,
              dut.rgmii_rx_ctl, dut.rgmii_rxc):
        s.value = 0
    dut.rgmii_rxd.value = 0
    cap = MiiCapture(dut)
    cocotb.start_soon(mdio_loop(dut))
    cocotb.start_soon(cap.run())

    await Timer(100, "ns")
    dut.rst_n.value = 1
    await Timer(100, "ns")

    dut._log.info("INFO: TX_CSUM_OFFLOAD=%d, CTRL[7] should %s", TX_CSUM_PARAM,
                  "patch checksums" if TX_CSUM_PARAM else "be a no-op")
    caps = await axil.read(0x98)
    c.eq("CAPS", caps, (2048 << 16) | (TX_CSUM_PARAM << 1))
    await axil.write(0x04, 0x000000A7)

    # Send the frame: driven on the falling edge, tready tested at the next one
    frame = build_frame()
    await FallingEdge(dut.clk)
    for k, b in enumerate(frame):
        dut.s_axis_tdata.value = b
        dut.s_axis_tvalid.value = 1
        dut.s_axis_tlast.value = 1 if k == FRAME_LEN - 1 else 0
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            ready = bit(dut.s_axis_tready)
            await FallingEdge(dut.clk)
            if ready:
                break
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0

    await Timer(20000, "ns")

    g = cap.buf
    n = cap.byte_cnt
    base = -1
    for k in range(n - 1):
        if g[k] == 0xD5:
            base = k + 1
            break
    if not c.check(f"SFD found at byte {base - 1}, data starts at {base}"
                   if base >= 0 else "SFD (0xD5) not found in GMII capture", base >= 0):
        c.finish()
        return

    data_len = n - base - 4
    c.check(f"GMII data_len={data_len} (>= FRAME_LEN={FRAME_LEN}, padding ok; "
            f"gmii_byte_cnt={n}, base={base})",
            data_len >= FRAME_LEN)

    d = [g[base + i] if base + i < 128 else None for i in range(FRAME_LEN)]

    def word(i):
        if d[i] is None or d[i + 1] is None:
            return None
        return (d[i] << 8) | d[i + 1]

    ip, udp = word(24), word(40)

    def h(x):
        return "X" if x is None else f"0x{x:04x}"

    hdr = [d[i] for i in list(range(14, 24)) + list(range(26, 34))]
    exp_ip = ip_csum_compute(d) if None not in hdr else None
    if TX_CSUM_PARAM:
        c.check(f"IP checksum patched = {h(ip)} (expected {h(exp_ip)})",
                ip is not None and ip == exp_ip)
        c.check(f"IP checksum overwritten (not still 0xDEAD): {h(ip)}", ip != 0xDEAD)
        c.check(f"UDP checksum inserted = {h(udp)} (expected 0x4ef6)",
                d[40] == 0x4E and d[41] == 0xF6)
    else:
        c.check(f"IP checksum preserved with TX_CSUM_OFFLOAD=0: {h(ip)}", ip == 0xDEAD)
        c.check(f"UDP checksum preserved with TX_CSUM_OFFLOAD=0: {h(udp)}", udp == 0xBEEF)

    c.check("unmodified bytes intact",
            d[0] == 0xFF and d[12] == 0x08 and d[13] == 0x00 and d[14] == 0x45
            and d[26] == 0xC0 and d[33] == 0xC8 and d[42] == 0x2A)
    c.finish()
