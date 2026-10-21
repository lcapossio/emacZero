# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""Small helpers shared by the cocotb ports of the TX-path Verilog benches.

(tests/test_eth_mac_fcs.py, test_eth_mac_tx_pad.py, test_mii_tx_bridge.py,
test_mii_tx_burst_backpressure.py, test_mii_tx_saf_tb.py,
test_mii_tx_saf_burst_stall.py, test_mii_tx_saf_oversize.py,
test_tx_csum_off_tb.py.)

Sampling convention, used by every one of those tests: a Verilog bench reads
a DUT output in an `always @(posedge clk)` block (or right after
`@(posedge clk)`) and so sees the value from before the edge. The tests read
the same value in the ReadOnly phase of a timestep before that edge, after
every input the test drives for that edge has been written, and act on it at
the edge.
"""
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge


def start_clock(sig, period_ns):
    """`reg c = 0; always #(period/2) c = ~c;`: low first, first rise at period/2."""
    clk = Clock(sig, period_ns, unit="ns")
    clk.start(start_high=False)
    return clk


def val(sig):
    """Integer value of a signal, or None while any bit is X/Z/U."""
    try:
        return int(sig.value)
    except ValueError:
        return None


def is1(sig):
    """Verilog `if (sig)`: true only for a known 1."""
    return val(sig) == 1


def crc_step(c, b):
    """One byte of the reflected CRC-32 (poly 0xEDB88320), no final complement:
    the benches' crc_step / crc_byte functions."""
    c ^= b & 0xFF
    for _ in range(8):
        c = (c >> 1) ^ 0xEDB88320 if c & 1 else c >> 1
    return c & 0xFFFFFFFF


def crc_raw(data, c=0xFFFFFFFF):
    for b in data:
        c = crc_step(c, b)
    return c


async def sample_before_rise(clk):
    """Go to the next falling edge of `clk` and settle (ReadOnly). Values read
    now are the ones the next rising edge sees: the DUTs only change on rising
    edges and the tests drive inputs on falling edges or right after rising
    ones, never in between."""
    await FallingEdge(clk)
    await ReadOnly()


async def saf_send_frame(dut, plen, first=0, bub=0, set_last=True, watchdog=None,
                         trailing_idle=False):
    """The `send_frame` task of the tb_mii_tx_saf* benches: drive on the falling
    edge, count a byte when tvalid && tready at a rising edge, next byte on the
    following falling edge. Byte 0 is `first`, byte k is k & 0xFF.

    bub: 0 = continuous; 1 = tvalid low for one cycle before every byte after
    the first; 2 = tvalid low for 40 cycles before byte plen/2 (tb_mii_tx_saf).
    set_last=False sends no tlast; watchdog: give up after that many cycles in
    a row without a transfer; trailing_idle: one more falling edge with tvalid
    and tlast low at the end (tb_mii_tx_saf_oversize). Returns bytes sent."""
    clk = dut.clk
    k = 0
    tvalid = 1
    await FallingEdge(clk)
    dut.s_axis_tvalid.value = 1
    dut.s_axis_tdata.value = first & 0xFF
    dut.s_axis_tlast.value = int(set_last and plen == 1)
    stall = 0
    while k < plen and (watchdog is None or stall < watchdog):
        await ReadOnly()
        hs = tvalid and is1(dut.s_axis_tready)
        await RisingEdge(clk)
        if hs:
            k += 1
            stall = 0
            await FallingEdge(clk)
            if k == plen:
                tvalid = 0
                dut.s_axis_tvalid.value = 0
                dut.s_axis_tlast.value = 0
            else:
                if bub == 1:
                    dut.s_axis_tvalid.value = 0
                    await FallingEdge(clk)
                    dut.s_axis_tvalid.value = 1
                elif bub == 2 and k == plen // 2:
                    dut.s_axis_tvalid.value = 0
                    for _ in range(40):
                        await FallingEdge(clk)
                    dut.s_axis_tvalid.value = 1
                dut.s_axis_tdata.value = k & 0xFF
                dut.s_axis_tlast.value = int(set_last and k == plen - 1)
        else:
            stall += 1
            await FallingEdge(clk)
    if trailing_idle:
        await FallingEdge(clk)
        dut.s_axis_tvalid.value = 0
        dut.s_axis_tlast.value = 0
    return k


async def axis_accept(clk, tready):
    """`@(posedge clk); while (!tready) @(posedge clk);` with the inputs driven
    right after a rising edge: returns right after the edge that took the beat."""
    while True:
        await ReadOnly()
        ready = is1(tready)
        await RisingEdge(clk)
        if ready:
            return


class BridgeMiiCapture:
    """The wire reassembly of tb_mii_tx_bridge / tb_mii_tx_burst_backpressure,
    `always @(posedge mii_clk or negedge rst_n)` with nonblocking updates:
    prev_mii_tx_en, nib_sel, low nibble, byte index (cleared when tx_en rises),
    buffer of `size` bytes (written only below `size`, never cleared). On the
    edge after tx_en falls calls on_frame_end(index, buf) with the values from
    before that edge."""

    def __init__(self, dut, size, on_frame_end=None):
        self.dut = dut
        self.size = size
        self.buf = [None] * size
        self.on_frame_end = on_frame_end or (lambda n, buf: None)
        self.prev = 0
        self.nib_sel = 0
        self.low = 0
        self.idx = 0

    async def run(self):
        dut = self.dut
        while True:
            await sample_before_rise(dut.mii_clk)
            if not is1(dut.rst_n):
                self.prev = self.nib_sel = self.low = self.idx = 0
                continue
            en = int(is1(dut.mii_tx_en))
            txd = val(dut.mii_txd)
            prev, nib_sel, idx = self.prev, self.nib_sel, self.idx
            self.prev = en
            if not prev and en:
                self.nib_sel = 0
                self.idx = 0
            if en:
                if not nib_sel:
                    self.low = txd
                    self.nib_sel = 1
                else:
                    if idx < self.size:
                        self.buf[idx] = (None if txd is None or self.low is None
                                         else (txd << 4) | self.low)
                    self.idx = idx + 1
                    self.nib_sel = 0
            if prev and not en:
                self.on_frame_end(idx, self.buf)


class MiiNibbleCapture:
    """The tb_mii_tx_saf* wire reconstruction, `always @(posedge mii_clk or
    negedge rst_n)`: en_d, nsel, lown, widx. Pairs nibbles low-first; on the
    edge where tx_en has fallen (en_d && !tx_en) calls on_frame(widx) and
    clears widx/nsel. on_byte(widx, byte) is called for every byte with the
    index it is written at."""

    def __init__(self, dut, clk, on_byte=None, on_frame=None):
        self.dut = dut
        self.clk = clk
        self.on_byte = on_byte or (lambda i, b: None)
        self.on_frame = on_frame or (lambda n: None)
        self.en_d = 0
        self.nsel = 0
        self.lown = 0
        self.widx = 0

    async def run(self):
        dut = self.dut
        while True:
            await sample_before_rise(self.clk)
            if not is1(dut.rst_n):
                self.en_d = self.nsel = self.widx = 0
                continue
            en = is1(dut.mii_tx_en)
            txd = val(dut.mii_txd)
            en_d = self.en_d
            self.en_d = int(en)
            if en:
                if not self.nsel:
                    self.lown = txd
                    self.nsel = 1
                else:
                    b = None if txd is None or self.lown is None else (txd << 4) | self.lown
                    self.on_byte(self.widx, b)
                    self.widx += 1
                    self.nsel = 0
            elif en_d:
                self.on_frame(self.widx)
                self.widx = 0
                self.nsel = 0
