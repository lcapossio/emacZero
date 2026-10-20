#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""L2 proof of rgmii_if (rtl/rgmii_if.v vs rtl/vhdl/rgmii_if.vhd) per RGMII_SPEEDS.

Runs translateHDL's own L2 flow (formal_equiv._prove_yosys: clk2fflogic,
equiv_induct, counterexample probe) and changes only how the design is read:

  * RGMII_SPEEDS is a string. translateHDL passes integer parameters only, and
    its one-instance-wrapper route crashes here: under a wrapper, GHDL's
    `<inst>_<port>` nets and the flattened `<inst>.<port>` wires both become
    `u_rgmii_<inst>_<port>` in `rename -unescape`, which trips a Yosys 0.63
    assertion (`count_id(wire->name) == 0`). So the value goes in directly:
    `chparam -set RGMII_SPEEDS "<v>"` on the Verilog side and
    `ghdl --synth -gRGMII_SPEEDS=<v>` on the VHDL side, no wrapper.

  * --ddr standin (also the proof of record, parity.yml) reads the stateless DDR
    stand-ins in sim/parity/stubs/ddr_standin.{v,vhd}. Yosys names a
    for-generate instance gen_txd[0].u_txd and GHDL names it gen_txd_n1_u_txd,
    so state inside those cells never pairs by name. The stand-ins hold no
    state, and each output depends on each input, so the proof checks every
    cell connection. The real cells are proven per target in
    sim/parity/ddr_output and sim/parity/ddr_input.

  * --ddr <target> reads the real ddr_output / ddr_input for
    that target (Xilinx primitives as the stubs in sim/parity/stubs/) and
    renames instance labels in the GHDL netlist so the cell state pairs:
    gen_txd_n<k>_u_txd -> gen_txd[k-1].u_txd (same for gen_rx_data), and the
    Xilinx generate prefix gen_<target>_u_oddr -> u_oddr (u_iddr). Labels
    only: a wrong pairing can leave points unproven, never hide a divergence.

Needs GHDL and a Yosys with `rename -unescape` (GHDL / YOSYS env vars as for
translateHDL). Usage, from the repository root:

  python3 sim/parity/rgmii_if/prove_rgmii_if.py <translateHDL>/skills/translate-hdl/scripts
  python3 sim/parity/rgmii_if/prove_rgmii_if.py <scripts> --ddr sim xilinx_7series

Without --ddr it proves the stand-ins and every target (sim/parity/run_all.py
runs it that way).
Exit status 0 only if every requested configuration is PASS.
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
SPEEDS = ("ALL", "1G_ONLY", "10_100")
TARGETS = ("sim", "intel_cyclone", "xilinx_7series", "xilinx_ultrascale_plus")


def sources(ddr: str) -> tuple[list[Path], list[Path]]:
    """(golden Verilog, candidate VHDL) source lists for one DDR mode."""
    if ddr == "standin":
        gold = [HERE.parent / "stubs/ddr_standin.v", REPO / "rtl/rgmii_if.v"]
        gate = [HERE.parent / "stubs/ddr_standin.vhd", REPO / "rtl/vhdl/rgmii_if.vhd"]
        return gold, gate
    xil = ddr.startswith("xilinx")
    gold = [HERE.parent / f"defines/{ddr}.vh"]
    gold += [HERE.parent / "stubs/xilinx_ddr_prims.v"] if xil else []
    gold += [REPO / "rtl/ddr_output.v", REPO / "rtl/ddr_input.v", REPO / "rtl/rgmii_if.v"]
    gate = [REPO / f"rtl/vhdl/target/emz_target_{ddr}.vhd"]
    gate += [HERE.parent / "stubs/xilinx_ddr_prims.vhd"] if xil else []
    gate += [REPO / "rtl/vhdl/ddr_output.vhd", REPO / "rtl/vhdl/ddr_input.vhd",
             REPO / "rtl/vhdl/rgmii_if.vhd"]
    return gold, gate


def relabel(net: str, ddr: str) -> str:
    """Label-only renames that let the real DDR cell state pair by name."""
    def gen(m: re.Match) -> str:
        return f"\\{m.group(1)}[{int(m.group(2)) - 1}].{m.group(3)} "
    net, n = re.subn(r"\b(gen_txd|gen_rx_data)_n(\d+)_(u_txd|u_rxd)\b(?= \()", gen, net)
    if n != 8:
        raise RuntimeError(f"expected 8 for-generate DDR instances in the GHDL netlist, found {n}")
    if ddr.startswith("xilinx"):
        net, n = re.subn(rf"\bgen_{ddr}_(u_oddr|u_iddr)\b(?= \()", r"\1", net)
        if n != 2:
            raise RuntimeError(f"expected 2 gen_{ddr} primitive instances, found {n}")
    return net


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("scripts", type=Path, help="translateHDL skills/translate-hdl/scripts dir")
    ap.add_argument("--ddr", nargs="+", choices=("standin",) + TARGETS,
                    default=["standin", *TARGETS],
                    help="DDR cells to prove with (default: the stand-ins and every target)")
    ap.add_argument("--speeds", nargs="+", choices=SPEEDS, default=list(SPEEDS))
    ap.add_argument("--induct-depth", type=int, default=20)
    args = ap.parse_args()

    sys.path.insert(0, str(args.scripts.resolve()))
    import formal_equiv  # noqa: E402  (translateHDL)
    from _common import tool  # noqa: E402

    if not formal_equiv._yosys_has_unescape(REPO):
        print("SKIP: yosys has no `rename -unescape`")
        return 77

    # translateHDL reads each side through _read_cmds; hand it ours instead.
    formal_equiv._read_cmds = lambda root, side, top, params, tmp, wrapper, *_: side["cmds"]

    ok = True
    with tempfile.TemporaryDirectory(prefix=".formal_rgmii_", dir=REPO) as tmpname:
        tmp = Path(tmpname)
        for ddr, speeds in ((d, s) for d in args.ddr for s in args.speeds):
            gold_src, gate_src = sources(ddr)
            net = tmp / f"rgmii_if_{ddr}_{speeds}.v"
            ghdl = [tool("ghdl"), "--std=93", f"--workdir={tmp}"]
            subprocess.run([ghdl[0], "-a", *ghdl[1:], *map(str, gate_src)], cwd=tmp, check=True)
            text = subprocess.run([ghdl[0], "--synth", *ghdl[1:], "--out=verilog",
                                   f"-gRGMII_SPEEDS={speeds}", "rgmii_if"],
                                  cwd=tmp, check=True, capture_output=True, text=True).stdout
            if ddr != "standin":
                text = relabel(text, ddr)
            net.write_text(text, encoding="utf-8")
            gold = ["read_verilog " + " ".join(p.as_posix() for p in gold_src),
                    f'chparam -set RGMII_SPEEDS "{speeds}" rgmii_if',
                    "hierarchy -check -top rgmii_if"]
            gate = [f"read_verilog {net.as_posix()}", "hierarchy -check -top rgmii_if"]
            status, detail = formal_equiv._prove_yosys(
                REPO, {"golden": {"cmds": gold}, "candidate": {"cmds": gate}},
                "rgmii_if", "rgmii_if", {}, {}, tmp, None, args.induct_depth, 0,
                "clk2fflogic")
            print(f"{status:5} rgmii_if[RGMII_SPEEDS={speeds}, ddr={ddr}] - {detail}",
                  flush=True)
            ok = ok and status == "PASS"
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
