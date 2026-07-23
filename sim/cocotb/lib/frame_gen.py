# SPDX-License-Identifier: Apache-2.0
"""Constrained-random AXIS frame generation for the store-and-forward TX path.

A `Segment` is one AXIS burst: a run of bytes plus whether it terminates with
`tlast`. Normal frames are a single `last=True` segment. Setting `last=False`
models an upstream that *dropped* tlast, so the next segment merges onto this one
- the exact condition that produced the mii_tx_saf uncommitted-data wedge.

Sizes are deliberately weighted toward the corners that break boundary logic:
1, the min-frame edge (59/60/61), the MAX_FRAME edge (MAX-1/MAX/MAX+1), twice
MAX_FRAME, and around the FIFO depth - not just a flat uniform distribution.
"""
from dataclasses import dataclass


@dataclass
class Segment:
    data: bytes
    last: bool


def _tagged(rng, size: int) -> bytes:
    """A payload whose first byte is a rolling tag and rest is random, so a
    human reading a failing waveform can tell frames apart."""
    if size <= 0:
        return b""
    tag = rng.randrange(1, 256)
    return bytes([tag]) + bytes(rng.randrange(256) for _ in range(size - 1))


def boundary_sizes(max_frame: int, fifo_bytes: int):
    """The directed corner sizes every run should cover at least once."""
    s = {1, 2, 59, 60, 61, 63, 64, 65,
         max_frame - 1, max_frame, max_frame + 1,
         2 * max_frame, fifo_bytes - 1, fifo_bytes, fifo_bytes + 1}
    return sorted(x for x in s if x >= 1)


def random_size(rng, max_frame: int, fifo_bytes: int) -> int:
    """One weighted-random frame size (favouring boundary regions)."""
    bucket = rng.random()
    if bucket < 0.30:                       # near the min-frame / small edge
        return rng.randint(1, 65)
    if bucket < 0.55:                       # near the MAX_FRAME edge
        return rng.randint(max_frame - 4, max_frame + 4)
    if bucket < 0.72:                       # oversized: > MAX_FRAME, may exceed FIFO
        return rng.randint(max_frame + 1, fifo_bytes + 200)
    return rng.randint(1, max_frame)        # bulk uniform legal range


def random_segments(rng, n_frames: int, max_frame: int, fifo_bytes: int,
                    p_drop_last: float = 0.15):
    """A stream of `n_frames` segments with occasional dropped tlast (merges)."""
    segs = []
    for _ in range(n_frames):
        size = random_size(rng, max_frame, fifo_bytes)
        drop = rng.random() < p_drop_last
        segs.append(Segment(_tagged(rng, size), last=not drop))
    # The stream must end on a committed boundary, else the tail sits uncommitted
    # in the FIFO (correctly never transmitted) and there is nothing to score.
    if segs and not segs[-1].last:
        segs[-1] = Segment(segs[-1].data, last=True)
    return segs


def directed_segments(max_frame: int, fifo_bytes: int):
    """One committed frame per boundary size, plus explicit merge/oversize cases."""
    segs = [Segment(bytes([0xA0 + (i & 0x3F)]) + bytes((s - 1) if s > 0 else 0),
                    last=True)
            for i, s in enumerate(boundary_sizes(max_frame, fifo_bytes))]
    # Explicit merged pair (two no-tlast segments then a terminator).
    segs.append(Segment(bytes([0x11]) * 20, last=False))
    segs.append(Segment(bytes([0x22]) * 20, last=True))
    # Explicit oversized no-tlast run that exceeds the FIFO, then a clean frame.
    segs.append(Segment(bytes([0x33]) * (fifo_bytes + 100), last=False))
    segs.append(Segment(bytes([0x44]) * 64, last=True))
    return segs
