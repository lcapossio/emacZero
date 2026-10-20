#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""L2 proof of arp_responder (fpga/arty_a7/rtl/arp_responder.v vs .vhd).

Runs translateHDL's own L2 flow (formal_equiv._prove_yosys: clk2fflogic,
equiv_simple + equiv_induct, base case, counterexample probe) and changes only
how the VHDL netlist is labelled:

  The Verilog keeps the 42-byte capture and reply buffers in arrays
  (`reg [7:0] cap [0:41]`, `reply [0:41]`) that are reset in a for loop, so
  Yosys splits them into 84 registers named cap[0]..cap[41] and
  reply[0]..reply[41]. GHDL synthesises the VHDL arrays into one 336-bit
  register each (`cap`, `reply`), element 0 in the most significant byte.
  translateHDL pairs state by name only, so these never pair and the proof
  cannot close (sim/parity/arp_responder/parity.yml therefore has no L2). A
  VHDL-93 name cannot produce the Verilog's: `rename -unescape` turns cap[0]
  into cap_0_, and a VHDL identifier cannot end in `_` (an extended identifier
  \\cap[0]\\ would, but GHDL 4.1 writes it to the Verilog netlist without the
  terminating space, which no Verilog reader accepts).

  So this script adds to the GHDL netlist one alias wire per element,
  `wire [7:0] \\cap[k] ; assign \\cap[k] = cap[335-8k -: 8];` (same for reply),
  which `equiv_make` then pairs with the Verilog's cap[k]. Names only: an alias
  adds a proof obligation, it never removes one, so a wrong pairing can leave
  points unproven but cannot hide a divergence.

Needs GHDL and a Yosys with `rename -unescape` (GHDL / YOSYS env vars as for
translateHDL). Usage, from the repository root:

  python3 sim/parity/arp_responder/prove_arp_responder.py <translateHDL>/skills/translate-hdl/scripts
Exit status 0 only if the proof is PASS.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
GOLD = REPO / "fpga/arty_a7/rtl/arp_responder.v"
GATE = REPO / "fpga/arty_a7/rtl/arp_responder.vhd"
ARRAYS = ("cap", "reply")
WORDS, WIDTH = 42, 8


def add_aliases(net: str) -> str:
    """One `\\<array>[k]` alias wire per element of each buffer array."""
    total = WORDS * WIDTH
    lines = []
    for name in ARRAYS:
        decl = f"wire [{total - 1}:0] {name};"
        if net.count(decl) != 1:
            raise RuntimeError(f"expected one `{decl}` in the GHDL netlist")
        for k in range(WORDS):
            hi = total - 1 - WIDTH * k
            lines.append(f"  wire [{WIDTH - 1}:0] \\{name}[{k}] ;\n"
                         f"  assign \\{name}[{k}]  = {name}[{hi}:{hi - WIDTH + 1}];\n")
    # After the last array declaration, so both are declared.
    last = f"wire [{total - 1}:0] {ARRAYS[-1]};\n"
    return net.replace(last, last + "".join(lines), 1)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("scripts", type=Path, help="translateHDL skills/translate-hdl/scripts dir")
    ap.add_argument("--induct-depth", type=int, default=8)
    ap.add_argument("--vhdl", type=Path, default=GATE, help="candidate VHDL (default: the port)")
    args = ap.parse_args()

    sys.path.insert(0, str(args.scripts.resolve()))
    import formal_equiv  # noqa: E402  (translateHDL)
    from _common import tool  # noqa: E402

    if not formal_equiv._yosys_has_unescape(REPO):
        print("SKIP: yosys has no `rename -unescape`")
        return 77

    # translateHDL reads each side through _read_cmds; hand it ours instead.
    formal_equiv._read_cmds = lambda root, side, *rest: side["cmds"]

    with tempfile.TemporaryDirectory(prefix=".formal_arp_", dir=REPO) as tmpname:
        tmp = Path(tmpname)
        net = tmp / "arp_responder.v"
        ghdl = [tool("ghdl"), "--std=93", f"--workdir={tmp}"]
        subprocess.run([ghdl[0], "-a", *ghdl[1:], str(args.vhdl.resolve())], cwd=tmp, check=True)
        text = subprocess.run([ghdl[0], "--synth", *ghdl[1:], "--out=verilog", "arp_responder"],
                              cwd=tmp, check=True, capture_output=True, text=True).stdout
        net.write_text(add_aliases(text), encoding="utf-8")
        gold = [f"read_verilog {GOLD.as_posix()}", "hierarchy -check -top arp_responder"]
        gate = [f"read_verilog {net.as_posix()}", "hierarchy -check -top arp_responder"]
        status, detail = formal_equiv._prove_yosys(
            REPO, {"golden": {"cmds": gold}, "candidate": {"cmds": gate}},
            "arp_responder", "arp_responder", {}, {}, tmp, None, args.induct_depth, 0,
            "clk2fflogic")
    print(f"{status:5} arp_responder - {detail}", flush=True)
    print("RESULT:", "PASS" if status == "PASS" else "FAIL")
    return 0 if status == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
