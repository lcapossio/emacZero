# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""The ZCU106 10G test traffic (fpga/zcu106/rtl/axis_test_gen64.v and
axis_test_chk64.v), each on its own, in both frame formats: the test frames
and the IPv4 / UDP datagrams.

  axis_test64  the generator's frames against a reference built here
               (the IPv4 header checksum by RFC 1071 over the header bytes,
               not the RTL's constant-sum shortcut), under random
               backpressure, for minimum, standard, jumbo and swept lengths;
               the checker takes reference frames with random gaps as good
               and in sequence, and counts as bad every frame with one bit
               flipped in any header byte or a payload byte, an IPv4
               identification other than seq (checksum still right), one
               byte short or long, or tuser set; a missing seq is one seq
               gap. The checksum test mode: the generator's junk IPv4 and
               UDP checksums, and the checker's UDP checksum check (correct
               checksums good; 0, off by one bit, or a stale one bad).
"""
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly


SUITES = {
    "axis_test64": {
        "toplevel": "h_axis_test64",
        "sources": ["fpga/zcu106/rtl/axis_test_gen64.v",
                    "fpga/zcu106/rtl/axis_test_chk64.v",
                    "sim/cocotb/hdl/h_axis_test64.v"],
        "skip_vhdl": "ZCU106 10G test logic is Verilog only",
    },
}

M64 = (1 << 64) - 1
M32 = (1 << 32) - 1
DST = bytes.fromhex("020000000001")
SRC = bytes.fromhex("020000000002")


def xs(s):
    t = s ^ ((s << 13) & M64)
    t ^= t >> 7
    return t ^ ((t << 17) & M64)


def csum16(data):
    """RFC 1071 one's complement sum, folded, not inverted."""
    s = 0
    for i in range(0, len(data), 2):
        s += (data[i] << 8) | data[i + 1]
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return s


def ref_frame(length, seq, udp):
    """axis_test_gen64's frame of `length` bytes (no FCS) with this seq."""
    nseq = ~seq & M32
    if not udp:
        hdr = DST + SRC + b"\x88\xb5" + length.to_bytes(2, "big")
        hdr += seq.to_bytes(4, "little") + nseq.to_bytes(4, "little")
    else:
        ip = bytearray(b"\x45\x00" + (length - 14).to_bytes(2, "big")
                       + (seq & 0xFFFF).to_bytes(2, "big") + b"\x40\x00\x40\x11"
                       + b"\x00\x00" + bytes([10, 0, 0, 2]) + bytes([10, 0, 0, 1]))
        ip[10:12] = (~csum16(ip) & 0xFFFF).to_bytes(2, "big")
        udph = ((5001).to_bytes(2, "big") * 2 + (length - 34).to_bytes(2, "big")
                + b"\x00\x00")
        hdr = (DST + SRC + b"\x08\x00" + bytes(ip) + udph
               + seq.to_bytes(4, "little") + (nseq >> 16).to_bytes(2, "little"))
    out = bytearray(hdr)
    p = (seq << 32) | nseq
    while len(out) < length:
        p = xs(p)
        out += p.to_bytes(8, "little")
    return bytes(out[:length])


def junk_frame(length, seq):
    """The UDP frame as sent with csum_junk: IPv4 checksum XOR 0x5555, UDP
    0xBEEF."""
    fr = bytearray(ref_frame(length, seq, 1))
    fr[24] ^= 0x55
    fr[25] ^= 0x55
    fr[40:42] = b"\xbe\xef"
    return bytes(fr)


def udp_fixed(fr):
    """fr with both checksums set as a checksum inserter would."""
    fr = bytearray(fr)
    fr[24:26] = b"\x00\x00"
    fr[24:26] = (~csum16(fr[14:34]) & 0xFFFF).to_bytes(2, "big")
    fr[40:42] = b"\x00\x00"
    dg = bytes(fr[34:])
    ph = fr[26:34] + b"\x00\x11" + len(dg).to_bytes(2, "big")
    c = ~csum16(ph + dg + (b"\x00" if len(dg) & 1 else b"")) & 0xFFFF
    fr[40:42] = (c or 0xFFFF).to_bytes(2, "big")
    return bytes(fr)


def parse_udp(fr):
    """Independent read of a UDP frame; returns the problems found."""
    bad = []
    if fr[12:14] != b"\x08\x00":
        bad.append("ethertype")
    ip = fr[14:34]
    if ip[0] != 0x45 or ip[9] != 17:
        bad.append("version/IHL/protocol")
    if csum16(ip) != 0xFFFF:
        bad.append("IPv4 checksum")
    if int.from_bytes(ip[2:4], "big") != len(fr) - 14:
        bad.append("total length")
    if int.from_bytes(fr[38:40], "big") != len(fr) - 34:
        bad.append("UDP length")
    if fr[30:34] != bytes([10, 0, 0, 1]) or fr[36:38] != (5001).to_bytes(2, "big"):
        bad.append("destination")
    return bad


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 5, "ns").start())
    dut.rst_n.value = 0
    for n in ("g_enable", "g_sweep", "g_udp", "g_csum_junk", "g_ipg", "g_inj_err",
              "g_tready", "c_clear", "c_udp", "c_csum", "c_tdata", "c_tkeep",
              "c_tvalid", "c_tlast", "c_tuser"):
        getattr(dut, n).value = 0
    dut.g_len.value = 60
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


async def gen_collect(dut, count, ready_p, rng):
    """Run the generator until `count` frames are out; returns them."""
    frames, cur = [], bytearray()
    dut.g_enable.value = 1
    while len(frames) < count:
        await FallingEdge(dut.clk)
        dut.g_tready.value = 1 if rng.random() < ready_p else 0
        await ReadOnly()
        if int(dut.g_tvalid.value) and int(dut.g_tready.value):
            keep = int(dut.g_tkeep.value)
            data = int(dut.g_tdata.value).to_bytes(8, "little")
            cur += bytes(data[i] for i in range(8) if keep >> i & 1)
            if int(dut.g_tlast.value):
                frames.append(bytes(cur))
                cur = bytearray()
    # the last beat goes at the next rising edge and a new frame could start
    # at the one after: dropping enable before that starts none
    await FallingEdge(dut.clk)
    dut.g_enable.value = 0
    await ClockCycles(dut.clk, 20)
    await FallingEdge(dut.clk)
    assert not int(dut.g_tvalid.value), "generator started a frame after enable fell"
    dut.g_tready.value = 0
    return frames


async def chk_send(dut, frames, rng, gap_p=0.0, tuser=()):
    """Write frames into the checker, with random idle cycles."""
    for f, fr in enumerate(frames):
        nb = (len(fr) + 7) // 8
        for b in range(nb):
            while rng.random() < gap_p:
                await FallingEdge(dut.clk)
                dut.c_tvalid.value = 0
            await FallingEdge(dut.clk)
            chunk = fr[8 * b:8 * b + 8]
            last = b == nb - 1
            dut.c_tvalid.value = 1
            dut.c_tdata.value = int.from_bytes(chunk.ljust(8, b"\0"), "little")
            dut.c_tkeep.value = (1 << len(chunk)) - 1 if last else 0xFF
            dut.c_tlast.value = 1 if last else 0
            dut.c_tuser.value = 1 if (last and f in tuser) else 0
    await FallingEdge(dut.clk)
    dut.c_tvalid.value = 0
    dut.c_tlast.value = 0
    dut.c_tuser.value = 0
    await ClockCycles(dut.clk, 3)


def counts(dut):
    return (int(dut.c_good.value), int(dut.c_bad.value),
            int(dut.c_tuser_frames.value), int(dut.c_seq_gaps.value))


async def clear(dut):
    await FallingEdge(dut.clk)
    dut.c_clear.value = 1
    await FallingEdge(dut.clk)
    dut.c_clear.value = 0
    await ClockCycles(dut.clk, 2)


@cocotb.test()
async def gen_frames(dut):
    """Generator output equals the reference, both formats, any backpressure."""
    if dut._name != "h_axis_test64":
        return
    rng = random.Random(7)
    await setup(dut)
    seq = 0
    for udp in (0, 1):
        dut.g_udp.value = udp
        for length, sweep, n, ready_p in ((60, 0, 40, 1.0), (61, 0, 20, 0.6),
                                          (1514, 0, 6, 0.8), (9014, 0, 2, 0.9),
                                          (140, 1, 120, 0.9)):
            dut.g_len.value = length
            dut.g_sweep.value = sweep
            frames = await gen_collect(dut, n, ready_p, rng)
            for fr in frames:
                if sweep:
                    assert 60 <= len(fr) <= length, len(fr)
                else:
                    assert len(fr) == length, (len(fr), length)
                assert fr == ref_frame(len(fr), seq, udp), \
                    f"udp {udp} len {len(fr)} seq {seq}: differs from the reference"
                if udp:
                    assert not parse_udp(fr), parse_udp(fr)
                seq += 1
            assert int(dut.g_frames.value) == seq
    dut._log.info("generator: %d frames match", seq)


@cocotb.test()
async def chk_good(dut):
    """Reference frames, both formats, with random gaps: all good, no gap."""
    if dut._name != "h_axis_test64":
        return
    rng = random.Random(11)
    await setup(dut)
    for udp in (0, 1):
        dut.c_udp.value = udp
        await clear(dut)
        lens = [60, 61, 62, 63, 64, 65, 66, 67, 68, 1514, 9014] + \
               [rng.randint(60, 2000) for _ in range(40)]
        frames = [ref_frame(n, 1000 + i, udp) for i, n in enumerate(lens)]
        await chk_send(dut, frames, rng, gap_p=0.2)
        assert counts(dut) == (len(frames), 0, 0, 0), (udp, counts(dut))


@cocotb.test()
async def chk_bad(dut):
    """One flipped bit in each header byte, in the payload, a byte short or
    long, tuser: each such frame is bad and the good ones around it are not."""
    if dut._name != "h_axis_test64":
        return
    rng = random.Random(13)
    await setup(dut)
    for udp, hdr_len in ((0, 24), (1, 48)):
        dut.c_udp.value = udp
        await clear(dut)
        seq = 0
        sent_bad = 0
        cases = [("hdr", i) for i in range(hdr_len)]
        cases += [("payload", None), ("short", None), ("long", None), ("tuser", None)]
        if udp:
            cases.append(("id", None))      # identification != seq, checksum right
        for kind, i in cases:
            length = rng.choice([60, 64, 77, 128, 1514])
            good = ref_frame(length, seq, udp)
            fr = bytearray(ref_frame(length, seq + 1, udp))
            tuser = ()
            if kind == "hdr":
                fr[i] ^= 1 << rng.randrange(8)
            elif kind == "payload":
                j = rng.randrange(hdr_len, length)
                fr[j] ^= 1 << rng.randrange(8)
            elif kind == "short":
                fr = fr[:-1]
            elif kind == "long":
                fr += b"\x5a"
            elif kind == "id":
                fr[18] ^= 0x01
                fr[24:26] = b"\x00\x00"
                fr[24:26] = (~csum16(fr[14:34]) & 0xFFFF).to_bytes(2, "big")
                assert csum16(fr[14:34]) == 0xFFFF
            else:
                tuser = (1,)
            g0, b0, t0, _ = counts(dut)
            await chk_send(dut, [good, bytes(fr)], rng, gap_p=0.1, tuser=tuser)
            g1, b1, t1, _ = counts(dut)
            assert (g1 - g0, b1 - b0) == (1, 1), \
                f"udp {udp} {kind} {i}: good +{g1 - g0} bad +{b1 - b0}"
            assert t1 - t0 == (1 if kind == "tuser" else 0)
            sent_bad += 1
            seq += 2
        dut._log.info("udp %d: %d broken frames all bad", udp, sent_bad)


@cocotb.test()
async def chk_seq_gap(dut):
    """A missing seq is one gap; a fresh clear forgets the last seq; a frame
    with a broken header or seq does not become the reference: the next
    good frame is one gap, not two."""
    if dut._name != "h_axis_test64":
        return
    rng = random.Random(17)
    await setup(dut)
    for udp in (0, 1):
        dut.c_udp.value = udp
        await clear(dut)
        frames = [ref_frame(100, s, udp) for s in (5, 6, 7, 9, 10)]
        await chk_send(dut, frames, rng)
        assert counts(dut) == (5, 0, 0, 1), (udp, counts(dut))
        await clear(dut)
        await chk_send(dut, [ref_frame(100, 70000, udp)], rng)
        assert counts(dut) == (1, 0, 0, 0), (udp, counts(dut))
        # broken header (destination MAC; UDP: destination port), seq intact
        await clear(dut)
        hdr = bytearray(ref_frame(100, 202, udp))
        hdr[37 if udp else 5] ^= 0x10
        await chk_send(dut, [ref_frame(100, 201, udp), bytes(hdr),
                             ref_frame(100, 203, udp)], rng)
        assert counts(dut) == (2, 1, 0, 1), (udp, "header", counts(dut))
        # every seq byte, one at a time
        for k in range(4):
            await clear(dut)
            sq = bytearray(ref_frame(100, 0x12345602, udp))
            sq[(42 if udp else 16) + k] ^= 0x04
            await chk_send(dut, [ref_frame(100, 0x12345601, udp), bytes(sq),
                                 ref_frame(100, 0x12345603, udp)], rng)
            assert counts(dut) == (2, 1, 0, 1), (udp, "seq byte", k, counts(dut))


@cocotb.test()
async def chk_mode_edge(dut):
    """The checker takes udp with a frame's first beat, not a cycle later."""
    if dut._name != "h_axis_test64":
        return
    rng = random.Random(29)
    await setup(dut)
    for udp in (0, 1):
        await clear(dut)
        fr = ref_frame(120, 0x40 + udp, udp)
        nb = (len(fr) + 7) // 8
        dut.c_udp.value = udp
        for b in range(nb):
            await FallingEdge(dut.clk)
            chunk = fr[8 * b:8 * b + 8]
            last = b == nb - 1
            dut.c_tvalid.value = 1
            dut.c_tdata.value = int.from_bytes(chunk.ljust(8, b"\0"), "little")
            dut.c_tkeep.value = (1 << len(chunk)) - 1 if last else 0xFF
            dut.c_tlast.value = 1 if last else 0
            if b == 1:
                dut.c_udp.value = 1 - udp      # flips after the first beat
        await FallingEdge(dut.clk)
        dut.c_tvalid.value = 0
        dut.c_tlast.value = 0
        await ClockCycles(dut.clk, 3)
        assert counts(dut)[:2] == (1, 0), (udp, counts(dut))
        # and the flipped mode holds for the next frame
        await chk_send(dut, [ref_frame(120, 0x41 + udp, 1 - udp)], rng)
        assert counts(dut)[:2] == (2, 0), (udp, counts(dut))


@cocotb.test()
async def gen_sweep(dut):
    """A sweep starts at 60 after fixed-length frames and never exceeds a lowered len."""
    if dut._name != "h_axis_test64":
        return
    rng = random.Random(23)
    await setup(dut)
    seq = 0

    async def run(length, sweep, n):
        nonlocal seq
        dut.g_len.value = length
        dut.g_sweep.value = sweep
        await ClockCycles(dut.clk, 2)
        frames = await gen_collect(dut, n, 1.0, rng)
        for fr in frames:
            assert fr == ref_frame(len(fr), seq, 0), f"len {len(fr)} seq {seq}"
            seq += 1
        return [len(fr) for fr in frames]

    assert await run(100, 0, 3) == [100] * 3
    assert await run(60, 1, 3) == [60] * 3
    assert await run(200, 1, 50) == list(range(60, 110))
    # the sweep stands at 110: a lower len restarts it at 60
    assert await run(80, 1, 25) == list(range(60, 81)) + list(range(60, 64))
    assert await run(300, 0, 2) == [300] * 2
    assert await run(64, 1, 7) == [60, 61, 62, 63, 64, 60, 61]


@cocotb.test()
async def gen_inject(dut):
    """inj_err flips bit 0 of exactly one payload word; the checker sees it."""
    if dut._name != "h_axis_test64":
        return
    rng = random.Random(19)
    await setup(dut)
    for udp in (0, 1):
        dut.g_udp.value = udp
        dut.g_len.value = 200
        await FallingEdge(dut.clk)
        dut.g_inj_err.value = 1
        await FallingEdge(dut.clk)
        dut.g_inj_err.value = 0
        frames = await gen_collect(dut, 3, 1.0, rng)
        seq0 = int.from_bytes(frames[0][42:46] if udp else frames[0][16:20], "little")
        diffs = []
        for k, fr in enumerate(frames):
            ref = ref_frame(len(fr), seq0 + k, udp)
            diffs += [(k, j, fr[j] ^ ref[j]) for j in range(len(fr)) if fr[j] != ref[j]]
        assert len(diffs) == 1 and diffs[0][2] == 1, diffs
        start = 48 if udp else 24
        assert diffs[0][0] == 0 and (diffs[0][1] - start) % 8 == 0, diffs
        dut.c_udp.value = udp
        await clear(dut)
        await chk_send(dut, frames, rng)
        g, b, _, _ = counts(dut)
        assert (g, b) == (2, 1), (udp, g, b)


@cocotb.test()
async def gen_csum_junk(dut):
    """csum_junk: the UDP frames carry the IPv4 checksum XOR 0x5555 and
    0xBEEF as checksums and are otherwise the reference; the test frames do
    not change. The length 61 / seq 0x2282480e frame, for which 0xDEAD and
    0xBEEF would both be correct, is wrong too."""
    if dut._name != "h_axis_test64":
        return
    rng = random.Random(31)
    await setup(dut)
    dut.g_csum_junk.value = 1
    seq = 0
    for udp, length, sweep, n in ((1, 60, 0, 10), (1, 1514, 0, 3), (1, 120, 1, 70),
                                  (0, 100, 0, 5)):
        dut.g_udp.value = udp
        dut.g_len.value = length
        dut.g_sweep.value = sweep
        for fr in await gen_collect(dut, n, 0.8, rng):
            want = junk_frame(len(fr), seq) if udp else ref_frame(len(fr), seq, 0)
            assert fr == want, f"udp {udp} len {len(fr)} seq {seq}"
            seq += 1
    for length, s in ((61, 0x2282480E), (60, 0), (1514, 0xFFFF)):
        fr = junk_frame(length, s)
        assert udp_fixed(fr)[24:26] != fr[24:26], (length, s)


@cocotb.test()
async def chk_csum(dut):
    """With csum the checker wants a correct UDP checksum: correct ones are
    good at every length; 0, one flipped bit, a stale checksum (another
    seq's) or the generator's junk are bad. It still checks the rest."""
    if dut._name != "h_axis_test64":
        return
    rng = random.Random(37)
    await setup(dut)
    dut.c_udp.value = 1
    dut.c_csum.value = 1
    await clear(dut)
    lens = list(range(60, 76)) + [1514, 9014] + [rng.randint(60, 2000) for _ in range(30)]
    good = [udp_fixed(ref_frame(n, 500 + i, 1)) for i, n in enumerate(lens)]
    await chk_send(dut, good, rng, gap_p=0.2)
    assert counts(dut) == (len(good), 0, 0, 0), counts(dut)

    seq = 600
    for kind in ("zero", "bit", "stale", "junk", "payload", "csum off"):
        for _ in range(4):
            length = rng.choice([60, 61, 77, 128, 1514])
            fr = bytearray(udp_fixed(ref_frame(length, seq + 1, 1)))
            if kind == "zero":
                fr[40:42] = b"\x00\x00"
            elif kind == "bit":
                fr[40 + rng.randrange(2)] ^= 1 << rng.randrange(8)
            elif kind == "stale":
                fr[40:42] = udp_fixed(ref_frame(length, seq + 7, 1))[40:42]
            elif kind == "junk":
                fr = bytearray(udp_fixed(junk_frame(length, seq + 1)))
                fr[40:42] = b"\xbe\xef"
            elif kind == "payload":
                # a payload bit and the checksum both changed to match: the
                # checksum passes, the payload check still fails it
                j = rng.randrange(48, length)
                fr[j] ^= 1 << rng.randrange(8)
                fr = bytearray(udp_fixed(bytes(fr)))
            g0, b0, _, _ = counts(dut)
            frames = [udp_fixed(ref_frame(length, seq, 1)), bytes(fr)]
            if kind == "csum off":
                # the field must be 0 again with csum off, so a filled one fails
                dut.c_csum.value = 0
                frames = [ref_frame(length, seq, 1), bytes(fr)]
            await chk_send(dut, frames, rng, gap_p=0.1)
            dut.c_csum.value = 1
            g1, b1, _, _ = counts(dut)
            assert (g1 - g0, b1 - b0) == (1, 1), \
                f"{kind} len {length}: good +{g1 - g0} bad +{b1 - b0}"
            seq += 2

    # csum with the test frames (udp off) changes nothing
    dut.c_udp.value = 0
    await clear(dut)
    await chk_send(dut, [ref_frame(n, 900 + i, 0) for i, n in enumerate((60, 61, 300))], rng)
    assert counts(dut) == (3, 0, 0, 0), counts(dut)
