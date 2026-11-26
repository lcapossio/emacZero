# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""10GBASE-R PCS (rtl/pcs10gbr*.v) against the clause 49 reference model in
lib/pcs10gbr_model.py.

  pcs10gbr_enc       every XGMII pattern the encoder knows, plus junk, compared
                     block by block with the model encoder
  pcs10gbr_dec       model-encoded frame streams with corrupted headers, block
                     types, control codes and broken sequences, compared with
                     the model decoder and receive state machine
  pcs10gbr           whole PCS: the TX bit stream is aligned, descrambled and
                     decoded by the model; the TX stream is looped back to RX at
                     several bit offsets and the RX XGMII stream must match;
                     sync header errors drop and regain block lock and raise
                     hi_ber
"""
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from lib.pcs10gbr_model import (CODE, E_D, LF_C, LF_D, SYNC_CTRL, SYNC_DATA,
                                RxFsm, Scrambler, decode, encode, frame_stream,
                                xgmii)

SUITES = {
    "pcs10gbr_enc": {
        "toplevel": "pcs10gbr_enc",
        "sources": ["rtl/pcs10gbr_enc.v"],
        "params": {},
        "skip_vhdl": "10GBASE-R PCS is Verilog only for now",
    },
    "pcs10gbr_dec": {
        "toplevel": "pcs10gbr_dec",
        "sources": ["rtl/pcs10gbr_dec.v"],
        "params": {},
        "skip_vhdl": "10GBASE-R PCS is Verilog only for now",
    },
    "pcs10gbr": {
        "toplevel": "pcs10gbr",
        "sources": ["rtl/pcs10gbr_enc.v", "rtl/pcs10gbr_dec.v",
                    "rtl/pcs10gbr_scrambler.v", "rtl/pcs10gbr_gearbox_tx.v",
                    "rtl/pcs10gbr_gearbox_rx.v", "rtl/pcs10gbr_block_lock.v",
                    "rtl/pcs10gbr_ber_mon.v", "rtl/pcs10gbr.v"],
        "params": {"BER_TIMER_CYCLES": 4000},
        "skip_vhdl": "10GBASE-R PCS is Verilog only for now",
    },
}

M64 = (1 << 64) - 1
LEAD_IDLES = 800


def junk_transfer(rng):
    """Random transfer biased toward near-valid control patterns."""
    pool = list(CODE) + [0xFB, 0xFD, 0x9C, 0x5C, 0x00, 0x55, 0xAA, 0x01]
    lanes = [rng.choice(pool) if rng.random() < 0.7 else rng.randrange(256)
             for _ in range(8)]
    ctl = [rng.randrange(2) for _ in range(8)]
    return xgmii(lanes, ctl)


# --------------------------------------------------------------------- encoder
@cocotb.test(timeout_time=2, timeout_unit="ms")
async def enc_vectors(dut):
    if dut._name != "pcs10gbr_enc":
        return
    rng = random.Random(0x10E)
    cocotb.start_soon(Clock(dut.clk, 6.4, unit="ns").start())
    dut.rst_n.value = 0
    dut.en.value = 1
    dut.xgmii_d.value = 0
    dut.xgmii_c.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1

    vecs = frame_stream(rng, 300)
    vecs += [junk_transfer(rng) for _ in range(3000)]
    seen, fails = set(), 0
    for d, c in vecs:
        await FallingEdge(dut.clk)
        dut.xgmii_d.value = d
        dut.xgmii_c.value = c
        await RisingEdge(dut.clk)
        await ReadOnly()
        eh, ep = encode(d, c)
        seen.add(ep & 0xFF if eh == SYNC_CTRL else 'D')
        gh, gp = int(dut.hdr.value), int(dut.pay.value)
        if (gh, gp) != (eh, ep):
            fails += 1
            if fails <= 10:
                dut._log.error(f"d={d:016X} c={c:02X}: got {gh:02b} {gp:016X} "
                               f"expected {eh:02b} {ep:016X}")
    want = {'D', 0x1E, 0x2D, 0x33, 0x66, 0x55, 0x78, 0x4B,
            0x87, 0x99, 0xAA, 0xB4, 0xCC, 0xD2, 0xE1, 0xFF}
    missing = want - seen
    dut._log.info(f"{len(vecs)} transfers, {fails} mismatches, block types missing: {missing}")
    assert not missing, f"block types not exercised: {missing}"
    assert fails == 0


# --------------------------------------------------------------------- decoder
def corrupt(rng, h, p):
    k = rng.randrange(5)
    if k == 0:
        return rng.choice((0b00, 0b11)), p                  # bad sync header
    if k == 1:
        return SYNC_CTRL, (p & ~0xFF) | rng.randrange(256)  # random block type
    if k == 2:
        return SYNC_CTRL, (rng.getrandbits(56) << 8) | 0x1E  # 0x1E, random codes
    if k == 3:
        return h ^ 0b11, p                                   # data <-> control
    return h, p ^ (1 << rng.randrange(64))                   # one payload bit


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def dec_vectors(dut):
    if dut._name != "pcs10gbr_dec":
        return
    rng = random.Random(0xDEC)
    cocotb.start_soon(Clock(dut.clk, 6.4, unit="ns").start())
    dut.rst_n.value = 0
    dut.en.value = 0
    dut.block_lock.value = 1
    dut.hi_ber.value = 0
    dut.hdr.value = SYNC_CTRL
    dut.pay.value = 0x1E
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1

    blocks = []
    for d, c in frame_stream(rng, 400):
        h, p = encode(d, c)
        if rng.random() < 0.03:
            h, p = corrupt(rng, h, p)
        blocks.append((h, p))

    fsm = RxFsm()
    fails = errs = 0
    for i, (h, p) in enumerate(blocks):
        await FallingEdge(dut.clk)
        dut.en.value = 1
        dut.hdr.value = h
        dut.pay.value = p
        await RisingEdge(dut.clk)
        await ReadOnly()
        exp = fsm.feed(decode(h, p))
        if exp is None:
            exp = (LF_D, LF_C)
        if exp == (E_D, 0xFF):
            errs += 1
        got = (int(dut.xgmii_d.value), int(dut.xgmii_c.value))
        if int(dut.valid.value) != 1 or got != exp:
            fails += 1
            if fails <= 10:
                dut._log.error(f"block {i}: got {got[0]:016X}/{got[1]:02X} "
                               f"expected {exp[0]:016X}/{exp[1]:02X}")
    dut._log.info(f"{len(blocks)} blocks, {errs} error outputs, {fails} mismatches")
    assert errs > 20, "corruption did not produce error outputs"
    assert fails == 0


# ------------------------------------------------------------------- full PCS
class Loop:
    """Drives XGMII into TX, records gt_txdata and feeds it back to RX with a
    bit offset and optional sync-header flips (absolute TX stream bit
    positions)."""

    def __init__(self, dut, vecs, offset):
        self.dut = dut
        self.vecs = vecs
        self.idx = 0
        self.offset = offset
        self.tx_words = []
        self.rx_out = []
        self.flips = set()
        self.lock_hist = []
        self.hiber_hist = []

    async def source(self):
        dut = self.dut
        idle = xgmii([0x07] * 8, [1] * 8)
        while True:
            await FallingEdge(dut.tx_clk)
            d, c = self.vecs[self.idx] if self.idx < len(self.vecs) else idle
            dut.xgmii_txd.value = d
            dut.xgmii_txc.value = c
            if int(dut.xgmii_tx_ready.value):
                self.idx += 1

    async def capture(self):
        dut = self.dut
        while True:
            await RisingEdge(dut.tx_clk)
            await ReadOnly()
            self.tx_words.append(int(dut.gt_txdata.value))
            if int(dut.xgmii_rx_valid.value):
                self.rx_out.append((int(dut.xgmii_rxd.value), int(dut.xgmii_rxc.value)))
            self.lock_hist.append(int(dut.rx_block_lock.value))
            self.hiber_hist.append(int(dut.rx_hi_ber.value))

    async def feed(self):
        dut = self.dut
        k = 0
        while True:
            await FallingEdge(dut.rx_clk)
            w0 = (k * 64 + self.offset) // 64
            sh = self.offset % 64
            if w0 + 1 < len(self.tx_words):
                v = (self.tx_words[w0] >> sh) | ((self.tx_words[w0 + 1] << (64 - sh)) if sh else 0)
                v &= M64
                base = k * 64 + self.offset
                for b in [f for f in self.flips if base <= f < base + 64]:
                    v ^= 1 << (b - base)
                dut.gt_rxdata.value = v
                k += 1
            else:
                dut.gt_rxdata.value = 0


def tx_bits(words):
    v = 0
    for i, w in enumerate(words):
        v |= w << (64 * i)
    return v, 64 * len(words)


def find_align(bits, n, start=0, blocks=200):
    for a in range(start, start + 66):
        if all(((bits >> (a + 66 * j)) & 3) in (1, 2) for j in range(blocks)):
            return a
    return None


def model_rx(bits, n, align):
    """Model receiver: descramble and decode the TX stream from align."""
    dsc = Scrambler(descramble=True)
    out = []
    pos = align
    while pos + 66 <= n:
        h = (bits >> pos) & 3
        p = dsc.block((bits >> (pos + 2)) & M64)
        out.append((h, p))
        pos += 66
    return out


def match_stream(got, vecs, log, what):
    """got must contain vecs from the first non-idle transfer, in order. The
    anchor is the transfer after it (random frame data, so unique)."""
    idle = xgmii([0x07] * 8, [1] * 8)
    j0 = next(j for j, v in enumerate(vecs) if v != idle)
    try:
        i0 = got.index(vecs[j0 + 1]) - 1
    except ValueError:
        log.error(f"{what}: first frame never seen")
        return False
    n = min(len(got) - i0, len(vecs) - j0)
    bad = [m for m in range(n) if got[i0 + m] != vecs[j0 + m]]
    for m in bad[:5]:
        g, e = got[i0 + m], vecs[j0 + m]
        log.error(f"{what} transfer {m}: got {g[0]:016X}/{g[1]:02X} expected {e[0]:016X}/{e[1]:02X}")
    log.info(f"{what}: {n} transfers compared, {len(bad)} mismatches")
    return i0 >= 0 and not bad and n >= len(vecs) - j0 - 2


async def pcs_reset(dut):
    dut.tx_rst_n.value = 0
    dut.rx_rst_n.value = 0
    dut.xgmii_txd.value = 0x0707070707070707
    dut.xgmii_txc.value = 0xFF
    dut.gt_rxdata.value = 0
    for _ in range(4):
        await RisingEdge(dut.tx_clk)
    dut.tx_rst_n.value = 1
    dut.rx_rst_n.value = 1


async def run_loop(dut, offset, n_frames, seed, extra=0):
    rng = random.Random(seed)
    # idles first: block lock takes up to ~66 slips of a few blocks each
    vecs = [xgmii([0x07] * 8, [1] * 8)] * LEAD_IDLES + frame_stream(rng, n_frames)
    lp = Loop(dut, vecs, offset)
    await pcs_reset(dut)
    tasks = [cocotb.start_soon(lp.source()), cocotb.start_soon(lp.capture()),
             cocotb.start_soon(lp.feed())]
    # lock (at most ~66 slips) then the whole stream, then the pipeline tail
    for _ in range(200 + len(vecs) * 34 // 32 + extra):
        await RisingEdge(dut.tx_clk)
    return lp, tasks


def stop(tasks):
    for t in tasks:
        t.cancel()


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def loopback_offsets(dut):
    if dut._name != "pcs10gbr":
        return
    cocotb.start_soon(Clock(dut.tx_clk, 6.2, unit="ns").start())
    cocotb.start_soon(Clock(dut.rx_clk, 6.2, unit="ns").start())
    ok = True
    for offset in (0, 1, 2, 31, 64, 65, 97):
        lp, tasks = await run_loop(dut, offset, 40, 0x100 + offset)
        stop(tasks)
        # TX stream through the model receiver
        bits, n = tx_bits(lp.tx_words[4:])
        a = find_align(bits, n)
        if a is None:
            dut._log.error(f"offset {offset}: no sync header alignment in TX stream")
            ok = False
            continue
        dec = []
        fsm = RxFsm()
        for h, p in model_rx(bits, n, a)[2:]:
            r = fsm.feed(decode(h, p))
            if r is not None:
                dec.append(r)
        ok &= match_stream(dec, lp.vecs, dut._log, f"offset {offset} TX->model")
        # DUT receiver
        if not lp.lock_hist[-1]:
            dut._log.error(f"offset {offset}: no block lock")
            ok = False
        ok &= match_stream(lp.rx_out, lp.vecs, dut._log, f"offset {offset} TX->RX")
    assert ok


@cocotb.test(timeout_time=40, timeout_unit="ms")
async def header_errors(dut):
    """Bad sync headers: 16 in one 64-block window drop lock, which comes back;
    16 spread over one BER window raise hi_ber with lock held,
    and hi_ber clears after a clean window."""
    if dut._name != "pcs10gbr":
        return
    cocotb.start_soon(Clock(dut.tx_clk, 6.2, unit="ns").start())
    cocotb.start_soon(Clock(dut.rx_clk, 6.2, unit="ns").start())
    offset = 17
    lp, tasks = await run_loop(dut, offset, 10, 0x55)
    assert lp.lock_hist[-1], "no initial lock"
    bits, n = tx_bits(lp.tx_words)
    a = find_align(bits, n)
    assert a is not None
    # next block boundary well ahead of the feeder
    fed = len(lp.tx_words) * 64
    base = a + 66 * ((fed + 66 * 20 - a) // 66)

    # (1) 32 bad headers in a row: at least 16 land in one 64-block window
    lp.flips |= {base + 66 * j for j in range(32)}
    mark = len(lp.lock_hist)
    for _ in range(600):
        await RisingEdge(dut.tx_clk)
    lost = 0 in lp.lock_hist[mark:]
    back = lp.lock_hist[-1] == 1
    dut._log.info(f"burst: lock lost={lost}, regained={back}")

    # (2) one bad header every 40 blocks, 34 times: at least 17 land in one
    # 4000-cycle BER window, never more than 2 in a 64-block lock window
    fed = len(lp.tx_words) * 64
    base = a + 66 * ((fed + 66 * 20 - a) // 66)
    lp.flips |= {base + 66 * 40 * j for j in range(34)}
    mark = len(lp.hiber_hist)
    for _ in range(40 * 34 * 34 // 32 + 200):
        await RisingEdge(dut.tx_clk)
    hi = 1 in lp.hiber_hist[mark:]
    held = all(lp.lock_hist[mark:])
    lf = (LF_D, LF_C) in lp.rx_out
    for _ in range(9000):
        await RisingEdge(dut.tx_clk)
    cleared = lp.hiber_hist[-1] == 0
    stop(tasks)
    dut._log.info(f"spread: hi_ber={hi}, lock held={held}, local fault out={lf}, "
                  f"cleared={cleared}, ber_cnt={int(dut.rx_ber_cnt.value)}")
    assert lost and back and hi and held and lf and cleared
