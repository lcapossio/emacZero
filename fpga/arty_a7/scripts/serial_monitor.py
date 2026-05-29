#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
"""
serial_monitor.py - Host-side UART monitor and Ethernet test for emacZero Arty A7.

Phase 1 (UART): Reads test output at 115200 baud, parses results, checks PASS/FAIL.
                When TX is printed, starts pinging to generate RX traffic.
Phase 2 (Net):  After DONE, waits for arp_responder to take over the TX bus,
                then verifies the board is actually pingable (ICMP echo reply)
                and checks the ARP table for the correct board MAC address.

Usage:
  python serial_monitor.py                   # auto-detect COM port
  python serial_monitor.py --port PORT       # specify serial port
  python serial_monitor.py --timeout 30      # wait up to 30s (default: 15)
  python serial_monitor.py --board-ip 192.168.137.200

Requires: pip install pyserial
"""

import argparse
import platform
import re
import shutil
import subprocess
import sys
import threading
import time

try:
    import serial
    import serial.tools.list_ports
except ImportError:
    print("ERROR: pyserial not installed. Run: pip install pyserial")
    sys.exit(1)


BOARD_IP = "192.168.137.200"
BOARD_MAC = "02-00-00-00-00-01"


def find_arty_port():
    """Auto-detect Arty A7 USB-UART port."""
    ports = serial.tools.list_ports.comports()
    for p in ports:
        # Digilent FT2232 channel B is the Arty USB-UART. Prefer PID 0x6010
        # before other FTDI serial adapters that may also expose channel B.
        if p.vid == 0x0403 and p.pid == 0x6010 and (p.serial_number or "").endswith("B"):
            return p.device
    for p in ports:
        desc = (p.description or "").lower()
        vid = p.vid or 0
        # Digilent/FTDI: VID 0x0403
        if vid == 0x0403 or "digilent" in desc or "ft2232" in desc or "usb serial" in desc:
            return p.device
    # Fallback: return first available port
    if ports:
        return ports[0].device
    return None


def ping_board(ip, count=5):
    """Send pings to the board to generate RX traffic. Runs in background thread."""
    try:
        subprocess.run(
            ping_command(ip, count, timeout_ms=500, size=64),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=10,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass


def run_ping_test(ip, count=10):
    """Ping the board and return (sent, received) counts."""
    proc_timeout = max(30, count + 10)
    try:
        result = subprocess.run(
            ping_command(ip, count, timeout_ms=1000, size=64),
            capture_output=True, text=True, timeout=proc_timeout,
        )
        output = result.stdout
        m = re.search(r"Sent\s*=\s*(\d+).*Received\s*=\s*(\d+)", output)
        if m:
            return int(m.group(1)), int(m.group(2))
        m = re.search(r"(\d+)\s+packets transmitted,\s+(\d+)\s+(?:packets )?received", output)
        if m:
            return int(m.group(1)), int(m.group(2))
        return count, 0
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return count, 0


def check_arp_table(ip):
    """Check ARP table for the board's MAC. Returns the MAC string or None."""
    if platform.system().lower().startswith("win"):
        return check_arp_table_windows(ip)
    return check_arp_table_posix(ip)


def ping_command(ip, count, timeout_ms, size):
    """Return a platform-appropriate ping command."""
    system = platform.system().lower()
    if system.startswith("win"):
        return ["ping", "-n", str(count), "-w", str(timeout_ms), "-l", str(size), ip]
    if system == "darwin":
        return ["ping", "-c", str(count), "-W", str(timeout_ms), "-s", str(size), ip]
    return ["ping", "-c", str(count), "-W", str(max(1, timeout_ms // 1000)), "-s", str(size), ip]


def check_arp_table_windows(ip):
    """Check Windows neighbor table for the board's MAC."""
    powershell = shutil.which("powershell") or shutil.which("pwsh")
    if not powershell:
        return None
    try:
        result = subprocess.run(
            [powershell,
             "-NoProfile",
             "-Command",
             f"Get-NetNeighbor -IPAddress {ip} -ErrorAction SilentlyContinue "
             "| Select-Object -ExpandProperty LinkLayerAddress"],
            capture_output=True, text=True, timeout=10,
        )
        mac = result.stdout.strip()
        return mac if mac else None
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None


def check_arp_table_posix(ip):
    """Check POSIX ARP/neighbor table for the board's MAC."""
    arp = shutil.which("arp")
    if not arp:
        return None
    try:
        result = subprocess.run(
            [arp, "-n", ip],
            capture_output=True, text=True, timeout=10,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None
    m = re.search(r"(([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2})", result.stdout)
    return m.group(1).replace(":", "-").upper() if m else None


def run_monitor(port, baud, timeout, board_ip, sustained_ping_count):
    """Connect to serial port, read lines, parse results, then run network tests."""
    print(f"Connecting to {port} at {baud} baud...")
    try:
        ser = serial.Serial(port, baud, timeout=1)
    except serial.SerialException as e:
        print(f"ERROR: Cannot open {port}: {e}")
        return False

    results = {}
    start = time.time()
    done = False
    ping_started = False

    print(f"Waiting for test output (timeout: {timeout}s)...\n")
    print("-" * 50)

    while (time.time() - start) < timeout and not done:
        try:
            line = ser.readline().decode("ascii", errors="replace").strip()
        except serial.SerialException:
            break

        if not line:
            continue

        print(f"  {line}")

        if line.startswith("VER: "):
            results["VER"] = line[5:]
        elif line.startswith("SCR: "):
            results["SCR"] = line[5:]
        elif line.startswith("PHY1: "):
            results["PHY1"] = line[6:]
        elif line.startswith("PHY2: "):
            results["PHY2"] = line[6:]
        elif line.startswith("BMCR: "):
            results["BMCR"] = line[6:]
        elif line.startswith("LINK: "):
            results["LINK"] = line[6:]
        elif line.startswith("TX: "):
            results["TX"] = line[4:]
            # TX printed means ARP was sent — start pinging to generate RX
            if not ping_started:
                ping_started = True
                print(f"  [host] Pinging {board_ip} to generate RX traffic...")
                t = threading.Thread(target=ping_board, args=(board_ip,), daemon=True)
                t.start()
        elif line.startswith("RX: "):
            results["RX"] = line[4:]
        elif line == "DONE":
            done = True

    print("-" * 50)
    ser.close()

    if not done:
        print("\nWARNING: Test did not complete within timeout.")

    # =====================================================================
    # Phase 1: UART results
    # =====================================================================
    print("\n=== PHASE 1: UART Test Results ===\n")
    all_pass = True

    def check(name, value, expected, prefix_match=False):
        nonlocal all_pass
        if name not in results:
            print(f"  FAIL  {name}: not received")
            all_pass = False
            return
        actual = results[name]
        if prefix_match:
            ok = actual.upper().startswith(expected.upper())
        else:
            ok = actual.upper() == expected.upper()
        if ok:
            print(f"  PASS  {name}: {actual}")
        else:
            print(f"  FAIL  {name}: {actual} (expected {expected})")
            all_pass = False

    check("VER", results.get("VER", ""), "0001454D")
    check("SCR", results.get("SCR", ""), "DEADBEEF")
    check("PHY1", results.get("PHY1", ""), "2000")
    check("PHY2", results.get("PHY2", ""), "5C9", prefix_match=True)
    bmcr = results.get("BMCR")
    if bmcr is None:
        print("  FAIL  BMCR: not received")
        all_pass = False
    else:
        try:
            bmcr_val = int(bmcr, 16)
        except ValueError:
            bmcr_val = -1
        # test_sequencer writes 0x1200 to restart autonegotiation. The restart
        # bit is self-clearing in the PHY, so readback may be 0x1000.
        if (bmcr_val & 0x1000) and not (bmcr_val & 0x0800):
            print(f"  PASS  BMCR: {bmcr}")
        else:
            print(f"  FAIL  BMCR: {bmcr} (expected autoneg enabled, power-up)")
            all_pass = False

    # Link: must be UP for real Ethernet test
    link = results.get("LINK", "?")
    if link == "UP":
        print(f"  PASS  LINK: {link}")
    else:
        print(f"  FAIL  LINK: {link} (expected UP)")
        all_pass = False

    if link == "UP":
        # TX: must have sent at least 1 frame (the ARP)
        if "TX" in results:
            tx_val = results["TX"]
            if tx_val != "0000":
                print(f"  PASS  TX: {tx_val}")
            else:
                print(f"  FAIL  TX: 0 frames sent")
                all_pass = False
        else:
            print("  FAIL  TX: not received")
            all_pass = False

        # RX: must have received at least 1 frame (from ping)
        if "RX" in results:
            rx_val = results["RX"]
            if rx_val.startswith("TO"):
                print(f"  FAIL  RX: timeout (no frames received)")
                all_pass = False
            elif rx_val != "0000":
                print(f"  PASS  RX: {rx_val}")
            else:
                print(f"  FAIL  RX: 0 frames received")
                all_pass = False
        else:
            print("  FAIL  RX: not received")
            all_pass = False
    else:
        print("  SKIP  TX/RX: no link")

    # =====================================================================
    # Phase 2: Network tests (ARP + ICMP echo after test_sequencer DONE)
    # =====================================================================
    if link == "UP":
        print("\n=== PHASE 2: Network Tests (ARP + ICMP) ===\n")

        # Give the network stack a moment to be ready
        time.sleep(0.5)

        # Test 1: ICMP echo — the authoritative proof of bidirectional data
        # integrity. The board must receive the frame, parse Eth+IP+ICMP, build
        # a reply with correct IP + ICMP checksums, and transmit it; the host OS
        # validates every checksum before reporting success. A successful ping
        # also proves ARP resolved, since the host cannot ping without it. This
        # runs first so it doubles as the ARP-cache warmup.
        print(f"  Pinging {board_ip} (20 packets, ICMP echo test)...")
        sent, received = run_ping_test(board_ip, count=20)
        loss_pct = 100.0 * (sent - received) / sent if sent > 0 else 100.0
        icmp_ok = received >= 18  # allow up to 10% loss
        if icmp_ok:
            print(f"  PASS  ICMP: {received}/{sent} replies ({loss_pct:.0f}% loss)")
        elif received > 0:
            print(f"  FAIL  ICMP: {received}/{sent} replies ({loss_pct:.0f}% loss, >10%)")
            all_pass = False
        else:
            print(f"  FAIL  ICMP: 0/{sent} replies (icmp_echo not responding)")
            all_pass = False

        # Test 2: ARP resolution — cross-check the board MAC in the host
        # neighbor table. This is a host-side convenience check: some hosts
        # (multiple NICs, or a neighbor cache that drops idle entries) report no
        # entry even though ARP clearly resolved. A missing entry is therefore
        # non-fatal when ICMP already proved reachability; only a *wrong* MAC,
        # or a missing entry with no ICMP proof, is a failure.
        expected_mac = BOARD_MAC.upper()
        mac = check_arp_table(board_ip)
        if mac and mac.upper() == expected_mac:
            print(f"  PASS  ARP: {board_ip} -> {mac}")
        elif mac:
            print(f"  FAIL  ARP: {board_ip} -> {mac} (expected {expected_mac})")
            all_pass = False
        elif icmp_ok:
            print(f"  PASS  ARP: no host neighbor-cache entry, but ICMP echo "
                  f"confirms {board_ip} resolved")
        else:
            print(f"  FAIL  ARP: no entry for {board_ip}")
            all_pass = False

        # Test 3: Sustained ping — verify no degradation over time
        if sustained_ping_count <= 0:
            sent2 = 0
            received2 = 0
            loss_pct2 = 0.0
        else:
            print(f"  Pinging {board_ip} ({sustained_ping_count} packets, sustained test)...")
            sent2, received2 = run_ping_test(board_ip, count=sustained_ping_count)
            loss_pct2 = 100.0 * (sent2 - received2) / sent2 if sent2 > 0 else 100.0
        if sustained_ping_count <= 0:
            pass
        elif received2 >= ((sustained_ping_count * 9 + 9) // 10):  # allow up to 10% loss
            print(f"  PASS  ICMP sustained: {received2}/{sent2} replies ({loss_pct2:.0f}% loss)")
        elif received2 > 0:
            print(f"  FAIL  ICMP sustained: {received2}/{sent2} replies ({loss_pct2:.0f}% loss)")
            all_pass = False
        else:
            print(f"  FAIL  ICMP sustained: 0/{sent2} replies")
            all_pass = False

    print()
    print("=" * 50)
    if all_pass:
        print("  ALL TESTS PASSED")
    else:
        print("  SOME TESTS FAILED")
    print("=" * 50)

    return all_pass


def main():
    parser = argparse.ArgumentParser(description="emacZero Arty A7 hardware test")
    parser.add_argument("--port", help="Serial port (auto-detect if omitted)")
    parser.add_argument("--baud", type=int, default=115200, help="Baud rate")
    parser.add_argument("--timeout", type=int, default=15, help="Timeout in seconds")
    parser.add_argument("--board-ip", default=BOARD_IP,
                        help=f"Board IP for ping test (default: {BOARD_IP})")
    parser.add_argument("--sustained-ping-count", type=int, default=0,
                        help="Optional extra ICMP sustained ping count after the smoke checks")
    args = parser.parse_args()

    port = args.port or find_arty_port()
    if not port:
        print("ERROR: No serial port found. Connect the Arty A7 or specify --port.")
        sys.exit(1)

    ok = run_monitor(port, args.baud, args.timeout, args.board_ip, args.sustained_ping_count)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
