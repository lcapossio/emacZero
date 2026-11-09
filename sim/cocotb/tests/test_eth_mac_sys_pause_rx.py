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
  5 short preambles count and pause: no preamble byte (the SFD first) on
    GMII; 14, 2 and 1 preamble nibbles (the SFD after an even or an odd
    number of nibbles) on MII and RGMII 10/100, where rx_er on a trailing
    odd nibble makes a frame not valid

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

pause_auto checks, per suite, automatic PAUSE (PAUSE_CTRL[2]; quanta 8,
XOFF 600, XON 200, refresh 0 = 4 quanta) against a link partner that sends
200-byte frames and obeys the MAC Control frames at our TX pins:
  1 PAUSE_XOFF / PAUSE_XON reset to half / a quarter of the 2 KB RX FIFO;
    CAPS[8:3] reports it and the feature
  2 m_axis stalled: XOFF once the FIFO fills, auto_active set, XOFF repeated
    4 quanta apart (no later than that plus two PAUSE frames), the partner
    held to the frame it had started, RX_DROP and RX_ERR_OVERFLOW 0; a
    tx_send (quanta 0x33) in the middle goes out once and the XOFF frames
    keep the quanta latched at enable
  3 m_axis released: XOFF repeats until the level is below XON, then one
    XON and nothing more; every partner frame delivered, none with terror;
    PAUSE_TX_CNT = the MAC Control frames at the pins
  4 auto_en cleared while XOFF is in force: one XON
  5 quanta 0, XON 0, XON > XOFF, XOFF > the FIFO watermark (2044) and
    refresh >= quanta raise auto_cfg_err, clear with auto_en and send
    nothing; XOFF = 2044 is valid
  6 two tx_send writes during one generated frame: tx_pending reads 1, and
    both frames go out in order with their own quanta

pause_mid_frame checks, per suite: a PAUSE that arrives while our frame is
on the wire counts from the end of that frame (802.3 Figure 31B-2,
transmission_in_progress; UNH-IOL flow control test 31.1.5). Q = one pause
quantum; a frame's end is its last byte at the TX pins.
  1 quanta 4 during our 1514-byte frame, the next data frame queued behind
    it: that frame starts 4Q..4Q+Q/2 after the long one ends; both intact
  2 quanta 4, then quanta 0, both during the long frame: the next frame
    follows within Q/2 (the zero cancels the pause before it has started)
  3 quanta 8 during the long frame, then our own PAUSE frames back to back
    (PAUSE_CTRL.tx_send; less than Q apart, except on GMII where the control
    path spaces them wider): tx_paused falls 8Q after the long frame ended, as
    the control frames after it do not hold the countdown, and the next data
    frame starts no earlier
  4 minimum-size data frames queued all along, quanta 2 ending at 12 phases
    across a frame period: no data frame starts after the budget until 2Q
    after the end of the last frame that started within it (or after RX_DV
    fell, if later), nor more than Q/2 + the budget after that; then every
    data frame reached the pins once, in order, with a good FCS
"""
import os
import zlib

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer, with_timeout
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
                if er:
                    # RX_ER on the high nibble: RX_CTL low on the falling
                    # edge only (it carries RX_DV xor RX_ER there).
                    await RisingEdge(self.clk)
                    await Timer(RXC_NS // 4, "ns")
                    self.dut.rgmii_rx_ctl.value = 0
        return await self._end()

    async def send_nibs(self, nibs, er_at=()):
        """MII and RGMII 10/100: drive nibbles as given, rx_er on the indices
        in er_at."""
        for i, n in enumerate(nibs):
            er = 1 if i in er_at else 0
            await self._slot()
            self._drive(n, 1, er)
            if er and MODE != "mii":
                await RisingEdge(self.clk)
                await Timer(RXC_NS // 4, "ns")
                self.dut.rgmii_rx_ctl.value = 0
        return await self._end()

    async def _end(self):
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
    good = wire(pause_frame(0xFFFF))
    bad.insert(1, ("rx_er", good, 30))
    bad.insert(2, ("rx_er on the last byte", good, len(good) - 1))
    for label, byts, er_at in bad:
        await pins.send(byts, er_at=er_at)
        await Timer(BUDGET_NS, "ns")
        c.eq(f"{label}: tx_paused", bit(dut.tx_paused), 0)
        c.eq(f"{label}: PAUSE_RX_CNT", await axil.read(0x8C), 0)

    # 4b. A valid PAUSE frame right after one with rx_er on its last byte
    #     counts: the error does not carry over to the next frame.
    await pins.send(good, er_at=len(good) - 1)
    await latency("PAUSE after an rx_er frame", [good])
    c.eq("PAUSE after an rx_er frame: PAUSE_RX_CNT", await axil.read(0x8C), 1)
    await latency("PAUSE quanta 0", [wire(pause_frame(0))], level=0)
    await axil.write(0x8C, 0)

    # 5. Short preambles: the PHY may drop part or all of the preamble. On
    #    MII and RGMII 10/100 the SFD can come after an odd number of nibbles
    #    (an even number of 5s before the D), and rx_er on a trailing odd
    #    nibble makes a frame invalid.
    def nibs(byts):
        return [n for b in byts for n in (b & 0xF, b >> 4)]

    def short(fives, q):
        return [5] * fives + [0xD] + nibs(wire(pause_frame(q))[8:])

    if MODE == "gmii":
        cases = [("no preamble", lambda q: pins.send(wire(pause_frame(q))[7:]))]
    else:
        cases = [(f"{f} preamble nibbles", lambda q, f=f: pins.send_nibs(short(f, q)))
                 for f in (14, 2, 1)]
    for label, go in cases:
        w = cocotb.start_soon(paused_edge(1))
        t_end = await go(0xFFFF)
        lat = (await with_timeout(w, 4 * BUDGET_NS, "ns")) - t_end
        c.check(f"{label}: tx_paused=1 {lat:.0f} ns after RX_DV fell "
                f"(budget {BUDGET_NS:.0f} ns)", lat <= BUDGET_NS)
        w = cocotb.start_soon(paused_edge(0))
        await go(0)
        await with_timeout(w, 4 * BUDGET_NS, "ns")
    n_short = 2 * len(cases)
    c.eq("short preambles: PAUSE_RX_CNT", await axil.read(0x8C), n_short)

    if MODE != "gmii":
        tail = nibs(wire(pause_frame(0xFFFF))) + [0]
        await pins.send_nibs(tail, er_at=(len(tail) - 1,))
        await Timer(BUDGET_NS, "ns")
        c.eq("rx_er on a trailing nibble: tx_paused", bit(dut.tx_paused), 0)
        c.eq("rx_er on a trailing nibble: PAUSE_RX_CNT", await axil.read(0x8C),
             n_short)

    c.finish()


class TxPins:
    """Collects the frames at one PHY's TX pins: (start time, wire bytes)."""

    def __init__(self, dut):
        self.dut = dut
        self.frames = []
        self.cur_t0 = None                        # start of the frame in flight
        self.end_at = {}                          # start -> first idle sample
        self.odd = 0                              # frames ending on a lone nibble

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
                    self.cur_t0 = t0
                if MODE == "gmii":
                    cur.append(v)
                else:
                    nib.append(v)
                    if len(nib) == 2:
                        cur.append(nib[0] | (nib[1] << 4))
                        nib = []
            elif cur is not None:
                self.frames.append((t0, cur))
                self.end_at[t0] = now_ns()
                self.odd += 1 if nib else 0
                cur = None
                self.cur_t0 = None

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


def numbered(n, size=60):
    """A data frame of `size` bytes, numbered n in bytes 14-15."""
    f = data_frame(size)
    f[14], f[15] = (n >> 8) & 0xFF, n & 0xFF
    return f


def seq_of(byts):
    """(number, FCS good) of a data frame from its wire bytes."""
    f, ok = split(byts)
    return (None, False) if f is None else ((f[14] << 8) | f[15], ok)


async def send_data(dut, n, size=60):
    """One data frame on s_axis, numbered n in bytes 14-15."""
    clk = dut.clk
    f = numbered(n, size)
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


def ctl_quanta(byts):
    """The quanta of a MAC Control frame's PAUSE, from its wire bytes."""
    f, _ = split(byts)
    return (f[16] << 8) | f[17]


class Partner:
    """A link partner that obeys our PAUSE frames: before each frame it
    checks the last MAC Control frame at our TX pins and waits while that
    frame's quanta, counted from its end, has not run out. A frame already
    started is finished, as 802.3 allows."""

    def __init__(self, pins, tx, size):
        self.pins, self.tx, self.size = pins, tx, size
        self.go = True
        self.sent = 0

    def paused(self):
        for t0, byts in reversed(self.tx.frames):
            if is_ctl(byts):
                end = t0 + len(byts) * BYTE_NS
                return now_ns() < end + ctl_quanta(byts) * 512 * BIT_NS
        return False

    async def run(self):
        while self.go:
            if self.paused():
                await Timer(8 * BYTE_NS, "ns")
                continue
            await self.pins.send(wire(data_frame(self.size)))
            self.sent += 1


class Sink:
    """Counts the frames handshaken on m_axis, and those ending in terror."""

    def __init__(self, dut):
        self.dut = dut
        self.frames = 0
        self.errors = 0

    async def run(self):
        d = self.dut
        while True:
            await RisingEdge(d.clk)
            await ReadOnly()
            if bit(d.m_axis_tvalid) and bit(d.m_axis_tready) and bit(d.m_axis_tlast):
                self.frames += 1
                self.errors += bit(d.m_axis_terror)


@cocotb.test(timeout_time=300, timeout_unit="ms")
async def pause_auto(dut):
    """Automatic PAUSE from the RX FIFO level (PAUSE_CTRL[2])."""
    c = Checks(dut._log)
    pins, axil = await bring_up(dut)
    tx = TxPins(dut)
    cocotb.start_soon(tx.run())
    sink = Sink(dut)
    cocotb.start_soon(sink.run())
    q_ns = 512 * BIT_NS                           # one pause quantum
    ctl_ns = 84 * BYTE_NS                         # a PAUSE frame and its IFG
    QUANTA, XOFF, XON = 8, 600, 200               # refresh 0: quanta / 2
    size = 200

    def ctls(t_from=0):
        return [(t0, ctl_quanta(b)) for t0, b in tx.frames
                if is_ctl(b) and t0 > t_from]

    async def wait_for(cond, limit_ns):
        t = now_ns()
        while not cond() and now_ns() - t < limit_ns:
            await Timer(8 * BYTE_NS, "ns")
        return cond()

    # 1. Reset values and configuration.
    c.eq("PAUSE_XOFF reset (RX FIFO / 2)", await axil.read(0x9C), 1024)
    c.eq("PAUSE_XON reset (RX FIFO / 4)", await axil.read(0xA0), 512)
    c.eq("CAPS[8:3]: RX FIFO 2**11, automatic PAUSE",
         (await axil.read(0x98)) & 0x1F8, (11 << 4) | 0x8)
    await axil.write(0x88, QUANTA)
    await axil.write(0x9C, XOFF)
    await axil.write(0xA0, XON)
    await axil.write(0xA4, 0)
    dut.m_axis_tready.value = 0
    await axil.write(0x84, 0x06)                  # rx_en + auto_en
    c.eq("PAUSE_CTRL after enable", await axil.read(0x84), 0x06)

    # 2. Stall the sink while the partner sends: XOFF, refreshed, keeps the
    #    partner paused with no frame lost; a tx_send in the middle goes out
    #    with its own quanta and does not change the automatic one.
    partner = Partner(pins, tx, size)
    p_task = cocotb.start_soon(partner.run())
    ok = await wait_for(lambda: ctls(), 20 * size * BYTE_NS)
    c.check("XOFF sent once the RX FIFO filled", ok)
    t_xoff = ctls()[0][0] if ok else now_ns()
    c.eq("PAUSE_CTRL: auto_active", (await axil.read(0x84)) & 0x08, 0x08)
    sent_at_xoff = partner.sent
    await Timer(int(10 * q_ns), "ns")
    await axil.write(0x88, 0x33)
    await axil.write(0x84, 0x07)                  # + tx_send, quanta 0x33
    await Timer(int(30 * q_ns), "ns")
    stalled = ctls(t_xoff - 1)
    auto = [t for t, q in stalled if q == QUANTA]
    c.eq("XOFF frames carry the latched quanta (not 0x33)",
         sorted({q for _, q in stalled} - {0x33}), [QUANTA])
    c.eq("the tx_send frame went out once", [q for _, q in stalled].count(0x33), 1)
    # The tx_send frame sits between two XOFF frames; leave that gap out.
    t_man = [t for t, q in stalled if q == 0x33]
    gaps = [b - a for a, b in zip(auto, auto[1:])
            if not any(a < t < b for t in t_man)]
    # The refresh interval runs from the generator, not the pins: a frame
    # held back at the pins (the XOFF right after the tx_send one) makes the
    # next gap shorter by up to one control frame. Early is harmless; late
    # would let the partner resume.
    lo = (QUANTA // 2) * q_ns - ctl_ns
    hi = (QUANTA // 2) * q_ns + 2 * ctl_ns + 2000
    c.check(f"{len(auto)} XOFF frames during the stall (>= 6)", len(auto) >= 6)
    c.check(f"XOFF repeat intervals {min(gaps, default=0):.0f}..{max(gaps, default=0):.0f} ns "
            f"within {lo:.0f}..{hi:.0f}", bool(gaps) and all(lo <= g <= hi for g in gaps))
    c.check(f"partner held: {partner.sent - sent_at_xoff} frames after the first XOFF (<= 1)",
            partner.sent - sent_at_xoff <= 1)
    c.eq("RX_DROP", await axil.read(0x7C), 0)
    c.eq("RX_ERR_OVERFLOW", await axil.read(0x50), 0)

    # 3. Release the sink: the FIFO drains below XON, one XON frame, the
    #    partner resumes, every frame it sent arrives intact.
    t_rel = now_ns()
    dut.m_axis_tready.value = 1
    ok = await wait_for(lambda: any(q == 0 for _, q in ctls(t_rel)), 40 * size * BYTE_NS)
    c.check("XON sent once the RX FIFO drained", ok)
    await Timer(int(4 * size * BYTE_NS), "ns")
    c.check(f"partner resumed: {partner.sent - sent_at_xoff} frames since the first XOFF",
            partner.sent - sent_at_xoff >= 3)
    partner.go = False
    await p_task
    await Timer(int(4 * size * BYTE_NS), "ns")
    # XOFF repeats until the level is below XON, then one XON and no more.
    after = [q for _, q in ctls(t_rel)]
    c.check(f"after the release: XOFF repeats, then one XON, nothing more ({after})",
            after.count(0) == 1 and after[-1] == 0 and set(after) <= {0, QUANTA})
    c.eq("PAUSE_CTRL after the release", await axil.read(0x84), 0x06)
    c.eq("every partner frame delivered", sink.frames, partner.sent)
    c.eq("none with terror", sink.errors, 0)
    c.eq("PAUSE_TX_CNT = MAC Control frames at the pins", await axil.read(0x90),
         len(ctls()))

    # 4. Clearing auto_en while XOFF is in force sends one XON.
    dut.m_axis_tready.value = 0
    n0 = len(ctls())
    partner = Partner(pins, tx, size)
    p_task = cocotb.start_soon(partner.run())
    ok = await wait_for(lambda: len(ctls()) > n0, 20 * size * BYTE_NS)
    c.check("XOFF again", ok)
    partner.go = False
    await p_task
    t_off = now_ns()
    await axil.write(0x84, 0x02)                  # auto_en off
    ok = await wait_for(lambda: any(q == 0 for _, q in ctls(t_off)), 4 * ctl_ns + 4000)
    c.check("XON when auto_en is cleared", ok)
    await Timer(int(8 * q_ns), "ns")
    c.eq("after disable: one XON, nothing more", [q for _, q in ctls(t_off)], [0])
    c.eq("PAUSE_CTRL after disable", await axil.read(0x84), 0x02)
    dut.m_axis_tready.value = 1
    await Timer(int(8 * size * BYTE_NS), "ns")

    # 5. Invalid configurations raise auto_cfg_err and send nothing.
    n0 = len(ctls())
    for label, quanta, xoff, xon, refresh in (
            ("quanta 0", 0, XOFF, XON, 0),
            ("XON 0", QUANTA, XOFF, 0, 0),
            ("XON > XOFF", QUANTA, 100, 101, 0),
            ("XOFF > RX FIFO watermark", QUANTA, 2045, XON, 0),
            ("refresh >= quanta", QUANTA, XOFF, XON, QUANTA)):
        await axil.write(0x88, quanta)
        await axil.write(0x9C, xoff)
        await axil.write(0xA0, xon)
        await axil.write(0xA4, refresh)
        await axil.write(0x84, 0x06)
        c.eq(f"{label}: PAUSE_CTRL auto_cfg_err", await axil.read(0x84), 0x16)
        await axil.write(0x84, 0x02)
        c.eq(f"{label}: cleared with auto_en", await axil.read(0x84), 0x02)
    await axil.write(0x88, QUANTA)
    await axil.write(0x9C, 2044)                  # the largest valid XOFF
    await axil.write(0xA0, XON)
    await axil.write(0xA4, 0)
    await axil.write(0x84, 0x06)
    c.eq("XOFF = RX FIFO watermark: valid", await axil.read(0x84), 0x06)
    await axil.write(0x84, 0x02)
    await Timer(int(4 * ctl_ns), "ns")
    c.eq("invalid configurations sent nothing", len(ctls()), n0)

    # 6. A tx_send while the generator is busy waits for it, and is sent.
    t0 = now_ns()
    await axil.write(0x88, 0x11)
    await axil.write(0x84, 0x03)
    await axil.write(0x88, 0x22)
    await axil.write(0x84, 0x03)
    c.eq("PAUSE_CTRL: tx_pending while the first frame is generated",
         await axil.read(0x84), 0x22)
    await Timer(int(4 * ctl_ns + 2000), "ns")
    c.eq("both tx_send frames, in order", [q for _, q in ctls(t0)], [0x11, 0x22])
    c.eq("PAUSE_CTRL: nothing pending", await axil.read(0x84), 0x02)

    c.finish()


@cocotb.test(timeout_time=300, timeout_unit="ms")
async def pause_mid_frame(dut):
    """A PAUSE received during our frame counts from the end of that frame."""
    c = Checks(dut._log)
    clk = dut.clk
    pins, axil = await bring_up(dut)
    tx = TxPins(dut)
    cocotb.start_soon(tx.run())
    q_ns = 512 * BIT_NS                           # one pause quantum
    long_ns = 1526 * BYTE_NS
    frame_ns = 84 * BYTE_NS                       # a minimum frame and its IFG

    def end_of(fr):
        return tx.end_at[fr[0]]

    async def wait_for(cond, limit_ns):
        t = now_ns()
        while not cond() and now_ns() - t < limit_ns:
            await Timer(BYTE_NS, "ns")
        return cond()

    async def paused_fall():
        """Time of the first sys clock edge where tx_paused reads 0 again."""
        while True:
            await RisingEdge(clk)
            await ReadOnly()
            if bit(dut.tx_paused):
                break
        while True:
            await RisingEdge(clk)
            await ReadOnly()
            if not bit(dut.tx_paused):
                return now_ns()

    seq = [0]

    async def long_then_short():
        """Queue a 1514-byte frame and a minimum one behind it, and wait
        until the long one is a few bytes onto the wire. Returns the frame
        count before them and their numbers."""
        n0 = len(tx.frames)
        a, b = seq[0], seq[0] + 1
        seq[0] += 2

        async def feed():
            await send_data(dut, a, 1514)
            await send_data(dut, b)

        cocotb.start_soon(feed())
        ok = await wait_for(lambda: tx.cur_t0 is not None, 4 * long_ns)
        c.check("long frame on the wire", ok)
        await Timer(8 * BYTE_NS, "ns")
        return n0, (a, b)

    def check_pair(label, n0, nums, lo, hi):
        ok = len(tx.frames) >= n0 + 2
        c.check(f"{label}: both frames at the pins", ok)
        if not ok:
            return
        big, nxt = tx.frames[n0], tx.frames[n0 + 1]
        gap = nxt[0] - end_of(big)
        c.check(f"{label}: next frame {gap:.0f} ns after the long one "
                f"(expect {lo:.0f}..{hi:.0f})", lo <= gap <= hi)
        c.eq(f"{label}: frames (number, FCS good)",
             [seq_of(big[1]), seq_of(nxt[1])], [(nums[0], True), (nums[1], True)])

    # 1. Quanta 4 during the long frame.
    n0, nums = await long_then_short()
    await pins.send(wire(pause_frame(4)))
    await wait_for(lambda: len(tx.frames) >= n0 + 2, 2 * long_ns + 6 * q_ns)
    check_pair("quanta 4 mid-frame", n0, nums, 4 * q_ns, 4.5 * q_ns)

    # 2. Quanta 4 then quanta 0, both during the long frame.
    await Timer(int(2 * frame_ns), "ns")
    n0, nums = await long_then_short()
    await pins.send(wire(pause_frame(4)))
    await pins.send(wire(pause_frame(0)))
    c.check("quanta 0 arrived while the long frame was on the wire",
            tx.cur_t0 is not None)
    await wait_for(lambda: len(tx.frames) >= n0 + 2, 2 * long_ns + 6 * q_ns)
    check_pair("quanta 4 then 0 mid-frame", n0, nums, 0, 0.5 * q_ns)

    # 3. Quanta 8 during the long frame, then our PAUSE frames back to back.
    await Timer(int(2 * frame_ns), "ns")
    n0, nums = await long_then_short()
    w = cocotb.start_soon(paused_fall())
    await pins.send(wire(pause_frame(8)))
    await wait_for(lambda: len(tx.frames) > n0, 2 * long_ns)
    await axil.write(0x88, 0x0010)
    await axil.write(0x8C, 0)                     # clear PAUSE_RX/TX_CNT
    # tx_send writes faster than the frames go out: one always waits in the
    # generator's slot (a later one replaces it), so they leave back to back.
    t_stop = end_of(tx.frames[n0]) + 7 * q_ns
    while now_ns() < t_stop:
        await axil.write(0x84, 0x03)              # rx_en + tx_send
    t_fall = await with_timeout(w, 4 * q_ns, "ns")
    while (await axil.read(0x84)) & 0x20:         # tx_pending
        pass
    await Timer(int(2 * q_ns + 4 * frame_ns), "ns")
    n_ctl = await axil.read(0x90)
    big = tx.frames[n0]
    ctl = [f for f in tx.frames[n0 + 1:] if is_ctl(f[1])]
    dat = [f for f in tx.frames[n0 + 1:] if not is_ctl(f[1])]
    c.eq("our PAUSE frames at the pins = PAUSE_TX_CNT", len(ctl), n_ctl)
    ctl_gaps = [b[0] - end_of(a) for a, b in zip(ctl, ctl[1:])]
    # At 1G the store-and-forward control FIFO in gmii_cdc spaces PAUSE
    # frames more than a quantum apart (a frame goes out only once it is
    # whole in the FIFO), so there the case is not reachable this way.
    c.check(f"{len(ctl)} PAUSE frames, gaps {max(ctl_gaps, default=0):.0f} ns at most "
            f"(< Q, so no quantum passes with the wire idle; not at 1G)",
            len(ctl) >= 4 and (MODE == "gmii" or all(g < q_ns for g in ctl_gaps)))
    lat = t_fall - end_of(big)
    lo, hi = 8 * q_ns - 2 * BYTE_NS, 8 * q_ns + 2 * BYTE_NS + 16 * SYS_NS
    c.check(f"tx_paused fell {lat:.0f} ns after the long frame ended "
            f"(expect {lo:.0f}..{hi:.0f})", lo <= lat <= hi)
    c.check("next data frame after the PAUSE frames, at least 8Q after the long one",
            bool(dat) and dat[0][0] - end_of(big) >= 8 * q_ns
            and seq_of(dat[0][1]) == (nums[1], True))

    # 3b. Quanta 4 with the transmitter idle, then our PAUSE frame inside the
    #     first quantum (past the first quarter, which covers a frame that
    #     slips out after the PAUSE): the countdown does not wait for it.
    #     Not on GMII, where a tx_send takes more than a quantum to reach the
    #     pins through the store-and-forward control path.
    await Timer(int(2 * q_ns + 4 * frame_ns), "ns")
    n0 = len(tx.frames)

    async def paused_span():
        while True:
            await RisingEdge(clk)
            await ReadOnly()
            if bit(dut.tx_paused):
                break
        t = now_ns()
        n = 0
        while True:
            n += 1
            await RisingEdge(clk)
            await ReadOnly()
            if not bit(dut.tx_paused):
                return t, n

    span = cocotb.start_soon(paused_span())
    await pins.send(wire(pause_frame(4)))
    if MODE != "gmii":
        while not bit(dut.tx_paused):
            await RisingEdge(clk)
        await Timer(int(q_ns // 3), "ns")
        await axil.write(0x84, 0x03)              # rx_en + tx_send
    t_rise, n = await with_timeout(span, 8 * q_ns, "ns")
    c.check(f"idle PAUSE, quanta 4, our PAUSE frame in the first quantum: paused "
            f"{n} clocks (expect {4 * QUANTUM_CLKS}..{4 * QUANTUM_CLKS + 1})",
            4 * QUANTUM_CLKS <= n <= 4 * QUANTUM_CLKS + 1)
    if MODE != "gmii":
        await wait_for(lambda: len(tx.frames) > n0, 4 * frame_ns)
        t_ctl = tx.frames[n0][0] - t_rise if len(tx.frames) > n0 else None
        c.check(f"our PAUSE frame started {t_ctl} ns after tx_paused rose "
                f"(expect {q_ns / 4:.0f}..{q_ns:.0f})",
                t_ctl is not None and is_ctl(tx.frames[n0][1])
                and q_ns / 4 < t_ctl < q_ns)

    # 4. Minimum frames queued all along, quanta 2 at 12 phases.
    await Timer(int(4 * frame_ns), "ns")
    t_start = now_ns()
    base = seq[0]

    def data_since():
        return [f for f in tx.starts(t_start) if not is_ctl(f[1])]

    class Fed(Feeder):
        async def run(self):
            while self.go:
                while self.sent - len(data_since()) >= self.AHEAD:
                    await Timer(BYTE_NS, "ns")
                await send_data(self.dut, base + self.sent)
                self.sent += 1

    feed = Fed(dut, tx)
    feed_task = cocotb.start_soon(feed.run())
    await wait_for(lambda: len(data_since()) >= 3, 20 * frame_ns)
    lo, hi = 2 * q_ns, 2.5 * q_ns + BUDGET_NS
    seen = []
    for ph in range(12):
        await Timer(int(ph * frame_ns // 12 + 3 * frame_ns), "ns")
        t_end = await pins.send(wire(pause_frame(2)))
        await Timer(int(2 * q_ns + BUDGET_NS + 4 * frame_ns), "ns")
        data = data_since()
        before = [f for f in data if f[0] <= t_end + BUDGET_NS]
        after = [f for f in data if f[0] > t_end + BUDGET_NS]
        t_from = max([t_end] + [end_of(f) for f in before])
        d = after[0][0] - t_from if after else None
        if d is not None:
            seen.append(d)
        c.check(f"phase {ph}: first data frame after the budget "
                f"{d if d is None else round(d)} ns after the countdown could "
                f"start (expect {lo:.0f}..{hi:.0f})",
                d is not None and lo <= d <= hi)
    dut._log.info("phase sweep: %.0f..%.0f ns from countdown start to the next frame",
                  min(seen, default=0), max(seen, default=0))
    feed.go = False
    await feed_task
    await Timer(int((Feeder.AHEAD + 4) * frame_ns), "ns")
    got = [seq_of(f[1]) for f in data_since()]
    c.check(f"phase sweep: data frames {base}..{base + feed.sent - 1} each once, "
            f"in order, good FCS ({len(got)} seen)",
            got == [(base + i, True) for i in range(feed.sent)])
    c.eq("frames ending on a lone nibble at the TX pins", tx.odd, 0)

    c.finish()
