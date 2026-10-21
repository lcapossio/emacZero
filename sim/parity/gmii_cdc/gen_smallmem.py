#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""Generate the small-memory parity models of async_fifo from the real RTL.

async_fifo_smallmem.v and async_fifo_smallmem.vhd are rtl/async_fifo.v and
rtl/vhdl/async_fifo.vhd with the memory array clamped to 2**MEM_AW words,
MEM_AW = min(ADDR_WIDTH, 3), and indexed with the low MEM_AW pointer bits.
Pointers, Gray synchronizers, full/empty and wr_data_count keep their real
ADDR_WIDTH+1 width, so every occupancy-dependent branch of the parent stays
reachable. Everything else is copied verbatim.

gmii_cdc instantiates async_fifo by name and hard-codes a 16K-word TX FIFO,
too large for memory_map + SAT, so the proofs of gmii_cdc, mii_if, eth_mac,
eth_mac_sys and the MII harnesses read these models on both sides. The real
async_fifo is proven separately in sim/parity/async_fifo/, at small depths.

Each edit must match the expected number of times, and every memory access
in the source must be one of the edited ones. So a change to the memory code
in either RTL file (a new access, or an index other than the full
ADDR_WIDTH-bit pointer, which the small-depth proofs might not see) stops
this script instead of producing a model that hides it.

    python sim/parity/gmii_cdc/gen_smallmem.py           # write both models
    python sim/parity/gmii_cdc/gen_smallmem.py --check   # exit 1 if out of date
"""

import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]

MODELS = [
    {
        "src": "rtl/async_fifo.v",
        "dst": "async_fifo_smallmem.v",
        "comment": "//",
        "access": "mem[",
        "edits": [
            # (old, new, expected count, memory accesses it covers per match)
            ("    localparam DEPTH = 1 << ADDR_WIDTH;\n",
             "    localparam DEPTH = 1 << ADDR_WIDTH;\n"
             "    // PARITY MODEL: memory clamped to 2**MEM_AW words (see header).\n"
             "    localparam MEM_AW    = (ADDR_WIDTH < 3) ? ADDR_WIDTH : 3;\n"
             "    localparam MEM_DEPTH = 1 << MEM_AW;\n", 1, 0),
            ("reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];",
             "reg [DATA_WIDTH-1:0] mem [0:MEM_DEPTH-1];", 2, 0),
            ("mem[wr_ptr_bin[ADDR_WIDTH-1:0]]", "mem[wr_ptr_bin[MEM_AW-1:0]]", 2, 1),
            ("mem[rd_ptr_bin[ADDR_WIDTH-1:0]]", "mem[rd_ptr_bin[MEM_AW-1:0]]", 2, 1),
        ],
    },
    {
        "src": "rtl/vhdl/async_fifo.vhd",
        "dst": "async_fifo_smallmem.vhd",
        "comment": "--",
        "access": "mem(",
        "edits": [
            ("    constant DEPTH : integer := 2 ** ADDR_WIDTH;\n",
             "    constant DEPTH : integer := 2 ** ADDR_WIDTH;\n"
             "    -- PARITY MODEL: memory clamped to 2**MEM_AW words (see header).\n"
             "    function min_int(a, b : integer) return integer is\n"
             "    begin\n"
             "        if a < b then\n"
             "            return a;\n"
             "        end if;\n"
             "        return b;\n"
             "    end function min_int;\n"
             "    constant MEM_AW    : integer := min_int(ADDR_WIDTH, 3);\n"
             "    constant MEM_DEPTH : integer := 2 ** MEM_AW;\n", 1, 0),
            ("type mem_t is array (0 to DEPTH-1)", "type mem_t is array (0 to MEM_DEPTH-1)", 1, 0),
            ("mem(to_integer(wr_ptr_bin(ADDR_WIDTH-1 downto 0)))",
             "mem(to_integer(wr_ptr_bin(MEM_AW-1 downto 0)))", 2, 1),
            ("mem(to_integer(rd_ptr_bin(ADDR_WIDTH-1 downto 0)))",
             "mem(to_integer(rd_ptr_bin(MEM_AW-1 downto 0)))", 2, 1),
        ],
    },
]


def render(model: dict) -> str:
    src = (ROOT / model["src"]).read_text(encoding="utf-8")
    accesses = src.count(model["access"])
    covered = sum(n * per for _, _, n, per in model["edits"])
    if accesses != covered:
        raise SystemExit(f"{model['src']}: {accesses} memory accesses '{model['access']}', "
                         f"the edits cover {covered}; update gen_smallmem.py")
    for old, new, n_exp, _ in model["edits"]:
        n = src.count(old)
        if n != n_exp:
            raise SystemExit(f"{model['src']}: expected {n_exp} x '{old.strip()}', found {n}; "
                             "update the edits in gen_smallmem.py")
        src = src.replace(old, new)
    c = model["comment"]
    header = [
        f"{c} PARITY MODEL ONLY - not for synthesis or the core. GENERATED from",
        f"{c} {model['src']} by sim/parity/gmii_cdc/gen_smallmem.py; do not edit.",
        f"{c} The memory array is clamped to 2**MEM_AW words, MEM_AW = min(ADDR_WIDTH, 3),",
        f"{c} indexed with the low MEM_AW pointer bits. Everything else is the source",
        f"{c} verbatim. The real async_fifo is proven in sim/parity/async_fifo/.",
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
                stale.append(dst.name)
        else:
            dst.write_text(text, encoding="utf-8", newline="\n")
            print(f"wrote {dst.relative_to(ROOT).as_posix()}")
    if stale:
        print("out of date: " + ", ".join(stale) + " (run sim/parity/gmii_cdc/gen_smallmem.py)")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
