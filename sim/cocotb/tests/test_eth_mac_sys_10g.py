# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""10G MAC system (rtl/eth_mac_sys_10g.v) and its frame FIFO.

  axis_async_frame_fifo     drop mode (DROP_WHEN_FULL=1), 32 words: random
                            frames, s_drop and stalls under three clock
                            ratios. Every frame is reported once (ok, drop,
                            overflow), exactly the ok ones come out, whole
                            and in order, and none is read before its last
                            word was written. A stalled reader overflows the
                            FIFO at exactly the expected frame.
  axis_async_frame_fifo_bp  the same with backpressure (DROP_WHEN_FULL=0):
                            nothing overflows except frames longer than the
                            FIFO, which are dropped without blocking it.
  eth_mac_sys_10g_loop      the system with the PCS and a line loopback, app
                            clock unrelated to the transceiver clock: CSRs;
                            line rate for 64-byte frames through both FIFOs;
                            every length, jumbo and tuser; the address filter,
                            promisc, multicast hash, rx_en and passthrough;
                            RX FIFO overflow under backpressure; a TX frame
                            too long for the FIFO; a slow app clock (the TX
                            MAC must never run dry); the counters; a
                            transceiver TX or RX reset alone; and a cut in
                            the line during traffic (local fault reported,
                            remote fault sequences sent instead of idles, no
                            new frame started, the app side held off; when
                            the line comes back, its own remote fault is
                            seen and cleared and traffic resumes in order).
"""
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, RisingEdge
from cocotb.utils import get_sim_time


SUITES = {
    "axis_async_frame_fifo": {
        "toplevel": "axis_async_frame_fifo",
        "sources": ["rtl/axis_async_frame_fifo.v"],
        "params": {"DATA_WIDTH": 16, "ADDR_WIDTH": 5, "DROP_WHEN_FULL": 1},
        "env": {"FIFO_MODE": "drop"},
        "skip_vhdl": "10G MAC is Verilog only so far",
    },
    "axis_async_frame_fifo_bp": {
        "toplevel": "axis_async_frame_fifo",
        "sources": ["rtl/axis_async_frame_fifo.v"],
        "params": {"DATA_WIDTH": 16, "ADDR_WIDTH": 5, "DROP_WHEN_FULL": 0},
        "env": {"FIFO_MODE": "bp"},
        "skip_vhdl": "10G MAC is Verilog only so far",
    },
    "eth_mac_sys_10g_loop": {
        "toplevel": "h_eth_mac_sys_10g_loop",
        "sources": ["rtl/crc32_d64.v", "rtl/async_fifo.v", "rtl/axis_async_frame_fifo.v",
                    "rtl/cdc_event_count.v", "rtl/eth_mac_10g_tx.v",
                    "rtl/eth_mac_10g_rx.v", "rtl/eth_rs_10g.v", "rtl/eth_mac_sys_10g.v",
                    "rtl/pcs10gbr_enc.v", "rtl/pcs10gbr_dec.v",
                    "rtl/pcs10gbr_scrambler.v", "rtl/pcs10gbr_gearbox_tx.v",
                    "rtl/pcs10gbr_gearbox_rx.v", "rtl/pcs10gbr_block_lock.v",
                    "rtl/pcs10gbr_ber_mon.v", "rtl/pcs10gbr.v",
                    "sim/cocotb/hdl/h_eth_mac_sys_10g_loop.v"],
        "skip_vhdl": "10G MAC is Verilog only so far",
    },
}

GT_NS = 6.206          # 161.13 MHz transceiver user clock
APP_NS = 5.0           # 200 MHz application clock


def is_fifo(dut):
    return dut._name == "axis_async_frame_fifo"


def is_sys(dut):
    return dut._name == "h_eth_mac_sys_10g_loop"


def now():
    return get_sim_time("ns")


# ---------------------------------------------------------------------------
# axis_async_frame_fifo
# ---------------------------------------------------------------------------
FIFO_DEPTH = 32


class FifoBench:
    def __init__(self, dut, wr_ns, rd_ns, seed):
        self.dut = dut
        self.rng = random.Random(seed)
        self.wr_ns, self.rd_ns = wr_ns, rd_ns
        self.sent = []           # (words, dropflag, t_last_written)
        self.fates = []          # "ok" / "drop" / "ovf", in order
        self.got = []            # (words, t_first_read)
        self.rd_ready_p = 1.0
        self.done = False
        self.tasks = []

    async def start(self):
        d = self.dut
        d.wr_rst_n.value = 0
        d.rd_rst_n.value = 0
        d.s_valid.value = 0
        d.s_last.value = 0
        d.s_drop.value = 0
        d.s_data.value = 0
        d.m_ready.value = 0
        self.tasks.append(cocotb.start_soon(Clock(d.wr_clk, self.wr_ns, "ns").start()))
        self.tasks.append(cocotb.start_soon(Clock(d.rd_clk, self.rd_ns, "ns").start()))
        await ClockCycles(d.wr_clk, 3)
        await ClockCycles(d.rd_clk, 3)
        d.wr_rst_n.value = 1
        d.rd_rst_n.value = 1
        await ClockCycles(d.wr_clk, 3)
        self.tasks.append(cocotb.start_soon(self.fate_mon()))
        self.tasks.append(cocotb.start_soon(self.reader()))

    def stop(self):
        for t in self.tasks:
            t.cancel()

    async def fate_mon(self):
        d = self.dut
        while True:
            await RisingEdge(d.wr_clk)
            await ReadOnly()
            n = 0
            if int(d.wr_frame_ok.value):
                self.fates.append("ok")
                n += 1
            if int(d.wr_frame_drop.value):
                self.fates.append("drop")
                n += 1
            if int(d.wr_frame_overflow.value):
                self.fates.append("ovf")
                n += 1
            assert n <= 1, "two frame reports in one cycle"

    async def reader(self):
        d = self.dut
        cur, t0 = [], None
        while True:
            await FallingEdge(d.rd_clk)
            d.m_ready.value = int(self.rng.random() < self.rd_ready_p)
            await ReadOnly()
            if int(d.m_valid.value) and int(d.m_ready.value):
                if not cur:
                    t0 = now()
                cur.append(int(d.m_data.value))
                if int(d.m_last.value):
                    self.got.append((cur, t0))
                    cur = []

    async def write(self, words, drop_at=None, gap_p=0.0):
        """One frame; drop_at = index of the word that carries s_drop."""
        d = self.dut
        i = 0
        while i < len(words):
            await FallingEdge(d.wr_clk)
            if self.rng.random() < gap_p:
                d.s_valid.value = 0
                continue
            d.s_valid.value = 1
            d.s_data.value = words[i]
            d.s_last.value = int(i == len(words) - 1)
            d.s_drop.value = int(i == drop_at)
            await ReadOnly()
            if int(d.s_ready.value):
                i += 1
        t_last = now()
        await FallingEdge(d.wr_clk)
        d.s_valid.value = 0
        d.s_last.value = 0
        d.s_drop.value = 0
        self.sent.append((words, drop_at is not None, t_last))

    async def drain(self, n_frames):
        d = self.dut
        for _ in range(20000):
            if len(self.fates) >= n_frames:
                break
            await RisingEdge(d.wr_clk)
        assert len(self.fates) == n_frames, f"{len(self.fates)} reports for {n_frames} frames"
        for _ in range(400):
            await RisingEdge(d.rd_clk)

    def check(self, bp):
        oks = [s for s, f in zip(self.sent, self.fates) if f == "ok"]
        for (words, dropped, _), fate in zip(self.sent, self.fates):
            if dropped:
                assert fate in ("drop", "ovf"), "a frame with s_drop came out"
            else:
                assert fate in ("ok", "ovf"), f"a clean frame reported {fate}"
            if bp and fate == "ovf":
                assert len(words) > FIFO_DEPTH, \
                    f"backpressure mode overflowed a {len(words)}-word frame"
            if bp and not dropped and len(words) <= FIFO_DEPTH:
                assert fate == "ok"
        assert len(self.got) == len(oks), f"{len(self.got)} frames out, {len(oks)} ok"
        for (words, _, t_last), (got, t0) in zip(oks, self.got):
            assert got == words, "frame data mismatch"
            assert t0 > t_last, "frame read before its last word was written"


async def fifo_run(dut, wr_ns, rd_ns, seed, bp):
    tb = FifoBench(dut, wr_ns, rd_ns, seed)
    await tb.start()
    tb.rd_ready_p = 0.7
    rng = tb.rng
    n = 0
    for k in range(300):
        if bp and k % 50 == 7:
            ln = FIFO_DEPTH + rng.randint(1, 10)       # can never fit
        else:
            ln = rng.randint(1, 12)
        words = [rng.getrandbits(16) for _ in range(ln)]
        drop_at = rng.randrange(ln) if rng.random() < 0.2 else None
        await tb.write(words, drop_at, gap_p=0.2)
        n += 1
        if k == 150:
            tb.rd_ready_p = 0.15         # a slow reader for a while
        if k == 200:
            tb.rd_ready_p = 1.0
    await tb.drain(n)
    tb.check(bp)
    tb.stop()
    return tb


@cocotb.test()
async def fifo_random(dut):
    """Random frames, s_drop and stalls; writer faster, slower, near equal."""
    if not is_fifo(dut):
        return
    bp = os.environ.get("FIFO_MODE") == "bp"
    for i, (w, r) in enumerate([(4.0, 7.0), (7.0, 4.0), (5.0, 5.3)]):
        tb = await fifo_run(dut, w, r, 10 + i, bp)
        if not bp:
            assert "ovf" in tb.fates, "the slow reader never overflowed the FIFO"
        dut._log.info("clocks %.1f/%.1f ns: %s", w, r,
                      {f: tb.fates.count(f) for f in ("ok", "drop", "ovf")})


@cocotb.test()
async def fifo_stalled_reader(dut):
    """Reader stalled: 4 frames of 8 words fill 32 words, the rest overflow
    (drop mode) or wait (backpressure mode); then everything drains."""
    if not is_fifo(dut):
        return
    bp = os.environ.get("FIFO_MODE") == "bp"
    tb = FifoBench(dut, 5.0, 6.0, 3)
    await tb.start()
    tb.rd_ready_p = 0.0
    frames = [[(f << 8) | j for j in range(8)] for f in range(10)]
    if bp:
        w = cocotb.start_soon(_write_all(tb, frames))
        for _ in range(300):
            await RisingEdge(dut.wr_clk)
        assert tb.fates == ["ok"] * 4, tb.fates
        assert int(dut.s_ready.value) == 0
        tb.rd_ready_p = 1.0
        await w
        await tb.drain(10)
        assert tb.fates == ["ok"] * 10
    else:
        for f in frames:
            await tb.write(f)
        for _ in range(20):
            await RisingEdge(dut.wr_clk)
        assert tb.fates == ["ok"] * 4 + ["ovf"] * 6, tb.fates
        assert tb.got == []
        tb.rd_ready_p = 1.0
        await tb.drain(10)
    tb.check(bp)
    tb.stop()


async def _write_all(tb, frames):
    for f in frames:
        await tb.write(f)


# ---------------------------------------------------------------------------
# eth_mac_sys_10g with the PCS and a line loopback
# ---------------------------------------------------------------------------
OUR_MAC = bytes.fromhex("020000000001")
SRC_MAC = bytes.fromhex("020000000002")

R_VERSION, R_CTRL, R_STATUS, R_MAC_LO, R_MAC_HI = 0x00, 0x04, 0x08, 0x0C, 0x10
R_SCRATCH, R_MC_LO, R_MC_HI, R_CAPS = 0x3C, 0x44, 0x48, 0x98
R_IP_ADDR = 0x40
R_TX_FRAMES, R_TX_BYTES, R_RX_FRAMES, R_RX_BYTES = 0xB0, 0xB8, 0xC0, 0xC8
R_RX_FCS, R_RX_CTL, R_RX_OVER, R_RX_UNDER = 0xD0, 0xD4, 0xD8, 0xDC
R_RX_BC, R_RX_MC, R_RX_DROP, R_RX_DISC = 0xE0, 0xE4, 0xE8, 0xEC
R_TX_UNR, R_TX_DROP, R_TX_ERR, R_LOCK_LOSS = 0xF0, 0xF4, 0xF8, 0xFC
R_LOCAL_F, R_REMOTE_F = 0xA8, 0xAC
C_TX, C_RX, C_PROMISC, C_JUMBO, C_PASS = 1, 2, 4, 0x40, 0x100
COUNTERS32 = [R_RX_FCS, R_RX_CTL, R_RX_OVER, R_RX_UNDER, R_RX_BC, R_RX_MC,
              R_RX_DROP, R_RX_DISC, R_TX_UNR, R_TX_DROP, R_TX_ERR, R_LOCK_LOSS,
              R_LOCAL_F, R_REMOTE_F]
COUNTERS64 = [R_TX_FRAMES, R_TX_BYTES, R_RX_FRAMES, R_RX_BYTES]


def mc_hash_idx(mac: bytes) -> int:
    v = int.from_bytes(mac, "big")
    idx = 0
    for i in range(8):
        idx ^= (v >> (6 * i)) & 0x3F
    return idx


def make_frame(rng, length, dst=OUR_MAC, seq=0):
    """length bytes before the FCS (at least 14)."""
    hdr = dst + SRC_MAC + b"\x88\xb5"
    body = seq.to_bytes(4, "big") + rng.randbytes(max(0, length - 18))
    return (hdr + body)[:length]


class SysBench:
    def __init__(self, dut, app_ns=APP_NS, seed=0):
        self.dut = dut
        self.app_ns = app_ns
        self.rng = random.Random(seed)
        self.got = []            # (bytes, tuser, t)
        self.ready_p = 1.0
        self.tasks = []

    async def start(self):
        d = self.dut
        for s in (d.s_axi_awvalid, d.s_axi_wvalid, d.s_axi_bready,
                  d.s_axi_arvalid, d.s_axi_rready, d.s_axis_tvalid,
                  d.s_axis_tlast, d.s_axis_tuser, d.m_axis_tready):
            s.value = 0
        d.s_axi_wstrb.value = 0xF
        d.s_axi_awaddr.value = 0
        d.s_axi_araddr.value = 0
        d.s_axi_wdata.value = 0
        d.s_axis_tdata.value = 0
        d.s_axis_tkeep.value = 0
        d.rst_n.value = 0
        d.gt_rst_n.value = 0
        d.tx_rst_n.value = 1
        d.rx_rst_n.value = 1
        d.cut.value = 0
        self.tasks.append(cocotb.start_soon(Clock(d.clk, self.app_ns, "ns").start()))
        self.tasks.append(cocotb.start_soon(Clock(d.gt_clk, GT_NS, "ns").start()))
        await ClockCycles(d.gt_clk, 5)
        d.rst_n.value = 1
        d.gt_rst_n.value = 1
        self.tasks.append(cocotb.start_soon(self.sink()))
        await self.wait_lock()
        await ClockCycles(d.clk, 20)

    async def wait_lock(self):
        d = self.dut
        for _ in range(3000):
            await RisingEdge(d.gt_clk)
            if int(d.block_lock.value):
                break
        assert int(d.block_lock.value), "no block lock"

    async def side_reset(self, sig, cycles=40):
        """Pulse one transceiver-side reset (TX or RX direction), wait for
        block lock again."""
        await FallingEdge(self.dut.gt_clk)
        sig.value = 0
        await ClockCycles(self.dut.gt_clk, cycles)
        sig.value = 1
        await ClockCycles(self.dut.gt_clk, 10)
        await self.wait_lock()
        await ClockCycles(self.dut.clk, 50)

    def stop(self):
        for t in self.tasks:
            t.cancel()

    # ---- AXI4-Lite
    async def write(self, addr, data):
        d = self.dut
        await FallingEdge(d.clk)
        d.s_axi_awaddr.value = addr
        d.s_axi_wdata.value = data
        d.s_axi_awvalid.value = 1
        d.s_axi_wvalid.value = 1
        d.s_axi_bready.value = 1
        while True:
            await ReadOnly()
            ok = int(d.s_axi_awready.value)
            await FallingEdge(d.clk)
            if ok:
                break
        d.s_axi_awvalid.value = 0
        d.s_axi_wvalid.value = 0
        while True:
            await ReadOnly()
            ok = int(d.s_axi_bvalid.value)
            await FallingEdge(d.clk)
            if ok:
                break
        d.s_axi_bready.value = 0

    async def read(self, addr):
        d = self.dut
        await FallingEdge(d.clk)
        d.s_axi_araddr.value = addr
        d.s_axi_arvalid.value = 1
        while True:
            await ReadOnly()
            ok = int(d.s_axi_arready.value)
            await FallingEdge(d.clk)
            if ok:
                break
        d.s_axi_arvalid.value = 0
        d.s_axi_rready.value = 1
        while True:
            await ReadOnly()
            ok = int(d.s_axi_rvalid.value)
            val = int(d.s_axi_rdata.value)
            await FallingEdge(d.clk)
            if ok:
                break
        d.s_axi_rready.value = 0
        return val

    async def read64(self, addr):
        lo = await self.read(addr)
        hi = await self.read(addr + 4)
        return (hi << 32) | lo

    async def counters(self):
        c = {}
        for a in COUNTERS64:
            c[a] = await self.read64(a)
        for a in COUNTERS32:
            c[a] = await self.read(a)
        return c

    async def clear_counters(self):
        for a in COUNTERS64 + COUNTERS32:
            await self.write(a, 0)

    async def setup(self, ctrl=C_TX | C_RX, mac=OUR_MAC):
        v = int.from_bytes(mac, "big")
        await self.write(R_MAC_LO, v & 0xFFFFFFFF)
        await self.write(R_MAC_HI, v >> 32)
        await self.write(R_CTRL, ctrl)

    # ---- AXI4-Stream
    async def send(self, frames, gap_p=0.0):
        """frames: list of bytes or (bytes, tuser)."""
        d = self.dut
        for fr in frames:
            data, tuser = (fr, 0) if isinstance(fr, (bytes, bytearray)) else fr
            beats = [data[i:i + 8] for i in range(0, len(data), 8)]
            i = 0
            while i < len(beats):
                await FallingEdge(d.clk)
                if gap_p and self.rng.random() < gap_p:
                    d.s_axis_tvalid.value = 0
                    continue
                b = beats[i]
                d.s_axis_tdata.value = int.from_bytes(b.ljust(8, b"\0"), "little")
                d.s_axis_tkeep.value = (1 << len(b)) - 1
                d.s_axis_tlast.value = int(i == len(beats) - 1)
                d.s_axis_tuser.value = tuser if i == len(beats) - 1 else 0
                d.s_axis_tvalid.value = 1
                await ReadOnly()
                if int(d.s_axis_tready.value):
                    i += 1
        await FallingEdge(d.clk)
        d.s_axis_tvalid.value = 0
        d.s_axis_tlast.value = 0
        d.s_axis_tuser.value = 0

    async def sink(self):
        d = self.dut
        cur = bytearray()
        while True:
            await FallingEdge(d.clk)
            d.m_axis_tready.value = int(self.rng.random() < self.ready_p)
            await ReadOnly()
            if int(d.m_axis_tvalid.value) and int(d.m_axis_tready.value):
                keep = int(d.m_axis_tkeep.value)
                n = bin(keep).count("1")
                assert keep == (1 << n) - 1, f"tkeep {keep:02x} not contiguous"
                w = int(d.m_axis_tdata.value).to_bytes(8, "little")
                cur += w[:n]
                if int(d.m_axis_tlast.value):
                    self.got.append((bytes(cur), int(d.m_axis_tuser.value), now()))
                    cur = bytearray()
                else:
                    assert n == 8, "short beat before tlast"

    async def wait_frames(self, n, limit_ns=2_000_000):
        t_end = now() + limit_ns
        while len(self.got) < n and now() < t_end:
            await ClockCycles(self.dut.clk, 50)
        await ClockCycles(self.dut.clk, 200)


def padded(f):
    return f + bytes(max(0, 60 - len(f)))


def wire_len(f):
    return max(60, len(f)) + 4


@cocotb.test()
async def sys_csr(dut):
    """VERSION, CAPS, SCRATCH, IP_ADDR, CTRL and MAC registers."""
    if not is_sys(dut):
        return
    tb = SysBench(dut)
    await tb.start()
    ver = await tb.read(R_VERSION)
    assert ver & 0xFFFF == 0x454D, f"VERSION {ver:08x}"
    caps = await tb.read(R_CAPS)
    assert caps >> 16 == 9018 and caps & (1 << 9) and caps & 1, f"CAPS {caps:08x}"
    assert (caps >> 4) & 0x1F == 14, "RX FIFO size field"
    assert await tb.read(R_CTRL) == 0
    await tb.write(R_SCRATCH, 0xA5A5_5A5A)
    assert await tb.read(R_SCRATCH) == 0xA5A5_5A5A
    assert await tb.read(R_IP_ADDR) == 0xC0A889C8, "IP_ADDR reset value"
    await tb.write(R_IP_ADDR, 0x0A00_0001)
    assert await tb.read(R_IP_ADDR) == 0x0A00_0001
    assert int(dut.u_sys.cfg_ip_addr.value) == 0x0A00_0001
    await tb.write(R_MAC_HI, 0xFFFF_1234)
    assert await tb.read(R_MAC_HI) == 0x1234
    st = await tb.read(R_STATUS)
    assert st & 1, "STATUS block lock"
    tb.stop()


@cocotb.test()
async def sys_line_rate(dut):
    """500 back-to-back 64-byte frames: all delivered at line rate, counted."""
    if not is_sys(dut):
        return
    tb = SysBench(dut, seed=1)
    await tb.start()
    await tb.setup()
    frames = [make_frame(tb.rng, 60, seq=i) for i in range(500)]
    await tb.send(frames)
    await tb.wait_frames(500)
    assert [g[0] for g in tb.got] == frames
    assert all(g[1] == 0 for g in tb.got)
    # steady state: 84 line bytes per frame, one 8-byte word on 32 of 33
    # transceiver clocks
    t = [g[2] for g in tb.got]
    per = (t[450] - t[50]) / 400
    want = 84 / 8 * 33 / 32 * GT_NS
    dut._log.info("%.2f ns per frame, line rate %.2f ns", per, want)
    assert abs(per / want - 1) < 0.005, f"{per:.2f} ns per frame, want {want:.2f}"
    c = await tb.counters()
    assert c[R_TX_FRAMES] == 500 and c[R_TX_BYTES] == 500 * 64
    assert c[R_RX_FRAMES] == 500 and c[R_RX_BYTES] == 500 * 64
    assert c[R_RX_DROP] == 0 and c[R_TX_UNR] == 0 and c[R_RX_DISC] == 0
    tb.stop()


@cocotb.test()
async def sys_lengths(dut):
    """Every length 14..160 and random ones to 1514, jumbo with jumbo_en,
    tuser frames dropped, then delivered flagged with passthrough."""
    if not is_sys(dut):
        return
    tb = SysBench(dut, seed=2)
    await tb.start()
    await tb.setup(C_TX | C_RX | C_JUMBO)
    rng = tb.rng
    lens = list(range(14, 161)) + [rng.randint(161, 1514) for _ in range(40)]
    lens += [1514, 9000, 9014]
    frames = [make_frame(rng, n, seq=i) for i, n in enumerate(lens)]
    await tb.send(frames, gap_p=0.1)
    await tb.wait_frames(len(frames))
    assert [g[0] for g in tb.got] == [padded(f) for f in frames]
    c = await tb.counters()
    assert c[R_RX_FRAMES] == len(frames)
    assert c[R_RX_BYTES] == sum(wire_len(f) for f in frames)
    assert c[R_TX_BYTES] == c[R_RX_BYTES]
    assert c[R_RX_OVER] == 0
    # tuser: sent with a bad FCS, dropped as bad, counted
    await tb.clear_counters()
    tb.got.clear()
    bad = make_frame(rng, 100, seq=1000)
    good = make_frame(rng, 100, seq=1001)
    await tb.send([(bad, 1), good])
    await tb.wait_frames(1)
    assert [g[0] for g in tb.got] == [good]
    c = await tb.counters()
    assert c[R_TX_ERR] == 1 and c[R_TX_FRAMES] == 1
    assert c[R_RX_FCS] == 1 and c[R_RX_DISC] == 1 and c[R_RX_FRAMES] == 1
    # passthrough delivers it, flagged
    await tb.write(R_CTRL, C_TX | C_RX | C_PASS)
    tb.got.clear()
    await tb.send([(bad, 1), good])
    await tb.wait_frames(2)
    assert [(g[0], g[1]) for g in tb.got] == [(bad, 1), (good, 0)]
    # oversize without jumbo_en: dropped, counted
    await tb.write(R_CTRL, C_TX | C_RX)
    await tb.clear_counters()
    tb.got.clear()
    await tb.send([make_frame(rng, 1515), good])
    await tb.wait_frames(1)
    assert [g[0] for g in tb.got] == [good]
    c = await tb.counters()
    assert c[R_RX_OVER] == 1 and c[R_RX_DISC] == 1
    tb.stop()


@cocotb.test()
async def sys_filter(dut):
    """Unicast to us, other unicast, broadcast, multicast in and out of the
    hash table; promisc; rx_en off."""
    if not is_sys(dut):
        return
    tb = SysBench(dut, seed=3)
    await tb.start()
    await tb.setup()
    rng = tb.rng
    mc_in = bytes.fromhex("01005e000001")
    mc_out = bytes.fromhex("01005e0000aa")
    assert mc_hash_idx(mc_in) != mc_hash_idx(mc_out)
    h = 1 << mc_hash_idx(mc_in)
    await tb.write(R_MC_LO, h & 0xFFFFFFFF)
    await tb.write(R_MC_HI, h >> 32)
    dsts = [OUR_MAC, bytes.fromhex("020000000099"), b"\xff" * 6, mc_in, mc_out]
    frames = [make_frame(rng, 80, dst=d, seq=i) for i, d in enumerate(dsts)]
    await tb.send(frames)
    await tb.wait_frames(3)
    assert [g[0] for g in tb.got] == [frames[0], frames[2], frames[3]]
    c = await tb.counters()
    assert c[R_RX_FRAMES] == 5 and c[R_RX_DISC] == 2
    assert c[R_RX_BC] == 1 and c[R_RX_MC] == 2
    # promisc: everything
    tb.got.clear()
    await tb.write(R_CTRL, C_TX | C_RX | C_PROMISC)
    await tb.send(frames)
    await tb.wait_frames(5)
    assert [g[0] for g in tb.got] == frames
    # RX disabled: nothing
    tb.got.clear()
    await tb.write(R_CTRL, C_TX)
    await tb.send(frames)
    await ClockCycles(dut.clk, 600)
    assert tb.got == []
    c = await tb.counters()
    assert c[R_RX_DISC] == 2 + 5
    tb.stop()


@cocotb.test()
async def sys_rx_backpressure(dut):
    """m_axis stalled: the RX FIFO fills and drops whole frames; what comes
    out is whole, correct and in order, and every frame is accounted for."""
    if not is_sys(dut):
        return
    tb = SysBench(dut, seed=4)
    await tb.start()
    await tb.setup()
    tb.ready_p = 0.0
    frames = [make_frame(tb.rng, 200, seq=i) for i in range(150)]
    await tb.send(frames)
    await ClockCycles(dut.clk, 500)
    tb.ready_p = 0.5
    await tb.wait_frames(150, limit_ns=300_000)
    got = [g[0] for g in tb.got]
    it = iter(frames)
    assert all(any(g == f for f in it) for g in got), "out of order or corrupt"
    c = await tb.counters()
    assert c[R_RX_DROP] > 0, "the RX FIFO never overflowed"
    assert len(got) + c[R_RX_DROP] == 150
    dut._log.info("%d delivered, %d dropped", len(got), c[R_RX_DROP])
    tb.stop()


@cocotb.test()
async def sys_tx_oversize(dut):
    """A frame longer than the TX FIFO is dropped; the next ones go out."""
    if not is_sys(dut):
        return
    tb = SysBench(dut, seed=5)
    await tb.start()
    await tb.setup(C_TX | C_RX | C_JUMBO)
    big = make_frame(tb.rng, 2048 * 8 + 100)
    after = [make_frame(tb.rng, 64 + i, seq=i) for i in range(5)]
    await tb.send([big] + after)
    await tb.wait_frames(5)
    assert [g[0] for g in tb.got] == after
    c = await tb.counters()
    assert c[R_TX_DROP] == 1 and c[R_TX_FRAMES] == 5
    tb.stop()


@cocotb.test()
async def sys_slow_app_clock(dut):
    """App clock (111 MHz) slower than the transceiver's: the TX MAC only
    starts whole frames, so it never runs dry, whatever the frame length."""
    if not is_sys(dut):
        return
    tb = SysBench(dut, app_ns=9.0, seed=6)
    await tb.start()
    await tb.setup(C_TX | C_RX | C_JUMBO)
    lens = [60, 1000, 64, 1514, 200, 3000, 61] * 3
    frames = [make_frame(tb.rng, n, seq=i) for i, n in enumerate(lens)]
    await tb.send(frames)
    await tb.wait_frames(len(frames))
    assert [g[0] for g in tb.got] == frames
    c = await tb.counters()
    assert c[R_TX_UNR] == 0 and c[R_RX_FCS] == 0 and c[R_RX_DROP] == 0
    tb.stop()


@cocotb.test()
async def sys_counter_clear(dut):
    """64-bit counter read latches the high word; a write clears a counter."""
    if not is_sys(dut):
        return
    tb = SysBench(dut, seed=7)
    await tb.start()
    await tb.setup()
    frames = [make_frame(tb.rng, 100, seq=i) for i in range(3)]
    await tb.send(frames)
    await tb.wait_frames(3)
    assert await tb.read64(R_RX_BYTES) == 3 * 104
    await tb.write(R_RX_BYTES, 0)
    assert await tb.read64(R_RX_BYTES) == 0
    assert await tb.read64(R_RX_FRAMES) == 3
    await tb.write(R_TX_UNR, 0)
    assert await tb.read(R_TX_UNR) == 0
    tb.stop()


@cocotb.test()
async def sys_side_reset(dut):
    """A transceiver TX or RX reset alone (as the GT's own resets do) resets
    the whole crossing: afterwards exactly the frames sent come out, none
    stale from the FIFO memory, and no counter jumps. Then a reset in the
    middle of traffic: every frame out is either one that was sent, intact,
    or closed flagged (tuser), and traffic recovers."""
    if not is_sys(dut):
        return
    tb = SysBench(dut, seed=8)
    await tb.start()
    await tb.setup()
    rng = tb.rng
    seq = 0
    for sig in (dut.rx_rst_n, dut.tx_rst_n, dut.rx_rst_n):
        # move the FIFO pointers well into the memory, then reset while idle
        lens = [rng.randint(60, 700) for _ in range(30)]
        frames = [make_frame(rng, n, seq=seq + i) for i, n in enumerate(lens)]
        seq += len(frames)
        tb.got.clear()
        await tb.send(frames)
        await tb.wait_frames(len(frames))
        assert [g[0] for g in tb.got] == frames
        await tb.side_reset(sig)
        c = await tb.counters()
        for a in (R_RX_DROP, R_RX_DISC, R_TX_UNR, R_TX_DROP):
            assert c[a] < 10, f"counter 0x{a:02X} = {c[a]} after a reset"
        await tb.clear_counters()
        tb.got.clear()
        frames = [make_frame(rng, 60 + 7 * i, seq=seq + i) for i in range(20)]
        seq += len(frames)
        await tb.send(frames)
        await tb.wait_frames(len(frames))
        assert [g[0] for g in tb.got] == frames, f"after {sig._name} reset"
        assert all(g[1] == 0 for g in tb.got)
        c = await tb.counters()
        assert c[R_RX_FRAMES] == 20 and c[R_TX_FRAMES] == 20
        assert c[R_RX_DROP] == 0 and c[R_RX_DISC] == 0 and c[R_TX_DROP] == 0

    # reset in the middle of traffic, with the reader stalling at times
    for sig in (dut.rx_rst_n, dut.tx_rst_n):
        tb.got.clear()
        tb.ready_p = 0.7
        frames = [make_frame(rng, rng.randint(60, 1514), seq=seq + i)
                  for i in range(60)]
        seq += len(frames)
        sender = cocotb.start_soon(tb.send(frames))
        await ClockCycles(dut.clk, 1500)
        await tb.side_reset(sig, cycles=25)
        await sender
        # the reset is a link fault too (lost lock, then the loop's own
        # remote fault): the TX gate holds frames back until it clears, so
        # wait until the output goes quiet
        n = -1
        while n != len(tb.got):
            n = len(tb.got)
            await ClockCycles(dut.clk, 3000)
        sent = set(frames)
        for data, tuser, _ in tb.got:
            assert tuser or data in sent, "corrupt frame delivered as good"
        n_good = sum(1 for g in tb.got if not g[1])
        dut._log.info("%s reset mid-traffic: %d of %d frames out, %d flagged",
                      sig._name, n_good, len(frames), len(tb.got) - n_good)
        tb.ready_p = 1.0
        tb.got.clear()
        frames = [make_frame(rng, 100, seq=seq + i) for i in range(10)]
        seq += len(frames)
        await tb.send(frames)
        await tb.wait_frames(10)
        assert [g[0] for g in tb.got] == frames
    tb.stop()


RF_WORD = 0x0200009C0200009C


@cocotb.test()
async def sys_link_fault(dut):
    """The line is cut in the middle of traffic: STATUS reports a local fault,
    remote fault sequences go out in place of idles, no new frame starts and
    the app side is held off by backpressure (nothing is dropped). When the
    line comes back, the system reads back its own remote fault sequences:
    a remote fault, counted, which clears once they stop. Traffic resumes:
    every frame out is one sent, in order, and only frames that were on the
    line around the cut are missing."""
    if not is_sys(dut):
        return
    tb = SysBench(dut, seed=9)
    await tb.start()
    await tb.setup()
    await tb.clear_counters()
    rng = tb.rng
    rs = dut.u_sys.u_rs
    frames = [make_frame(rng, rng.randint(60, 300), seq=i) for i in range(400)]
    mon = {"cyc": 0, "rise": None, "late": [], "rf": 0, "rf_bad": 0, "held": False,
           "send_rf": 0}

    async def watch():
        d = dut
        while True:
            await RisingEdge(d.gt_clk)
            await ReadOnly()
            mon["cyc"] += 1
            f = int(rs.tx_fault.value)
            if f and mon["rise"] is None:
                mon["rise"] = mon["cyc"]
            elif not f:
                mon["rise"] = None
            txd, txc = int(d.xgmii_txd.value), int(d.xgmii_txc.value)
            start = ((txc & 1) and (txd & 0xFF) == 0xFB) or \
                    ((txc & 0x10) and ((txd >> 32) & 0xFF) == 0xFB)
            # a start more than a few clocks after tx_fault rose: a frame
            # begun after the fault was seen
            if start and mon["rise"] is not None and mon["cyc"] - mon["rise"] > 12:
                mon["late"].append(mon["cyc"])
            # the output word was chosen with last clock's send_rf
            if txd == RF_WORD and txc == 0x11:
                mon["rf"] += 1
                if mon["send_rf"] != 1:
                    mon["rf_bad"] += 1
            mon["send_rf"] = int(rs.send_rf.value)
            if f and int(d.s_axis_tvalid.value) and not int(d.s_axis_tready.value):
                mon["held"] = True

    w = cocotb.start_soon(watch())
    sender = cocotb.start_soon(tb.send(frames))
    await ClockCycles(dut.gt_clk, 1500)
    assert 0 < len(tb.got) < len(frames)
    dut.cut.value = 1
    for _ in range(200):
        await ClockCycles(dut.clk, 20)
        if (await tb.read(R_STATUS)) & 0x8:
            break
    st = await tb.read(R_STATUS)
    assert st & 0x8 and not st & 0x10 and not st & 1, f"STATUS {st:02x} with the line cut"
    n_cut = len(tb.got)
    await ClockCycles(dut.gt_clk, 3000)
    assert mon["rf"] > 1000, f"{mon['rf']} remote fault words with the line cut"
    assert len(tb.got) == n_cut, "frames received with the line cut"
    assert mon["held"], "the app side was not held off"
    assert not sender.done()
    dut.cut.value = 0
    rf_seen = False
    for _ in range(400):
        await ClockCycles(dut.clk, 20)
        st = await tb.read(R_STATUS)
        rf_seen |= bool(st & 0x10)
        if rf_seen and not st & 0x18:
            break
    assert rf_seen and not st & 0x18 and st & 1, f"STATUS {st:02x} after the line came back"
    await sender
    await tb.wait_frames(len(frames) - 20, limit_ns=4_000_000)
    await ClockCycles(dut.clk, 2000)
    w.cancel()
    assert not mon["late"], f"frames started with a fault seen: {mon['late'][:4]}"
    assert mon["rf_bad"] == 0, "remote fault words without a local fault"
    idx = {f: i for i, f in enumerate(frames)}
    for g in tb.got:
        assert g[1] or g[0] in idx, "corrupt frame delivered as good"
    good = [idx[g[0]] for g in tb.got if not g[1]]
    assert good == sorted(good), "frames out of order"
    assert good[-1] == len(frames) - 1, "last frame missing"
    missing = sorted(set(range(len(frames))) - set(good))
    dut._log.info("missing frames around the cut: %s", missing)
    assert missing and missing[-1] - missing[0] == len(missing) - 1, \
        f"missing frames not one run: {missing}"
    assert len(missing) <= 4, f"{len(missing)} frames lost"
    c = await tb.counters()
    assert c[R_LOCAL_F] == 1 and c[R_REMOTE_F] == 1, (c[R_LOCAL_F], c[R_REMOTE_F])
    assert c[R_TX_FRAMES] == len(frames) and c[R_TX_DROP] == 0 and c[R_TX_UNR] == 0
    assert c[R_LOCK_LOSS] >= 1
    tb.stop()
