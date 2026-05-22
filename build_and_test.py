#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
"""
build_and_test.py — emacZero: Simulate Ethernet MAC
====================================================
Runs all testbenches via Icarus Verilog.

Usage:
  python build_and_test.py              # run all tests
  python build_and_test.py --sim-only   # same (only sim available)
"""

import argparse
import os
import re
import subprocess
import sys

PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))
IVERILOG_BIN = "iverilog"
VVP_BIN = "vvp"

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
    "rtl/eth_mac_sys.v",
]

LINT_SUPPRESS = [
    "is sensitive to all",
    "timescale",
]


def _incdir_args():
    return " ".join(f'-I"{os.path.join(PROJECT_DIR, d)}"' for d in IVERILOG_INCDIRS)


def run_lint():
    header("PHASE 0: Lint (iverilog -Wall)")
    srcs = " ".join(os.path.join(PROJECT_DIR, s) for s in LINT_SOURCES)
    null_out = os.path.join(PROJECT_DIR, "sim", "lint_check.vvp")
    os.makedirs(os.path.join(PROJECT_DIR, "sim"), exist_ok=True)

    rc, stdout, stderr = run_cmd(
        f'{IVERILOG_BIN} -g2001 -Wall {_incdir_args()} -o "{null_out}" {srcs}',
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
        "name": "ETH-MAC-FCS",
        "srcs": ["rtl/crc32.v", "rtl/eth_mac_tx.v", "sim/tb/tb_eth_mac_fcs.v"],
        "out": "sim/tb_eth_mac_fcs.vvp",
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
        "name": "MII-RX-REPLAY-STRESS",
        "srcs": ["sim/tb/xpm_fifo_async_model.v", "rtl/async_fifo.v", "rtl/mii_if.v",
                 "sim/tb/tb_mii_rx_replay_stress.v"],
        "out": "sim/tb_mii_rx_replay_stress.vvp",
        "iverilog_args": "-DSYNTHESIS",
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
                 "rtl/ddr_output.v", "rtl/ddr_input.v", "rtl/rgmii_if.v",
                 "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v",
                 "rtl/eth_mac_sys.v",
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
        "name": "ARTY-TX-ARBITER",
        "srcs": ["fpga/arty_a7/rtl/arty_tx_arbiter.v", "sim/tb/tb_arty_tx_arbiter.v"],
        "out": "sim/tb_arty_tx_arbiter.vvp",
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
                 "rtl/ddr_output.v", "rtl/ddr_input.v", "rtl/rgmii_if.v",
                 "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v",
                 "rtl/eth_mac_sys.v",
                 "sim/tb/tb_eth_mac_sys_csum.v"],
        "out": "sim/tb_eth_mac_sys_csum.vvp",
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
                 "rtl/ddr_output.v", "rtl/ddr_input.v", "rtl/rgmii_if.v",
                 "rtl/gmii_cdc.v", "rtl/net/tx_csum_off.v",
                 "rtl/eth_mac_sys.v",
                 "sim/tb/tb_rgmii_loopback.v"],
        "out": "sim/tb_rgmii_loopback.vvp",
        "sim_timeout": 300,
    },
]


def run_simulation():
    header("PHASE 1: Simulation (Icarus Verilog)")
    all_pass = True

    for t in TESTS:
        srcs = " ".join(os.path.join(PROJECT_DIR, s) for s in t["srcs"])
        out = os.path.join(PROJECT_DIR, t["out"])

        extra_args = t.get("iverilog_args", "")
        rc, stdout, stderr = run_cmd(
            f'{IVERILOG_BIN} -g2001 {extra_args} {_incdir_args()} -o "{out}" {srcs}',
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
            cwd=PROJECT_DIR, timeout=sim_timeout
        )

        combined = stdout + stderr
        if "ALL TESTS PASSED" in combined:
            pass_count = combined.count("PASS:")
            if pass_count == 0:
                for pattern in [r"(\d+)\s+tests passed", r"(\d+)\s+PASS"]:
                    m = re.search(pattern, combined, re.IGNORECASE)
                    if m:
                        pass_count = int(m.group(1))
                        break
            ok(f"{t['name']}: {pass_count} tests passed")
        else:
            fail(f"{t['name']}: simulation failed (rc={rc})")
            for line in combined.splitlines():
                if "FAIL" in line or "PASS" in line or "Error" in line:
                    print(f"    {line.strip()}")
            if rc == -1:
                print(f"    (timeout or command not found)")
            all_pass = False

    if all_pass:
        print(f"\n  {C.GREEN}{C.BOLD}All simulations passed.{C.END}")
    else:
        print(f"\n  {C.RED}{C.BOLD}Simulation failures detected.{C.END}")
    return all_pass


def main():
    parser = argparse.ArgumentParser(description="emacZero — Build & Test")
    parser.add_argument("--sim-only", action="store_true", help="Run simulation only")
    args = parser.parse_args()

    print(f"{C.BOLD}")
    print("  +----------------------------------------------+")
    print("  |       emacZero — Ethernet MAC Test Suite      |")
    print("  +----------------------------------------------+")
    print(f"{C.END}")

    version_ok = run_version_check()
    lint_ok = run_lint()
    sim_ok = run_simulation()

    if version_ok and lint_ok and sim_ok:
        print(f"\n{C.GREEN}{C.BOLD}All tests passed.{C.END}")
        sys.exit(0)
    else:
        print(f"\n{C.RED}{C.BOLD}Some tests failed.{C.END}")
        sys.exit(1)


if __name__ == "__main__":
    main()
