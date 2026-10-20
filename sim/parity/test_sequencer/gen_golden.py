#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""Generate the parity golden of test_sequencer from the real RTL.

test_sequencer_x0.v is fpga/arty_a7/rtl/test_sequencer.v, renamed to
test_sequencer_x0 (L2 only; L0, L1 and L4 run on the real module), with one
read changed: the ARP frame ROM has 42 words but is read with an 8-bit arp_idx,

    tx_tdata <= arp_frame[arp_idx];          // x for arp_idx >= 42

which becomes

    tx_tdata <= (arp_idx < 8'd42) ? arp_frame[arp_idx] : 8'h00;

Why: arp_idx never passes 41, but induction starts from any state, and
translateHDL treats a Verilog x as one fixed value that Yosys picks when it
folds the read (translateHDL BUG-066). Choosing 0 for the x is a refinement
of the Verilog (an x may be any value), and it is what the VHDL port returns,
so the production VHDL carries no Yosys-specific bytes. Everything else is
copied verbatim; the edit must match exactly once, so a change to that line
stops this script instead of producing a stale model.

    python sim/parity/test_sequencer/gen_golden.py           # write the model
    python sim/parity/test_sequencer/gen_golden.py --check   # exit 1 if out of date
"""

import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
SRC = "fpga/arty_a7/rtl/test_sequencer.v"
DST = "test_sequencer_x0.v"

EDITS = [
    ("module test_sequencer #(", "module test_sequencer_x0 #("),
    ("tx_tdata  <= arp_frame[arp_idx];",
     "tx_tdata  <= (arp_idx < 8'd42) ? arp_frame[arp_idx] : 8'h00;"),
]


def render() -> str:
    src = (ROOT / SRC).read_text(encoding="utf-8")
    for old, new in EDITS:
        n = src.count(old)
        if n != 1:
            raise SystemExit(f"{SRC}: expected one '{old}', found {n}; "
                             "update the edits in gen_golden.py")
        src = src.replace(old, new)
    header = [
        "// PARITY MODEL ONLY - not for synthesis. GENERATED from",
        f"// {SRC} by sim/parity/test_sequencer/gen_golden.py; do not edit.",
        "// Renamed to test_sequencer_x0; the out-of-range ARP ROM read returns",
        "// 8'h00 instead of x. Everything else is the source verbatim.",
    ]
    lines = src.splitlines(keepends=True)
    # Keep the SPDX and copyright lines first.
    return "".join(lines[:2]) + "\n".join(header) + "\n" + "".join(lines[2:])


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if the model differs from what would be generated")
    args = ap.parse_args()
    text = render()
    dst = HERE / DST
    if args.check:
        if not dst.exists() or dst.read_text(encoding="utf-8") != text:
            print(f"out of date: {DST} (run sim/parity/test_sequencer/gen_golden.py)")
            return 1
        return 0
    dst.write_text(text, encoding="utf-8", newline="\n")
    print(f"wrote {dst.relative_to(ROOT).as_posix()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
