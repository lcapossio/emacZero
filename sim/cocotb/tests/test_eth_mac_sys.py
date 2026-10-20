# SPDX-License-Identifier: Apache-2.0
"""cocotb port of sim/tb/tb_eth_mac_sys.v (build_and_test.py bench ETH-MAC-SYS).

eth_mac_sys, PHY_INTERFACE="MII", RX_AXIS_ADDR_WIDTH=11 (2 KiB RX FIFO), other
parameters at their defaults. 100 MHz clk; one 25 MHz clock drives both
mii_tx_clk and mii_rx_clk (the bench ties them to one net; here two clocks
with the same period and phase). Bench processes mirrored here:
  - MII loopback: mii_rxd / mii_rx_dv <= mii_txd / mii_tx_en on each rising
    edge of the MII clock (a one-cycle register, as in the bench).
  - mdio_i follows mdio_o.
  - The RX sink: drives m_axis_tready on the falling edge of clk; holds it low
    while sink_hold, or on a TLAST word while sink_park_tlast, or for 20
    cycles on each TLAST word while sink_stall_tlast.
  - The RX counters on the rising edge of clk: rx_byte_cnt / rx_frame_cnt
    (tvalid runs, independent of tready) and rx_tlast_hs / rx_tlast_err_hs
    (TLAST handshakes, those with terror).
  - The AXIS send_frame task: dst MAC, src 02:00:00:00:00:01, EtherType
    0x0800, payload of incrementing bytes; driven on the falling edge, tready
    tested at the next falling edge.
The bench leaves the phy_gmii_* inputs unconnected (Z); they stay undriven
here too (U on GHDL); the MII build does not use them.

Checks, in bench order (26 printed by the Verilog bench: Test 6 is one check
when a frame was received, else a SKIP line):
  T1  VERSION == rtl/version.vh value
  T2  MAC_LO readback 0xFFFFFFFF
  T3  CTRL promisc readback 0x7
  T4  >= 1 frame received via MII loopback
  T5  TX_FRAME_CNT nonzero; TX_BYTE_CNT nonzero
  T6  RX_FRAME_CNT nonzero (only if T4 saw a frame)
  T7  TX_FRAME_CNT after clear == 0
  T8  STATUS mdio_busy cleared after an MDIO read
  T9  stalled sink: TLAST handshakes 3, RX_FRAME 3, RX_ERR 0
  T10 RX FIFO full: TLAST handshakes 5, terror handshakes 1, RX_FRAME 5,
      RX_ERR 1, RX_ERR_OVERFLOW 1, RX_DROP 3, RX_DROP after clear 0
  T11 TLAST parked: TLAST handshakes 0, RX_FRAME 0, RX_ERR 0; released:
      terror handshakes 1, RX_FRAME 1, RX_ERR 1, RX_ERR_OVERSIZE 1
No $random in the bench.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer

from lib.axil_master import AxiLiteMaster
from lib.bench import Checks, VERSION
from lib.mac_sys_a import bit, mdio_loop, sample_pre, start_clock

SUITES = {
    "eth_mac_sys": {
        "toplevel": "eth_mac_sys",
        "sources": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                    "rtl/sync_fifo.v", "rtl/net/csum_calc.v", "rtl/eth_mac_rx.v",
                    "rtl/eth_mac_tx.v", "rtl/eth_stats.v", "rtl/eth_pause.v",
                    "rtl/axilite_regs.v", "rtl/mdio_master.v", "rtl/ddr_output.v",
                    "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                    "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v", "rtl/mii_tx_saf.v",
                    "rtl/eth_mac_sys.v"],
        "params": {"PHY_INTERFACE": "MII", "RX_AXIS_ADDR_WIDTH": 11},
    },
}

TLAST_STALL = 20


async def mii_loopback(dut):
    """always @(posedge mii_rx_clk) {rxd, rx_dv} <= {txd, tx_en}. mii_txd
    changes only on the rising edge of the (same) MII clock, so the value a
    flop samples there is the one settled since the falling edge. A value with
    X/U bits is not copied (the input then keeps its last value)."""
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


class RxSide:
    """The bench's RX sink (negedge) and its two RX counter blocks (posedge)."""

    def __init__(self, dut):
        self.dut = dut
        self.sink_stall_tlast = 0
        self.sink_park_tlast = 0
        self.sink_hold = 0
        self.tlast_stall_cnt = 0
        self.rx_byte_cnt = 0
        self.rx_frame_cnt = 0
        self.rx_cap = 0
        self.rx_tlast_hs = 0
        self.rx_tlast_err_hs = 0

    async def sink(self):
        d = self.dut
        while True:
            # rx_tvalid / rx_tlast as seen at the falling edge: settled after
            # the rising edge before it.
            await RisingEdge(d.clk)
            await ReadOnly()
            tv, tl = bit(d.m_axis_tvalid), bit(d.m_axis_tlast)
            await FallingEdge(d.clk)
            if self.sink_hold or (self.sink_park_tlast and tv and tl):
                d.m_axis_tready.value = 0
            elif (self.sink_stall_tlast and tv and tl
                  and self.tlast_stall_cnt < TLAST_STALL):
                d.m_axis_tready.value = 0
                self.tlast_stall_cnt += 1
            else:
                d.m_axis_tready.value = 1
                if tv and tl:
                    self.tlast_stall_cnt = 0

    async def counters(self):
        d = self.dut
        while True:
            rst_n, tv, tr, tl, te = await sample_pre(
                d.clk, d.rst_n, d.m_axis_tvalid, d.m_axis_tready,
                d.m_axis_tlast, d.m_axis_terror)
            await RisingEdge(d.clk)
            if not rst_n:
                self.rx_byte_cnt = self.rx_frame_cnt = self.rx_cap = 0
                self.rx_tlast_hs = self.rx_tlast_err_hs = 0
                continue
            if tv:
                self.rx_byte_cnt += 1
                self.rx_cap = 1
            elif self.rx_cap:
                self.rx_frame_cnt += 1
                self.rx_cap = 0
            if tv and tr and tl:
                self.rx_tlast_hs += 1
                if te:
                    self.rx_tlast_err_hs += 1


async def send_frame(dut, dst_mac, payload_len):
    """The bench's send_frame: bytes driven on the falling edge; each is held
    until s_axis_tready reads high at a later falling edge (read settled after
    the rising edge before it, where it does not change until that falling
    edge)."""
    total = 14 + payload_len
    data = [(dst_mac >> (40 - 8 * k)) & 0xFF for k in range(6)]
    data += [0x02, 0x00, 0x00, 0x00, 0x00, 0x01, 0x08, 0x00]
    data += [k & 0xFF for k in range(payload_len)]
    assert len(data) == total
    await FallingEdge(dut.clk)
    for k, b in enumerate(data):
        dut.s_axis_tdata.value = b
        dut.s_axis_tvalid.value = 1
        dut.s_axis_tlast.value = 1 if k == total - 1 else 0
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            ready = bit(dut.s_axis_tready)
            await FallingEdge(dut.clk)
            if ready:
                break
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tb_eth_mac_sys(dut):
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
    dut.mii_rx_er.value = 0
    dut.mii_col.value = 0
    dut.mii_crs.value = 0
    for s in (dut.clk_125, dut.clk_125_90, dut.clk_25, dut.clk_2_5,
              dut.rgmii_rx_ctl, dut.rgmii_rxc):
        s.value = 0
    dut.rgmii_rxd.value = 0
    rx = RxSide(dut)
    cocotb.start_soon(mii_loopback(dut))
    cocotb.start_soon(mdio_loop(dut))
    cocotb.start_soon(rx.sink())
    cocotb.start_soon(rx.counters())

    await Timer(100, "ns")
    dut.rst_n.value = 1
    await Timer(100, "ns")

    # Test 1: VERSION
    c.eq("VERSION", await axil.read(0x00), VERSION)

    # Test 2: MAC address
    await axil.write(0x0C, 0xFFFFFFFF)
    await axil.write(0x10, 0x0000FFFF)
    c.eq("MAC_LO", await axil.read(0x0C), 0xFFFFFFFF)

    # Test 3: tx_en, rx_en, promisc
    await axil.write(0x04, 0x00000007)
    c.eq("CTRL promisc", await axil.read(0x04), 0x00000007)

    # Test 4: one frame through the MII loopback
    rx.rx_byte_cnt = 0
    rx.rx_frame_cnt = 0
    await send_frame(dut, 0xFFFFFFFFFFFF, 50)
    await Timer(200000, "ns")
    c.check(f"received {rx.rx_frame_cnt} frame(s) via MII loopback (expected >= 1)",
            rx.rx_frame_cnt >= 1)
    got_frame = rx.rx_frame_cnt >= 1

    # Test 5: TX stats
    v = await axil.read(0x28)
    c.check(f"TX_FRAME_CNT = {v} (nonzero)", isinstance(v, int) and v != 0)
    v = await axil.read(0x2C)
    c.check(f"TX_BYTE_CNT = {v} (nonzero)", isinstance(v, int) and v != 0)

    # Test 6: RX stats
    v = await axil.read(0x30)
    if got_frame:
        c.check(f"RX_FRAME_CNT = {v} (nonzero)", isinstance(v, int) and v != 0)
    else:
        dut._log.info("SKIP: RX_FRAME_CNT (no frame received)")

    # Test 7: clear TX stats
    await axil.write(0x28, 0)
    await Timer(50, "ns")
    c.eq("TX_FRAME_CNT after clear", await axil.read(0x28), 0)

    # Test 8: MDIO read command
    await axil.write(0x14, 0x00000800)
    await Timer(80000, "ns")
    v = await axil.read(0x08)
    c.eq("STATUS mdio_busy cleared", v & 0x4 if isinstance(v, int) else v, 0)

    # Test 9: RX_FRAME counts each frame once under a stalled sink
    await axil.write(0x04, 0x00000003)
    await axil.write(0x30, 0)
    rx.sink_stall_tlast = 1
    rx.rx_tlast_hs = 0
    for _ in range(3):
        await send_frame(dut, 0xFFFFFFFFFFFF, 50)
    await Timer(100000, "ns")
    rx.sink_stall_tlast = 0
    c.eq("TLAST handshakes (stalled sink)", rx.rx_tlast_hs, 3)
    c.eq("RX_FRAME (stalled sink)", await axil.read(0x30), 3)
    c.eq("RX_ERR (stalled sink)", await axil.read(0x38), 0)

    # Test 10: RX FIFO full -> RX_ERR_OVERFLOW / RX_DROP
    await axil.write(0x30, 0)
    rx.rx_tlast_hs = 0
    rx.rx_tlast_err_hs = 0
    rx.sink_hold = 1
    for _ in range(8):
        await send_frame(dut, 0xFFFFFFFFFFFF, 400)
    await send_frame(dut, 0x020000000099, 400)   # not for us
    await Timer(400000, "ns")
    rx.sink_hold = 0
    await Timer(100000, "ns")
    c.eq("TLAST handshakes (FIFO full)", rx.rx_tlast_hs, 5)
    c.eq("terror handshakes (FIFO full)", rx.rx_tlast_err_hs, 1)
    c.eq("RX_FRAME (FIFO full)", await axil.read(0x30), 5)
    c.eq("RX_ERR (FIFO full)", await axil.read(0x38), 1)
    c.eq("RX_ERR_OVERFLOW (FIFO full)", await axil.read(0x50), 1)
    c.eq("RX_DROP (FIFO full)", await axil.read(0x7C), 3)
    await axil.write(0x7C, 0)
    c.eq("RX_DROP after clear", await axil.read(0x7C), 0)

    # Test 11: an errored (oversize) frame is counted once, when the sink
    # takes its TLAST
    await axil.write(0x30, 0)
    rx.rx_tlast_hs = 0
    rx.rx_tlast_err_hs = 0
    rx.sink_park_tlast = 1
    await send_frame(dut, 0xFFFFFFFFFFFF, 1504)
    await Timer(200000, "ns")
    c.eq("TLAST handshakes (TLAST parked)", rx.rx_tlast_hs, 0)
    c.eq("RX_FRAME (TLAST parked)", await axil.read(0x30), 0)
    c.eq("RX_ERR (TLAST parked)", await axil.read(0x38), 0)
    rx.sink_park_tlast = 0
    await Timer(1000, "ns")
    c.eq("terror handshakes (released)", rx.rx_tlast_err_hs, 1)
    c.eq("RX_FRAME (released)", await axil.read(0x30), 1)
    c.eq("RX_ERR (released)", await axil.read(0x38), 1)
    c.eq("RX_ERR_OVERSIZE (released)", await axil.read(0x54), 1)

    await Timer(100, "ns")
    c.finish()
