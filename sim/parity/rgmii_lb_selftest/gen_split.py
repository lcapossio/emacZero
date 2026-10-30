#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""Generate the split-pad parity models of rgmii_lb_selftest from the real RTL.

rgmii_lb_selftest_split.v and rgmii_lb_selftest_split.vhd are
fpga/arty_a7/rtl/rgmii_lb_selftest.v and .vhd with the module/entity renamed
to rgmii_lb_selftest_split and two changes:

  * The six RGMII pads are split into plain ports. Each IOBUF (I = pad_out[i],
    T = 0, O = pad_in[i], IO = pad[i]) is replaced by
        pad_o (out) = pad_out,   pad_in = pad_i (in).
    translateHDL's L2 does not model inout ports (it SKIPs), and a 'Z' driven
    output is no evidence either, since the solver folds 'Z' to a constant.
    The edit matches the IOBUF instance text exactly, on both sides, so the
    replaced connections (including T tied to 0) are checked to be the same.

  * The five IDELAYE2s, a for-generate on both sides, are unrolled into
    instances u_idelay_0 .. u_idelay_4 (Verilog) and idelay_0 .. idelay_4 in
    generate u (VHDL, which flattens to the same names). Yosys names a
    for-generate instance gen_dly[0].u_idelay and GHDL names it
    gen_dly_n1_u_idelay, so the state inside the IDELAYE2 stand-in (a
    register, see sim/parity/stubs/xilinx_io_standin.v) would not pair by name
    and would start from independent values on each side. Each copy is the
    loop body verbatim with the loop index replaced by its value. The VHDL
    IODELAY_GROUP attribute on the loop label is dropped; no proof sees
    attributes.

  * The Verilog IDELAYCTRL instance u_idelayctrl is renamed u_dlyctrl, the
    name the VHDL's dlyctrl in generate u flattens to (a VHDL label cannot
    be idelayctrl, the component's name), so its stand-in state pairs too.
    Labels only: a wrong pairing can leave state unproven, never hide a
    divergence.

Everything else is copied verbatim, so L2 on these models covers all of
rgmii_lb_selftest except the IOBUF cells themselves. Each edit must match
exactly once, so a change to the edited code in either source stops this
script instead of producing a stale model. L0, L1 and L4 run on the real
module.

    python sim/parity/rgmii_lb_selftest/gen_split.py           # write the models
    python sim/parity/rgmii_lb_selftest/gen_split.py --check   # exit 1 if out of date
"""

import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
N_DLY = 5

V_EDITS = [
    ("module rgmii_lb_selftest #(", "module rgmii_lb_selftest_split #("),
    ("    inout  wire [5:0]   pad         // [3:0] TXD/RXD, [4] TX_CTL/RX_CTL, [5] TXC/RXC\n",
     "    output wire [5:0]   pad_o,      // parity split: the pads as driven\n"
     "    input  wire [5:0]   pad_i       // parity split: the pads as read\n"),
    ("    assign     pad     = pad_out;\n"
     "    assign #1  pad_in  = pad;\n",
     "    assign     pad_o   = pad_out;\n"
     "    assign #1  pad_in  = pad_i;\n"),
    ("        for (i_pad = 0; i_pad < 6; i_pad = i_pad + 1) begin : gen_pad\n"
     "            (* DONT_TOUCH = \"TRUE\" *)\n"
     "            IOBUF u_iobuf (\n"
     "                .I  (pad_out[i_pad]),\n"
     "                .T  (1'b0),\n"
     "                .O  (pad_in[i_pad]),\n"
     "                .IO (pad[i_pad])\n"
     "            );\n"
     "        end\n",
     "        assign pad_o  = pad_out;     // parity split: IOBUF I, T = 0\n"
     "        assign pad_in = pad_i;       // parity split: IOBUF O\n"),
    ("    IDELAYCTRL u_idelayctrl (", "    IDELAYCTRL u_dlyctrl ("),
]
V_LOOP_HEAD = "        for (i_pad = 0; i_pad < 5; i_pad = i_pad + 1) begin : gen_dly\n"
V_LOOP_TAIL = "        end\n    endgenerate\n"

VHD_EDITS = [
    ("entity rgmii_lb_selftest is", "entity rgmii_lb_selftest_split is"),
    ("end entity rgmii_lb_selftest;", "end entity rgmii_lb_selftest_split;"),
    ("architecture rtl of rgmii_lb_selftest is", "architecture rtl of rgmii_lb_selftest_split is"),
    ("        pad    : inout std_logic_vector(5 downto 0)     -- [3:0] TXD/RXD, [4] TX_CTL/RX_CTL, [5] TXC/RXC\n",
     "        pad_o  : out   std_logic_vector(5 downto 0);    -- parity split: the pads as driven\n"
     "        pad_i  : in    std_logic_vector(5 downto 0)     -- parity split: the pads as read\n"),
    ("        pad     <= pad_out;\n"
     "        pad_in  <= pad after 1 ns;\n",
     "        pad_o   <= pad_out;\n"
     "        pad_in  <= pad_i after 1 ns;\n"),
    ("        gen_pad : for i_pad in 0 to 5 generate\n"
     "            attribute DONT_TOUCH of u_iobuf : label is \"TRUE\";\n"
     "        begin\n"
     "            u_iobuf : IOBUF\n"
     "                port map (\n"
     "                    I  => pad_out(i_pad),\n"
     "                    T  => '0',\n"
     "                    O  => pad_in(i_pad),\n"
     "                    IO => pad(i_pad)\n"
     "                );\n"
     "        end generate gen_pad;\n",
     "        pad_o  <= pad_out;           -- parity split: IOBUF I, T = '0'\n"
     "        pad_in <= pad_i;             -- parity split: IOBUF O\n"),
]
VHD_LOOP_HEAD = ("        gen_dly : for i_pad in 0 to 4 generate\n"
                 "            attribute IODELAY_GROUP of u_idelay : label is \"rgmii_lb\";\n"
                 "        begin\n")
VHD_LOOP_TAIL = "        end generate gen_dly;\n"


def apply_edits(src: str, path: str, edits: list) -> str:
    for old, new in edits:
        n = src.count(old)
        if n != 1:
            first = old.strip().splitlines()[0]
            raise SystemExit(f"{path}: expected one '{first}', found {n}; "
                             "update the edits in gen_split.py")
        src = src.replace(old, new)
    return src


def unroll(src: str, path: str, head: str, tail: str, label: tuple, index: tuple) -> str:
    """Replace the loop from head to the first tail after it by N_DLY copies of
    its body, with label[0] -> label[1] and index[0] -> index[1] ({k} = copy)."""
    if src.count(head) != 1:
        raise SystemExit(f"{path}: expected one '{head.strip()}'; update gen_split.py")
    start = src.index(head)
    end = src.find(tail, start)
    if end < 0:
        raise SystemExit(f"{path}: no '{tail.strip()}' after '{head.strip()}'")
    body = src[start + len(head):end]
    if body.count(label[0]) != 1:
        raise SystemExit(f"{path}: expected one '{label[0]}' in the gen_dly body")
    copies = []
    for k in range(N_DLY):
        c = body.replace(label[0], label[1].format(k=k))
        c = c.replace(index[0], index[1].format(k=k))
        if "i_pad" in c:
            raise SystemExit(f"{path}: gen_dly body uses i_pad other than as "
                             f"'{index[0]}'; update gen_split.py")
        copies.append(c)
    # The Verilog tail also closes the generate region: keep that part.
    keep = tail[len(tail.split("\n")[0]) + 1:]
    return src[:start] + "".join(copies) + keep + src[end + len(tail):]


def render_v() -> str:
    path = "fpga/arty_a7/rtl/rgmii_lb_selftest.v"
    src = (ROOT / path).read_text(encoding="utf-8")
    src = apply_edits(src, path, V_EDITS)
    src = unroll(src, path, V_LOOP_HEAD, V_LOOP_TAIL,
                 (") u_idelay (", ") u_idelay_{k} ("), ("[i_pad]", "[{k}]"))
    return header(path, "//") + src


def render_vhd() -> str:
    path = "fpga/arty_a7/rtl/rgmii_lb_selftest.vhd"
    src = (ROOT / path).read_text(encoding="utf-8")
    src = apply_edits(src, path, VHD_EDITS)
    src = unroll(src, path, VHD_LOOP_HEAD, VHD_LOOP_TAIL,
                 ("u_idelay : IDELAYE2", "idelay_{k} : IDELAYE2"), ("(i_pad)", "({k})"))
    return header(path, "--") + src


def header(path: str, c: str) -> str:
    return "\n".join([
        f"{c} PARITY MODEL ONLY - not for synthesis. GENERATED from",
        f"{c} {path} by sim/parity/rgmii_lb_selftest/gen_split.py; do not edit.",
        f"{c} Renamed to rgmii_lb_selftest_split, with the IOBUF pads split into",
        f"{c} pad_o and pad_i, the five IDELAYE2s unrolled and (Verilog) the",
        f"{c} IDELAYCTRL instance named u_dlyctrl. Everything else is the source",
        f"{c} verbatim.",
    ]) + "\n"


def with_spdx_first(text: str) -> str:
    """Move the source's SPDX and copyright lines above the generated header."""
    lines = text.splitlines(keepends=True)
    head = [i for i, ln in enumerate(lines) if "SPDX-License-Identifier" in ln]
    if not head:
        raise SystemExit("no SPDX line in the source")
    i = head[0]
    return "".join(lines[i:i + 2]) + "".join(lines[:i]) + "".join(lines[i + 2:])


MODELS = [("rgmii_lb_selftest_split.v", render_v),
          ("rgmii_lb_selftest_split.vhd", render_vhd)]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if a model differs from what would be generated")
    args = ap.parse_args()
    stale = []
    for name, render in MODELS:
        text = with_spdx_first(render())
        dst = HERE / name
        if args.check:
            if not dst.exists() or dst.read_text(encoding="utf-8") != text:
                stale.append(name)
        else:
            dst.write_text(text, encoding="utf-8", newline="\n")
            print(f"wrote {dst.relative_to(ROOT).as_posix()}")
    if stale:
        print("out of date: " + ", ".join(stale) + " (run sim/parity/rgmii_lb_selftest/gen_split.py)")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
