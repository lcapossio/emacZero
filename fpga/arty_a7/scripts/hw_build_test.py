#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design - hello@bard0.com
#
"""hw_build_test.py - Build, program, and hardware-test the emacZero Arty A7.

Pure-Python orchestrator for the full Arty A7-100T hardware flow:

    build       Vivado batch synth + implement + bitstream (build_arty.tcl)
    program     flash the bitstream to the board          (program_arty.tcl)
    smoke       UART + ARP/ICMP smoke test                (serial_monitor.py)
    regression  bidirectional UDP regression profiles     (run_hw_regression.py)

With no phase flag all phases run in order, stopping on the first failure.

Tools are looked up in PATH first (Vivado, Python). If Vivado is not in PATH
the script reports it immediately and exits. Vivado's thread count defaults to
half the host CPU count and can be overridden with --jobs.

All paths are resolved relative to the repo root, so the script runs from any
working directory and from a clean checkout. Build artifacts land under
build_arty/ in the repo root.

Examples:
    python fpga/arty_a7/scripts/hw_build_test.py
    python fpga/arty_a7/scripts/hw_build_test.py --build --jobs 8
    python fpga/arty_a7/scripts/hw_build_test.py --program --smoke
    python fpga/arty_a7/scripts/hw_build_test.py --regression --board 192.168.137.200
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPTS_DIR.parents[2]
BUILD_TCL = SCRIPTS_DIR / "build_arty.tcl"
PROGRAM_TCL = SCRIPTS_DIR / "program_arty.tcl"
SERIAL_MONITOR = SCRIPTS_DIR / "serial_monitor.py"
HW_REGRESSION = SCRIPTS_DIR / "run_hw_regression.py"
BUILD_DIR = REPO_ROOT / "build_arty"
BITFILE = BUILD_DIR / "arty_a7_top.bit"

DEFAULT_BOARD_IP = "192.168.137.200"
DEFAULT_PROFILES = ["bidirectional-smoke", "bidirectional-long"]


def banner(msg):
    line = "=" * 60
    print(f"\n{line}\n  {msg}\n{line}", flush=True)


def find_vivado(override):
    """Locate Vivado in PATH (or honor --vivado); exit immediately if absent."""
    if override:
        if Path(override).exists():
            return override
        sys.exit(f"ERROR: Vivado not found at --vivado path: {override}")
    exe = shutil.which("vivado")
    if not exe:
        sys.exit("ERROR: 'vivado' is not in PATH. Add Vivado to PATH "
                 "or pass --vivado /path/to/vivado.")
    return exe


def default_jobs():
    cores = os.cpu_count() or 2
    return max(1, cores // 2)


def run(cmd, label):
    """Run a subprocess from the repo root, streaming output. Returns rc."""
    print(f"+ ({label}) " + " ".join(str(c) for c in cmd), flush=True)
    start = time.monotonic()
    rc = subprocess.run(cmd, cwd=str(REPO_ROOT)).returncode
    dur = time.monotonic() - start
    print(f"  ({label}) exit={rc} in {dur:.1f}s", flush=True)
    return rc


def phase_build(vivado, jobs):
    banner(f"BUILD: Vivado batch (maxThreads={jobs})")
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    # Untracked preamble caps Vivado threads (PROJECTS.md: max cores/2) before
    # sourcing the canonical build script, which keeps build_arty.tcl unmodified.
    preamble = (f"set_param general.maxThreads {jobs}\n"
                f"source {{{BUILD_TCL.as_posix()}}}\n")
    tcl_path = None
    try:
        with tempfile.NamedTemporaryFile("w", suffix=".tcl", delete=False) as fh:
            fh.write(preamble)
            tcl_path = fh.name
        rc = run([vivado, "-mode", "batch", "-source", tcl_path,
                  "-log", "build_arty/vivado_build.log", "-nojournal"],
                 "build")
    finally:
        if tcl_path:
            os.unlink(tcl_path)
    if rc == 0 and not BITFILE.exists():
        print(f"ERROR: build exited 0 but bitstream missing: {BITFILE}",
              file=sys.stderr)
        return 1
    return rc


def _program(vivado):
    if not BITFILE.exists():
        sys.exit(f"ERROR: bitstream not found: {BITFILE} (run --build first).")
    return run([vivado, "-mode", "batch", "-source", str(PROGRAM_TCL),
                "-log", "build_arty/vivado_program.log", "-nojournal"],
               "program")


def phase_program(vivado):
    banner("PROGRAM: Vivado Hardware Manager")
    return _program(vivado)


def phase_smoke(vivado, port, timeout):
    # The board prints its UART banner (VER/SCR/PHY/LINK) once at startup, so the
    # monitor must already be listening when the design starts. Launch the
    # monitor first, then reprogram to reset the design so the banner is
    # captured live rather than missed.
    banner("SMOKE: UART + ARP/ICMP (reset board while monitor listens)")
    cmd = [sys.executable, str(SERIAL_MONITOR), "--timeout", str(timeout)]
    if port:
        cmd += ["--port", port]
    print("+ (smoke) " + " ".join(str(c) for c in cmd), flush=True)
    monitor = subprocess.Popen(cmd, cwd=str(REPO_ROOT))
    time.sleep(2)  # let the monitor open the serial port before the reset
    rc_prog = _program(vivado)
    if rc_prog:
        monitor.terminate()
        return rc_prog
    monitor.wait()
    print(f"  (smoke) monitor exit={monitor.returncode}", flush=True)
    return monitor.returncode


def phase_regression(board, profiles):
    banner(f"REGRESSION: {', '.join(profiles)}")
    return run([sys.executable, str(HW_REGRESSION), *profiles, "--board", board],
               "regression")


def main():
    parser = argparse.ArgumentParser(
        description="Build, program, and hardware-test the emacZero Arty A7.")
    parser.add_argument("--build", action="store_true", help="build the bitstream")
    parser.add_argument("--program", action="store_true", help="flash the board")
    parser.add_argument("--smoke", action="store_true", help="UART/ARP/ICMP smoke test")
    parser.add_argument("--regression", action="store_true",
                        help="bidirectional UDP regression profiles")
    parser.add_argument("--jobs", type=int, default=default_jobs(),
                        help="Vivado max threads (default: host cores / 2)")
    parser.add_argument("--vivado", default=None, help="path to vivado (default: PATH)")
    parser.add_argument("--board", default=DEFAULT_BOARD_IP, help="FPGA IPv4 address")
    parser.add_argument("--port", default=None, help="UART serial port for the smoke test")
    parser.add_argument("--smoke-timeout", type=int, default=75,
                        help="seconds the smoke monitor waits for board output")
    parser.add_argument("--profiles", nargs="+", default=DEFAULT_PROFILES,
                        help="regression profile names (see run_hw_regression.py --list)")
    args = parser.parse_args()

    # No phase flag -> run the whole flow.
    run_all = not (args.build or args.program or args.smoke or args.regression)
    do_build = args.build or run_all
    do_program = args.program or run_all
    do_smoke = args.smoke or run_all
    do_regression = args.regression or run_all

    vivado = None
    if do_build or do_program or do_smoke:
        vivado = find_vivado(args.vivado)
        print(f"Vivado: {vivado}", flush=True)

    started = time.monotonic()
    if do_build and phase_build(vivado, args.jobs):
        return 1
    # The smoke phase reprograms the board to reset it, so a standalone program
    # phase is redundant whenever smoke will also run.
    if do_program and not do_smoke and phase_program(vivado):
        return 1
    if do_smoke and phase_smoke(vivado, args.port, args.smoke_timeout):
        return 1
    if do_regression and phase_regression(args.board, args.profiles):
        return 1

    banner(f"ALL REQUESTED PHASES PASSED in {time.monotonic() - started:.1f}s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
