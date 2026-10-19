#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Build + run the emacZero cocotb suites on Icarus (Verilog) or GHDL (VHDL port).

Backend-agnostic by design: sources are passed via the language-neutral
`sources=` argument, so the same Python testbenches run against rtl/ on Icarus
and against the VHDL port in rtl/vhdl/ on GHDL. With --hdl vhdl each Verilog
source maps to rtl/vhdl/<name>.vhd, after the SIM target and utility packages.

Usage:
    python run.py                       # all suites
    python run.py --suite eth_mac_rx    # one suite
    python run.py --seed 12345          # force cocotb's master seed (replay)
    python run.py --test random_mix     # one testcase
    python run.py --waves
    python run.py --hdl vhdl            # the VHDL port under GHDL (cocotb >= 2.0)
"""
import argparse
import os
import sys
from pathlib import Path

from cocotb_tools.runner import get_runner

HERE = Path(__file__).parent.resolve()
REPO = HERE.parent.parent
RTL = REPO / "rtl"
TESTS = HERE / "tests"
BUILD = HERE / "sim_build"

SUITES = {
    "mii_tx_saf": {
        "toplevel": "mii_tx_saf",
        "sources": ["async_fifo.v", "mii_tx_saf.v"],
        "params": {"MAX_FRAME": 1518, "FIFO_ADDR_WIDTH": 12},
        "test_module": "test_mii_tx_saf",
        "env": {"SAF_MAX_FRAME": "1518", "SAF_FIFO_ADDR_WIDTH": "12"},
    },
    "eth_mac_rx": {
        "toplevel": "eth_mac_rx",
        "sources": ["crc32.v", "sync_fifo.v", "eth_mac_rx.v"],
        "params": {"MAX_FRAME_STD": 1518},
        "test_module": "test_eth_mac_rx",
        "env": {"RX_MAX_FRAME_STD": "1518"},
    },
    "eth_mac_rx_robust": {
        "toplevel": "eth_mac_rx",
        "sources": ["crc32.v", "sync_fifo.v", "eth_mac_rx.v"],
        "params": {"MAX_FRAME_STD": 1518},
        "test_module": "test_eth_mac_rx_robust",
        "env": {"RX_MAX_FRAME_STD": "1518"},
    },
    "eth_mac_rx_mcast": {
        "toplevel": "eth_mac_rx",
        "sources": ["crc32.v", "sync_fifo.v", "eth_mac_rx.v"],
        "params": {"MAX_FRAME_STD": 1518, "MCAST_HASH_FILTER": 1},
        "test_module": "test_eth_mac_rx_mcast",
        "env": {"RX_MAX_FRAME_STD": "1518"},
    },
    "eth_mac_rx_csum": {
        "toplevel": "eth_mac_rx",
        "sources": ["crc32.v", "sync_fifo.v", "net/csum_calc.v", "eth_mac_rx.v"],
        "params": {"MAX_FRAME_STD": 1518, "RX_CSUM_OFFLOAD": 1},
        "test_module": "test_eth_mac_rx_csum",
        "env": {},
    },
    "csum_calc": {
        "toplevel": "csum_calc",
        "sources": ["net/csum_calc.v"],
        "params": {},
        "test_module": "test_csum_calc",
        "env": {},
    },
    "tx_csum_off": {
        "toplevel": "tx_csum_off",
        "sources": ["sync_fifo.v", "net/csum_calc.v", "net/tx_csum_off.v"],
        "params": {"MAX_FRAME": 600},
        "test_module": "test_tx_csum_off",
        "env": {},
    },
    "gmii_cdc": {
        "toplevel": "gmii_cdc",
        "sources": ["async_fifo.v", "gmii_cdc.v"],
        "params": {},
        "test_module": "test_gmii_cdc",
        "env": {},
    },
}


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


VHDL_PACKAGES = ["vhdl/target/emz_target_sim.vhd", "vhdl/emz_util_pkg.vhd"]
# VHDL entity instantiation needs the entity analysed even inside a generate
# that is off; Verilog does not. eth_mac_rx instantiates csum_calc only when
# RX_CSUM_OFFLOAD=1, so its Verilog source lists may leave it out.
VHDL_EXTRA_DEPS = {"eth_mac_rx": ["csum_calc"]}


def _vhdl_sources(sources):
    """rtl/<dir>/<name>.v -> rtl/vhdl/<name>.vhd, after the packages."""
    names = []
    for s in sources:
        stem = Path(s).stem
        for dep in VHDL_EXTRA_DEPS.get(stem, []):
            if dep not in names:
                names.append(dep)
        if stem not in names:
            names.append(stem)
    return VHDL_PACKAGES + [f"vhdl/{n}.vhd" for n in names]


def run_suite(name, spec, args) -> int:
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

    if args.hdl == "vhdl":
        name = f"vhdl_{name}"
        runner = get_runner("ghdl")
        sources = _vhdl_sources(spec["sources"])
        tool_args = {"build_args": ["--std=08", "-fsynopsys"]}
    else:
        runner = get_runner("icarus")
        sources = spec["sources"]
        tool_args = {"timescale": ("1ns", "1ps")}
    build_dir = BUILD / name
    runner.build(
        sources=[str(RTL / s) for s in sources],
        hdl_toplevel=spec["toplevel"],
        parameters=spec["params"],
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
        test_dir=str(build_dir if args.hdl == "vhdl" else TESTS),
        build_dir=str(build_dir),
        seed=args.seed,
        testcase=args.test,
        extra_env=env,
        waves=args.waves,
        results_xml=f"results_{name}.xml",
    )
    failed = _count_failures(xml)
    print(f"[{name}] results: {xml}  failures={failed}")
    return failed


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--suite", default=None, choices=list(SUITES))
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--test", default=None)
    ap.add_argument("--waves", action="store_true")
    ap.add_argument("--hdl", default="verilog", choices=["verilog", "vhdl"],
                    help="verilog: rtl/ on Icarus (default); vhdl: rtl/vhdl/ on GHDL")
    args = ap.parse_args()

    names = [args.suite] if args.suite else list(SUITES)
    total = 0
    for name in names:
        total += run_suite(name, SUITES[name], args)
    print(f"\n[cocotb] total failures across {len(names)} suite(s): {total}")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
