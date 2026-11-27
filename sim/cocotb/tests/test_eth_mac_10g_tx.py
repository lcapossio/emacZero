# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""10 Gb/s transmit MAC (rtl/eth_mac_10g_tx.v) and its CRC (rtl/crc32_d64.v).

  crc32_d64        the 8-byte CRC step against zlib for every byte count,
                   chained over random messages
  eth_mac_10g_tx   the MAC's XGMII output, parsed independently of the RTL:
                   start in lane 0 or 4, preamble and SFD, payload padded to
                   60 bytes, FCS (zlib), terminate, idles between frames.
                   Back-to-back frames must start exactly where the clause 46
                   deficit idle count puts them (line rate for every length),
                   with ce gaps like the PCS's and random ones. A missing beat
                   mid-frame and tuser both corrupt the frame with error
                   characters and the frames after it are unharmed.
  eth_mac_10g_tx_loop  the MAC through pcs10gbr and a line loopback at a bit
                   offset: the received XGMII stream holds every frame,
                   right, with the deficit idle count gaps intact.
  eth_mac_10g_loop the whole datapath short of the transceiver: AXIS ->
                   TX MAC -> PCS -> line -> PCS -> RX MAC (rtl/eth_mac_10g_rx.v)
                   -> AXIS, at line rate: every frame back, padded, clean.
"""
import random
import zlib

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, Timer


SUITES = {
    "crc32_d64": {
        "toplevel": "crc32_d64",
        "sources": ["rtl/crc32_d64.v"],
        "skip_vhdl": "10G MAC is Verilog only so far",
    },
    "eth_mac_10g_tx": {
        "toplevel": "eth_mac_10g_tx",
        "sources": ["rtl/crc32_d64.v", "rtl/eth_mac_10g_tx.v"],
        "skip_vhdl": "10G MAC is Verilog only so far",
    },
    "eth_mac_10g_tx_loop": {
        "toplevel": "h_eth_mac_10g_tx_loop",
        "sources": ["rtl/crc32_d64.v", "rtl/eth_mac_10g_tx.v",
                    "rtl/pcs10gbr_enc.v", "rtl/pcs10gbr_dec.v",
                    "rtl/pcs10gbr_scrambler.v", "rtl/pcs10gbr_gearbox_tx.v",
                    "rtl/pcs10gbr_gearbox_rx.v", "rtl/pcs10gbr_block_lock.v",
                    "rtl/pcs10gbr_ber_mon.v", "rtl/pcs10gbr.v",
                    "sim/cocotb/hdl/h_eth_mac_10g_tx_loop.v"],
        "skip_vhdl": "10G MAC is Verilog only so far",
    },
    "eth_mac_10g_loop": {
        "toplevel": "h_eth_mac_10g_loop",
        "sources": ["rtl/crc32_d64.v", "rtl/eth_mac_10g_tx.v",
                    "rtl/eth_mac_10g_rx.v",
                    "rtl/pcs10gbr_enc.v", "rtl/pcs10gbr_dec.v",
                    "rtl/pcs10gbr_scrambler.v", "rtl/pcs10gbr_gearbox_tx.v",
                    "rtl/pcs10gbr_gearbox_rx.v", "rtl/pcs10gbr_block_lock.v",
                    "rtl/pcs10gbr_ber_mon.v", "rtl/pcs10gbr.v",
                    "sim/cocotb/hdl/h_eth_mac_10g_loop.v"],
        "skip_vhdl": "10G MAC is Verilog only so far",
    },
}


# ---------------------------------------------------------------------------
# crc32_d64
# ---------------------------------------------------------------------------
def crc_reg(data: bytes, reg: int = 0xFFFFFFFF) -> int:
    """The raw CRC register after data (zlib keeps it complemented)."""
    return zlib.crc32(data, reg ^ 0xFFFFFFFF) ^ 0xFFFFFFFF


@cocotb.test()
async def crc_every_length(dut):
    """Each byte count 0..8 (and 9..15, treated as 8) against zlib."""
    if dut._name != "crc32_d64":
        return
    rng = random.Random(1)
    for _ in range(400):
        reg = rng.getrandbits(32)
        data = rng.randbytes(8)
        for n in range(16):
            dut.crc_in.value = reg
            dut.data.value = int.from_bytes(data, "little")
            dut.nbytes.value = n
            await Timer(1, "ns")
            exp = crc_reg(data[:min(n, 8)], reg)
            got = int(dut.crc_out.value)
            assert got == exp, f"n={n} reg={reg:08x} got {got:08x} exp {exp:08x}"


@cocotb.test()
async def crc_chained(dut):
    """Random messages fed 8 bytes at a time give zlib's FCS."""
    if dut._name != "crc32_d64":
        return
    rng = random.Random(2)
    for _ in range(200):
        msg = rng.randbytes(rng.randint(1, 100))
        reg = 0xFFFFFFFF
        for i in range(0, len(msg), 8):
            chunk = msg[i:i + 8]
            dut.crc_in.value = reg
            dut.data.value = int.from_bytes(chunk.ljust(8, b"\0"), "little")
            dut.nbytes.value = len(chunk)
            await Timer(1, "ns")
            reg = int(dut.crc_out.value)
        assert reg ^ 0xFFFFFFFF == zlib.crc32(msg)


# ---------------------------------------------------------------------------
# eth_mac_10g_tx bench
# ---------------------------------------------------------------------------
IDLE, START, TERM, ERR = 0x07, 0xFB, 0xFD, 0xFE


def pcs_ce(cycle):
    """The PCS's xgmii_tx_ready: 32 of every 33 cycles."""
    return (cycle % 33) != 32


class Bench:
    """One coroutine drives ce and AXIS on the falling edge and samples the
    XGMII output in the read-only phase after it, so every handshake and
    every output word is seen exactly once."""

    def __init__(self, dut, ce_fn=lambda c: 1, seed=0):
        self.dut = dut
        self.ce_fn = ce_fn
        self.rng = random.Random(seed)
        self.words = []          # (data, ctl) per ce, in order
        self.underruns = 0
        self.tx_frames = 0
        # the loop harness: ce comes from the PCS, words from the PCS RX
        self.loop = dut._name == "h_eth_mac_10g_tx_loop"
        # the whole datapath: frames come back out of the RX MAC
        self.e2e = dut._name == "h_eth_mac_10g_loop"
        self.loop = self.loop or self.e2e
        self.rx_frames = []      # (payload, tuser) from the RX MAC
        self.rx_cur = bytearray()
        self.rx_fcs_errs = 0

    async def start(self):
        dut = self.dut
        cocotb.start_soon(Clock(dut.clk, 6.4, "ns").start())
        dut.rst_n.value = 0
        if not self.loop:
            dut.ce.value = 0
        if self.e2e:
            dut.jumbo_en.value = 1
        dut.s_axis_tvalid.value = 0
        dut.s_axis_tdata.value = 0
        dut.s_axis_tkeep.value = 0
        dut.s_axis_tlast.value = 0
        dut.s_axis_tuser.value = 0
        await ClockCycles(dut.clk, 5)
        dut.rst_n.value = 1
        if self.loop:
            for _ in range(3000):
                await ClockCycles(dut.clk, 1)
                if int(dut.block_lock.value):
                    break
            assert int(dut.block_lock.value), "no block lock"
            await ClockCycles(dut.clk, 50)

    async def run(self, frames, stall=None, err_beat=None, tail_cycles=200):
        """Send frames (list of bytes). stall(f, beat) -> cycles to withhold
        tvalid before that beat; err_beat = set of (f, beat) sent with tuser."""
        dut = self.dut
        beats = []
        for f, fr in enumerate(frames):
            nb = (len(fr) + 7) // 8
            for b in range(nb):
                chunk = fr[8 * b:8 * b + 8]
                beats.append((f, b, chunk, b == nb - 1))
        i = 0
        hold = 0
        cycle = 0
        ce_prev = 0
        idle_after = 0
        presented = False
        while idle_after < tail_cycles:
            await FallingEdge(dut.clk)
            ce = 1 if self.ce_fn(cycle) else 0
            cycle += 1
            if not self.loop:
                dut.ce.value = ce
            if i < len(beats):
                f, b, chunk, last = beats[i]
                if not presented and stall is not None and hold == 0:
                    hold = stall(f, b)
                    presented = True
                if hold > 0:
                    hold -= 1
                    dut.s_axis_tvalid.value = 0
                else:
                    dut.s_axis_tvalid.value = 1
                    dut.s_axis_tdata.value = int.from_bytes(chunk.ljust(8, b"\0"), "little")
                    dut.s_axis_tkeep.value = (1 << len(chunk)) - 1 if last else 0xFF
                    dut.s_axis_tlast.value = 1 if last else 0
                    dut.s_axis_tuser.value = 1 if err_beat and (f, b) in err_beat else 0
            else:
                dut.s_axis_tvalid.value = 0
                idle_after += 1
            await ReadOnly()
            if self.e2e:
                self._rx_sample()
            elif self.loop:
                if int(dut.xgmii_rx_valid.value):
                    self.words.append((int(dut.xgmii_rxd.value), int(dut.xgmii_rxc.value)))
            elif ce_prev:
                self.words.append((int(dut.xgmii_txd.value), int(dut.xgmii_txc.value)))
            self.underruns += int(dut.stat_underrun.value)
            self.tx_frames += int(dut.stat_tx_frame.value)
            if (i < len(beats) and int(dut.s_axis_tvalid.value)
                    and int(dut.s_axis_tready.value)):
                i += 1
                presented = False
            ce_prev = ce


    def _rx_sample(self):
        dut = self.dut
        if int(dut.m_axis_tvalid.value):
            n = bin(int(dut.m_axis_tkeep.value)).count("1")
            self.rx_cur += int(dut.m_axis_tdata.value).to_bytes(8, "little")[:n]
            if int(dut.m_axis_tlast.value):
                self.rx_frames.append((bytes(self.rx_cur), int(dut.m_axis_tuser.value)))
                self.rx_cur = bytearray()
        if int(dut.stat_done.value):
            self.rx_fcs_errs += int(dut.stat_err_fcs.value)


def parse(words):
    """Split the XGMII byte stream into frames. Returns a list of dicts:
    start (absolute byte index of S), term (index of T), body (bytes from
    after the SFD to before T), pre_ok, err (an error character inside)."""
    lanes = []
    for d, c in words:
        for k in range(8):
            lanes.append(((d >> (8 * k)) & 0xFF, (c >> k) & 1))
    frames = []
    i = 0
    n = len(lanes)
    while i < n:
        b, c = lanes[i]
        if c and b == START:
            j = i + 1
            body = bytearray()
            err = False
            while j < n and not (lanes[j][1] and lanes[j][0] == TERM):
                bj, cj = lanes[j]
                if cj:
                    assert bj == ERR, f"control {bj:02x} inside a frame at {j}"
                    err = True
                body.append(bj)
                j += 1
            assert j < n, "frame without terminate"
            pre = bytes(body[:7])
            frames.append({"start": i, "term": j, "pre_ok": pre == b"\x55" * 6 + b"\xd5",
                           "body": bytes(body[7:]), "err": err})
            i = j + 1
        else:
            if c:
                assert b == IDLE, f"control {b:02x} outside a frame at {i}"
            else:
                assert False, f"data byte {b:02x} outside a frame at {i}"
            i += 1
    return frames


def wire(payload: bytes) -> bytes:
    p = payload.ljust(60, b"\0")
    return p + zlib.crc32(p).to_bytes(4, "little")


def wire_stomped(payload: bytes) -> bytes:
    """A tuser frame: the payload as sent, the CRC not complemented."""
    p = payload.ljust(60, b"\0")
    return p + (zlib.crc32(p) ^ 0xFFFFFFFF).to_bytes(4, "little")


def check_frames(got, frames, errs=(), stomped=()):
    """errs: frames that must carry error characters (underrun);
    stomped: tuser frames, which must carry the payload and a wrong FCS."""
    assert len(got) == len(frames), f"{len(got)} frames on the line, sent {len(frames)}"
    for k, (g, fr) in enumerate(zip(got, frames)):
        assert g["start"] % 4 == 0, f"frame {k} starts in lane {g['start'] % 8}"
        assert g["pre_ok"], f"frame {k} preamble"
        if k in errs:
            assert g["err"], f"frame {k} should carry error characters"
            continue
        assert not g["err"], f"frame {k} has error characters"
        exp = wire_stomped(fr) if k in stomped else wire(fr)
        assert g["body"] == exp, (f"frame {k} len {len(fr)}: got {g['body'].hex()} "
                                  f"exp {exp.hex()}")


def check_dic(got):
    """Back to back: each frame starts at the first 4-byte column where the
    gap (T and the idles after it) is at least 9 + the deficit; the deficit
    becomes max(0, deficit + 12 - gap)."""
    d = 0
    gaps = []
    for k in range(1, len(got)):
        t = got[k - 1]["term"]
        exp = t + 9 + d
        exp = (exp + 3) // 4 * 4
        g = got[k]["start"] - t
        assert got[k]["start"] == exp, (f"frame {k} starts at {got[k]['start']}, "
                                        f"DIC says {exp} (gap {g}, deficit {d})")
        d = max(0, d + 12 - g)
        assert 0 <= d <= 3
        gaps.append(g)
    return gaps


def ok_len_frames(rng, n, lo=1, hi=200):
    return [rng.randbytes(rng.randint(lo, hi)) for _ in range(n)]


# ---------------------------------------------------------------------------
# eth_mac_10g_tx tests
# ---------------------------------------------------------------------------
@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tx_every_length(dut):
    """Payload lengths 1..140 and a few long ones, every lane alignment,
    back to back: the frames are right and the gaps follow the DIC."""
    if dut._name != "eth_mac_10g_tx":
        return
    rng = random.Random(10)
    frames = [rng.randbytes(n) for n in list(range(1, 141)) + [500, 1500, 1514, 9000]]
    tb = Bench(dut)
    await tb.start()
    await tb.run(frames)
    got = parse(tb.words)
    check_frames(got, frames)
    check_dic(got)
    assert tb.underruns == 0
    assert tb.tx_frames == len(frames)
    assert any(g["start"] % 8 == 4 for g in got) and any(g["start"] % 8 == 0 for g in got)


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tx_line_rate_min(dut):
    """64-byte frames (60 + FCS) back to back average a 12-byte gap: 84
    bytes per frame on the line, 14.88 Mpps at 10 Gb/s."""
    if dut._name != "eth_mac_10g_tx":
        return
    rng = random.Random(11)
    frames = [rng.randbytes(60) for _ in range(400)]
    tb = Bench(dut)
    await tb.start()
    await tb.run(frames)
    got = parse(tb.words)
    check_frames(got, frames)
    gaps = check_dic(got)
    span = got[-1]["start"] - got[0]["start"]
    per = span / (len(got) - 1)
    assert abs(per - 84) < 0.1, f"{per:.2f} line bytes per 64-byte frame (want 84)"
    avg = sum(gaps) / len(gaps)
    assert abs(avg - 12) < 0.1, f"average gap {avg:.2f} bytes (want 12)"


@cocotb.test(timeout_time=10, timeout_unit="ms")
async def tx_pcs_ce(dut):
    """With the PCS's ce pattern (one cycle in 33 without a word) the line
    sees the same stream: random lengths, back to back, DIC exact."""
    if dut._name != "eth_mac_10g_tx":
        return
    rng = random.Random(12)
    frames = ok_len_frames(rng, 600, 1, 300)
    tb = Bench(dut, ce_fn=pcs_ce)
    await tb.start()
    await tb.run(frames)
    got = parse(tb.words)
    check_frames(got, frames)
    check_dic(got)
    assert tb.underruns == 0


@cocotb.test(timeout_time=10, timeout_unit="ms")
async def tx_random_ce(dut):
    """ce random (about half the cycles): nothing depends on ce timing."""
    if dut._name != "eth_mac_10g_tx":
        return
    rng = random.Random(13)
    frames = ok_len_frames(rng, 300, 1, 200)
    cer = random.Random(14)
    tb = Bench(dut, ce_fn=lambda c: cer.random() < 0.5)
    await tb.start()
    await tb.run(frames)
    got = parse(tb.words)
    check_frames(got, frames)
    check_dic(got)
    assert tb.underruns == 0


@cocotb.test(timeout_time=10, timeout_unit="ms")
async def tx_gaps_between_frames(dut):
    """The source pauses between frames: frames stay right, gaps are at
    least the DIC minimum, idles fill the rest."""
    if dut._name != "eth_mac_10g_tx":
        return
    rng = random.Random(15)
    frames = ok_len_frames(rng, 200, 1, 150)
    tb = Bench(dut, ce_fn=pcs_ce)
    await tb.start()
    await tb.run(frames, stall=lambda f, b: rng.randint(0, 12) if b == 0 else 0)
    got = parse(tb.words)
    check_frames(got, frames)
    for k in range(1, len(got)):
        assert got[k]["start"] - got[k - 1]["term"] >= 9
    assert tb.underruns == 0


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tx_underrun(dut):
    """A beat that is late mid-frame: that frame carries error characters,
    stat_underrun pulses, the frames around it are good."""
    if dut._name != "eth_mac_10g_tx":
        return
    rng = random.Random(16)
    frames = [rng.randbytes(n) for n in (100, 100, 200, 64, 100)]
    tb = Bench(dut)
    await tb.start()
    await tb.run(frames, stall=lambda f, b: 3 if (f, b) == (2, 5) else 0)
    got = parse(tb.words)
    check_frames(got, frames, errs={2})
    assert tb.underruns >= 1


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def tx_tuser(dut):
    """tuser on a beat (first, middle, last, last of a short frame) sends
    that frame with its payload and a wrong FCS (no error characters, which
    the PCS could not encode before a terminate); the others are clean."""
    if dut._name != "eth_mac_10g_tx":
        return
    rng = random.Random(17)
    frames = [rng.randbytes(n) for n in (80, 80, 80, 80, 30, 80, 13, 80)]
    errs = {(1, 0), (3, 4), (5, 9), (6, 1)}
    tb = Bench(dut, ce_fn=pcs_ce)
    await tb.start()
    await tb.run(frames, err_beat=errs)
    got = parse(tb.words)
    check_frames(got, frames, stomped={1, 3, 5, 6})
    assert tb.underruns == 0


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def loop_through_pcs(dut):
    """Random lengths back to back, through the PCS and the line: every
    frame arrives right and the gaps keep the DIC spacing."""
    if dut._name != "h_eth_mac_10g_tx_loop":
        return
    rng = random.Random(20)
    frames = [rng.randbytes(n) for n in list(range(1, 80)) + [1514, 9000]]
    frames += ok_len_frames(rng, 400, 1, 300)
    tb = Bench(dut)
    await tb.start()
    await tb.run(frames, tail_cycles=400)
    got = parse(tb.words)
    check_frames(got, frames)
    check_dic(got)
    assert tb.underruns == 0
    assert not int(dut.hi_ber.value)


@cocotb.test(timeout_time=30, timeout_unit="ms")
async def e2e_line_rate(dut):
    """Minimum frames back to back, then random lengths up to jumbo, with a
    few tuser frames: every frame comes back out of the RX MAC in order,
    padded to 60 bytes, clean (or flagged, for the tuser ones)."""
    if dut._name != "h_eth_mac_10g_loop":
        return
    rng = random.Random(30)
    frames = [rng.randbytes(60) for _ in range(300)]
    frames += [rng.randbytes(n) for n in range(1, 70)]
    frames += ok_len_frames(rng, 300, 1, 1500) + [rng.randbytes(9000)]
    bad = {400, 555, 640}
    err_beat = {(f, 2) for f in bad}
    # tuser on the last beat of a short frame, followed by a minimum frame,
    # for every end lane: the terminate must survive the PCS
    for n in range(57, 75):
        f = len(frames)
        frames += [rng.randbytes(n), rng.randbytes(60)]
        bad.add(f)
        err_beat.add((f, (n - 1) // 8))
    tb = Bench(dut)
    await tb.start()
    await tb.run(frames, err_beat=err_beat, tail_cycles=600)
    assert len(tb.rx_frames) == len(frames), f"{len(tb.rx_frames)} back of {len(frames)}"
    for k, ((got, tuser), fr) in enumerate(zip(tb.rx_frames, frames)):
        if k in bad:
            assert tuser, f"frame {k} should be flagged"
            continue
        assert not tuser, f"frame {k} len {len(fr)} flagged"
        assert got == fr.ljust(60, b"\0"), f"frame {k} len {len(fr)} differs"
    assert tb.underruns == 0
    assert tb.rx_fcs_errs == len(bad)
    assert not int(dut.hi_ber.value)
