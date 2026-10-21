#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""Generate the small-RAM parity models of mii_if from the real RTL.

mii_if_smallram.v and mii_if_smallram.vhd are rtl/mii_if.v and
rtl/vhdl/mii_if.vhd with the inline 4096x9 RX frame RAM cut to 8 words,
indexed by the low three address bits. Everything else is copied verbatim.

A second 8-word array, rx_frame_mem_tag, keeps the high nine bits of each
word's write address, and a read returns the stored byte XOR (stored high
bits XOR read high bits): the byte itself when the read address is the one
written, and otherwise a value that depends on every address bit. Without
the tag, an error in address bits 11:3 on either port would be invisible,
since eight-word storage aliases them. (The tag is its own array: widening
the data word to 18 bits instead stops equiv_induct from closing.)

The real RAM makes equiv_induct intractable for yowasp-yosys. The parity
manifests that use these models are parity_smallram.yml,
../eth_mac/parity.yml and the MII set of ../eth_mac_sys/parity.yml.

Each edit must match exactly once, so a change to the RAM code in either RTL
file stops this script instead of producing a stale model.

    python sim/parity/mii_if/gen_smallram.py           # write both models
    python sim/parity/mii_if/gen_smallram.py --check   # exit 1 if out of date
"""

import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]

MODELS = [
    {
        "src": "rtl/mii_if.v",
        "dst": "mii_if_smallram.v",
        "comment": "//",
        "edits": [
            ("reg [8:0] rx_frame_mem [0:4095];",
             "reg [8:0] rx_frame_mem [0:7];\n"
             "    reg [8:0] rx_frame_mem_tag [0:7];"),
            ("rx_frame_mem[rx_mem_wr_addr] <= rx_mem_wr_data;",
             "begin\n"
             "                rx_frame_mem[rx_mem_wr_addr[2:0]]     <= rx_mem_wr_data;\n"
             "                rx_frame_mem_tag[rx_mem_wr_addr[2:0]] <= rx_mem_wr_addr[11:3];\n"
             "            end"),
            ("rx_frame_mem_dout_r <= rx_frame_mem[rx_mem_rd_addr_reg];",
             "rx_frame_mem_dout_r <= rx_frame_mem[rx_mem_rd_addr_reg[2:0]] ^\n"
             "                                   rx_frame_mem_tag[rx_mem_rd_addr_reg[2:0]] ^\n"
             "                                   rx_mem_rd_addr_reg[11:3];"),
        ],
    },
    {
        "src": "rtl/vhdl/mii_if.vhd",
        "dst": "mii_if_smallram.vhd",
        "comment": "--",
        "edits": [
            ("type frame_mem_t is array (0 to 4095)", "type frame_mem_t is array (0 to 7)"),
            ("    signal rx_frame_mem        : frame_mem_t;\n",
             "    signal rx_frame_mem        : frame_mem_t;\n"
             "    signal rx_frame_mem_tag    : frame_mem_t;\n"),
            ("rx_frame_mem(to_integer(rx_mem_wr_addr)) <= rx_mem_wr_data;",
             "rx_frame_mem(to_integer(rx_mem_wr_addr(2 downto 0)))     <= rx_mem_wr_data;\n"
             "                    rx_frame_mem_tag(to_integer(rx_mem_wr_addr(2 downto 0))) <=\n"
             "                        std_logic_vector(rx_mem_wr_addr(11 downto 3));"),
            ("rx_frame_mem_dout_r <= rx_frame_mem(to_integer(unsigned(rx_mem_rd_addr_reg)));",
             "rx_frame_mem_dout_r <=\n"
             "                        rx_frame_mem(to_integer(unsigned(rx_mem_rd_addr_reg(2 downto 0)))) xor\n"
             "                        rx_frame_mem_tag(to_integer(unsigned(rx_mem_rd_addr_reg(2 downto 0)))) xor\n"
             "                        rx_mem_rd_addr_reg(11 downto 3);"),
        ],
    },
]


def render(model: dict) -> str:
    src = (ROOT / model["src"]).read_text(encoding="utf-8")
    for old, new in model["edits"]:
        n = src.count(old)
        if n != 1:
            raise SystemExit(f"{model['src']}: expected one '{old}', found {n}; "
                             "update the edits in gen_smallram.py")
        src = src.replace(old, new)
    c = model["comment"]
    header = [
        f"{c} PARITY MODEL ONLY - not for synthesis or the core. GENERATED from",
        f"{c} {model['src']} by sim/parity/mii_if/gen_smallram.py; do not edit.",
        f"{c} The inline RX frame RAM is cut from 4096 to 8 words, indexed by the",
        f"{c} low three address bits; rx_frame_mem_tag keeps each word's write",
        f"{c} address bits 11:3, XORed with the read address bits 11:3 on a read",
        f"{c} (see gen_smallram.py).",
        f"{c} Everything else is the source verbatim.",
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
        print("out of date: " + ", ".join(stale) + " (run sim/parity/mii_if/gen_smallram.py)")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
