#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
"""
build_and_test.py — emacZero: lint and simulate Ethernet MAC
============================================================
Runs version checks, Icarus lint, Verilator lint, and all Icarus testbenches.

Usage:
  python build_and_test.py              # run all tests
  python build_and_test.py --sim-only   # same (kept for compatibility)
"""

import argparse
import os
import re
import shutil
import subprocess
import sys

PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))
IVERILOG_BIN = "iverilog"
VVP_BIN = "vvp"
VERILATOR_BIN = "verilator"
VIVADO_BIN = "vivado"
ELAB_TCL = "fpga/arty_a7/scripts/elab_check.tcl"
RGMII_IMPL_TCL = "fpga/scripts/rgmii_impl_check.tcl"

# rtl/ holds version.vh (single source of truth, included by axilite_regs.v).
IVERILOG_INCDIRS = ["rtl"]


class C:
    GREEN = "\033[92m"
    RED = "\033[91m"
    YELLOW = "\033[93m"
    CYAN = "\033[96m"
    BOLD = "\033[1m"
    END = "\033[0m"


def header(msg):
    print(f"\n{C.BOLD}{C.CYAN}{'='*60}{C.END}")
    print(f"{C.BOLD}{C.CYAN}  {msg}{C.END}")
    print(f"{C.BOLD}{C.CYAN}{'='*60}{C.END}")


def ok(msg):
    print(f"  {C.GREEN}PASS{C.END} {msg}")


def fail(msg):
    print(f"  {C.RED}FAIL{C.END} {msg}")


def run_cmd(cmd, cwd=None, timeout=None):
    try:
        r = subprocess.run(
            cmd, shell=True, cwd=cwd, timeout=timeout,
            capture_output=True, text=True, encoding="utf-8", errors="replace"
        )
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "TIMEOUT"
    except FileNotFoundError:
        return -1, "", f"Command not found: {cmd}"


# =============================================================================
# Version consistency
# =============================================================================
VERSION_VH       = os.path.join(PROJECT_DIR, "rtl", "version.vh")
VERSION_C_HEADER = os.path.join(PROJECT_DIR, "sw", "emaczero", "emaczero.h")
VERSION_FUSESOC  = os.path.join(PROJECT_DIR, "emaczero.core")

_VH_DEFINE_RE = re.compile(
    r'`define\s+(EMZ_VERSION_MAJOR|EMZ_VERSION_MINOR|EMZ_VERSION_ID)\s+'
    r"\d+'[hH]([0-9A-Fa-f_]+)"
)
_VH_DEFINE_ANY_RE = re.compile(
    r'`define\s+(EMZ_VERSION_MAJOR|EMZ_VERSION_MINOR|EMZ_VERSION_ID)\s+(.+?)'
    r"(?:\s*//.*)?$",
    re.MULTILINE,
)
_C_DEFINE_RE = re.compile(
    r'#define\s+(EMZ_VERSION_MAJOR|EMZ_VERSION_MINOR|EMZ_VERSION_ID)\s+'
    r"(?:0x([0-9A-Fa-f]+)u?|(\d+)u?)"
)
_C_VALUE_LITERAL_RE = re.compile(
    r"#define\s+EMZ_VERSION_VALUE\s+"
    r"(?:0x([0-9A-Fa-f]+)u?|(\d+)u?)"
)
_CORE_NAME_RE = re.compile(
    r"^name:\s*[^:]+:[^:]+:[^:]+:(\d+)\.(\d+)\.\d+", re.MULTILINE
)


def _read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


class VersionParseError(ValueError):
    pass


def _parse_vh(text):
    out = {}
    for m in _VH_DEFINE_RE.finditer(text):
        out[m.group(1)] = int(m.group(2).replace("_", ""), 16)
    for m in _VH_DEFINE_ANY_RE.finditer(text):
        key, value = m.group(1), m.group(2).strip()
        if key not in out:
            raise VersionParseError(
                f"{key} in version.vh has unsupported format: {value!r} "
                "(expected sized hexadecimal like 8'h01)"
            )
    return out


def _parse_c(text):
    out = {}
    for m in _C_DEFINE_RE.finditer(text):
        hex_val, dec_val = m.group(2), m.group(3)
        out[m.group(1)] = int(hex_val, 16) if hex_val else int(dec_val)
    return out


def _parse_c_version_value(text, cdef):
    m = _C_VALUE_LITERAL_RE.search(text)
    if m:
        hex_val, dec_val = m.group(1), m.group(2)
        return int(hex_val, 16) if hex_val else int(dec_val)

    if "EMZ_VERSION_VALUE" in text:
        return ((cdef["EMZ_VERSION_MAJOR"] << 24)
                | (cdef["EMZ_VERSION_MINOR"] << 16)
                | cdef["EMZ_VERSION_ID"])
    return None


def _parse_core(text):
    m = _CORE_NAME_RE.search(text)
    if not m:
        return None
    return int(m.group(1)), int(m.group(2))


def run_version_check():
    header("PHASE 0a: Version consistency")
    try:
        vh   = _parse_vh(_read(VERSION_VH))
        cdef = _parse_c(_read(VERSION_C_HEADER))
        core = _parse_core(_read(VERSION_FUSESOC))
    except (OSError, ValueError) as e:
        fail(f"Version check: {e}")
        return False

    keys = ("EMZ_VERSION_MAJOR", "EMZ_VERSION_MINOR", "EMZ_VERSION_ID")
    missing = [(name, k) for name, src in (("version.vh", vh), ("emaczero.h", cdef))
                          for k in keys if k not in src]
    if missing:
        for src, k in missing:
            fail(f"Version check: {k} missing in {src}")
        return False
    if core is None:
        fail("Version check: could not parse package version from emaczero.core")
        return False

    mismatches = [k for k in keys if vh[k] != cdef[k]]
    if mismatches:
        for k in mismatches:
            fail(f"Version check: {k} mismatch — version.vh=0x{vh[k]:X}, "
                 f"emaczero.h=0x{cdef[k]:X}")
        return False

    c_value = _parse_c_version_value(_read(VERSION_C_HEADER), cdef)
    expected_value = ((vh["EMZ_VERSION_MAJOR"] << 24)
                      | (vh["EMZ_VERSION_MINOR"] << 16)
                      | vh["EMZ_VERSION_ID"])
    if c_value is None:
        fail("Version check: EMZ_VERSION_VALUE missing in emaczero.h")
        return False
    if c_value != expected_value:
        fail(f"Version check: EMZ_VERSION_VALUE mismatch - emaczero.h=0x{c_value:08X}, "
             f"version.vh components imply 0x{expected_value:08X}")
        return False

    core_major, core_minor = core
    if (core_major, core_minor) != (vh["EMZ_VERSION_MAJOR"], vh["EMZ_VERSION_MINOR"]):
        fail(f"Version check: emaczero.core says {core_major}.{core_minor}.x, "
             f"version.vh says {vh['EMZ_VERSION_MAJOR']}.{vh['EMZ_VERSION_MINOR']}.x")
        return False

    ok(f"Version: v{vh['EMZ_VERSION_MAJOR']}.{vh['EMZ_VERSION_MINOR']} "
       f"(VERSION CSR = 0x{expected_value:08X})")
    return True


# =============================================================================
# Lint
# =============================================================================
LINT_SOURCES = [
    "rtl/crc32.v",
    "rtl/async_fifo.v",
    "rtl/mii_if.v",
    "rtl/mii_tx_saf.v",
    "rtl/sync_fifo.v", "rtl/eth_mac_rx.v",
    "rtl/eth_mac_tx.v",
    "rtl/eth_mac.v",
    "rtl/mdio_master.v",
    "rtl/eth_stats.v",
    "rtl/eth_pause.v",
    "rtl/axilite_regs.v",
    "rtl/ddr_output.v",
    "rtl/ddr_input.v",
    "rtl/rgmii_if.v",
    "rtl/gmii_if.v",
    "rtl/gmii_cdc.v",
    "rtl/net/tx_csum_off.v",
    "rtl/net/net_rx.v",
    "rtl/net/icmp_echo.v",
    "rtl/net/udp_echo.v",
    "rtl/net/udp_blast.v",
    "rtl/net/udp_blast_trigger.v",
    "rtl/net/udp_iperf_sink.v",
    "rtl/net/udp_stats_reply.v",
    "fpga/arty_a7/rtl/arty_tx_arbiter.v",
    "rtl/axil_arb2.v",
    "rtl/eth_mac_sys.v",
]

LINT_SUPPRESS = [
    "is sensitive to all",
    "timescale",
]

VERILATOR_LINT_ARGS = [
    "--lint-only",
    "-Wall",
    "-DSIM",  # select the simulation-only behavioral DDR models
    "--top-module", "eth_mac_sys",
    "-Irtl",
    "-Wno-DECLFILENAME",
    "-Wno-UNUSEDSIGNAL",
    "-Wno-UNUSEDPARAM",
    "-Wno-PINCONNECTEMPTY",
    "-Wno-TIMESCALEMOD",
    "-Wno-WIDTH",
    "-Wno-BLKSEQ",
    "-Wno-SYNCASYNCNET",
    "-f", "rtl/eth_mac_sys.f",
]


def _incdir_args():
    return " ".join(f'-I"{os.path.join(PROJECT_DIR, d)}"' for d in IVERILOG_INCDIRS)


def _windows_to_wsl_path(path):
    drive, rest = os.path.splitdrive(path)
    if not drive:
        return path.replace("\\", "/")
    drive_letter = drive[0].lower()
    rest = rest.replace("\\", "/")
    return f"/mnt/{drive_letter}{rest}"


def _find_wsl():
    """Locate wsl.exe even when launched from a shell (e.g. git-bash) whose
    MSYS-format PATH defeats shutil.which for Windows executables."""
    if os.name != "nt":
        return None
    for cand in ("wsl", "wsl.exe"):
        found = shutil.which(cand)
        if found:
            return found
    fallback = os.path.join(os.environ.get("SystemRoot", r"C:\Windows"),
                            "System32", "wsl.exe")
    return fallback if os.path.exists(fallback) else None


def run_verilator_lint():
    header("PHASE 0b: Verilator lint")
    cmd = " ".join([VERILATOR_BIN, *VERILATOR_LINT_ARGS])
    wsl = _find_wsl()

    if shutil.which(VERILATOR_BIN):
        rc, stdout, stderr = run_cmd(cmd, cwd=PROJECT_DIR, timeout=120)
    elif wsl:
        # Run the Linux verilator under WSL. Use an argument list (no shell) so
        # cmd.exe quoting can't mangle the nested "bash -lc" script.
        wsl_project_dir = _windows_to_wsl_path(PROJECT_DIR)
        wsl_cmd = f"cd '{wsl_project_dir}' && {cmd}"
        try:
            r = subprocess.run(
                [wsl, "-e", "bash", "-lc", wsl_cmd],
                cwd=PROJECT_DIR, timeout=120,
                capture_output=True, text=True,
                encoding="utf-8", errors="replace",
            )
            rc, stdout, stderr = r.returncode, r.stdout, r.stderr
        except (OSError, subprocess.TimeoutExpired) as exc:
            fail(f"Verilator lint via WSL failed to launch: {exc}")
            return False
    else:
        fail("Verilator lint: verilator not found (native PATH or WSL)")
        return False

    if rc != 0:
        fail("Verilator lint failed")
        output = "\n".join(x for x in [stdout.strip(), stderr.strip()] if x)
        for line in output.splitlines()[:40]:
            print(f"    {line}")
        return False

    ok("Verilator lint: clean")
    return True


def _find_vivado():
    """vivado is a .bat on Windows; try both spellings."""
    for cand in (VIVADO_BIN, VIVADO_BIN + ".bat"):
        found = shutil.which(cand)
        if found:
            return found
    return None


def run_vivado_elab():
    """Elaborate the Arty top in Vivado without synthesizing.

    Neither linter covers elaboration-time errors: an out-of-range part-select
    passed iverilog -Wall and Verilator for two months and was only caught when
    Vivado refused to elaborate it, by which point no bitstream could be built.
    Skipped (not failed) where Vivado is unavailable, so CI and contributors
    without the toolchain still get the rest of the suite.
    """
    header("PHASE 0c: Vivado RTL elaboration")
    vivado = _find_vivado()
    if not vivado:
        print(f"  {C.YELLOW}SKIP{C.END} Vivado not found on PATH - "
              "elaboration-only errors are NOT covered by this run")
        return True

    cmd = f'"{vivado}" -mode batch -source "{ELAB_TCL}" -nojournal -nolog'
    rc, stdout, stderr = run_cmd(cmd, cwd=PROJECT_DIR, timeout=1200)
    if rc != 0:
        fail("Vivado RTL elaboration failed")
        output = "\n".join(x for x in [stdout.strip(), stderr.strip()] if x)
        errors = [ln for ln in output.splitlines() if "ERROR" in ln]
        for line in (errors or output.splitlines())[:20]:
            print(f"    {line}")
        return False

    ok("Vivado RTL elaboration: clean")
    return True


def run_lint():
    header("PHASE 0: Lint (iverilog -Wall)")
    srcs = " ".join(os.path.join(PROJECT_DIR, s) for s in LINT_SOURCES)
    null_out = os.path.join(PROJECT_DIR, "sim", "lint_check.vvp")
    os.makedirs(os.path.join(PROJECT_DIR, "sim"), exist_ok=True)

    rc, stdout, stderr = run_cmd(
        f'{IVERILOG_BIN} -g2001 -Wall -DSIM {_incdir_args()} -o "{null_out}" {srcs}',
        cwd=PROJECT_DIR, timeout=30
    )

    raw_lines = stderr.strip().splitlines() if stderr.strip() else []
    warnings = []
    errors = []
    for line in raw_lines:
        if any(s in line for s in LINT_SUPPRESS):
            continue
        if "error" in line.lower():
            errors.append(line)
        elif "warning" in line.lower():
            warnings.append(line)

    if rc != 0 and errors:
        fail(f"Lint: {len(errors)} error(s)")
        for e in errors[:10]:
            print(f"    {e}")
        return False
    elif warnings:
        print(f"  {C.YELLOW}WARN{C.END} Lint: {len(warnings)} warning(s)")
        for w in warnings[:10]:
            print(f"    {w}")
    else:
        ok("Lint: clean")
    return True


# =============================================================================
# Simulation
# =============================================================================
TESTS = [
    {
        "name": "CRC32",
        "srcs": ["rtl/crc32.v", "sim/tb/tb_crc32.v"],
        "out": "sim/tb_crc32.vvp",
    },
    {
        "name": "ASYNC-FIFO",
        "srcs": ["rtl/async_fifo.v", "sim/tb/tb_async_fifo.v"],
        "out": "sim/tb_async_fifo.vvp",
    },
    {
        "name": "ASYNC-FIFO-BLOCK",
        "srcs": ["rtl/async_fifo.v", "sim/tb/tb_async_fifo.v"],
        "out": "sim/tb_async_fifo_block.vvp",
        "iverilog_args": "-DASYNC_FIFO_BLOCK",
    },
    {
        "name": "ETH-MAC-FCS",
        "srcs": ["rtl/crc32.v", "rtl/eth_mac_tx.v", "sim/tb/tb_eth_mac_fcs.v"],
        "out": "sim/tb_eth_mac_fcs.vvp",
    },
    {
        "name": "ETH-MAC-TX-PAD",
        "srcs": ["rtl/async_fifo.v", "rtl/eth_mac_tx.v", "rtl/mii_tx_saf.v",
                 "sim/tb/tb_eth_mac_tx_pad.v"],
        "out": "sim/tb_eth_mac_tx_pad.vvp",
    },
    {
        "name": "ETH-MAC-MULTIFRAME",
        "srcs": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                 "rtl/sync_fifo.v", "rtl/eth_mac_rx.v", "rtl/eth_mac_tx.v", "rtl/eth_mac.v",
                 "sim/tb/tb_eth_mac_multiframe.v"],
        "out": "sim/tb_eth_mac_multiframe.vvp",
    },
    {
        "name": "ETH-MAC-JUMBO",
        "srcs": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                 "rtl/sync_fifo.v", "rtl/eth_mac_rx.v", "rtl/eth_mac_tx.v", "rtl/eth_mac.v",
                 "sim/tb/tb_eth_mac_jumbo.v"],
        "out": "sim/tb_eth_mac_jumbo.vvp",
        "sim_timeout": 120,
    },
    {
        "name": "MII-TX-BRIDGE",
        "srcs": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                 "rtl/eth_mac_tx.v", "sim/tb/tb_mii_tx_bridge.v"],
        "out": "sim/tb_mii_tx_bridge.vvp",
    },
    {
        "name": "MII-TX-BURST-BACKPRESSURE",
        "srcs": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                 "rtl/eth_mac_tx.v", "sim/tb/tb_mii_tx_burst_backpressure.v"],
        "out": "sim/tb_mii_tx_burst_backpressure.vvp",
        "sim_timeout": 180,
    },
    {
        "name": "MII-STORE-FORWARD",
        "srcs": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                 "rtl/sync_fifo.v", "rtl/eth_mac_rx.v", "rtl/eth_mac_tx.v", "rtl/eth_mac.v",
                 "sim/tb/tb_mii_store_forward.v"],
        "out": "sim/tb_mii_store_forward.vvp",
    },
    {
        "name": "MII-LOOPBACK",
        "srcs": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                 "rtl/sync_fifo.v", "rtl/eth_mac_rx.v", "rtl/eth_mac_tx.v", "rtl/eth_mac.v",
                 "sim/tb/tb_mii_loopback.v"],
        "out": "sim/tb_mii_loopback.vvp",
    },
    {
        "name": "MII-TX-SAF",
        "srcs": ["rtl/async_fifo.v", "rtl/mii_tx_saf.v",
                 "sim/tb/tb_mii_tx_saf.v"],
        "out": "sim/tb_mii_tx_saf.vvp",
    },
    {
        "name": "MII-TX-SAF-BURST-STALL",
        "srcs": ["rtl/async_fifo.v", "rtl/mii_tx_saf.v",
                 "sim/tb/tb_mii_tx_saf_burst_stall.v"],
        "out": "sim/tb_mii_tx_saf_burst_stall.vvp",
        "sim_timeout": 90,
    },
    {
        "name": "MII-TX-SAF-OVERSIZE",
        "srcs": ["rtl/async_fifo.v", "rtl/mii_tx_saf.v",
                 "sim/tb/tb_mii_tx_saf_oversize.v"],
        "out": "sim/tb_mii_tx_saf_oversize.vvp",
        "sim_timeout": 90,
    },
    {
        "name": "MII-RX-REPLAY-STRESS",
        "srcs": ["sim/tb/xpm_fifo_async_model.v", "sim/tb/xpm_memory_sdpram_model.v",
                 "rtl/mii_if.v",
                 "sim/tb/tb_mii_rx_replay_stress.v"],
        "out": "sim/tb_mii_rx_replay_stress.vvp",
        "iverilog_args": "-DXILINX_7SERIES",
        "sim_timeout": 120,
    },
    {
        "name": "ETH-STATS",
        "srcs": ["rtl/eth_stats.v", "sim/tb/tb_eth_stats.v"],
        "out": "sim/tb_eth_stats.vvp",
    },
    {
        "name": "AXILITE-REGS",
        "srcs": ["rtl/axilite_regs.v", "sim/tb/tb_axilite_regs.v"],
        "out": "sim/tb_axilite_regs.vvp",
    },
    {
        "name": "GMII-CDC",
        "srcs": ["rtl/async_fifo.v", "rtl/gmii_cdc.v",
                 "sim/tb/tb_gmii_cdc.v"],
        "out": "sim/tb_gmii_cdc.vvp",
    },
    {
        "name": "ETH-MAC-SYS",
        "srcs": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                 "rtl/sync_fifo.v", "rtl/eth_mac_rx.v", "rtl/eth_mac_tx.v",
                 "rtl/eth_stats.v", "rtl/eth_pause.v", "rtl/axilite_regs.v", "rtl/mdio_master.v",
                 "rtl/ddr_output.v", "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                 "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v",
                 "rtl/mii_tx_saf.v", "rtl/eth_mac_sys.v",
                 "sim/tb/tb_eth_mac_sys.v"],
        "out": "sim/tb_eth_mac_sys.vvp",
        "sim_timeout": 300,
    },
    {
        "name": "RGMII-IF",
        "srcs": ["rtl/ddr_output.v", "rtl/ddr_input.v", "rtl/rgmii_if.v",
                 "sim/tb/tb_rgmii_if.v"],
        "out": "sim/tb_rgmii_if.vvp",
    },
    {
        "name": "MCAST-FILTER",
        "srcs": ["rtl/crc32.v", "rtl/eth_mac_tx.v", "rtl/sync_fifo.v", "rtl/eth_mac_rx.v",
                 "sim/tb/tb_eth_mac_rx_mcast.v"],
        "out": "sim/tb_eth_mac_rx_mcast.vvp",
    },
    {
        "name": "ETH-MAC-RX-BACKPRESSURE",
        "srcs": ["rtl/crc32.v", "rtl/eth_mac_tx.v", "rtl/sync_fifo.v", "rtl/eth_mac_rx.v",
                 "sim/tb/tb_eth_mac_rx_backpressure.v"],
        "out": "sim/tb_eth_mac_rx_backpressure.vvp",
    },
    {
        "name": "ETH-MAC-RX-JUMBO-GATE",
        "srcs": ["rtl/crc32.v", "rtl/eth_mac_tx.v", "rtl/sync_fifo.v", "rtl/eth_mac_rx.v",
                 "sim/tb/tb_eth_mac_rx_jumbo_gate.v"],
        "out": "sim/tb_eth_mac_rx_jumbo_gate.vvp",
        "sim_timeout": 60,
    },
    {
        "name": "ETH-MAC-RX-BYTE0",
        "srcs": ["rtl/crc32.v", "rtl/eth_mac_tx.v", "rtl/sync_fifo.v", "rtl/eth_mac_rx.v",
                 "sim/tb/tb_eth_mac_rx_byte0.v"],
        "out": "sim/tb_eth_mac_rx_byte0.vvp",
    },
    {
        "name": "MDIO-MASTER",
        "srcs": ["rtl/mdio_master.v", "sim/tb/tb_mdio_master.v"],
        "out": "sim/tb_mdio_master.vvp",
    },
    {
        "name": "TX-CSUM-OFF",
        "srcs": ["rtl/net/tx_csum_off.v", "sim/tb/tb_tx_csum_off.v"],
        "out": "sim/tb_tx_csum_off.vvp",
    },
    {
        "name": "NET-RX",
        "srcs": ["rtl/net/net_rx.v", "sim/tb/tb_net_rx.v"],
        "out": "sim/tb_net_rx.vvp",
    },
    {
        "name": "ICMP-ECHO",
        "srcs": ["rtl/net/icmp_echo.v", "sim/tb/tb_icmp_echo.v"],
        "out": "sim/tb_icmp_echo.vvp",
    },
    {
        "name": "UDP-IPERF-SINK",
        "srcs": ["rtl/net/udp_iperf_sink.v", "sim/tb/tb_udp_iperf_sink.v"],
        "out": "sim/tb_udp_iperf_sink.vvp",
    },
    {
        "name": "UDP-BLAST-TRIGGER",
        "srcs": ["rtl/net/udp_blast_trigger.v", "sim/tb/tb_udp_blast_trigger.v"],
        "out": "sim/tb_udp_blast_trigger.vvp",
    },
    {
        "name": "UDP-BLAST-START-DELAY",
        "srcs": ["rtl/net/udp_blast.v", "sim/tb/tb_udp_blast_start_delay.v"],
        "out": "sim/tb_udp_blast_start_delay.vvp",
    },
    {
        "name": "UDP-BLAST-BACKPRESSURE",
        "srcs": ["rtl/net/udp_blast.v", "sim/tb/tb_udp_blast_backpressure.v"],
        "out": "sim/tb_udp_blast_backpressure.vvp",
    },
    {
        "name": "ICMP-ECHO-BACKPRESSURE",
        "srcs": ["rtl/net/icmp_echo.v", "sim/tb/tb_icmp_echo_backpressure.v"],
        "out": "sim/tb_icmp_echo_backpressure.vvp",
    },
    {
        "name": "ICMP-ECHO-SIZES",
        "srcs": ["rtl/net/icmp_echo.v", "sim/tb/tb_icmp_echo_sizes.v"],
        "out": "sim/tb_icmp_echo_sizes.vvp",
    },
    {
        "name": "UDP-ECHO-BACKPRESSURE",
        "srcs": ["rtl/net/udp_echo.v", "sim/tb/tb_udp_echo_backpressure.v"],
        "out": "sim/tb_udp_echo_backpressure.vvp",
    },
    {
        "name": "UDP-STATS-REPLY-BACKPRESSURE",
        "srcs": ["rtl/net/udp_stats_reply.v",
                 "sim/tb/tb_udp_stats_reply_backpressure.v"],
        "out": "sim/tb_udp_stats_reply_backpressure.vvp",
    },
    {
        "name": "ARTY-TX-ARBITER",
        "srcs": ["fpga/arty_a7/rtl/arty_tx_arbiter.v", "sim/tb/tb_arty_tx_arbiter.v"],
        "out": "sim/tb_arty_tx_arbiter.vvp",
    },
    {
        "name": "AXIL-ARB2",
        "srcs": ["rtl/axil_arb2.v", "sim/tb/tb_axil_arb2.v"],
        "out": "sim/tb_axil_arb2.vvp",
    },
    {
        "name": "UDP-BLAST-PATH",
        "srcs": ["rtl/crc32.v", "rtl/eth_mac_tx.v", "rtl/net/net_rx.v",
                 "rtl/net/udp_blast_trigger.v", "rtl/net/udp_blast.v",
                 "sim/tb/tb_udp_blast_path.v"],
        "out": "sim/tb_udp_blast_path.vvp",
    },
    {
        "name": "UDP-STATS-REPLY",
        "srcs": ["rtl/net/udp_stats_reply.v", "sim/tb/tb_udp_stats_reply.v"],
        "out": "sim/tb_udp_stats_reply.vvp",
    },
    {
        "name": "ETH-MAC-SYS-CSUM",
        "srcs": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                 "rtl/sync_fifo.v", "rtl/eth_mac_rx.v", "rtl/eth_mac_tx.v",
                 "rtl/eth_stats.v", "rtl/eth_pause.v", "rtl/axilite_regs.v", "rtl/mdio_master.v",
                 "rtl/ddr_output.v", "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                 "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v",
                 "rtl/mii_tx_saf.v", "rtl/eth_mac_sys.v",
                 "sim/tb/tb_eth_mac_sys_csum.v"],
        "out": "sim/tb_eth_mac_sys_csum.vvp",
        "iverilog_args": "-DTB_TX_CSUM_OFFLOAD",
        "sim_timeout": 60,
    },
    {
        "name": "ETH-MAC-SYS-CSUM-BYPASS",
        "srcs": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                 "rtl/sync_fifo.v", "rtl/eth_mac_rx.v", "rtl/eth_mac_tx.v",
                 "rtl/eth_stats.v", "rtl/eth_pause.v", "rtl/axilite_regs.v", "rtl/mdio_master.v",
                 "rtl/ddr_output.v", "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                 "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v",
                 "rtl/mii_tx_saf.v", "rtl/eth_mac_sys.v",
                 "sim/tb/tb_eth_mac_sys_csum.v"],
        "out": "sim/tb_eth_mac_sys_csum_bypass.vvp",
        "sim_timeout": 60,
    },
    {
        "name": "ETH-MAC-SYS-JUMBO",
        "srcs": ["rtl/crc32.v", "rtl/eth_mac_tx.v", "rtl/sync_fifo.v", "rtl/eth_mac_rx.v",
                 "sim/tb/tb_eth_mac_sys_jumbo.v"],
        "out": "sim/tb_eth_mac_sys_jumbo.vvp",
        "sim_timeout": 120,
    },
    {
        "name": "GMII-CDC-RX-OVERFLOW",
        "srcs": ["rtl/async_fifo.v", "rtl/gmii_cdc.v",
                 "sim/tb/tb_gmii_cdc_rx_overflow.v"],
        "out": "sim/tb_gmii_cdc_rx_overflow.vvp",
    },
    {
        "name": "GMII-CDC-RX-OVERFLOW-DIST",
        "srcs": ["rtl/async_fifo.v", "rtl/gmii_cdc.v",
                 "sim/tb/tb_gmii_cdc_rx_overflow.v"],
        "out": "sim/tb_gmii_cdc_rx_overflow_dist.vvp",
        "iverilog_args": "-DGMII_CDC_DISTRIBUTED",
    },
    {
        "name": "GMII-CDC-100M",
        "srcs": ["rtl/async_fifo.v", "rtl/gmii_cdc.v",
                 "sim/tb/tb_gmii_cdc_100m.v"],
        "out": "sim/tb_gmii_cdc_100m.vvp",
    },
    {
        "name": "GMII-CDC-10M",
        "srcs": ["rtl/async_fifo.v", "rtl/gmii_cdc.v",
                 "sim/tb/tb_gmii_cdc_10m.v"],
        "out": "sim/tb_gmii_cdc_10m.vvp",
        "sim_timeout": 60,
    },
    {
        "name": "RGMII-IF-100M",
        "srcs": ["rtl/ddr_input.v", "rtl/ddr_output.v", "rtl/rgmii_if.v",
                 "sim/tb/tb_rgmii_if_100m.v"],
        "out": "sim/tb_rgmii_if_100m.vvp",
    },
    {
        "name": "RGMII-IF-SPEED-SWITCH",
        "srcs": ["rtl/ddr_input.v", "rtl/ddr_output.v", "rtl/rgmii_if.v",
                 "sim/tb/tb_rgmii_if_speed_switch.v"],
        "out": "sim/tb_rgmii_if_speed_switch.vvp",
        "sim_timeout": 60,
    },
    {
        "name": "RGMII-IF-VARIANTS",
        "srcs": ["rtl/ddr_input.v", "rtl/ddr_output.v", "rtl/rgmii_if.v",
                 "sim/tb/tb_rgmii_if_variants.v"],
        "out": "sim/tb_rgmii_if_variants.vvp",
    },
    {
        "name": "RGMII-LOOPBACK",
        "srcs": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                 "rtl/sync_fifo.v", "rtl/eth_mac_rx.v", "rtl/eth_mac_tx.v",
                 "rtl/eth_stats.v", "rtl/eth_pause.v", "rtl/axilite_regs.v", "rtl/mdio_master.v",
                 "rtl/ddr_output.v", "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                 "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v",
                 "rtl/mii_tx_saf.v", "rtl/eth_mac_sys.v",
                 "sim/tb/tb_rgmii_loopback.v"],
        "out": "sim/tb_rgmii_loopback.vvp",
        "sim_timeout": 300,
    },
    {
        "name": "RGMII-100M-LOOPBACK",
        "srcs": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                 "rtl/sync_fifo.v", "rtl/eth_mac_rx.v", "rtl/eth_mac_tx.v",
                 "rtl/eth_stats.v", "rtl/eth_pause.v", "rtl/axilite_regs.v", "rtl/mdio_master.v",
                 "rtl/ddr_output.v", "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                 "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v",
                 "rtl/mii_tx_saf.v", "rtl/eth_mac_sys.v",
                 "sim/tb/tb_rgmii_10_100_loopback.v"],
        "out": "sim/tb_rgmii_100m_loopback.vvp",
        "sim_timeout": 300,
    },
    {
        "name": "RGMII-10M-LOOPBACK",
        "srcs": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                 "rtl/sync_fifo.v", "rtl/eth_mac_rx.v", "rtl/eth_mac_tx.v",
                 "rtl/eth_stats.v", "rtl/eth_pause.v", "rtl/axilite_regs.v", "rtl/mdio_master.v",
                 "rtl/ddr_output.v", "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                 "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v",
                 "rtl/mii_tx_saf.v", "rtl/eth_mac_sys.v",
                 "sim/tb/tb_rgmii_10_100_loopback.v"],
        "out": "sim/tb_rgmii_10m_loopback.vvp",
        "iverilog_args": "-DRGMII_10M",
        "sim_timeout": 300,
    },
    {
        "name": "GMII-LOOPBACK",
        "srcs": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                 "rtl/sync_fifo.v", "rtl/eth_mac_rx.v", "rtl/eth_mac_tx.v",
                 "rtl/eth_stats.v", "rtl/eth_pause.v", "rtl/axilite_regs.v", "rtl/mdio_master.v",
                 "rtl/ddr_output.v", "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                 "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v",
                 "rtl/mii_tx_saf.v", "rtl/eth_mac_sys.v",
                 "sim/tb/tb_gmii_loopback.v"],
        "out": "sim/tb_gmii_loopback.vvp",
        "sim_timeout": 300,
    },
    {
        "name": "ETH-MAC-SYS-MAX-FRAME",
        "srcs": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                 "rtl/sync_fifo.v", "rtl/eth_mac_rx.v", "rtl/eth_mac_tx.v",
                 "rtl/eth_stats.v", "rtl/eth_pause.v", "rtl/axilite_regs.v", "rtl/mdio_master.v",
                 "rtl/ddr_output.v", "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                 "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v",
                 "rtl/mii_tx_saf.v", "rtl/eth_mac_sys.v",
                 "sim/tb/tb_eth_mac_sys_max_frame.v"],
        "out": "sim/tb_eth_mac_sys_max_frame.vvp",
    },
    {
        "name": "GMII-RX-LINE-RATE",
        "srcs": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                 "rtl/sync_fifo.v", "rtl/eth_mac_rx.v", "rtl/eth_mac_tx.v",
                 "rtl/eth_stats.v", "rtl/eth_pause.v", "rtl/axilite_regs.v", "rtl/mdio_master.v",
                 "rtl/ddr_output.v", "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                 "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v",
                 "rtl/mii_tx_saf.v", "rtl/eth_mac_sys.v",
                 "sim/tb/tb_gmii_rx_line_rate.v"],
        "out": "sim/tb_gmii_rx_line_rate.vvp",
        "sim_timeout": 300,
    },
    {
        "name": "GMII-LB-SELFTEST",
        "srcs": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                 "rtl/sync_fifo.v", "rtl/eth_mac_rx.v", "rtl/eth_mac_tx.v",
                 "rtl/eth_stats.v", "rtl/eth_pause.v", "rtl/axilite_regs.v", "rtl/mdio_master.v",
                 "rtl/ddr_output.v", "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                 "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v",
                 "rtl/mii_tx_saf.v", "rtl/eth_mac_sys.v",
                 "fpga/arty_a7/rtl/gmii_lb_selftest.v",
                 "sim/tb/tb_gmii_lb_selftest.v"],
        "out": "sim/tb_gmii_lb_selftest.vvp",
        "sim_timeout": 300,
    },
    {
        "name": "ZCU106-I2C-INIT",
        "srcs": ["fpga/zcu106/rtl/i2c_init.v",
                 "sim/tb/tb_zcu106_i2c_init.v"],
        "out": "sim/tb_zcu106_i2c_init.vvp",
        "iverilog_args": "-Ifpga/zcu106/rtl",
        "sim_timeout": 120,
    },
    {
        "name": "ZCU106-SFP-LB",
        "srcs": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                 "rtl/sync_fifo.v", "rtl/eth_mac_rx.v", "rtl/eth_mac_tx.v",
                 "rtl/eth_stats.v", "rtl/eth_pause.v", "rtl/axilite_regs.v", "rtl/mdio_master.v",
                 "rtl/ddr_output.v", "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                 "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v",
                 "rtl/mii_tx_saf.v", "rtl/eth_mac_sys.v",
                 "rtl/net/net_rx.v", "rtl/net/icmp_echo.v", "rtl/net/udp_echo.v",
                 "fpga/arty_a7/rtl/arp_responder.v",
                 "fpga/arty_a7/rtl/arty_tx_arbiter.v",
                 "rtl/net/udp_blast.v", "rtl/net/udp_blast_trigger.v",
                 "rtl/net/udp_iperf_sink.v", "rtl/net/udp_stats_reply.v",
                 "fpga/zcu106/rtl/zcu106_eth_demo.v",
                 "fpga/zcu106/rtl/sfp_lb_tester.v",
                 "sim/tb/tb_zcu106_sfp_lb.v"],
        "out": "sim/tb_zcu106_sfp_lb.vvp",
        "sim_timeout": 600,
    },
    {
        "name": "ZCU106-PERF",
        "srcs": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                 "rtl/sync_fifo.v", "rtl/eth_mac_rx.v", "rtl/eth_mac_tx.v",
                 "rtl/eth_stats.v", "rtl/eth_pause.v", "rtl/axilite_regs.v", "rtl/mdio_master.v",
                 "rtl/ddr_output.v", "rtl/ddr_input.v", "rtl/rgmii_if.v", "rtl/gmii_if.v",
                 "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v",
                 "rtl/mii_tx_saf.v", "rtl/eth_mac_sys.v",
                 "rtl/net/net_rx.v", "rtl/net/icmp_echo.v", "rtl/net/udp_echo.v",
                 "rtl/net/udp_blast.v", "rtl/net/udp_blast_trigger.v",
                 "rtl/net/udp_iperf_sink.v", "rtl/net/udp_stats_reply.v",
                 "fpga/arty_a7/rtl/arp_responder.v",
                 "fpga/arty_a7/rtl/arty_tx_arbiter.v",
                 "fpga/zcu106/rtl/zcu106_eth_demo.v",
                 "sim/tb/tb_zcu106_perf.v"],
        "out": "sim/tb_zcu106_perf.vvp",
        "sim_timeout": 1200,
    },
]


def _sim_result(name, rc, combined):
    """Report one testbench run: it passes only if vvp exited 0, printed
    ALL TESTS PASSED and printed no FAIL line."""
    failed = any(ln.strip().startswith("FAIL") for ln in combined.splitlines())
    if rc == 0 and "ALL TESTS PASSED" in combined and not failed:
        pass_count = combined.count("PASS:")
        if pass_count == 0:
            for pattern in [r"(\d+)\s+tests passed", r"(\d+)\s+PASS"]:
                m = re.search(pattern, combined, re.IGNORECASE)
                if m:
                    pass_count = int(m.group(1))
                    break
        ok(f"{name}: {pass_count} tests passed")
        return True
    fail(f"{name}: simulation failed (rc={rc})")
    for line in combined.splitlines():
        if "FAIL" in line or "PASS" in line or "Error" in line:
            print(f"    {line.strip()}")
    if rc == -1:
        print(f"    (timeout or command not found)")
    return False


def run_simulation():
    header("PHASE 1: Simulation (Icarus Verilog)")
    all_pass = True
    run_dir = os.path.join(PROJECT_DIR, "sim", f".run_{os.getpid()}")
    os.makedirs(run_dir, exist_ok=True)

    for t in TESTS:
        srcs = " ".join(os.path.join(PROJECT_DIR, s) for s in t["srcs"])
        out_name = os.path.basename(t["out"])
        out = os.path.join(run_dir, out_name)

        extra_args = t.get("iverilog_args", "")
        rc, stdout, stderr = run_cmd(
            f'{IVERILOG_BIN} -g2001 -DSIM {extra_args} {_incdir_args()} -o "{out}" {srcs}',
            cwd=PROJECT_DIR, timeout=30
        )
        if rc != 0:
            fail(f"{t['name']}: compile error")
            print(f"    {stderr.strip()[:200]}")
            all_pass = False
            continue

        sim_timeout = t.get("sim_timeout", 60)
        rc, stdout, stderr = run_cmd(
            f'{VVP_BIN} "{out}"',
            cwd=run_dir, timeout=sim_timeout
        )

        if not _sim_result(t["name"], rc, stdout + stderr):
            all_pass = False

    if all_pass:
        print(f"\n  {C.GREEN}{C.BOLD}All simulations passed.{C.END}")
    else:
        print(f"\n  {C.RED}{C.BOLD}Simulation failures detected.{C.END}")
    return all_pass


# RGMII testbenches rerun on the Xilinx simulation models of the DDR cells
# (Vivado's unisims) instead of the behavioral SIM model in ddr_input.v /
# ddr_output.v. That model was once wrong (it sampled d2 on the falling edge)
# and every RGMII test passed against it.
RGMII_VENDOR_TBS = [
    ("RGMII-IF", 300),
    ("RGMII-IF-100M", 300),
    ("RGMII-IF-SPEED-SWITCH", 300),
    ("RGMII-IF-VARIANTS", 300),
]
# (label, wrapper define, unisim model files)
XILINX_DDR_FAMILIES = [
    ("7-series", "XILINX_7SERIES", ["ODDR.v", "IDDR.v"]),
    ("UltraScale+", "XILINX_ULTRASCALE_PLUS", ["ODDRE1.v", "IDDRE1.v"]),
]


def _ddr_wrappers_support(define):
    """True if both DDR wrappers have a branch for this vendor define."""
    return all(define in _read(os.path.join(PROJECT_DIR, "rtl", f))
               for f in ("ddr_input.v", "ddr_output.v"))


def run_vendor_ddr_sims():
    """Run the RGMII testbenches on Vivado's DDR cell models.

    Skipped (not failed) where Vivado is unavailable, like PHASE 0c.
    """
    header("PHASE 1b: RGMII on the Xilinx DDR cell models")
    vivado = _find_vivado()
    if not vivado:
        print(f"  {C.YELLOW}SKIP{C.END} Vivado not found on PATH - RGMII is "
              "only checked against the behavioral DDR model")
        return True
    src = os.path.join(os.path.dirname(os.path.dirname(vivado)),
                       "data", "verilog", "src")
    if not os.path.isfile(os.path.join(src, "glbl.v")):
        fail(f"Vivado simulation models not found under {src}")
        return False

    by_name = {t["name"]: t for t in TESTS}
    run_dir = os.path.join(PROJECT_DIR, "sim", f".run_{os.getpid()}")
    os.makedirs(run_dir, exist_ok=True)
    all_pass = True
    for label, define, models in XILINX_DDR_FAMILIES:
        if not _ddr_wrappers_support(define):
            print(f"  {C.YELLOW}SKIP{C.END} {label}: rtl/ddr_input.v / "
                  f"ddr_output.v have no {define} branch")
            continue
        libs = [os.path.join(src, "glbl.v")] + \
               [os.path.join(src, "unisims", m) for m in models]
        for name, sim_timeout in RGMII_VENDOR_TBS:
            t = by_name[name]
            top = os.path.splitext(os.path.basename(t["srcs"][-1]))[0]
            srcs = " ".join(f'"{s}"' for s in libs) + " " + \
                   " ".join(os.path.join(PROJECT_DIR, s) for s in t["srcs"])
            out = os.path.join(run_dir, f"{top}_{define}.vvp")
            rc, stdout, stderr = run_cmd(
                f'{IVERILOG_BIN} -g2005 -D{define} {_incdir_args()} '
                f'-s {top} -s glbl -o "{out}" {srcs}',
                cwd=PROJECT_DIR, timeout=60
            )
            if rc != 0:
                fail(f"{name} ({label} models): compile error")
                print(f"    {stderr.strip()[:200]}")
                all_pass = False
                continue
            rc, stdout, stderr = run_cmd(f'{VVP_BIN} "{out}"', cwd=run_dir,
                                         timeout=sim_timeout)
            if not _sim_result(f"{name} ({label} models)", rc, stdout + stderr):
                all_pass = False
    return all_pass


# rgmii_if alone through synthesis, place and route for every RGMII_SPEEDS on
# one part per family. No board build uses RGMII, so without this nothing
# would notice RGMII becoming unimplementable (as it once was, on every part).
RGMII_IMPL_PARTS = [
    ("7-series", "XILINX_7SERIES", "xc7a100tcsg324-1"),
    ("UltraScale+", "XILINX_ULTRASCALE_PLUS", "xczu7ev-ffvc1156-2-e"),
]


def run_rgmii_impl():
    """Opt-in (--impl): implement rgmii_if on each family. About 10 minutes."""
    header("PHASE 3: RGMII implementation check (Vivado)")
    vivado = _find_vivado()
    if not vivado:
        fail("Vivado not found on PATH (--impl needs it)")
        return False
    all_pass = True
    for label, define, part in RGMII_IMPL_PARTS:
        if not _ddr_wrappers_support(define):
            print(f"  {C.YELLOW}SKIP{C.END} {label}: rtl/ddr_input.v / "
                  f"ddr_output.v have no {define} branch")
            continue
        for speeds in ("ALL", "1G_ONLY", "10_100"):
            cmd = (f'"{vivado}" -mode batch -source "{RGMII_IMPL_TCL}" '
                   f'-nojournal -nolog -tclargs "{PROJECT_DIR}" {speeds} '
                   f'{part} {define}')
            rc, stdout, stderr = run_cmd(cmd, cwd=PROJECT_DIR, timeout=1800)
            output = stdout + stderr
            m = re.search(r"^RGMII_IMPL (OK|FAIL) \S+ \S+ (.*)$", output,
                          re.MULTILINE)
            if rc == 0 and m and m.group(1) == "OK":
                ok(f"RGMII {label} {speeds} ({part}): {m.group(2)}")
                continue
            fail(f"RGMII {label} {speeds} ({part}) rc={rc}")
            if m:
                print(f"    {m.group(2)[:300]}")
            # The step that failed often only says "failed due to earlier
            # errors"; the DRC or placer errors themselves come before it.
            errors = [ln for ln in output.splitlines()
                      if ln.startswith("ERROR") and "17-39" not in ln]
            for line in (errors or output.splitlines()[-10:])[:6]:
                print(f"    {line[:300]}")
            all_pass = False
    return all_pass


def run_cocotb():
    header("PHASE 2: cocotb (directed + randomized)")
    try:
        import cocotb  # noqa: F401
    except Exception:
        print(f"  {C.YELLOW}SKIP{C.END} cocotb not installed "
              "(pip install 'cocotb>=2.0') - randomized suite not run")
        return True

    runner = os.path.join(PROJECT_DIR, "sim", "cocotb", "run.py")
    if not os.path.exists(runner):
        fail("cocotb runner missing")
        return False

    rc, stdout, stderr = run_cmd(
        f'"{sys.executable}" "{runner}"', cwd=PROJECT_DIR, timeout=1800
    )
    combined = stdout + stderr
    for line in combined.splitlines():
        if re.search(r"TESTS=\d", line):
            print(f"    {line.strip()}")

    if rc == 0:
        ok("cocotb suite (mii_tx_saf: directed + randomized)")
        return True

    fail(f"cocotb suite (mii_tx_saf) rc={rc}")
    for line in combined.splitlines():
        if "failed" in line.lower() or "random seed =" in line.lower():
            print(f"    {line.strip()[:160]}")  # seeds shown for deterministic replay
    return False


def main():
    parser = argparse.ArgumentParser(description="emacZero — Build & Test")
    parser.add_argument("--sim-only", action="store_true", help="Run simulation only")
    parser.add_argument("--impl", action="store_true",
                        help="Also implement rgmii_if on 7-series and "
                             "UltraScale+ parts (Vivado, about 10 minutes)")
    args = parser.parse_args()

    print(f"{C.BOLD}")
    print("  +----------------------------------------------+")
    print("  |       emacZero — Ethernet MAC Test Suite      |")
    print("  +----------------------------------------------+")
    print(f"{C.END}")

    version_ok = run_version_check()
    lint_ok = run_lint()
    verilator_ok = run_verilator_lint()
    elab_ok = run_vivado_elab()
    sim_ok = run_simulation()
    vendor_ok = run_vendor_ddr_sims()
    cocotb_ok = run_cocotb()
    impl_ok = run_rgmii_impl() if args.impl else True

    if (version_ok and lint_ok and verilator_ok and elab_ok
            and sim_ok and vendor_ok and cocotb_ok and impl_ok):
        print(f"\n{C.GREEN}{C.BOLD}All tests passed.{C.END}")
        sys.exit(0)
    else:
        print(f"\n{C.RED}{C.BOLD}Some tests failed.{C.END}")
        sys.exit(1)


if __name__ == "__main__":
    main()
