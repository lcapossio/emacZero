#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""Generate the x-refined parity goldens from the real Verilog.

Each model is a real Verilog module, renamed, with one out-of-range memory
read changed from x to 0:

  test_sequencer/test_sequencer_x0.v  (fpga/arty_a7/rtl/test_sequencer.v)
      tx_tdata <= arp_frame[arp_idx];        42-word ROM, 8-bit index
  udp_echo/udp_echo_x0.v              (rtl/net/udp_echo.v)
      tx_data_mux = udp_buf[payload_tx_cnt[ADDR_W-1:0]];   BUF_SIZE words,
                                             2^ADDR_W addresses

Why: translateHDL takes a Verilog x as the one value Yosys folds it to
(translateHDL BUG-066), so where the VHDL returns 0 past the end the proof
could not close, even though 0 is a legal value of the x. These models make
the refinement explicit; they are used as L2's golden_top only, and L0, L1
and L4 run on the real modules. Everything else is copied verbatim; each edit
must match exactly once, so a change to an edited line stops this script
instead of producing a stale model.

    python sim/parity/gen_goldens.py           # write the models
    python sim/parity/gen_goldens.py --check   # exit 1 if any is out of date
"""

import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]

MODELS = [
    {"src": "fpga/arty_a7/rtl/test_sequencer.v", "dst": "test_sequencer/test_sequencer_x0.v",
     "edits": [
         ("module test_sequencer #(", "module test_sequencer_x0 #("),
         ("tx_tdata  <= arp_frame[arp_idx];",
          "tx_tdata  <= (arp_idx < 8'd42) ? arp_frame[arp_idx] : 8'h00;"),
     ]},
    {"src": "rtl/net/udp_echo.v", "dst": "udp_echo/udp_echo_x0.v",
     "edits": [
         ("module udp_echo #(", "module udp_echo_x0 #("),
         ("TX_PAYLOAD: tx_data_mux = udp_buf[payload_tx_cnt[ADDR_W-1:0]];",
          "TX_PAYLOAD: tx_data_mux = (payload_tx_cnt[ADDR_W-1:0] < BUF_SIZE) ?\n"
          "                                    udp_buf[payload_tx_cnt[ADDR_W-1:0]] : 8'h00;"),
     ]},
]


def render(model: dict) -> str:
    src = (ROOT / model["src"]).read_text(encoding="utf-8")
    for old, new in model["edits"]:
        n = src.count(old)
        if n != 1:
            raise SystemExit(f"{model['src']}: expected one '{old}', found {n}; "
                             "update the edits in gen_goldens.py")
        src = src.replace(old, new)
    name = Path(model["dst"]).stem
    header = [
        "// PARITY MODEL ONLY - not for synthesis. GENERATED from",
        f"// {model['src']} by sim/parity/gen_goldens.py; do not edit.",
        f"// Renamed to {name}; an out-of-range memory read returns 8'h00 instead",
        "// of x. Everything else is the source verbatim.",
    ]
    lines = src.splitlines(keepends=True)
    # Keep the SPDX and copyright lines first.
    return "".join(lines[:2]) + "\n".join(header) + "\n" + "".join(lines[2:])


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if a model differs from what would be generated")
    args = ap.parse_args()
    stale = []
    for model in MODELS:
        text = render(model)
        dst = HERE / model["dst"]
        if args.check:
            if not dst.exists() or dst.read_text(encoding="utf-8") != text:
                stale.append(model["dst"])
        else:
            dst.write_text(text, encoding="utf-8", newline="\n")
            print(f"wrote {dst.relative_to(ROOT).as_posix()}")
    if stale:
        print("out of date: " + ", ".join(stale) + " (run sim/parity/gen_goldens.py)")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
