#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""Generate the split-I2C-pin parity models of zcu106_top from the real RTL.

zcu106_top_split.v, zcu106_top_split.vhd and zcu106_top_lb_split.vhd are
fpga/zcu106/rtl/zcu106_top.v, zcu106_top.vhd and zcu106_top_lb.vhd with the
module/entity renamed to zcu106_top_split and the two open-drain I2C pins
split into plain ports:

    IIC_SCL (out, scl_t ? 'Z' : '0')  ->  IIC_SCL_t (out) = scl_t
    IIC_SDA (inout, sda_t ? 'Z' : '0',
             read into i2c_init.sda_i) ->  IIC_SDA_t (out) = sda_t,
                                           IIC_SDA_i (in)  -> i2c_init.sda_i

Why: translateHDL's L2 does not model inout ports (it SKIPs), and a 'Z'
driven output is no evidence either, since the solver folds 'Z' to a
constant on both sides (`c ? 'Z' : '0'` "proves" equal to `d ? 'Z' : '0'`).

The models also bring the fcapz EIO's probe_in vector out on an extra output,
PARITY_PROBE_IN (256 bits, 608 in the ZCU106_SFP1_LB build), so L2 compares
every probe bit directly. The EIO has no clock, so its stand-in can only fold
the probe onto its 8 or 16 outputs, where two wrong probe bits can cancel;
through this port they cannot. The port is driven from whatever the EIO's
probe_in is actually wired to, never from a name fixed here: in the Verilog
the inline concatenation is moved into `assign PARITY_PROBE_IN = {...};`
and the EIO reads PARITY_PROBE_IN; in the VHDL the one signal on probe_in is
read from the port map (anything but one EIO instance with a plain signal on
probe_in stops the script).

Everything else is copied verbatim, so L2 on these models covers all of the
top except the two tri-state drivers, which this script checks are the same
expression on both sides (each edit must match exactly once, so a change to
the edited code in any source stops this script instead of producing a stale
model). L0, L1 and L4 run on the real tops.

    python sim/parity/zcu106_top/gen_split.py           # write the models
    python sim/parity/zcu106_top/gen_split.py --check   # exit 1 if out of date
"""

import argparse
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]

V_EDITS = [
    ("module zcu106_top #(", "module zcu106_top_split #("),
    ("    output wire       IIC_SCL,            // open drain (no clock stretching)\n"
     "    inout  wire       IIC_SDA,\n",
     "    output wire       IIC_SCL_t,          // parity split: scl_t\n"
     "    output wire       IIC_SDA_t,          // parity split: sda_t\n"
     "    input  wire       IIC_SDA_i,          // parity split: the pin as read\n"
     "`ifdef ZCU106_SFP1_LB\n"
     "    output wire [607:0] PARITY_PROBE_IN,  // parity split: EIO probe_in\n"
     "`else\n"
     "    output wire [255:0] PARITY_PROBE_IN,  // parity split: EIO probe_in\n"
     "`endif\n"),
    ("    assign IIC_SCL = scl_t ? 1'bz : 1'b0;\n"
     "    assign IIC_SDA = sda_t ? 1'bz : 1'b0;\n",
     "    assign IIC_SCL_t = scl_t;\n"
     "    assign IIC_SDA_t = sda_t;\n"),
    ("        .sda_i      (IIC_SDA),", "        .sda_i      (IIC_SDA_i),"),
]


def vhdl_edits(probe_w: int) -> list:
    """The I2C split and the EIO probe port, for one VHDL top."""
    return [
        ("entity zcu106_top is", "entity zcu106_top_split is"),
        ("end entity zcu106_top;", "end entity zcu106_top_split;"),
        ("architecture rtl of zcu106_top is", "architecture rtl of zcu106_top_split is"),
        ("        IIC_SCL             : out   std_logic;  -- open drain (no clock stretching)\n"
         "        IIC_SDA             : inout std_logic;\n",
         "        IIC_SCL_t           : out   std_logic;  -- parity split: scl_t\n"
         "        IIC_SDA_t           : out   std_logic;  -- parity split: sda_t\n"
         "        IIC_SDA_i           : in    std_logic;  -- parity split: the pin as read\n"
         f"        PARITY_PROBE_IN     : out   std_logic_vector({probe_w - 1} downto 0);"
         "  -- parity split: EIO probe_in\n"),
        ("    IIC_SCL <= 'Z' when scl_t = '1' else '0';\n"
         "    IIC_SDA <= 'Z' when sda_t = '1' else '0';\n",
         "    IIC_SCL_t <= scl_t;\n"
         "    IIC_SDA_t <= sda_t;\n"),
        ("                sda_i      => IIC_SDA,", "                sda_i      => IIC_SDA_i,"),
    ]


EIO_VHD = re.compile(r"^    (\w+) : fcapz_eio_xilinxus\n.*?\n        \);\n", re.M | re.S)
PROBE_VHD = re.compile(r"\bprobe_in\s*=>\s*([^,\n]*?)\s*,")


def lift_probe_vhd(src: str) -> str:
    """Drive PARITY_PROBE_IN from the signal the EIO's probe_in is actually wired to."""
    insts = list(EIO_VHD.finditer(src))
    if len(insts) != 1:
        raise SystemExit(f"expected one fcapz_eio_xilinxus instance, found {len(insts)}; "
                         "update gen_split.py")
    m = insts[0]
    actuals = PROBE_VHD.findall(m.group(0))
    if len(actuals) != 1 or not re.fullmatch(r"[A-Za-z]\w*", actuals[0]):
        raise SystemExit(f"{m.group(1)}: probe_in must be wired to one plain signal, found "
                         f"{actuals}; update gen_split.py")
    return (src[:m.start()] + f"    PARITY_PROBE_IN <= {actuals[0]};\n" + src[m.start():])


PROBE_V = re.compile(r"\.probe_in  \((\{[^;]*?\})\),")


def lift_probes_v(src: str) -> str:
    """Move each inline EIO probe concatenation into an assign to PARITY_PROBE_IN."""
    found = list(PROBE_V.finditer(src))
    if len(found) != 2:
        raise SystemExit("fpga/zcu106/rtl/zcu106_top.v: expected two EIO probe_in "
                         f"concatenations, found {len(found)}; update gen_split.py")
    for m in reversed(found):
        inst = src.rfind("    fcapz_eio_xilinxus #(", 0, m.start())
        if inst < 0:
            raise SystemExit("fpga/zcu106/rtl/zcu106_top.v: probe_in outside an EIO instance")
        expr = " ".join(m.group(1).split())
        src = (src[:inst] + f"    assign PARITY_PROBE_IN = {expr};\n" + src[inst:m.start()]
               + ".probe_in  (PARITY_PROBE_IN)," + src[m.end():])
    return src


MODELS = [
    {"src": "fpga/zcu106/rtl/zcu106_top.v", "dst": "zcu106_top_split.v",
     "comment": "//", "edits": V_EDITS, "post": lift_probes_v},
    {"src": "fpga/zcu106/rtl/zcu106_top.vhd", "dst": "zcu106_top_split.vhd",
     "comment": "--", "edits": vhdl_edits(256), "post": lift_probe_vhd},
    {"src": "fpga/zcu106/rtl/zcu106_top_lb.vhd", "dst": "zcu106_top_lb_split.vhd",
     "comment": "--", "edits": vhdl_edits(608), "post": lift_probe_vhd},
]


def render(model: dict) -> str:
    src = (ROOT / model["src"]).read_text(encoding="utf-8")
    for old, new in model["edits"]:
        n = src.count(old)
        if n != 1:
            raise SystemExit(f"{model['src']}: expected one '{old.strip()}', found {n}; "
                             "update the edits in gen_split.py")
        src = src.replace(old, new)
    if "post" in model:
        src = model["post"](src)
    c = model["comment"]
    header = [
        f"{c} PARITY MODEL ONLY - not for synthesis. GENERATED from",
        f"{c} {model['src']} by sim/parity/zcu106_top/gen_split.py; do not edit.",
        f"{c} Renamed to zcu106_top_split, with the open-drain I2C pins split into",
        f"{c} IIC_SCL_t, IIC_SDA_t and IIC_SDA_i, and the EIO probe_in brought out on",
        f"{c} PARITY_PROBE_IN. Everything else is the source verbatim.",
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
        print("out of date: " + ", ".join(stale) + " (run sim/parity/zcu106_top/gen_split.py)")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
