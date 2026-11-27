# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""10G reconciliation sublayer link fault signalling (rtl/eth_rs_10g.v),
IEEE 802.3 clause 46.3.4.

  eth_rs_10g  RX: the reported fault against a model kept here as a list of
              sequence positions (four of one type within 128 columns
              report it; 128 columns without one of its type clear it), on
              directed boundary cases (127 versus 128 columns, both column
              positions, the other type, reserved and malformed sequences,
              rx_valid gaps) and on random column streams. TX: the MAC's
              words pass with one word of latency on tx_ce; with a local
              fault, all-idle words become remote fault sequences and
              nothing else changes; tx_fault follows either fault.
"""
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly


SUITES = {
    "eth_rs_10g": {
        "toplevel": "h_eth_rs_10g",
        "sources": ["rtl/eth_rs_10g.v", "sim/cocotb/hdl/h_eth_rs_10g.v"],
        "skip_vhdl": "10G MAC is Verilog only so far",
    },
}

NONE, LOCAL, REMOTE = 0, 1, 3          # rx_fault codes
IDLE = (0x07070707, 0xF)
COL = {
    "I": IDLE,
    "L": (0x0100009C, 0x1),            # local fault sequence
    "R": (0x0200009C, 0x1),            # remote fault sequence
    "Q": (0x0300009C, 0x1),            # reserved sequence: not a fault
    "M": (0x0100019C, 0x1),            # lane 1 not zero: not a fault
    "C": (0x0100009C, 0x3),            # lane 1 a control: not a fault
    "D": (0x12345678, 0x0),            # data
}


class Model:
    """Link fault reporting, from the clause 46 rules, by column positions:
    a count of one type's sequences starts at a sequence and lasts 128
    columns; its fourth reports that fault. A reported fault is kept while
    sequences of its type come no more than 128 columns apart; one of the
    other type starts a count (the fault stays reported meanwhile), and a
    count that runs out clears it."""

    def __init__(self):
        self.fault = NONE
        self.count = None      # [type, first column, sequences]
        self.last = None       # column of the last sequence of the fault's type
        self.n = 0             # columns seen

    def column(self, kind):
        p = self.n
        self.n += 1
        t = {"L": LOCAL, "R": REMOTE}.get(kind)
        c = self.count
        if c is not None and t == c[0] and c[2] == 3:
            self.fault, self.last, self.count = t, p, None
            return
        if c is not None and p - c[1] >= 127:
            self.count, self.fault = None, NONE
        if self.count is None and self.fault != NONE:
            if t == self.fault:
                self.last = p
            elif t is None:
                if p - self.last >= 128:
                    self.fault = NONE
            else:
                self.count = [t, p, 1]
            return
        if t is None:
            return
        if self.count is None or self.count[0] != t:
            self.count = [t, p, 1]
        else:
            self.count[2] += 1


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 6, "ns").start())
    dut.rst_n.value = 0
    dut.rxd.value = 0x0707070707070707
    dut.rxc.value = 0xFF
    dut.rx_valid.value = 0
    dut.tx_ce.value = 0
    dut.mac_txd.value = 0x0707070707070707
    dut.mac_txc.value = 0xFF
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


async def send(dut, cols, model=None, valid_p=1.0, rng=None):
    """Send columns (two per word) on RX; checks rx_fault against the model
    after every word."""
    assert len(cols) % 2 == 0
    for i in range(0, len(cols), 2):
        while rng is not None and rng.random() > valid_p:
            await FallingEdge(dut.clk)
            dut.rx_valid.value = 0
        d0, c0 = COL[cols[i]]
        d1, c1 = COL[cols[i + 1]]
        await FallingEdge(dut.clk)
        dut.rxd.value = d1 << 32 | d0
        dut.rxc.value = c1 << 4 | c0
        dut.rx_valid.value = 1
        if model is not None:
            model.column(cols[i])
            model.column(cols[i + 1])
            await ReadOnly()
            await FallingEdge(dut.clk)
            dut.rx_valid.value = 0
            await ReadOnly()
            assert int(dut.rx_fault.value) == model.fault, \
                (i // 2, cols[max(0, i - 8):i + 2], int(dut.rx_fault.value), model.fault)
    await FallingEdge(dut.clk)
    dut.rx_valid.value = 0


def fault(dut):
    return int(dut.rx_fault.value)


@cocotb.test()
async def rx_directed(dut):
    """Boundaries of the 4-in-128 rule and of the 128-column clear."""
    if dut._name != "h_eth_rs_10g":
        return

    async def case(cols, want, why):
        await setup(dut)
        m = Model()
        await send(dut, cols, m)
        assert m.fault == want, ("model", why, m.fault)
        assert fault(dut) == want, (why, fault(dut))

    def at(n, marks, kind="L"):
        c = ["I"] * n
        for p in marks:
            c[p] = kind
        return c

    await case(at(16, [0, 1, 2]), NONE, "three sequences")
    await case(at(16, [0, 1, 2, 3]), LOCAL, "four")
    await case(at(16, [1, 2, 3, 4], "R"), REMOTE, "four remote, odd start")
    await case(at(140, [0, 42, 84, 127]), LOCAL, "fourth at column 127")
    await case(at(140, [0, 42, 84, 128]), NONE, "fourth at column 128")
    await case(at(16, [0, 1, 2]) + at(2, [1]) + at(14, [1, 2, 3]), LOCAL,
               "a fourth of the same type after a gap")
    await case(["L", "R"] * 40, NONE, "alternating types")
    for k in "QMCD":
        await case([k] * 64, NONE, "not a fault: " + k)
    # a fault clears after 128 columns without a sequence of its type
    await case(at(4, [0, 1, 2, 3]) + ["I"] * 126, LOCAL, "126 idle columns")
    await case(at(4, [0, 1, 2, 3]) + ["I"] * 128, NONE, "128 idle columns")
    await case(at(4, [0, 1, 2, 3]) + ["I"] * 100 + ["L"] + ["I"] * 126 + ["D"],
               LOCAL, "kept by one more sequence")
    await case(at(4, [0, 1, 2, 3]) + ["I"] * 100 + ["L"] + ["I"] * 127 + ["D", "I"],
               NONE, "128 columns after that one")
    # sequences late in a count's window do not stretch it
    await case(at(132, [0, 126, 127]) + ["I"] * 124 + at(4, [0, 1]), NONE,
               "count runs out after column 127")
    # local to remote: the report changes after four remote sequences
    await setup(dut)
    m = Model()
    await send(dut, ["L"] * 8, m)
    assert fault(dut) == LOCAL
    await send(dut, ["R"] * 2, m)
    assert fault(dut) == LOCAL, "two remote sequences do not change it"
    await send(dut, ["R"] * 2, m)
    assert fault(dut) == REMOTE
    # gaps in rx_valid do not count as columns
    await setup(dut)
    m = Model()
    rng = random.Random(3)
    await send(dut, at(8, [0, 1, 2, 3]) + ["I"] * 120, m, valid_p=0.3, rng=rng)
    assert fault(dut) == LOCAL


@cocotb.test()
async def rx_random(dut):
    """Random column streams of bursts against the model, word by word."""
    if dut._name != "h_eth_rs_10g":
        return
    rng = random.Random(11)
    await setup(dut)
    m = Model()
    seen = set()
    for _ in range(300):
        kind = rng.choice("ILRQDLR")
        n = rng.choice([1, 2, 3, 4, 5, 8, 60, 126, 127, 128, 129, 200])
        cols = []
        for _ in range(n):
            cols.append(kind if rng.random() < 0.8 else rng.choice("ILRD"))
        if len(cols) % 2:
            cols.append("I")
        await send(dut, cols, m, valid_p=0.9, rng=rng)
        seen.add(m.fault)
    assert seen == {NONE, LOCAL, REMOTE}, seen


@cocotb.test()
async def tx_output(dut):
    """One word of latency on tx_ce; remote fault sequences only in idle
    words, only with a local fault; tx_fault with either fault."""
    if dut._name != "h_eth_rs_10g":
        return
    rng = random.Random(5)
    await setup(dut)
    rf = 0x0200009C0200009C
    idle = 0x0707070707070707
    words = [(idle, 0xFF), (0x0707070707FDAABB, 0xF8), (0x1122334455667788, 0x00),
             (0xD5555555555555FB, 0x01), (idle, 0xFF), (0x07070707_0707FD99, 0xFE)]

    async def run(n, want_fault, rf_on_idle):
        prev = None
        for _ in range(n):
            await FallingEdge(dut.clk)
            ce = rng.random() < 0.8
            d, c = rng.choice(words)
            dut.tx_ce.value = 1 if ce else 0
            dut.mac_txd.value = d
            dut.mac_txc.value = c
            await ReadOnly()
            assert int(dut.tx_fault.value) == want_fault
            if ce:
                await FallingEdge(dut.clk)
                dut.tx_ce.value = 0
                await ReadOnly()
                od, oc = int(dut.txd.value), int(dut.txc.value)
                if rf_on_idle and (d, c) == (idle, 0xFF):
                    assert (od, oc) == (rf, 0x11), hex(od)
                else:
                    assert (od, oc) == (d, c), (hex(od), hex(d))
                prev = (od, oc)
        return prev

    await run(200, 0, False)
    # local fault
    await send(dut, ["L"] * 8)
    await ClockCycles(dut.clk, 6)
    await run(200, 1, True)
    # remote fault: idles stay idles
    await send(dut, ["R"] * 8)
    await ClockCycles(dut.clk, 6)
    await run(200, 1, False)
    # cleared
    await send(dut, ["I"] * 130)
    await ClockCycles(dut.clk, 6)
    assert fault(dut) == NONE
    await run(200, 0, False)
