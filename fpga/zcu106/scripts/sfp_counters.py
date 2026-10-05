#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""sfp_counters.py - Read or clear the ZCU106 demo's frame and PCS counters.

Needs the throughput bitstream (build_zcu106.tcl without lb) on the board and
a hw_server on :3121. Two fcapz cores in zcu106_top, reached through the fcapz
host library from the fcapz submodule:

  USER4  JTAG-to-AXI bridge -> the MAC CSRs: eth_mac_sys statistics
         (TX/RX frames and bytes, RX errors by type)
  USER3  EIO: PCS/PMA status_vector, link-down / sync-loss / RUDI(INVALID)
         events, disparity-error and not-in-table cycles, GMII rx_er events,
         and the blast frames generated

Clear before a run and read after it; do not poll during a throughput run,
since the host load can drop frames on the host side.

    python fpga/zcu106/scripts/sfp_counters.py --clear
    python fpga/zcu106/scripts/sfp_counters.py

Reading the result: TX frames counts the MAC's TX_EN falling edges, every
frame that left the MAC toward the PCS/PMA (blast frames plus ARP / ping /
stats replies). Blast frames generated below what was triggered is a
generator problem. TX frames minus blast frames should be the few replies
the board sent; below zero, the MAC lost frames. A frame lost in the MAC
could hide behind a reply, so a host loss can be put outside the FPGA only
when it is larger than that difference; then it happened in the PCS/PMA,
the SFP, the cable or the host NIC. The PCS event counters show
physical-layer events on the SFP0 receive side.
"""

import argparse
import json
import os
import sys
import time

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
sys.path.insert(0, os.path.join(REPO, "fcapz", "host"))

from fcapz.cli import _chain_shape_kwargs          # noqa: E402
from fcapz.eio import EioController                 # noqa: E402
from fcapz.ejtagaxi import EjtagAxiController       # noqa: E402
from fcapz.transport import XilinxHwServerTransport  # noqa: E402

MARKER, LAYOUT = 0x107, 1

# eth_mac_sys CSRs (axilite_regs.v); each is cleared by any write
MAC_REGS = [
    ("tx_frames", 0x28),
    ("tx_bytes", 0x2C),          # saturates at 2^32 - 1 within one long run
    ("rx_frames", 0x30),
    ("rx_bytes", 0x34),
    ("rx_bad_frames", 0x38),     # every RX frame ending with an error, any cause
    ("rx_err_align", 0x4C),      # rx_er during a frame
    ("rx_err_overflow", 0x50),
    ("rx_err_oversize", 0x54),
    ("pause_rx", 0x8C),          # PAUSE frames received from the link partner
    ("pause_tx", 0x90),
]

# EIO probe_in fields (name, lsb, width), see the counter block in zcu106_top.v
EIO_FIELDS = [
    ("pcs_status", 0, 16),
    ("link_downs", 16, 32),
    ("sync_losses", 48, 32),
    ("rudi_invalid_events", 80, 32),
    ("disperr_cycles", 112, 32),
    ("notintable_cycles", 144, 32),
    ("rx_er_events", 176, 32),
    ("blast_frames", 208, 32),
    ("layout", 240, 4),
    ("marker", 244, 12),
]
EIO_IN_W, EIO_OUT_W = 256, 8
EIO_CLEAR = 0x01
PAUSE_CTRL = 0x84               # [1] honor received PAUSE frames (reset 0)


def transport(args):
    fpga = args.tap.removesuffix(".tap")
    return XilinxHwServerTransport(host=args.host, port=args.port, fpga_name=fpga,
                                   **_chain_shape_kwargs(fpga))


class WrongBuild(Exception):
    """The board is not running the throughput build; retrying cannot help."""


def read_eio(eio):
    # The counters cross into TCK unsynchronized and are read as 32-bit
    # words; take a value only when two whole reads agree.
    prev = None
    for _ in range(10):
        raw = eio.read_inputs()
        if raw == prev:
            return {n: (raw >> lsb) & ((1 << w) - 1) for n, lsb, w in EIO_FIELDS}
        prev = raw
    raise RuntimeError("EIO inputs changed on every read")


def eio_write(eio, value):
    # write_outputs does not report a failed scan; read the value back.
    eio.write_outputs(value)
    got = eio.read_outputs()
    if got != value:
        raise RuntimeError("EIO output reads 0x%02x after writing 0x%02x" % (got, value))


def eio_session(args, clear):
    eio = EioController(transport(args), chain=3)
    try:
        eio.connect()
        if (eio.in_w, eio.out_w) != (EIO_IN_W, EIO_OUT_W):
            raise WrongBuild("EIO on USER3 is %d in / %d out, expected %d / %d"
                             % (eio.in_w, eio.out_w, EIO_IN_W, EIO_OUT_W))
        # Check the build before writing: in the loopback build the same
        # output bit starts the tester.
        fields = read_eio(eio)
        if fields["marker"] != MARKER or fields["layout"] != LAYOUT:
            raise WrongBuild("EIO marker 0x%03x layout %d, expected 0x%03x layout %d"
                             % (fields["marker"], fields["layout"], MARKER, LAYOUT))
        if clear:
            eio_write(eio, EIO_CLEAR)
            time.sleep(0.05)
            eio_write(eio, 0)
            fields = read_eio(eio)
        return fields
    finally:
        eio.close()


def mac_session(args, clear, pause=None):
    axi = EjtagAxiController(transport(args), chain=4)

    def write(addr, data):
        resp = axi.axi_write(addr, data)
        if resp != 0:
            raise RuntimeError("AXI write to 0x%02x: response %d" % (addr, resp))

    try:
        axi.connect()
        if pause is not None:
            write(PAUSE_CTRL, 2 if pause else 0)
        if clear:
            for _, addr in MAC_REGS:
                write(addr, 0)
        regs = {name: axi.axi_read(addr) for name, addr in MAC_REGS}
        regs["pause_ctrl"] = axi.axi_read(PAUSE_CTRL)
        if pause is not None and bool(regs["pause_ctrl"] & 2) != pause:
            raise RuntimeError("PAUSE_CTRL reads 0x%x after the write" % regs["pause_ctrl"])
        return regs
    finally:
        axi.close()


def retry(session, *args, tries=3):
    """Run one JTAG session, opening a new one if it fails.

    hw_server sometimes answers 'JTAG node is not accessible' for a scan. A
    session only writes clears and the PAUSE switch, and checks its writes,
    so it can run again.
    """
    for attempt in range(1, tries + 1):
        try:
            return session(*args)
        except (RuntimeError, OSError) as e:
            if attempt == tries:
                raise
            print("%s failed (%s), retrying" % (session.__name__, e), file=sys.stderr)
            time.sleep(1.0)


def report(mac, pcs):
    st = pcs["pcs_status"]
    print("PCS/PMA status_vector 0x%04x: link %d, sync %d"
          % (st, st & 1, (st >> 1) & 1))
    print("MAC TX frames       %12d" % mac["tx_frames"])
    print("blast frames        %12d" % pcs["blast_frames"])
    print("  other TX frames   %12d  (ARP / ping / stats replies; negative = lost in the MAC)"
          % (mac["tx_frames"] - pcs["blast_frames"]))
    print("MAC RX frames       %12d" % mac["rx_frames"])
    print("MAC RX bad frames   %d (any error: FCS, undersize, ...; among them rx_er %d, "
          "overflow %d, oversize %d)"
          % (mac["rx_bad_frames"], mac["rx_err_align"], mac["rx_err_overflow"],
             mac["rx_err_oversize"]))
    print("MAC PAUSE frames    received %d, sent %d (PAUSE honored: %s)"
          % (mac["pause_rx"], mac["pause_tx"], "yes" if mac["pause_ctrl"] & 2 else "no"))
    print("PCS events          link down %d, sync loss %d, RUDI(INVALID) %d, "
          "disparity-error cycles %d, not-in-table cycles %d, GMII rx_er %d"
          % (pcs["link_downs"], pcs["sync_losses"], pcs["rudi_invalid_events"],
             pcs["disperr_cycles"], pcs["notintable_cycles"], pcs["rx_er_events"]))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=3121)
    ap.add_argument("--tap", default="xczu7.tap")
    ap.add_argument("--clear", action="store_true", help="clear all counters, then read them")
    ap.add_argument("--json", action="store_true", help="print the raw counters as JSON")
    ap.add_argument("--pause", choices=["on", "off"],
                    help="honor received PAUSE frames (MAC PAUSE_CTRL[1]); "
                         "resets to off with the board")
    args = ap.parse_args()

    try:
        pcs = retry(eio_session, args, args.clear)
    except WrongBuild as e:
        sys.exit("%s: not the throughput build" % e)
    mac = retry(mac_session, args, args.clear,
                None if args.pause is None else args.pause == "on")
    if args.json:
        print(json.dumps({"mac": mac, "pcs": pcs}, indent=2))
    else:
        report(mac, pcs)


if __name__ == "__main__":
    main()
