# SPDX-License-Identifier: Apache-2.0
"""Ethernet framing / FCS helpers shared by drivers, monitors and models.

Conventions match rtl/mii_tx_saf.v exactly:
  - 7x 0x55 preamble + 0xD5 SFD before the frame.
  - data+pad padded up to MIN_FRAME (60) bytes before the FCS.
  - 4-byte FCS = standard Ethernet CRC-32 (poly 0x04C11DB7, reflected, init/xorout
    all-ones) transmitted LSByte-first. That is precisely what zlib.crc32 returns,
    so on the wire: fcs_bytes == crc32(payload).to_bytes(4, "little").
"""
import zlib

PREAMBLE_BYTE = 0x55
PREAMBLE_LEN = 7
SFD = 0xD5
MIN_FRAME = 60        # data + pad bytes before the FCS (rtl MIN_FRAME)
PAD_BYTE = 0x00
FCS_LEN = 4
IFG_BYTES = 12


def fcs(payload: bytes) -> int:
    """Ethernet FCS value for `payload` (the wire sends it LSByte-first)."""
    return zlib.crc32(payload) & 0xFFFFFFFF


def fcs_bytes(payload: bytes) -> bytes:
    return fcs(payload).to_bytes(4, "little")


def fcs_ok(payload: bytes, wire_fcs: bytes) -> bool:
    """True if the 4 wire FCS bytes match the CRC recomputed over `payload`."""
    return int.from_bytes(wire_fcs, "little") == fcs(payload)


def pad_payload(payload: bytes) -> bytes:
    """Apply the framer's min-frame zero-pad (data+pad up to MIN_FRAME)."""
    if len(payload) < MIN_FRAME:
        return payload + bytes([PAD_BYTE]) * (MIN_FRAME - len(payload))
    return payload


def expected_wire_payload(raw: bytes) -> bytes:
    """The padded payload the framer will actually put on the wire for `raw`."""
    return pad_payload(raw)
