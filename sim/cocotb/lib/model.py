# SPDX-License-Identifier: Apache-2.0
"""Reference model of the mii_tx_saf commit / truncate / drop policy.

This is the whole point of the randomized suite: predict, from the exact AXIS
stimulus, which frames the framer will put on the wire - so a scoreboard can
check observed-vs-expected without hand-authoring each case.

DUT policy (rtl/mii_tx_saf.v):
  * The framer starts only a fully committed frame (committed = a byte accepted
    with tlast, real or synthetic).
  * The write side caps the in-flight run at MAX_FRAME: on the MAX_FRAME-th byte
    of a run with no real tlast it forces a synthetic EOF (commits a MAX_FRAME
    frame) and then DROPS every following byte until the next real tlast.
  * A committed frame shorter than MIN_FRAME is zero-padded before the FCS.
  * An uncommitted tail (no tlast, shorter than MAX_FRAME, left at end of stream)
    stays in the FIFO and is never transmitted.
"""
from .eth import pad_payload
from .frame_gen import Segment


def saf_expected(segments, max_frame: int):
    """List of padded wire payloads (bytes) the framer should transmit."""
    # Flatten segments into a per-byte (value, is_last) stream.
    stream = []
    for seg in segments:
        n = len(seg.data)
        for i, b in enumerate(seg.data):
            stream.append((b, seg.last and i == n - 1))

    frames = []
    cur = bytearray()
    dropping = False
    for b, last in stream:
        if dropping:
            if last:
                dropping = False        # real EOF ends the discarded tail
            continue
        cur.append(b)
        forced = (len(cur) == max_frame) and not last
        if last or forced:
            frames.append(pad_payload(bytes(cur)))
            cur = bytearray()
            if forced:
                dropping = True
    # Any leftover `cur` is uncommitted -> not transmitted (matches the DUT).
    return frames


class Scoreboard:
    """Compare framer output (from the MII monitor) against the reference model."""

    def __init__(self, expected):
        self.expected = list(expected)
        self.errors = []

    def check(self, observed):
        """observed: list of payload `bytes` recovered from the wire (FCS-stripped)."""
        if len(observed) != len(self.expected):
            self.errors.append(
                f"frame count mismatch: expected {len(self.expected)}, "
                f"observed {len(observed)}")
        for i, (exp, obs) in enumerate(zip(self.expected, observed)):
            if exp != obs:
                self.errors.append(
                    f"frame {i}: len exp={len(exp)} obs={len(obs)}; "
                    f"first-diff {_first_diff(exp, obs)}")
        return not self.errors


def _first_diff(a: bytes, b: bytes):
    for i in range(min(len(a), len(b))):
        if a[i] != b[i]:
            return f"@{i} exp=0x{a[i]:02x} obs=0x{b[i]:02x}"
    return f"len {len(a)} vs {len(b)}"
