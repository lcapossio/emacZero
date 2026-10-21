# SPDX-License-Identifier: Apache-2.0
"""cocotb port of sim/tb/tb_rgmii_if_speed_switch.v (build_and_test.py bench
RGMII-IF-SPEED-SWITCH).

rgmii_if TXC across speed changes and reset. The DUT pair is that of
tb_rgmii_if_100m (the two benches wire it identically), so this suite uses
sim/cocotb/hdl/h_rgmii_if_100m.{v,vhd}; the bench ties u_tx's gmii_tx_er low,
and the test drives tx_gmii_tx_er 0 for the whole run. clk_125 rises at 4,
12, ... ns and clk_125_90 2 ns later, as in the bench. cfg_speed and the GMII
inputs change on the falling edge of clk_125, as in the bench.

Sequence (as the bench): reset with 100M selected, then for every ordered
pair of 1G / 100M / 10M and every offset 0..49 clk_125 cycles: go to the
"from" speed if not there, wait `offset` cycles, (100M <-> 10M only) hold
cfg_speed 11 for 3 cycles, go to the "to" speed (160 cycles), and send a
4-byte burst (pattern ^ offset) that must loop back exactly. 300 trials.

Checks, in the order of the bench (5):
  TXC stays low through reset                  (no TXC rise while rst_n low)
  TXC after reset: full 100M pulses only       (bad high == 0, bad low == 0,
                                                more than 4 pulses)
  speed change: TXC high times all 4/20/200 ns (of a speed in flight, +-1 ps)
  speed change: no short TXC low time          (>= shortest low time allowed)
  speed change: burst after each loops back exact (no bad burst, 300 trials)
The TXC pulse monitor watches the 10 ps-delayed TXC (txc_s) and keeps the
bench's $realtime arithmetic in integer picoseconds (its 1 ps precision).

Sampling: the bench's RX capture runs on posedge rgmii_rxc and reads the RX
outputs (registered on that same edge) before they update. Here they are read
after the edge has settled (RisingEdge + ReadOnly), race-free on both
simulators; every captured signal moves by the same one RXC cycle, which a
burst's byte count, bytes and RX_ER count do not see.
No randomness.
"""
import cocotb
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer

from lib.bench import Checks
from lib.rgmii_tb import as_int, is1, now_ps, start_clocks, watch_edges


# Suites this module backs (read by run.py; see its docstring).
SUITES = {
    "rgmii_if_speed_switch": {
        "toplevel": "h_rgmii_if_100m",
        "sources": ["rtl/ddr_input.v", "rtl/ddr_output.v", "rtl/rgmii_if.v",
                    "sim/cocotb/hdl/h_rgmii_if_100m.v"],
        "params": {},
    },
}

PATTERN = [0x12, 0xA5, 0x3C, 0xF0]
NB = len(PATTERN)
HIGH_PS = (4_000, 20_000, 200_000)       # TXC high time per speed index


def code(s):        # speed index -> cfg_speed
    return 0b00 if s == 0 else 0b01 if s == 1 else 0b10


def cpb(s):         # clk_125 cycles per byte
    return 1 if s == 0 else 10 if s == 1 else 100


def min_low(allow):
    return 4_000 if allow[0] else 20_000 if allow[1] else 200_000


class Bench:
    """The bench's module-level state: TXC pulse monitor and RX capture."""

    def __init__(self, dut):
        self.dut = dut
        self.allow = [False, False, False]   # 1G, 100M, 10M
        self.mon_on = False
        self.t_r = -1
        self.t_f = -1
        self.bad_hi = 0
        self.bad_lo = 0
        self.n_hi = 0
        self.rst_hi = 0
        self.rx_buf = [None] * 8              # reg [7:0] rx_buf [0:7], X at start
        self.rx_idx = 0
        self.er_bytes = 0

    def _allow_str(self):
        return "".join("1" if a else "0" for a in reversed(self.allow))

    def on_txc_rise(self):
        now = now_ps()
        if not is1(self.dut.rst_n):
            self.rst_hi += 1
        if self.mon_on and self.t_f >= 0:
            w = now - self.t_f
            if w < min_low(self.allow) - 1:
                if self.bad_lo < 5:
                    self.dut._log.info(f"  TXC low {w / 1000:.3f} ns at {now} ps "
                                       f"(allow {self._allow_str()})")
                self.bad_lo += 1
        self.t_r = now

    def on_txc_fall(self):
        now = now_ps()
        if self.mon_on and self.t_r >= 0:
            w = now - self.t_r
            self.n_hi += 1
            if not any(self.allow[i] and abs(w - HIGH_PS[i]) <= 1 for i in range(3)):
                if self.bad_hi < 5:
                    self.dut._log.info(f"  TXC high {w / 1000:.3f} ns at {now} ps "
                                       f"(allow {self._allow_str()})")
                self.bad_hi += 1
        self.t_f = now

    async def rx_capture(self):
        dut = self.dut
        while True:
            await RisingEdge(dut.rgmii_rxc)
            await ReadOnly()
            if is1(dut.rst_n) and is1(dut.rx_gmii_rx_dv) and is1(dut.rx_gmii_rx_ce):
                if self.rx_idx < 8:
                    self.rx_buf[self.rx_idx] = as_int(dut.rx_gmii_rxd)
                self.rx_idx += 1
                if is1(dut.rx_gmii_rx_er):
                    self.er_bytes += 1


async def _negedges(dut, n):
    for _ in range(n):
        await FallingEdge(dut.clk_125)


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def rgmii_if_speed_switch(dut):
    """tb_rgmii_if_speed_switch: TXC pulses across 300 speed changes and reset."""
    ck = Checks(dut._log)
    start_clocks(dut, shifted=True)
    dut.rst_n.value = 0
    dut.cfg_speed.value = 0b01
    dut.tx_gmii_txd.value = 0
    dut.tx_gmii_tx_en.value = 0
    dut.tx_gmii_tx_er.value = 0          # the bench ties u_tx's gmii_tx_er low

    tb = Bench(dut)
    cocotb.start_soon(watch_edges(dut.txc_s, tb.on_txc_rise, tb.on_txc_fall))
    cocotb.start_soon(tb.rx_capture())

    st = {"cur": 0, "from": 0, "to": 0, "off": 0, "bad_burst": 0, "trials": 0}

    async def burst(s):
        off = st["off"] & 0xFF
        tb.rx_idx = 0
        tb.er_bytes = 0
        await FallingEdge(dut.clk_125)
        dut.tx_gmii_tx_en.value = 1
        for b in PATTERN:
            dut.tx_gmii_txd.value = b ^ off
            await _negedges(dut, cpb(s))
        dut.tx_gmii_tx_en.value = 0
        dut.tx_gmii_txd.value = 0
        await _negedges(dut, 8 * cpb(s) + 20)
        mism = sum(1 for k in range(min(NB, tb.rx_idx))
                   if tb.rx_buf[k] != (PATTERN[k] ^ off))
        if tb.rx_idx != NB or tb.er_bytes != 0 or mism != 0:
            if st["bad_burst"] < 5:
                dut._log.info(f"  burst {st['from']} -> {st['to']} offset {st['off']}: "
                              f"{tb.rx_idx} bytes, {mism} wrong, {tb.er_bytes} RX_ER")
            st["bad_burst"] += 1

    async def go_speed(s):
        tb.allow[s] = True
        dut.cfg_speed.value = code(s)
        await _negedges(dut, 160)
        tb.allow = [False, False, False]
        tb.allow[s] = True
        st["cur"] = s

    # Reset with 100M selected: TXC must stay low, then start with full 100M
    # pulses (no 1G pulse from the reset value).
    dut.cfg_speed.value = 0b01
    # clk_125 starts at 0 from X/U at time 0, which a FallingEdge trigger
    # would count; the bench's first negedge is at 8 ns. Step past time 0.
    await Timer(1, "ns")
    await _negedges(dut, 20)
    tb.allow = [False, True, False]
    tb.mon_on = True
    dut.rst_n.value = 1
    await _negedges(dut, 160)
    st["cur"] = 1
    ck.check("TXC stays low through reset", tb.rst_hi == 0, f"{tb.rst_hi} rises")
    ck.check("TXC after reset: full 100M pulses only",
             tb.bad_hi == 0 and tb.bad_lo == 0 and tb.n_hi > 4,
             f"bad high {tb.bad_hi}, bad low {tb.bad_lo}, pulses {tb.n_hi}")

    for frm in range(3):
        for to in range(3):
            if frm == to:
                continue
            for off in range(50):
                st["from"], st["to"], st["off"] = frm, to, off
                if st["cur"] != frm:
                    await go_speed(frm)
                await _negedges(dut, off)
                # Between 100M and 10M both bits change; with the bits
                # synchronized separately, changes on consecutive cycles can
                # read as 11 (1G) for more than one cycle: hold 11 for 3.
                if frm != 0 and to != 0:
                    dut.cfg_speed.value = 0b11
                    await _negedges(dut, 3)
                await go_speed(to)
                await burst(to)
                st["trials"] += 1

    dut._log.info(f"INFO: {st['trials']} speed changes, {tb.n_hi} TXC pulses, "
                  f"{tb.bad_hi} bad high, {tb.bad_lo} bad low, "
                  f"{st['bad_burst']} bad bursts")
    ck.check("speed change: TXC high times all 4/20/200 ns", tb.bad_hi == 0,
             f"{tb.bad_hi} bad")
    ck.check("speed change: no short TXC low time", tb.bad_lo == 0, f"{tb.bad_lo} bad")
    ck.check("speed change: burst after each loops back exact",
             st["bad_burst"] == 0 and st["trials"] == 300,
             f"{st['bad_burst']} bad of {st['trials']}")

    ck.finish()
