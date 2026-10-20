#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""Run every translateHDL parity manifest in sim/parity/ with --strict.

    python sim/parity/run_all.py --translatehdl <translateHDL checkout> [-j N] [module ...]

Each sim/parity/<module>/ directory runs its manifests one after another (they
share a GHDL work library there); up to N directories run in parallel. GHDL
and Yosys come from $GHDL / $YOSYS or PATH, as translateHDL looks them up.
Prints each module's log, then a summary, and exits 1 if any manifest did not
pass. Under GitHub Actions each module's log is a collapsible group.
"""

import argparse
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent


def modules() -> list[str]:
    # stubs/ and defines/ hold shared files, no manifests.
    return sorted(d.name for d in HERE.iterdir() if d.is_dir() and any(d.glob("*.yml")))


def run_module(name: str, parity: Path) -> tuple[str, list[tuple[str, int]], str, float]:
    """Every manifest of one module: (name, [(manifest, rc)], log, seconds)."""
    start = time.monotonic()
    results, log = [], []
    for manifest in sorted((HERE / name).glob("*.yml")):
        res = subprocess.run(
            [sys.executable, str(parity), manifest.name, "--strict"],
            cwd=HERE / name, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, check=False,
        )
        results.append((manifest.name, res.returncode))
        log.append(f"===== {name}/{manifest.name} (exit {res.returncode})\n{res.stdout}")
    return name, results, "\n".join(log), time.monotonic() - start


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--translatehdl", default=os.environ.get("TRANSLATEHDL"),
                    help="translateHDL checkout (default: $TRANSLATEHDL)")
    ap.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 1,
                    help="module directories run in parallel (default: CPU count)")
    ap.add_argument("module", nargs="*", help="modules to run (default: all)")
    args = ap.parse_args()

    if not args.translatehdl:
        ap.error("give --translatehdl or set $TRANSLATEHDL")
    parity = Path(args.translatehdl) / "skills" / "translate-hdl" / "scripts" / "parity.py"
    if not parity.is_file():
        ap.error(f"{parity} not found")
    names = args.module or modules()
    unknown = sorted(set(names) - set(modules()))
    if unknown:
        ap.error(f"no manifests for: {', '.join(unknown)}")

    gha = os.environ.get("GITHUB_ACTIONS") == "true"
    done = []
    with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        for name, results, log, secs in pool.map(lambda n: run_module(n, parity), names):
            ok = all(rc == 0 for _, rc in results)
            print(f"::group::{name} {'PASS' if ok else 'FAIL'}" if gha
                  else f"\n##### {name} {'PASS' if ok else 'FAIL'}", flush=True)
            print(log, flush=True)
            if gha:
                print("::endgroup::", flush=True)
            done.append((name, results, secs))

    print("\nSummary")
    failed = []
    for name, results, secs in done:
        bad = [m for m, rc in results if rc != 0]
        failed += [f"{name}/{m}" for m in bad]
        verdict = "PASS" if not bad else "FAIL " + ", ".join(bad)
        print(f"  {name:<14} {len(results)} manifest(s)  {secs:6.0f} s  {verdict}")
    if failed:
        print(f"\n{len(failed)} manifest(s) did not pass: {', '.join(failed)}")
        if gha:
            for f in failed:
                print(f"::error::parity {f} did not pass")
        return 1
    print(f"\nAll {sum(len(r) for _, r, _ in done)} manifests passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
