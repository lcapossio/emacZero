#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
"""
udp_throughput.py - Host-side UDP throughput test for emacZero Arty A7.

Phase A test: blasts UDP packets at the board at a target rate and reads the
periodic RXF/RXB/RXE/OVF stats lines emitted by test_sequencer over UART.
The board does not echo (Phase B will add udp_echo.v); this measures one-way
RX ingest capacity of the MAC.

Output line format from the board (every ~1 s):
  RXF: XXXXXXXX   (rx_frame_cnt, hex)
  RXB: XXXXXXXX   (rx_byte_cnt, hex)
  RXE: XXXXXXXX   (rx_err_cnt = FCS errors, hex)
  OVF: XXXXXXXX   (rx_err_overflow_cnt, hex)

Usage:
  python udp_throughput.py                        # default 1500B @ 50 Mbps for 10s
  python udp_throughput.py --mbps 100 --secs 5    # try line rate
  python udp_throughput.py --size 64 --mbps 50    # min-size frames
  python udp_throughput.py --port COM4

Requires: pip install pyserial
"""
import argparse
import re
import socket
import sys
import threading
import time

try:
    import serial
    import serial.tools.list_ports
except ImportError:
    print("ERROR: pyserial not installed. Run: pip install pyserial")
    sys.exit(1)


BOARD_IP   = "192.168.137.200"
BOARD_PORT = 9999  # any port — board doesn't bind, just drops at the AXIS sink


def find_arty_port():
    """Return the COM port of the Arty A7 USB-UART (FT2232 channel B)."""
    for p in serial.tools.list_ports.comports():
        if (p.vid == 0x0403) and (p.serial_number or "").endswith("B"):
            return p.device
    for p in serial.tools.list_ports.comports():
        if p.vid == 0x0403:
            return p.device
    return None


# ---------------------------------------------------------------------------
# Sender
# ---------------------------------------------------------------------------
class Sender(threading.Thread):
    def __init__(self, ip, port, payload_size, target_mbps, duration_s):
        super().__init__(daemon=True)
        self.ip          = ip
        self.port        = port
        self.payload     = b"\x55" * payload_size
        self.target_mbps = target_mbps
        self.duration_s  = duration_s
        self.sent_pkts   = 0
        self.sent_bytes  = 0
        self.actual_mbps = 0.0
        self._stop_flag       = False

    def run(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 20)

        psize_wire = 14 + 20 + 8 + max(len(self.payload), 18) + 4 + 8 + 12  # eth+IP+UDP+pad+FCS+preamble+IFG
        bytes_per_sec = self.target_mbps * 1_000_000 / 8
        # Pace via wire bytes (closer to true line-rate budget).
        target_pps    = bytes_per_sec / psize_wire if self.target_mbps > 0 else 1e9

        start = time.time()
        end   = start + self.duration_s
        next_t = start
        interval = (1.0 / target_pps) if target_pps > 0 else 0

        while not self._stop_flag and time.time() < end:
            try:
                sock.sendto(self.payload, (self.ip, self.port))
            except OSError:
                # ARP miss / buffer full — short sleep and retry
                time.sleep(0.001)
                continue
            self.sent_pkts  += 1
            self.sent_bytes += len(self.payload)
            if interval > 0:
                next_t += interval
                slack = next_t - time.time()
                if slack > 0.0005:
                    time.sleep(slack)
                elif slack < -0.05:
                    next_t = time.time()  # we are far behind — give up pacing for a tick

        elapsed = time.time() - start
        sock.close()
        if elapsed > 0:
            self.actual_mbps = self.sent_bytes * 8 / elapsed / 1_000_000

    def stop_sender(self):
        self._stop_flag = True


# ---------------------------------------------------------------------------
# UART monitor
# ---------------------------------------------------------------------------
LINE_RE = re.compile(r"^(RXF|RXB|RXE|OVF):\s*([0-9A-Fa-f]{1,8})$")


def monitor_uart(ser, samples, stop_event):
    """Read UART lines and append (time, key, value) tuples to samples."""
    start = time.time()
    while not stop_event.is_set():
        try:
            line = ser.readline().decode("ascii", errors="replace").strip()
        except serial.SerialException:
            break
        if not line:
            continue
        m = LINE_RE.match(line)
        if m:
            key = m.group(1)
            val = int(m.group(2), 16)
            samples.append((time.time() - start, key, val))


def deltas(samples):
    """Group samples by (key) and emit per-window deltas (t, key, val, dval)."""
    last = {}
    out = []
    for (t, key, v) in samples:
        if key in last:
            out.append((t, key, v, v - last[key]))
        else:
            out.append((t, key, v, 0))
        last[key] = v
    return out


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="emacZero UDP throughput test")
    ap.add_argument("--port", help="Serial port (auto-detect if omitted)")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--ip",   default=BOARD_IP, help=f"Board IP (default {BOARD_IP})")
    ap.add_argument("--udp-port", type=int, default=BOARD_PORT)
    ap.add_argument("--size", type=int, default=1472,
                    help="UDP payload bytes (1472 = 1518 wire frame; 18 = min)")
    ap.add_argument("--mbps", type=float, default=50.0,
                    help="Target Mbps on the wire (0 = unthrottled)")
    ap.add_argument("--secs", type=float, default=10.0,
                    help="Test duration in seconds")
    ap.add_argument("--warmup", type=float, default=2.0,
                    help="Pre-test delay so we capture a baseline RXB sample")
    args = ap.parse_args()

    port = args.port or find_arty_port()
    if not port:
        print("ERROR: no COM port found. Use --port.", file=sys.stderr)
        sys.exit(2)

    print(f"== emacZero UDP throughput test ==")
    print(f"  COM port    : {port}")
    print(f"  Board       : {args.ip}:{args.udp_port}")
    print(f"  Payload     : {args.size} bytes  (~{args.size + 46}-byte wire frame)")
    print(f"  Target rate : {args.mbps:.1f} Mbps for {args.secs:.1f} s")
    print()

    try:
        ser = serial.Serial(port, args.baud, timeout=0.2)
    except serial.SerialException as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(2)

    samples = []
    stop_evt = threading.Event()
    mon = threading.Thread(target=monitor_uart, args=(ser, samples, stop_evt),
                           daemon=True)
    mon.start()

    print(f"-- warmup {args.warmup:.1f}s (baseline) --")
    time.sleep(args.warmup)
    base = {k: v for (_t, k, v) in samples[-8:] if k in ("RXF", "RXB", "RXE", "OVF")}
    if not base:
        print("WARNING: no UART stats received yet; is the bitstream loaded with the new test_sequencer?")

    print(f"-- sending UDP for {args.secs:.1f}s --")
    sender = Sender(args.ip, args.udp_port, args.size, args.mbps, args.secs)
    t0 = time.time()
    sender.start()
    sender.join()
    t_send = time.time() - t0

    # Allow the board one more stats tick to reflect the final bytes
    time.sleep(1.5)
    stop_evt.set()
    mon.join(timeout=2.0)
    ser.close()

    final = {}
    for (_t, k, v) in samples:
        final[k] = v

    print()
    print("-- results --")
    print(f"  Host TX     : {sender.sent_pkts} packets, "
          f"{sender.sent_bytes/1e6:.2f} MB, "
          f"{sender.actual_mbps:.2f} Mbps in {t_send:.2f}s")

    if "RXB" in base and "RXB" in final:
        d_rxb = (final["RXB"] - base["RXB"]) & 0xFFFFFFFF
        d_rxf = (final.get("RXF", 0) - base.get("RXF", 0)) & 0xFFFFFFFF
        d_rxe = (final.get("RXE", 0) - base.get("RXE", 0)) & 0xFFFFFFFF
        d_ovf = (final.get("OVF", 0) - base.get("OVF", 0)) & 0xFFFFFFFF
        # The window used by the board for these deltas is roughly t_send + warmup tail;
        # we approximate using the last and first sample timestamps for these keys.
        ts = [t for (t, k, _v) in samples if k == "RXB"]
        win = ts[-1] - ts[0] if len(ts) >= 2 else max(t_send, 1.0)
        rx_mbps = d_rxb * 8 / win / 1_000_000
        rx_pps  = d_rxf / win
        loss_pct = 100.0 * (sender.sent_pkts - d_rxf) / max(sender.sent_pkts, 1)
        print(f"  Board RX    : {d_rxf} frames, {d_rxb/1e6:.2f} MB, "
              f"{rx_mbps:.2f} Mbps, {rx_pps:.0f} pps over {win:.1f}s")
        print(f"  Frame loss  : {loss_pct:+.2f}%  "
              f"(host_tx_pkts={sender.sent_pkts} - board_rxf={d_rxf})")
        if d_rxe or d_ovf:
            print(f"  ERRORS      : FCS={d_rxe}, OVERFLOW={d_ovf}")
        else:
            print(f"  ERRORS      : none")
    else:
        print("  (no UART RXB samples — verify the new test_sequencer bitstream is loaded)")

    print()
    if "OVF" in final and final["OVF"] != base.get("OVF", 0):
        print("VERDICT: OVERFLOW detected — board RX FIFO saturated. Lower --mbps.")
        sys.exit(1)
    else:
        print("VERDICT: no overflow.")
        sys.exit(0)


if __name__ == "__main__":
    main()
