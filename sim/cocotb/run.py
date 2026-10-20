#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Build + run the emacZero cocotb suites on Icarus (Verilog) or GHDL (VHDL port).

The same Python testbenches run against rtl/ on Icarus and against the VHDL
port in rtl/vhdl/ on GHDL; only the simulator and the source list change.

Each tests/test_*.py declares the suites it backs in a literal dict, read here
without importing the module:

    SUITES = {
        "<suite name>": {
            "toplevel": "eth_mac_rx",            # HDL top (DUT or a harness)
            "sources": ["rtl/crc32.v", ...],     # Verilog, repo-relative, in order
            "params": {"MAX_FRAME_STD": 1518},   # parameters / generics
            # optional:
            "target": "SIM",                     # vendor target, default SIM
            "vhdl_sources": [...],               # instead of the automatic mapping
            "env": {"KEY": "value"},             # extra environment for the test
            "skip_vhdl": "reason",               # Verilog only, with the reason
        },
    }

The target becomes a Verilog define (-DSIM) and, for VHDL, the package
rtl/vhdl/target/emz_target_<target>.vhd. Without "vhdl_sources", rtl/**/<n>.v
maps to rtl/vhdl/<n>.vhd and any other <dir>/<n>.v to <dir>/<n>.vhd (the test
harnesses in sim/cocotb/hdl/ keep both languages side by side).

Usage:
    python run.py                         # every suite, Verilog
    python run.py --hdl vhdl              # every suite, VHDL port on GHDL
    python run.py --hdl both -j 4         # both languages, 4 suites at a time
    python run.py --suite eth_mac_rx      # one suite (repeatable)
    python run.py --list                  # suite names
    python run.py --seed 12345            # force cocotb's master seed (replay)
    python run.py --test random_mix       # one testcase
    python run.py --waves
"""
import argparse
import ast
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).parent.resolve()
REPO = HERE.parent.parent
RTL = REPO / "rtl"
TESTS = HERE / "tests"
BUILD = HERE / "sim_build"

SPEC_KEYS = {"toplevel", "sources", "params", "target", "vhdl_sources", "env",
             "skip_vhdl"}
VHDL_UTIL = "rtl/vhdl/emz_util_pkg.vhd"
# VHDL entity instantiation needs the entity analysed even inside a generate
# that is off; Verilog does not. eth_mac_rx instantiates csum_calc only when
# RX_CSUM_OFFLOAD=1, so its Verilog source lists may leave it out.
VHDL_EXTRA_DEPS = {"eth_mac_rx": ["rtl/vhdl/csum_calc.vhd"]}


def discover() -> dict:
    """{suite name: spec}, each spec with its "test_module" filled in."""
    suites = {}
    for path in sorted(TESTS.glob("test_*.py")):
        tree = ast.parse(path.read_text(encoding="utf-8"), str(path))
        for node in tree.body:
            if (isinstance(node, ast.Assign) and len(node.targets) == 1
                    and isinstance(node.targets[0], ast.Name)
                    and node.targets[0].id == "SUITES"):
                for name, spec in ast.literal_eval(node.value).items():
                    if name in suites:
                        sys.exit(f"suite {name!r} declared twice ({path.name})")
                    unknown = set(spec) - SPEC_KEYS
                    if unknown:
                        sys.exit(f"suite {name!r}: unknown keys {sorted(unknown)}")
                    suites[name] = {**spec, "test_module": path.stem}
    return suites


def vhdl_sources(spec) -> list:
    target = spec.get("target", "SIM").lower()
    out = [f"rtl/vhdl/target/emz_target_{target}.vhd", VHDL_UTIL]
    if "vhdl_sources" in spec:
        files = list(spec["vhdl_sources"])
    else:
        files = []
        for s in spec["sources"]:
            p = Path(s)
            vhd = (f"rtl/vhdl/{p.stem}.vhd" if p.parts[0] == "rtl"
                   else p.with_suffix(".vhd").as_posix())
            files += VHDL_EXTRA_DEPS.get(p.stem, []) + [vhd]
    for f in files:
        if f not in out:
            out.append(f)
    return out


def run_one(name, spec, hdl, args) -> int:
    """Build and run one suite in this process. Returns the failure count."""
    from cocotb_tools.runner import get_runner

    env = dict(os.environ)
    env["PYTHONPATH"] = os.pathsep.join([str(HERE), str(TESTS), env.get("PYTHONPATH", "")])
    env.update(spec.get("env", {}))
    os.environ.update(env)
    # The runner builds the simulator's PYTHONPATH from sys.path, not from the
    # environment, so the test modules must be on sys.path when the simulator
    # does not run inside TESTS (GHDL).
    for p in (str(TESTS), str(HERE)):
        if p not in sys.path:
            sys.path.insert(0, p)

    params = dict(spec.get("params", {}))
    if hdl == "vhdl":
        build_name = f"vhdl_{name}"
        runner = get_runner("ghdl")
        sources = vhdl_sources(spec)
        tool_args = {"build_args": ["--std=93"]}
    else:
        build_name = name
        runner = get_runner("icarus")
        sources = spec["sources"]
        # Icarus reads -P values as expressions: a string needs its quotes.
        params = {k: (f'"{v}"' if isinstance(v, str) else v) for k, v in params.items()}
        tool_args = {"timescale": ("1ns", "1ps"),
                     "defines": {spec.get("target", "SIM"): 1},
                     "includes": [str(RTL)]}
    build_dir = BUILD / build_name
    runner.build(
        sources=[str(REPO / s) for s in sources],
        hdl_toplevel=spec["toplevel"],
        parameters=params,
        build_dir=str(build_dir),
        always=True,
        waves=args.waves,
        **tool_args,
    )
    xml = runner.test(
        test_module=spec["test_module"],
        hdl_toplevel=spec["toplevel"],
        # GHDL's gcc/llvm backends run the executable that elaboration left in
        # build_dir; the test modules are found through PYTHONPATH either way.
        test_dir=str(build_dir if hdl == "vhdl" else TESTS),
        build_dir=str(build_dir),
        seed=args.seed,
        testcase=args.test,
        extra_env=env,
        waves=args.waves,
        results_xml=f"results_{build_name}.xml",
    )
    failed = _count_failures(xml)
    print(f"[{build_name}] results: {xml}  failures={failed}")
    return failed


def _count_failures(xml_path) -> int:
    try:
        from cocotb_tools.runner import get_results
        _, failed = get_results(Path(xml_path))
        return failed
    except Exception:
        import xml.etree.ElementTree as ET
        root = ET.parse(xml_path).getroot()
        return sum(sum(1 for _ in tc.iter("failure")) + sum(1 for _ in tc.iter("error"))
                   for tc in root.iter("testcase"))


def _child(name, hdl, args):
    """One (suite, language) in a subprocess: (name, hdl, rc, output, seconds)."""
    cmd = [sys.executable, str(Path(__file__).resolve()), "--suite", name, "--hdl", hdl]
    if args.seed is not None:
        cmd += ["--seed", str(args.seed)]
    if args.test:
        cmd += ["--test", args.test]
    if args.waves:
        cmd.append("--waves")
    start = time.monotonic()
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, check=False)
    return name, hdl, res.returncode, res.stdout, time.monotonic() - start


def main() -> int:
    suites = discover()
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--suite", action="append", choices=sorted(suites),
                    help="suite to run (repeatable; default: all)")
    ap.add_argument("--hdl", default="verilog", choices=["verilog", "vhdl", "both"],
                    help="verilog: rtl/ on Icarus (default); vhdl: rtl/vhdl/ on GHDL")
    ap.add_argument("-j", "--jobs", type=int, default=1,
                    help="suites run in parallel, each in its own process")
    ap.add_argument("--list", action="store_true", help="print the suite names")
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--test", default=None)
    ap.add_argument("--waves", action="store_true")
    args = ap.parse_args()

    if args.list:
        for name in sorted(suites):
            skip = suites[name].get("skip_vhdl")
            print(name + (f"  (Verilog only: {skip})" if skip else ""))
        return 0

    hdls = ["verilog", "vhdl"] if args.hdl == "both" else [args.hdl]
    jobs, skipped = [], []
    for name in args.suite or sorted(suites):
        for hdl in hdls:
            if hdl == "vhdl" and suites[name].get("skip_vhdl"):
                skipped.append((name, suites[name]["skip_vhdl"]))
            else:
                jobs.append((name, hdl))

    if len(jobs) == 1 and args.jobs <= 1:
        name, hdl = jobs[0]
        failed = run_one(name, suites[name], hdl, args)
        return 1 if failed else 0

    gha = os.environ.get("GITHUB_ACTIONS") == "true"
    results = []
    with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        for name, hdl, rc, out, secs in pool.map(lambda j: _child(*j, args), jobs):
            tag = f"{name} [{hdl}] {'PASS' if rc == 0 else 'FAIL'}"
            print(f"::group::{tag}" if gha else f"\n##### {tag}", flush=True)
            print(out, flush=True)
            if gha:
                print("::endgroup::", flush=True)
            results.append((name, hdl, rc, secs))

    print("\n[cocotb] Summary")
    failed = []
    for name, hdl, rc, secs in results:
        print(f"  {name:<32} {hdl:<8} {secs:7.0f} s  {'PASS' if rc == 0 else 'FAIL'}")
        if rc:
            failed.append(f"{name} [{hdl}]")
    for name, why in skipped:
        print(f"  {name:<32} {'vhdl':<8} {'':>9}  SKIP ({why})")
    if failed:
        print(f"\n[cocotb] {len(failed)} suite run(s) failed: {', '.join(failed)}")
        if gha:
            for f in failed:
                print(f"::error::cocotb {f} failed")
        return 1
    print(f"\n[cocotb] all {len(results)} suite run(s) passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
