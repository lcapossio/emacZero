# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""Packet builder and Internet-checksum reference for the checksum-offload tests.

Builds Ethernet frames (optional 802.1Q / 802.1ad tag) carrying IPv4 (any IHL,
optional fragmentation) or IPv6 with TCP, UDP, ICMP / ICMPv6 or another
protocol, and says what the RTL should do with them:

  - Packet.frame()          the frame bytes (no FCS), checksums as built
  - Packet.expect()         what csum_calc / tx_csum_off / the RX checker
                            should compute (Expect)

Scope mirrors rtl/net/csum_calc.v: the L4 checksum applies to TCP / UDP / ICMP
over unfragmented IPv4 without a source route option, and TCP / UDP / ICMPv6
directly after the IPv6 fixed header. Sums cover the IP datagram only (IP
length), not padding or trailer; UDP covers only its Length field's bytes and
applies only when 8 <= that length <= the IP payload. The IPv4 header verdict
needs only the header to be present, the L4 verdict the whole datagram.
"""
from dataclasses import dataclass, field
import random

ETH_IPV4 = 0x0800
ETH_IPV6 = 0x86DD
TPID_8021Q = 0x8100
TPID_8021AD = 0x88A8

ICMP, TCP, UDP, ICMPV6 = 1, 6, 17, 58

# Offset of the checksum field inside each L4 header
L4_CSUM_OFF = {TCP: 16, UDP: 6, ICMP: 2, ICMPV6: 2}


def ones_sum(data: bytes) -> int:
    """16-bit ones'-complement sum (folded, not inverted)."""
    if len(data) % 2:
        data = data + b"\x00"
    s = 0
    for i in range(0, len(data), 2):
        s += (data[i] << 8) | data[i + 1]
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return s


def csum(data: bytes) -> int:
    """Internet checksum: ones' complement of the ones'-complement sum."""
    return (~ones_sum(data)) & 0xFFFF


LSRR, SSRR = 0x83, 0x89


def ip4_opts_skip(opts: bytes) -> bool:
    """True if IPv4 options hold a source route or cannot be walked.

    Walks the list as RFC 791 lays it out: EOL (0) ends it, NOP (1) is one
    byte, any other option is type, length (>= 2), data.
    """
    i = 0
    while i < len(opts):
        t = opts[i]
        if t == 0:
            break
        if t == 1:
            i += 1
            continue
        if t in (LSRR, SSRR):
            return True
        if i + 1 >= len(opts):
            break
        n = opts[i + 1]
        if n < 2:
            return True
        i += n
    return False


def random_opts(rng: random.Random, n: int) -> bytes:
    """n bytes of IPv4 options: a well-formed list, sometimes with a source
    route, sometimes with junk after EOL or a broken length."""
    out = bytearray()
    while len(out) < n:
        room = n - len(out)
        k = rng.choices(["nop", "eol", "tlv", "srr", "bad"], weights=[3, 1, 4, 1, 0.3])[0]
        if k == "nop" or room < 2:
            out.append(1)
        elif k == "eol":
            out.append(0)
            out += bytes(rng.randrange(256) for _ in range(room - 1))   # ignored
        elif k == "bad":
            out += bytes([rng.choice([7, 68, 130]), rng.randint(0, 1)])
        else:
            ln = rng.randint(2, min(room, 11))
            t = rng.choice([LSRR, SSRR]) if k == "srr" else rng.choice([7, 68, 130, 148])
            out += bytes([t, ln]) + bytes(rng.randrange(256) for _ in range(ln - 2))
    return bytes(out[:n])


@dataclass
class Expect:
    done: bool            # an IP datagram the engine recognises, fully present
    ip4: bool             # IPv4 header checksum applies (header present)
    l4_ok: bool           # L4 checksum applies
    l4_udp: bool
    l3_end: int
    ip_csum_pos: int      # frame offset of the IPv4 checksum MSB
    l4_csum_pos: int      # frame offset of the L4 checksum MSB
    ip_csum: int          # correct IPv4 header checksum
    l4_csum: int          # correct L4 checksum, before UDP's 0 -> 0xFFFF
    ip_good: bool         # header checksum as built is correct
    l4_good: bool         # L4 checksum as built is correct (UDPv4 0 counts)


@dataclass
class Packet:
    vlan: int = 0                 # 0, TPID_8021Q or TPID_8021AD
    family: int = 4               # 4, 6, or 0 = not IP (EtherType 0x88B5)
    proto: int = UDP
    l4_len: int = 8               # L4 header + payload bytes
    ihl: int = 5
    mf: bool = False
    frag_off: int = 0
    trailer: bytes = b""          # bytes after the datagram (padding etc.)
    bad_ip: bool = False          # corrupt the IPv4 header checksum
    bad_l4: bool = False          # corrupt the L4 checksum
    udp_zero: bool = False        # send UDP checksum 0 (no checksum; invalid over IPv6)
    udp_len: int = None           # UDP Length field; None = l4_len
    opts: bytes = None            # IPv4 options (ihl*4 - 20 bytes); None = random list
    truncate: int = 0             # bytes cut from the end of the datagram (may reach the IP header)
    seed: int = 0
    _l4: bytes = field(default=b"", repr=False)

    # ---- construction -----------------------------------------------------
    def _rng(self):
        return random.Random(self.seed)

    def _l3_off(self) -> int:
        return 18 if self.vlan else 14

    def _ip_hdr_len(self) -> int:
        return self.ihl * 4 if self.family == 4 else 40

    def _addrs(self, rng) -> bytes:
        n = 8 if self.family == 4 else 32
        return bytes(rng.randrange(256) for _ in range(n))

    def _l4_bytes(self, rng) -> bytearray:
        b = bytearray(rng.randrange(256) for _ in range(self.l4_len))
        if self.proto == TCP and self.l4_len >= 20:
            b[12] = (5 << 4) | (b[12] & 0x0F)        # data offset 5
        if self.proto == UDP and self.l4_len >= 6:
            ul = self.l4_len if self.udp_len is None else self.udp_len
            b[4:6] = ul.to_bytes(2, "big")           # UDP length
        off = L4_CSUM_OFF.get(self.proto)
        if off is not None and self.l4_len >= off + 2:
            b[off:off + 2] = b"\x00\x00"
        return b

    def build(self):
        rng = self._rng()
        addrs = self._addrs(rng)
        l4 = self._l4_bytes(rng)
        self._addr_bytes = addrs
        self._l4 = l4
        return self

    def _udp_cov(self) -> int:
        """Bytes the L4 checksum covers: UDP Length for UDP, else all."""
        if self.proto == UDP and self.udp_len is not None:
            return self.udp_len
        return self.l4_len

    def _opts(self) -> bytes:
        n = self.ihl * 4 - 20
        if self.opts is not None:
            assert len(self.opts) == n, "opts must fill ihl*4 - 20 bytes"
            return self.opts
        return random_opts(random.Random(self.seed ^ 0x5A5A), n)

    def _cut(self, dgram: bytes) -> bytes:
        return dgram[:len(dgram) - self.truncate]

    def _l4_csum(self, l4: bytes, cover: int = None) -> int:
        """Checksum of l4 (field zeroed) over its first `cover` bytes
        (default: the UDP Length as built, or all)."""
        l4 = bytes(l4)[:self._udp_cov() if cover is None else cover]
        if self.proto == ICMP and self.family == 4:
            return csum(bytes(l4))
        ph = self._addr_bytes + bytes([0, self.proto]) + len(l4).to_bytes(2, "big")
        if self.family == 6:
            ph = self._addr_bytes + len(l4).to_bytes(4, "big") + bytes([0, 0, 0, self.proto])
        return csum(ph + bytes(l4))

    def _l4_applies(self, udp_len: int = None) -> bool:
        """Whether the L4 checksum applies, given the UDP Length (default:
        as built; expect() passes the one in the frame)."""
        off = L4_CSUM_OFF.get(self.proto)
        if off is None or self.l4_len < off + 2:
            return False
        ul = self._udp_cov() if udp_len is None else udp_len
        if self.proto == UDP and not 8 <= ul <= self.l4_len:
            return False
        if self.family == 4:
            return (self.proto in (TCP, UDP, ICMP) and not self.mf and
                    self.frag_off == 0 and not ip4_opts_skip(self._opts()))
        if self.family == 6:
            return self.proto in (TCP, UDP, ICMPV6)
        return False

    def frame(self) -> bytes:
        if not self._l4 and self.l4_len:
            self.build()
        rng = self._rng()
        eth = bytes.fromhex("020000000001") + bytes.fromhex("0a0b0c0d0e0f")
        if self.vlan:
            eth += self.vlan.to_bytes(2, "big") + rng.randrange(65536).to_bytes(2, "big")
        if self.family == 0:
            return eth + b"\x88\xb5" + bytes(self._l4) + self.trailer

        l4 = bytearray(self._l4)
        if self._l4_applies():
            off = L4_CSUM_OFF[self.proto]
            c = self._l4_csum(l4)
            if self.proto == UDP and c == 0:
                c = 0xFFFF
            if self.proto == UDP and self.udp_zero:
                c = 0
            if self.bad_l4:
                c ^= 0x0101
            l4[off:off + 2] = c.to_bytes(2, "big")

        if self.family == 4:
            hlen = self.ihl * 4
            hdr = bytearray(hlen)
            hdr[0] = 0x40 | self.ihl
            hdr[2:4] = (hlen + len(l4)).to_bytes(2, "big")
            hdr[4:6] = rng.randrange(65536).to_bytes(2, "big")
            fo = (0x2000 if self.mf else 0) | (self.frag_off & 0x1FFF)
            hdr[6:8] = fo.to_bytes(2, "big")
            hdr[8] = 64
            hdr[9] = self.proto
            hdr[12:20] = self._addr_bytes
            hdr[20:hlen] = self._opts()
            c = csum(bytes(hdr))
            if self.bad_ip:
                c ^= 0x8001
            hdr[10:12] = c.to_bytes(2, "big")
            return eth + b"\x08\x00" + self._cut(bytes(hdr) + bytes(l4)) + self.trailer

        hdr = bytearray(40)
        hdr[0] = 0x60
        hdr[4:6] = len(l4).to_bytes(2, "big")
        hdr[6] = self.proto
        hdr[7] = 64
        hdr[8:40] = self._addr_bytes
        return eth + b"\x86\xdd" + self._cut(bytes(hdr) + bytes(l4)) + self.trailer

    # ---- expectations ------------------------------------------------------
    def expect(self, frame: bytes = None) -> Expect:
        """What the engine reports for this packet, sent as `frame` (default
        p.frame(); pass the padded frame when the MAC pads). Bytes past a
        truncated datagram's real end (padding, trailer) count where IP says
        the datagram extends over them, as they do in the RTL."""
        f = self.frame() if frame is None else frame
        l3 = self._l3_off()
        if self.family == 0:
            return Expect(False, False, False, False, 0, 0, 0, 0, 0, False, False)
        hlen = self._ip_hdr_len()
        l3_end = l3 + hlen + self.l4_len
        l4s = l3 + hlen
        done = l3_end <= len(f)
        ip4 = self.family == 4 and l4s <= len(f)
        ip_csum = 0
        ip_good = True
        if ip4:
            hdr = bytearray(f[l3:l3 + hlen])
            ip_good = ones_sum(bytes(hdr)) == 0xFFFF
            hdr[10:12] = b"\x00\x00"
            ip_csum = csum(bytes(hdr))
        # Like the RTL, take the UDP Length from the frame: on a truncated
        # datagram it may be trailer or padding bytes.
        cover = self.l4_len
        if self.proto == UDP and done and self.l4_len >= 6:
            cover = int.from_bytes(f[l4s + 4:l4s + 6], "big")
        applies = self._l4_applies(cover) and done
        l4_csum = l4_good = 0
        pos = l4s + L4_CSUM_OFF.get(self.proto, 0)
        if applies:
            l4 = bytearray(f[l4s:l3_end])
            field_val = int.from_bytes(l4[L4_CSUM_OFF[self.proto]:L4_CSUM_OFF[self.proto] + 2], "big")
            off = L4_CSUM_OFF[self.proto]
            l4z = bytearray(l4)
            l4z[off:off + 2] = b"\x00\x00"
            l4_csum = self._l4_csum(l4z, cover)
            if self.proto == UDP and ip4 and field_val == 0:
                l4_good = True
            else:
                want = 0xFFFF if (self.proto == UDP and l4_csum == 0) else l4_csum
                l4_good = field_val == want
        return Expect(done=done, ip4=ip4, l4_ok=applies, l4_udp=self.proto == UDP,
                      l3_end=l3_end, ip_csum_pos=l3 + 10, l4_csum_pos=pos,
                      ip_csum=ip_csum, l4_csum=l4_csum, ip_good=ip_good,
                      l4_good=bool(l4_good))


def random_packet(rng: random.Random, max_l4: int = 300) -> Packet:
    """A random packet across the scope, including cases the engine skips."""
    family = rng.choices([4, 6, 0], weights=[6, 3, 1])[0]
    if family == 4:
        proto = rng.choices([UDP, TCP, ICMP, 47], weights=[4, 4, 2, 1])[0]
    elif family == 6:
        proto = rng.choices([UDP, TCP, ICMPV6, 0], weights=[4, 4, 2, 1])[0]   # 0 = hop-by-hop
    else:
        proto = 0
    min_l4 = {TCP: 20, UDP: 8, ICMP: 4, ICMPV6: 4}.get(proto, 0)
    l4_len = rng.randint(min_l4, max_l4)
    if rng.random() < 0.1 and min_l4:
        l4_len = rng.randint(0, min_l4 + 1)                 # too short to apply
    frag = family == 4 and rng.random() < 0.15
    trailer = bytes(rng.randrange(256) for _ in range(rng.choice([0, 0, 1, 2, 7, 33])))
    p = Packet(vlan=rng.choice([0, 0, 0, TPID_8021Q, TPID_8021AD]),
               family=family, proto=proto, l4_len=l4_len,
               ihl=rng.choice([5, 5, 5, 6, 9, 15]),
               mf=frag and rng.random() < 0.5,
               frag_off=(rng.randint(1, 100) if frag and rng.random() < 0.6 else 0),
               trailer=trailer,
               bad_ip=rng.random() < 0.2,
               bad_l4=rng.random() < 0.25,
               udp_zero=rng.random() < 0.15,
               seed=rng.randrange(1 << 30))
    if p.mf is False and frag and p.frag_off == 0:
        p.mf = True
    if proto == UDP and l4_len >= 8 and rng.random() < 0.2:
        p.udp_len = rng.choice([rng.randint(8, l4_len),            # shorter: valid
                                l4_len + rng.randint(1, 20),       # past the payload
                                rng.randint(0, 7)])                # below the header
    if family and l4_len and rng.random() < 0.08:
        p.truncate = rng.randint(1, l4_len)                        # IP length > data
    return p.build()


def force_zero_l4_csum(p: Packet) -> Packet:
    """Adjust payload word 8..9 so the L4 checksum computes to 0x0000.

    Exercises UDP's rule that a computed 0 is sent as 0xFFFF. Needs
    l4_len >= 10 and a protocol the checksum applies to.
    """
    assert p.l4_len >= 10 and p._l4_applies()
    l4 = bytearray(p._l4)
    c = p._l4_csum(l4)                   # field is zero in p._l4
    w = int.from_bytes(l4[8:10], "big") + c
    w = (w & 0xFFFF) + (w >> 16)
    l4[8:10] = w.to_bytes(2, "big")
    p._l4 = l4
    assert p._l4_csum(l4) == 0
    return p


def pad60(frame: bytes) -> bytes:
    """Pad a frame to the 60-byte Ethernet minimum, as a MAC does on TX."""
    return frame + bytes(max(0, 60 - len(frame)))
