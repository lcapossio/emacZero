# SPDX-License-Identifier: Apache-2.0
"""Received PAUSE frames act as soon as they end at the PHY pins (802.3
Annex 31B), on the receive side and at the TX pins.

eth_mac_sys recognizes PAUSE frames on the PHY receive stream, ahead of the
RX FIFO (eth_pause_rx), so the TX gate does not wait for the frames buffered
ahead of a PAUSE frame to be replayed. 802.3 Annex 31B allows 512 bit times
(1024 at 1 Gb/s, MDI to MDI) from the end of a PAUSE frame until no new data
frame starts. These suites give the receive side a quarter of that: from
RX_DV falling at the PHY pins to eth_mac_sys's internal tx_paused.

One suite per receive path, each with its own byte format:
  eth_mac_sys_pause_rx_gmii       GMII, 1G, bytes on phy_gmii_rx_clk (125 MHz)
  eth_mac_sys_pause_rx_mii        MII, 100M, nibbles on mii_rx_clk (25 MHz)
  eth_mac_sys_pause_rx_rgmii100   RGMII 10/100 at 100M, rgmii_rxc 25 MHz
  eth_mac_sys_pause_rx_rgmii10    RGMII 10/100 at 10M, rgmii_rxc 2.5 MHz
sys clk is 125 MHz on GMII and 100 MHz on the others. m_axis_tready is 1.
The tests drive the RX pins only; the TX pins are not looped back.

pause_rx checks, per suite:
  1 a lone PAUSE frame (quanta 0xFFFF): tx_paused within the budget;
    PAUSE_RX_CNT = 1; PAUSE quanta 0 releases it within the budget
  2 a PAUSE frame right behind a 1514-byte frame (minimum IFG): tx_paused
    within the budget, so it did not wait for the long frame to be replayed
  3 quanta 1 and 2 at three phases each: tx_paused lasts at least that many
    full pause quanta and at most one sys clock more (the quantum prescaler
    restarts on every PAUSE frame)
  4 not valid, so not counted and no pause: bad FCS; rx_er on one byte (on
    MII on the low nibble of a byte; not on RGMII); 56-byte frame

pause_tx checks, per suite, with minimum-size data frames queued all along
(up to 4 not yet at the TX pins) and the TX pins monitored (frame start =
first TX_EN sample):
  1 a PAUSE frame (quanta 0xFFFF) ending at 8 phases across a data frame
    period: at most one data frame starts in the budget after RX_DV fell,
    none after it until quanta 0, and data resumes after quanta 0
  2 paused: PAUSE_CTRL.tx_send sends our PAUSE frame (72 wire bytes, our
    quanta) while the data frames stay held
  3 every data frame reached the pins once, in order, with a good FCS
  4 GMII / RGMII 100M: a data frame and a PAUSE frame leave their framers
    together, at 41 offsets; TX_FRAME and TX_BYTE count both, and the sweep
    saw the byte events and the frame-done events in the same clock
"""
import os
import zlib

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer
from cocotb.utils import get_sim_time

from lib.axil_master import AxiLiteMaster
from lib.bench import Checks
from lib.mac_sys_a import bit


SUITES = {
    "eth_mac_sys_pause_rx_gmii": {
        "toplevel": "eth_mac_sys",
        "sources": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                    "rtl/sync_fifo.v", "rtl/net/csum_calc.v", "rtl/eth_mac_rx.v",
                    "rtl/eth_mac_tx.v", "rtl/eth_stats.v", "rtl/eth_pause_rx.v", "rtl/eth_pause.v",
                    "rtl/axilite_regs.v", "rtl/mdio_master.v", "rtl/ddr_output.v",
                    "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                    "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v", "rtl/mii_tx_saf.v",
                    "rtl/eth_mac_sys.v"],
        "params": {"PHY_INTERFACE": "GMII", "MAX_FRAME": 1518,
                   "CLK_FREQ_HZ": 125000000},
        "env": {"PAUSE_RX_MODE": "gmii"},
    },
    "eth_mac_sys_pause_rx_mii": {
        "toplevel": "eth_mac_sys",
        "sources": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                    "rtl/sync_fifo.v", "rtl/net/csum_calc.v", "rtl/eth_mac_rx.v",
                    "rtl/eth_mac_tx.v", "rtl/eth_stats.v", "rtl/eth_pause_rx.v", "rtl/eth_pause.v",
                    "rtl/axilite_regs.v", "rtl/mdio_master.v", "rtl/ddr_output.v",
                    "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                    "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v", "rtl/mii_tx_saf.v",
                    "rtl/eth_mac_sys.v"],
        "params": {"PHY_INTERFACE": "MII", "MAX_FRAME": 1518,
                   "CLK_FREQ_HZ": 100000000},
        "env": {"PAUSE_RX_MODE": "mii"},
    },
    "eth_mac_sys_pause_rx_rgmii100": {
        "toplevel": "eth_mac_sys",
        "sources": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                    "rtl/sync_fifo.v", "rtl/net/csum_calc.v", "rtl/eth_mac_rx.v",
                    "rtl/eth_mac_tx.v", "rtl/eth_stats.v", "rtl/eth_pause_rx.v", "rtl/eth_pause.v",
                    "rtl/axilite_regs.v", "rtl/mdio_master.v", "rtl/ddr_output.v",
                    "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                    "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v", "rtl/mii_tx_saf.v",
                    "rtl/eth_mac_sys.v"],
        "params": {"PHY_INTERFACE": "RGMII", "MAX_FRAME": 1518,
                   "RGMII_SPEEDS": "10_100", "CLK_FREQ_HZ": 100000000},
        "env": {"PAUSE_RX_MODE": "rgmii100"},
    },
    "eth_mac_sys_pause_rx_rgmii10": {
        "toplevel": "eth_mac_sys",
        "sources": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                    "rtl/sync_fifo.v", "rtl/net/csum_calc.v", "rtl/eth_mac_rx.v",
                    "rtl/eth_mac_tx.v", "rtl/eth_stats.v", "rtl/eth_pause_rx.v", "rtl/eth_pause.v",
                    "rtl/axilite_regs.v", "rtl/mdio_master.v", "rtl/ddr_output.v",
                    "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                    "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v", "rtl/mii_tx_saf.v",
                    "rtl/eth_mac_sys.v"],
        "params": {"PHY_INTERFACE": "RGMII", "MAX_FRAME": 1518,
                   "RGMII_SPEEDS": "10_100", "CLK_FREQ_HZ": 100000000},
        "env": {"PAUSE_RX_MODE": "rgmii10"},
    },
}

MODE = os.environ.get("PAUSE_RX_MODE", "gmii")

# Per mode: sys clk period (ns), PHY RX clock period (ns), CTRL[4:3] speed,
# bit time (ns), pause quantum in sys clocks (eth_mac_sys PAUSE_DIV_*).
if MODE == "gmii":
    SYS_NS, RXC_NS, SPEED, BIT_NS, QUANTUM_CLKS = 8, 8, 0b00, 1, 64
    BOUND_BITS = 1024
elif MODE == "mii":
    SYS_NS, RXC_NS, SPEED, BIT_NS, QUANTUM_CLKS = 10, 40, 0b01, 10, 512
    BOUND_BITS = 512
elif MODE == "rgmii100":
    SYS_NS, RXC_NS, SPEED, BIT_NS, QUANTUM_CLKS = 10, 40, 0b01, 10, 512
    BOUND_BITS = 512
else:
    SYS_NS, RXC_NS, SPEED, BIT_NS, QUANTUM_CLKS = 10, 400, 0b10, 100, 5120
    BOUND_BITS = 512
BOUND_NS = BOUND_BITS * BIT_NS
BUDGET_NS = BOUND_NS / 4
BYTE_NS = 8 * BIT_NS


def now_ns():
    return get_sim_time(unit="ns")


def wire(frame, bad_fcs=False):
    fcs = zlib.crc32(bytes(frame)) & 0xFFFFFFFF
    if bad_fcs:
        fcs ^= 1
    return [0x55] * 7 + [0xD5] + list(frame) + [(fcs >> (8 * i)) & 0xFF for i in range(4)]


def pause_frame(quanta, length=60):
    f = [0x01, 0x80, 0xC2, 0, 0, 0x01, 0x02, 0x11, 0x22, 0x33, 0x44, 0x55,
         0x88, 0x08, 0x00, 0x01, quanta >> 8, quanta & 0xFF]
    return f + [0] * (length - len(f))


def data_frame(n):
    f = [0xFF] * 6 + [0x02, 0x11, 0x22, 0x33, 0x44, 0x55, 0x08, 0x00]
    return f + [i & 0xFF for i in range(n - len(f))]


class RxPins:
    """Drives one PHY's receive pins. send() returns the time RX_DV fell."""

    def __init__(self, dut):
        self.dut = dut
        if MODE == "gmii":
            self.clk = dut.phy_gmii_rx_clk
        elif MODE == "mii":
            self.clk = dut.mii_rx_clk
        else:
            self.clk = dut.rgmii_rxc

    async def _slot(self):
        """Wait until the next point where the pins may change."""
        if MODE in ("gmii", "mii"):
            await FallingEdge(self.clk)
        else:
            # RGMII 10/100: one nibble per RXC cycle, the same on both edges
            # (rgmii_if pairs a rising edge with the falling edge after it);
            # change it a quarter cycle after the falling edge.
            await FallingEdge(self.clk)
            await Timer(RXC_NS // 4, "ns")

    def _drive(self, nib_or_byte, dv, er):
        d = self.dut
        if MODE == "gmii":
            d.phy_gmii_rxd.value = nib_or_byte
            d.phy_gmii_rx_dv.value = dv
            d.phy_gmii_rx_er.value = er
        elif MODE == "mii":
            d.mii_rxd.value = nib_or_byte
            d.mii_rx_dv.value = dv
            d.mii_rx_er.value = er
        else:
            d.rgmii_rxd.value = nib_or_byte
            d.rgmii_rx_ctl.value = dv

    async def send(self, byts, er_at=None):
        for i, b in enumerate(byts):
            er = 1 if i == er_at else 0
            if MODE == "gmii":
                await self._slot()
                self._drive(b, 1, er)
            elif MODE == "mii":
                await self._slot()
                self._drive(b & 0xF, 1, er)      # rx_er on the low nibble
                await self._slot()
                self._drive(b >> 4, 1, 0)
            else:
                await self._slot()
                self._drive(b & 0xF, 1, 0)
                await self._slot()
                self._drive(b >> 4, 1, 0)
        await self._slot()
        self._drive(0, 0, 0)
        t_end = now_ns()
        idle_slots = 12 if MODE == "gmii" else 24
        for _ in range(idle_slots - 1):
            await self._slot()
        return t_end


async def bring_up(dut):
    """Clocks, reset, CTRL (TX + RX + promiscuous, speed), PAUSE rx_en."""
    clk = dut.clk
    cocotb.start_soon(Clock(clk, SYS_NS, unit="ns").start(start_high=False))
    cocotb.start_soon(Clock(dut.clk_125, 8, unit="ns").start(start_high=False))
    cocotb.start_soon(Clock(dut.clk_125_90, 8, unit="ns").start(start_high=False))
    for s in (dut.mii_tx_clk, dut.mii_rx_dv, dut.mii_rx_er, dut.mii_rx_clk,
              dut.mii_col, dut.mii_crs, dut.clk_25, dut.clk_2_5,
              dut.rgmii_rx_ctl, dut.rgmii_rxc, dut.phy_gmii_rx_clk,
              dut.phy_gmii_rx_dv, dut.phy_gmii_rx_er):
        s.value = 0
    dut.mii_rxd.value = 0
    dut.rgmii_rxd.value = 0
    dut.phy_gmii_rxd.value = 0
    dut.mdio_i.value = 1
    dut.s_axis_tdata.value = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    dut.m_axis_tready.value = 1
    pins = RxPins(dut)
    if MODE == "mii":
        cocotb.start_soon(Clock(dut.mii_tx_clk, RXC_NS, unit="ns").start(start_high=False))
    await Timer(2, "ns")
    cocotb.start_soon(Clock(pins.clk, RXC_NS, unit="ns").start(start_high=False))
    axil = AxiLiteMaster(dut, clk)
    dut.rst_n.value = 0
    await Timer(200, "ns")
    dut.rst_n.value = 1
    await Timer(500, "ns")
    await axil.write(0x04, 0x07 | (SPEED << 3))   # TX + RX + promiscuous, speed
    await axil.write(0x84, 0x02)                  # honour received PAUSE
    await Timer(40 * RXC_NS, "ns")                # speed settles in the media domain
    dut._log.info("mode %s: budget %.0f ns (bound %d bit times = %.0f ns)",
                  MODE, BUDGET_NS, BOUND_BITS, BOUND_NS)
    return pins, axil


@cocotb.test(timeout_time=60, timeout_unit="ms")
async def pause_rx(dut):
    c = Checks(dut._log)
    clk = dut.clk
    pins, axil = await bring_up(dut)

    async def paused_edge(level):
        """Time of the first sys clock edge where tx_paused reads `level`."""
        while True:
            await RisingEdge(clk)
            await ReadOnly()
            if bit(dut.tx_paused) == level:
                return now_ns()

    async def latency(label, bursts, level=1):
        w = cocotb.start_soon(paused_edge(level))
        t_end = None
        for b in bursts:
            t_end = await pins.send(b)
        t_p = await w
        lat = t_p - t_end
        c.check(f"{label}: tx_paused={level} {lat:.0f} ns after RX_DV fell "
                f"(budget {BUDGET_NS:.0f} ns)", lat <= BUDGET_NS)
        return lat

    # 1. Lone PAUSE frame, then quanta 0 releases it.
    await latency("lone PAUSE", [wire(pause_frame(0xFFFF))])
    c.eq("PAUSE_RX_CNT", await axil.read(0x8C), 1)
    await latency("PAUSE quanta 0", [wire(pause_frame(0))], level=0)

    # 2. PAUSE right behind a 1514-byte frame.
    await latency("PAUSE behind 1514-byte frame",
                  [wire(data_frame(1514)), wire(pause_frame(0xFFFF))])
    await latency("PAUSE quanta 0", [wire(pause_frame(0))], level=0)

    # 3. Full quanta: the prescaler restarts on each PAUSE frame. Measured in
    #    sys clocks from the first cycle tx_paused reads 1 to the first that
    #    reads 0 again.
    async def paused_clocks():
        while True:
            await RisingEdge(clk)
            await ReadOnly()
            if bit(dut.tx_paused):
                break
        n = 0
        while True:
            n += 1
            await RisingEdge(clk)
            await ReadOnly()
            if not bit(dut.tx_paused):
                return n

    for q in (1, 2):
        for phase in range(3):
            await Timer((phase * QUANTUM_CLKS // 3 + 7) * SYS_NS, "ns")
            w = cocotb.start_soon(paused_clocks())
            await pins.send(wire(pause_frame(q)))
            n = await w
            c.check(f"quanta {q}, phase {phase}: paused {n} clocks "
                    f"(expect {q * QUANTUM_CLKS}..{q * QUANTUM_CLKS + 1})",
                    q * QUANTUM_CLKS <= n <= q * QUANTUM_CLKS + 1)

    # 4. Not valid PAUSE frames: not counted, no pause.
    await axil.write(0x8C, 0)
    bad = [("bad FCS", wire(pause_frame(0xFFFF), bad_fcs=True), None),
           ("56-byte frame", wire(pause_frame(0xFFFF, length=52)), None)]
    if MODE in ("gmii", "mii"):
        bad.insert(1, ("rx_er", wire(pause_frame(0xFFFF)), 30))
    for label, byts, er_at in bad:
        await pins.send(byts, er_at=er_at)
        await Timer(BUDGET_NS, "ns")
        c.eq(f"{label}: tx_paused", bit(dut.tx_paused), 0)
        c.eq(f"{label}: PAUSE_RX_CNT", await axil.read(0x8C), 0)

    c.finish()


class TxPins:
    """Collects the frames at one PHY's TX pins: (start time, wire bytes)."""

    def __init__(self, dut):
        self.dut = dut
        self.frames = []

    async def _rgmii_sample(self):
        """TX_CTL / TXD where TXC rises. The DDR outputs are read settled at
        both clk_125 edges (TXC's sim model glitches inside a time step, so
        RisingEdge(rgmii_txc) fires more than once per period); TXD and
        TX_CTL change in the slot where a TXC period starts, and TXC rises
        two slots later."""
        d = self.dut
        while True:
            for edge in (RisingEdge, FallingEdge):
                await edge(d.clk_125)
                await ReadOnly()
                txc = bit(d.rgmii_txc)
                rise = txc and not self.txc_prev
                self.txc_prev = txc
                if rise:
                    return bit(d.rgmii_tx_ctl), int(d.rgmii_txd.value)

    async def run(self):
        d = self.dut
        cur, t0, nib = None, None, []
        self.txc_prev = 1
        while True:
            if MODE == "gmii":
                await RisingEdge(d.clk_125)
                await ReadOnly()
                en, v = bit(d.phy_gmii_tx_en), int(d.phy_gmii_txd.value)
            elif MODE == "mii":
                await FallingEdge(d.mii_tx_clk)
                await ReadOnly()
                en, v = bit(d.mii_tx_en), int(d.mii_txd.value)
            else:
                en, v = await self._rgmii_sample()
            if en:
                if cur is None:
                    cur, t0, nib = [], now_ns(), []
                if MODE == "gmii":
                    cur.append(v)
                else:
                    nib.append(v)
                    if len(nib) == 2:
                        cur.append(nib[0] | (nib[1] << 4))
                        nib = []
            elif cur is not None:
                self.frames.append((t0, cur))
                cur = None

    def starts(self, t_from, t_to=None):
        return [f for f in self.frames
                if f[0] > t_from and (t_to is None or f[0] <= t_to)]


def split(byts):
    """(frame without FCS, FCS good) from wire bytes, or (None, False)."""
    if len(byts) < 8 + 64 or byts[:8] != [0x55] * 7 + [0xD5]:
        return None, False
    f = byts[8:-4]
    fcs = sum(b << (8 * i) for i, b in enumerate(byts[-4:]))
    return f, fcs == (zlib.crc32(bytes(f)) & 0xFFFFFFFF)


def is_ctl(byts):
    f, _ = split(byts)
    return f is not None and f[12:14] == [0x88, 0x08]


async def send_data(dut, n):
    """One minimum-size data frame on s_axis, numbered n in bytes 14-15."""
    clk = dut.clk
    f = data_frame(60)
    f[14], f[15] = (n >> 8) & 0xFF, n & 0xFF
    for k, b in enumerate(f):
        await FallingEdge(clk)
        dut.s_axis_tdata.value = b
        dut.s_axis_tvalid.value = 1
        dut.s_axis_tlast.value = 1 if k == len(f) - 1 else 0
        await ReadOnly()
        while not bit(dut.s_axis_tready):
            await FallingEdge(clk)
            await ReadOnly()
    await FallingEdge(clk)
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0


class Feeder:
    """Keeps numbered data frames queued, at most AHEAD of them not yet at
    the TX pins, until stopped."""

    AHEAD = 4

    def __init__(self, dut, tx):
        self.dut = dut
        self.tx = tx
        self.go = True
        self.sent = 0

    async def run(self):
        while self.go:
            while self.sent - sum(not is_ctl(f[1]) for f in self.tx.frames) >= self.AHEAD:
                await Timer(BYTE_NS, "ns")
            await send_data(self.dut, self.sent)
            self.sent += 1


@cocotb.test(timeout_time=300, timeout_unit="ms")
async def pause_tx(dut):
    c = Checks(dut._log)
    clk = dut.clk
    pins, axil = await bring_up(dut)
    tx = TxPins(dut)
    cocotb.start_soon(tx.run())
    feed = Feeder(dut, tx)
    feed_task = cocotb.start_soon(feed.run())
    frame_ns = 84 * BYTE_NS                       # 72 wire bytes + 12 IFG

    async def wait_frames(n, limit_ns):
        t = now_ns()
        while len(tx.frames) < n and now_ns() - t < limit_ns:
            await Timer(BYTE_NS, "ns")

    await wait_frames(3, 20 * frame_ns)
    c.check(f"data frames flowing before the test: {len(tx.frames)}",
            len(tx.frames) >= 3)

    # 1. Data held within the budget, at 8 phases.
    worst = 0
    for ph in range(8):
        await wait_frames(len(tx.frames) + 2, 10 * frame_ns)
        await Timer(ph * frame_ns // 8 + 1, "ns")
        t_end = await pins.send(wire(pause_frame(0xFFFF)))
        await Timer(int(4 * frame_ns + BUDGET_NS), "ns")
        early = [f for f in tx.starts(t_end, t_end + BUDGET_NS) if not is_ctl(f[1])]
        late = [f for f in tx.starts(t_end + BUDGET_NS) if not is_ctl(f[1])]
        if early:
            worst = max(worst, early[-1][0] - t_end)
        c.check(f"phase {ph}: data frames starting within the budget: {len(early)} (<= 1)",
                len(early) <= 1)
        c.check(f"phase {ph}: data frames starting after the budget while paused: "
                f"{len(late)}", not late)
        n0 = len(tx.frames)
        await pins.send(wire(pause_frame(0)))
        await wait_frames(n0 + 1, 4 * frame_ns + BUDGET_NS)
        c.check(f"phase {ph}: data resumes after quanta 0", len(tx.frames) > n0)
    dut._log.info("latest data frame start after RX_DV fell: %.0f ns (budget %.0f ns)",
                  worst, BUDGET_NS)

    # 2. Our PAUSE frame goes out while paused.
    await pins.send(wire(pause_frame(0xFFFF)))
    await Timer(int(2 * frame_ns + BUDGET_NS), "ns")
    n0 = len(tx.frames)
    await axil.write(0x88, 0x1234)
    await axil.write(0x84, 0x03)                  # rx_en + tx_send
    await Timer(int(4 * frame_ns), "ns")
    new = tx.frames[n0:]
    c.eq("frames out while paused after tx_send", len(new), 1)
    if new:
        f, ok = split(new[0][1])
        c.eq("our PAUSE frame wire bytes", len(new[0][1]), 72)
        c.check("our PAUSE frame: MAC Control, opcode 1, quanta 0x1234, good FCS",
                f is not None and ok and f[12:18] == [0x88, 0x08, 0, 1, 0x12, 0x34])
    n0 = len(tx.frames)
    await pins.send(wire(pause_frame(0)))
    await wait_frames(n0 + 1, 4 * frame_ns + BUDGET_NS)
    c.check("data resumes after quanta 0", len(tx.frames) > n0)

    # 3. Every data frame once, in order, good FCS.
    feed.go = False
    await feed_task
    await Timer(int((Feeder.AHEAD + 4) * frame_ns), "ns")
    seqs, bad = [], 0
    for _, byts in tx.frames:
        if is_ctl(byts):
            continue
        f, ok = split(byts)
        if not ok and not bad:
            dut._log.info("first bad frame: %d bytes: %s", len(byts),
                          " ".join(f"{b:02x}" for b in byts[:24]))
        bad += 0 if ok else 1
        if f is not None:
            seqs.append((f[14] << 8) | f[15])
    c.eq("data frames with a bad FCS or framing", bad, 0)
    c.check(f"data frames 0..{feed.sent - 1} each once, in order ({len(seqs)} seen)",
            seqs == list(range(feed.sent)))

    # 4. Data and PAUSE frames leave their framers together.
    if MODE in ("gmii", "rgmii100"):
        both = {"byte": 0, "done": 0}

        async def watch():
            while True:
                await RisingEdge(clk)
                await ReadOnly()
                if bit(dut.tx_byte_ev) and bit(dut.tx_byte_ev2):
                    both["byte"] += 1
                if bit(dut.tx_frame_done_ev) and bit(dut.tx_frame_done_ev2):
                    both["done"] += 1

        w = cocotb.start_soon(watch())
        await axil.write(0x28, 0)
        await axil.write(0x2C, 0)

        async def one_data(delay):
            for _ in range(delay):
                await RisingEdge(clk)
            await send_data(dut, 0)

        n = 41
        for off in range(n):
            t = cocotb.start_soon(one_data(off))
            await axil.write(0x84, 0x03)
            await t
            await Timer(int(3 * frame_ns), "ns")
        w.kill()
        c.eq("TX_FRAME: data and PAUSE frames", await axil.read(0x28), 2 * n)
        c.eq("TX_BYTE: 72 per frame", await axil.read(0x2C), 2 * n * 72)
        c.check(f"byte events of both framers in the same clock: {both['byte']}",
                both["byte"] > 0)
        c.check(f"frame-done events of both framers in the same clock: {both['done']}",
                both["done"] > 0)

    c.finish()
