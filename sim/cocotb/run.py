#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Build + run the mii_tx_saf cocotb suite on Icarus.

Backend-agnostic by design: sources are passed via the language-neutral
`sources=` argument, so the same flow retargets GHDL once a VHDL port exists -
only the simulator name and the source files change, not the Python testbenches.

Usage:
    python run.py                 # full suite
    python run.py --seed 12345    # force cocotb's master seed (reproduce a failure)
    python run.py --test random_heavy_bubble
    python run.py --waves         # dump FST/VCD waves
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

TOPLEVEL = "mii_tx_saf"
SOURCES = [RTL / "async_fifo.v", RTL / "mii_tx_saf.v"]
PARAMS = {"MAX_FRAME": 1518, "FIFO_ADDR_WIDTH": 12}


def _count_failures(xml_path) -> int:
    """Return #failures+#errors from the JUnit results XML (0 == all passed)."""
    try:
        from cocotb_tools.runner import get_results
        _, failed = get_results(Path(xml_path))
        return failed
    except Exception:
        import xml.etree.ElementTree as ET
        root = ET.parse(xml_path).getroot()
        bad = 0
        for tc in root.iter("testcase"):
            bad += sum(1 for _ in tc.iter("failure")) + sum(1 for _ in tc.iter("error"))
        return bad


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=None,
                    help="cocotb master seed (for deterministic replay)")
    ap.add_argument("--test", default=None, help="run only this testcase")
    ap.add_argument("--waves", action="store_true")
    args = ap.parse_args()

    # The Python testbenches import `lib.*`; expose the cocotb root + tests dir.
    env = dict(os.environ)
    env["PYTHONPATH"] = os.pathsep.join(
        [str(HERE), str(TESTS), env.get("PYTHONPATH", "")])
    env["SAF_MAX_FRAME"] = str(PARAMS["MAX_FRAME"])
    env["SAF_FIFO_ADDR_WIDTH"] = str(PARAMS["FIFO_ADDR_WIDTH"])
    os.environ.update(env)

    runner = get_runner("icarus")
    runner.build(
        sources=[str(p) for p in SOURCES],
        hdl_toplevel=TOPLEVEL,
        parameters=PARAMS,
        build_dir=str(BUILD),
        timescale=("1ns", "1ps"),
        always=True,
        waves=args.waves,
    )
    xml = runner.test(
        test_module="test_mii_tx_saf",
        hdl_toplevel=TOPLEVEL,
        test_dir=str(TESTS),
        build_dir=str(BUILD),
        seed=args.seed,
        testcase=args.test,
        extra_env=env,
        waves=args.waves,
    )
    failed = _count_failures(xml)
    print(f"\n[mii_tx_saf cocotb] results: {xml}  failures={failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
