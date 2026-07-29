# SPDX-License-Identifier: Apache-2.0
"""GMII receive driver: feed frames into eth_mac_rx's gmii_rxd/rx_dv/rx_er.

Drives a full wire frame - 7x 0x55 preamble, 0xD5 SFD, the payload (dst+src+
type+data), then the 4-byte FCS - with gmii_rx_dv high throughout and low for
the inter-frame gap. Supports FCS corruption (a flipped byte) and rx_er assertion
(an alignment error) for the error-path tests.
"""
from cocotb.triggers import RisingEdge
from .eth import PREAMBLE_BYTE, PREAMBLE_LEN, SFD, fcs_bytes


class GmiiRxDriver:
    def __init__(self, dut):
        self.dut = dut
        dut.gmii_rxd.value = 0
        dut.gmii_rx_dv.value = 0
        dut.gmii_rx_er.value = 0

    async def _beat(self, data, dv, er):
        self.dut.gmii_rxd.value = data
        self.dut.gmii_rx_dv.value = dv
        self.dut.gmii_rx_er.value = er
        await RisingEdge(self.dut.clk)

    async def idle(self, cycles):
        for _ in range(cycles):
            await self._beat(0, 0, 0)

    async def send_frame(self, payload: bytes, corrupt_fcs=False, align_err=False,
                         er_wire_idx=None):
        """payload = dst+src+type+data (no preamble/FCS). Returns nothing; the
        model predicts the expected result from the same descriptor.

        er_wire_idx: assert rx_er on an absolute wire-byte index (0..6 = preamble,
        7 = SFD, 8+ = payload), overriding align_err. Used to test rx_er on
        preamble/SFD bytes, not just mid-payload."""
        f = bytearray(fcs_bytes(payload))
        if corrupt_fcs:
            f[0] ^= 0xFF                      # guarantees a CRC residue mismatch
        wire = (bytes([PREAMBLE_BYTE]) * PREAMBLE_LEN + bytes([SFD])
                + payload + bytes(f))
        data_start = PREAMBLE_LEN + 1
        if er_wire_idx is not None:
            er_idx = er_wire_idx
        elif align_err:
            # Alignment error on a mid-payload byte (rx_er is sampled in S_DATA).
            er_idx = data_start + max(0, len(payload) // 2)
        else:
            er_idx = -1
        for i, b in enumerate(wire):
            await self._beat(b, 1, 1 if i == er_idx else 0)
        await self._beat(0, 0, 0)             # dv low -> end of frame
