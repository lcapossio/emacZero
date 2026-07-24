# SPDX-License-Identifier: Apache-2.0
"""Reference model + scoreboard for the gmii_cdc TX store-and-forward path.

gmii_cdc re-times bytes across the sys->media clock domains without touching
their content, so the model is an identity: every committed input frame must
appear on the media output, in order, byte-for-byte. The pacing (1G/100M/10M) is
checked by the monitor's per-period sampling, not by the model.
"""


def gmii_tx_expected(frames):
    """Expected media-side output frames = the input frames, unchanged, in order."""
    return [bytes(f) for f in frames]


class GmiiTxScoreboard:
    def __init__(self, expected):
        self.expected = list(expected)
        self.errors = []

    def check(self, observed):
        if len(observed) != len(self.expected):
            self.errors.append(
                f"frame count: expected {len(self.expected)}, observed {len(observed)}")
        for i, (e, o) in enumerate(zip(self.expected, observed)):
            if e != o:
                self.errors.append(
                    f"frame {i}: len exp={len(e)} obs={len(o)}; {_first_diff(e, o)}")
        return not self.errors


def _first_diff(a, b):
    for i in range(min(len(a), len(b))):
        if a[i] != b[i]:
            return f"@{i} exp=0x{a[i]:02x} obs=0x{b[i]:02x}"
    return f"len {len(a)} vs {len(b)}"
