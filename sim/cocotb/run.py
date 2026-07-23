#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Build + run the emacZero cocotb suites on Icarus.

Backend-agnostic by design: sources are passed via the language-neutral
`sources=` argument, so the same flow retargets GHDL once a VHDL port exists -
only the simulator name and the source files change, not the Python testbenches.

Usage:
    python run.py                       # all suites
    python run.py --suite eth_mac_rx    # one suite
    python run.py --seed 12345          # force cocotb's master seed (replay)
    python run.py --test random_mix     # one testcase
    python run.py --waves
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


def run_suite(name, spec, args) -> int:
    env = dict(os.environ)
    env["PYTHONPATH"] = os.pathsep.join([str(HERE), str(TESTS), env.get("PYTHONPATH", "")])
    env.update(spec.get("env", {}))
    os.environ.update(env)

    build_dir = BUILD / name
    runner = get_runner("icarus")
    runner.build(
        sources=[str(RTL / s) for s in spec["sources"]],
        hdl_toplevel=spec["toplevel"],
        parameters=spec["params"],
        build_dir=str(build_dir),
        timescale=("1ns", "1ps"),
        always=True,
        waves=args.waves,
    )
    xml = runner.test(
        test_module=spec["test_module"],
        hdl_toplevel=spec["toplevel"],
        test_dir=str(TESTS),
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
    args = ap.parse_args()

    names = [args.suite] if args.suite else list(SUITES)
    total = 0
    for name in names:
        total += run_suite(name, SUITES[name], args)
    print(f"\n[cocotb] total failures across {len(names)} suite(s): {total}")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
