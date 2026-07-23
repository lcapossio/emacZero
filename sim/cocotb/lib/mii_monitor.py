# SPDX-License-Identifier: Apache-2.0
"""MII TX monitor: reconstruct frames from the 4-bit nibble stream.

Samples mii_txd / mii_tx_en on the FALLING edge of mii_tx_clk - the DUT drives
them on the rising edge, so they are stable mid-cycle and the sample is race
free. MII sends the low nibble first, so two nibbles assemble low-then-high.

Each frame (a contiguous mii_tx_en run) is split into 7x preamble + SFD + payload
+ 4-byte FCS. The monitor validates the preamble/SFD and the recomputed FCS, and
exposes the FCS-stripped payloads for the scoreboard.
"""
from cocotb.triggers import FallingEdge
from .eth import PREAMBLE_BYTE, PREAMBLE_LEN, SFD, FCS_LEN, fcs_ok


class MiiMonitor:
    def __init__(self, dut):
        self.dut = dut
        self.payloads = []          # list[bytes]  (FCS-stripped, as seen on wire)
        self.fcs_errors = 0
        self.framing_errors = []

    async def run(self):
        dut = self.dut
        nibbles = []
        active = False
        while True:
            await FallingEdge(dut.mii_tx_clk)
            en = int(dut.mii_tx_en.value)
            if en:
                nibbles.append(int(dut.mii_txd.value) & 0xF)
                active = True
            elif active:
                self._finish(nibbles)
                nibbles = []
                active = False

    def _finish(self, nibbles):
        if len(nibbles) % 2 != 0:
            self.framing_errors.append(f"odd nibble count {len(nibbles)}")
            return
        data = bytes((nibbles[i] | (nibbles[i + 1] << 4))
                     for i in range(0, len(nibbles), 2))

        # Preamble + SFD.
        hdr = PREAMBLE_LEN + 1
        if len(data) < hdr + FCS_LEN:
            self.framing_errors.append(f"runt frame ({len(data)} bytes)")
            return
        if any(b != PREAMBLE_BYTE for b in data[:PREAMBLE_LEN]) or data[PREAMBLE_LEN] != SFD:
            self.framing_errors.append("bad preamble/SFD")
            return

        body = data[hdr:]
        payload, wire_fcs = body[:-FCS_LEN], body[-FCS_LEN:]
        if not fcs_ok(payload, wire_fcs):
            self.fcs_errors += 1
            self.framing_errors.append(f"FCS mismatch on {len(payload)}-byte frame")
        self.payloads.append(payload)
