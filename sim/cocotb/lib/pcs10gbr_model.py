# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""Reference model of the 10GBASE-R PCS (IEEE 802.3 clause 49).

Written from the clause 49 block formats, independently of the RTL: blocks are
built and parsed from field lists, and the scrambler runs one bit at a time.

Conventions, as in the RTL:
  - XGMII transfer: d = 64-bit int, lane i in bits [8i+7:8i]; c = 8-bit int,
    bit i set when lane i is a control character. Lane 0 is first on the wire.
  - Block: hdr (2 bits, bit 0 first on the wire; data = 0b10, control = 0b01)
    and pay (64 bits, bit 0 first). Every field is sent LSB first.
"""

SYNC_DATA = 0b10
SYNC_CTRL = 0b01

I, S, T, E = 0x07, 0xFB, 0xFD, 0xFE
SEQ_OS, SIG_OS = 0x9C, 0x5C

# XGMII control character -> 7-bit 10GBASE-R control code
CODE = {0x07: 0x00, 0x06: 0x06, 0xFE: 0x1E, 0x1C: 0x2D, 0x3C: 0x33,
        0x7C: 0x4B, 0xBC: 0x55, 0xDC: 0x66, 0xF7: 0x78}
UNCODE = {v: k for k, v in CODE.items()}
OCODE = {SEQ_OS: 0x0, SIG_OS: 0xF}
UNOCODE = {v: k for k, v in OCODE.items()}
TERM_TYPE = [0x87, 0x99, 0xAA, 0xB4, 0xCC, 0xD2, 0xE1, 0xFF]

LF_D = 0x0100009C0100009C   # local fault ordered set, both halves
LF_C = 0x11
E_D = 0xFEFEFEFEFEFEFEFE


def pack(fields):
    """[(value, width), ...] from bit 0 upward -> int (must total 64 bits)."""
    v, pos = 0, 0
    for val, w in fields:
        assert 0 <= val < (1 << w), (val, w)
        v |= val << pos
        pos += w
    assert pos == 64, pos
    return v


def unpack(v, widths):
    out, pos = [], 0
    for w in widths:
        out.append((v >> pos) & ((1 << w) - 1))
        pos += w
    return out


def lanes_of(d, c):
    return [(d >> (8 * i)) & 0xFF for i in range(8)], [(c >> i) & 1 for i in range(8)]


def xgmii(lanes, ctl):
    d = sum(b << (8 * i) for i, b in enumerate(lanes))
    c = sum(f << i for i, f in enumerate(ctl))
    return d, c


def encode(d, c):
    """One XGMII transfer -> (hdr, pay), unscrambled."""
    L, C = lanes_of(d, c)

    def isD(i): return not C[i]
    def isC(i): return C[i] and L[i] in CODE
    def isS(i): return C[i] and L[i] == S
    def isT(i): return C[i] and L[i] == T
    def isO(i): return C[i] and L[i] in OCODE
    def D(i): return (L[i], 8)
    def Cc(i): return (CODE[L[i]], 7)
    def O(i): return (OCODE[L[i]], 4)

    if all(isD(i) for i in range(8)):
        return SYNC_DATA, d
    if all(isC(i) for i in range(8)):
        return SYNC_CTRL, pack([(0x1E, 8)] + [Cc(i) for i in range(8)])
    hi_d = all(isD(i) for i in (5, 6, 7))
    lo_d = all(isD(i) for i in (1, 2, 3))
    if isS(0) and all(isD(i) for i in range(1, 8)):
        return SYNC_CTRL, pack([(0x78, 8)] + [D(i) for i in range(1, 8)])
    if all(isC(i) for i in range(4)) and isS(4) and hi_d:
        return SYNC_CTRL, pack([(0x33, 8)] + [Cc(i) for i in range(4)] + [(0, 4)]
                               + [D(i) for i in (5, 6, 7)])
    if all(isC(i) for i in range(4)) and isO(4) and hi_d:
        return SYNC_CTRL, pack([(0x2D, 8)] + [Cc(i) for i in range(4)] + [O(4)]
                               + [D(i) for i in (5, 6, 7)])
    if isO(0) and lo_d and isS(4) and hi_d:
        return SYNC_CTRL, pack([(0x66, 8)] + [D(i) for i in (1, 2, 3)] + [O(0), (0, 4)]
                               + [D(i) for i in (5, 6, 7)])
    if isO(0) and lo_d and isO(4) and hi_d:
        return SYNC_CTRL, pack([(0x55, 8)] + [D(i) for i in (1, 2, 3)] + [O(0), O(4)]
                               + [D(i) for i in (5, 6, 7)])
    if isO(0) and lo_d and all(isC(i) for i in range(4, 8)):
        return SYNC_CTRL, pack([(0x4B, 8)] + [D(i) for i in (1, 2, 3)] + [O(0)]
                               + [Cc(i) for i in range(4, 8)])
    for k in range(8):
        if (all(isD(i) for i in range(k)) and isT(k)
                and all(isC(i) for i in range(k + 1, 8))):
            return SYNC_CTRL, pack([(TERM_TYPE[k], 8)] + [D(i) for i in range(k)]
                                   + [(0, 7 - k)] + [Cc(i) for i in range(k + 1, 8)])
    return SYNC_CTRL, pack([(0x1E, 8)] + [(0x1E, 7)] * 8)


def decode(hdr, pay):
    """(hdr, pay) -> (d, c, rtype), rtype in 'CSTDE'. E decodes to all /E/."""
    err = (E_D, 0xFF, 'E')
    if hdr == SYNC_DATA:
        return pay, 0x00, 'D'
    if hdr != SYNC_CTRL:
        return err
    bt = pay & 0xFF
    rest = pay >> 8

    def codes(vals):
        if any(v not in UNCODE for v in vals):
            return None
        return [UNCODE[v] for v in vals]

    def os_(o):
        return UNOCODE.get(o)

    if bt == 0x1E:
        cc = codes(unpack(rest, [7] * 8))
        if cc is None:
            return err
        return (*xgmii(cc, [1] * 8), 'C')
    if bt in (0x33, 0x2D):
        f = unpack(rest, [7, 7, 7, 7, 4, 8, 8, 8])
        cc = codes(f[:4])
        if cc is None:
            return err
        if bt == 0x33:
            l4, rt = S, 'S'
        else:
            l4, rt = os_(f[4]), 'C'
            if l4 is None:
                return err
        return (*xgmii(cc + [l4] + f[5:], [1, 1, 1, 1, 1, 0, 0, 0]), rt)
    if bt in (0x66, 0x55):
        f = unpack(rest, [8, 8, 8, 4, 4, 8, 8, 8])
        l0 = os_(f[3])
        if l0 is None:
            return err
        if bt == 0x66:
            l4, rt = S, 'S'
        else:
            l4, rt = os_(f[4]), 'C'
            if l4 is None:
                return err
        return (*xgmii([l0] + f[0:3] + [l4] + f[5:], [1, 0, 0, 0, 1, 0, 0, 0]), rt)
    if bt == 0x78:
        f = unpack(rest, [8] * 7)
        return (*xgmii([S] + f, [1] + [0] * 7), 'S')
    if bt == 0x4B:
        f = unpack(rest, [8, 8, 8, 4, 7, 7, 7, 7])
        l0 = os_(f[3])
        cc = codes(f[4:])
        if l0 is None or cc is None:
            return err
        return (*xgmii([l0] + f[0:3] + cc, [1, 0, 0, 0, 1, 1, 1, 1]), 'C')
    if bt in TERM_TYPE:
        k = TERM_TYPE.index(bt)
        f = unpack(rest, [8] * k + [7 - k] + [7] * (7 - k))
        cc = codes(f[k + 1:])
        if cc is None:
            return err
        return (*xgmii(f[:k] + [T] + cc, [0] * k + [1] * (8 - k)), 'T')
    return err


class Scrambler:
    """Bit-serial 1 + x^39 + x^58 scrambler / descrambler (clause 49.2.6)."""

    def __init__(self, descramble=False, state=(1 << 58) - 1):
        self.descramble = descramble
        self.s = state          # bit j = stream bit j+1 ago (bit 0 newest)

    def block(self, v):
        out = 0
        for i in range(64):
            b = (v >> i) & 1
            o = b ^ ((self.s >> 38) & 1) ^ ((self.s >> 57) & 1)
            fb = b if self.descramble else o
            self.s = ((self.s << 1) | fb) & ((1 << 58) - 1)
            out |= o << i
        return out


class RxFsm:
    """Clause 49 receive state machine over decoded blocks, with the T
    lookahead. feed() takes blocks in order and returns the output for the
    previous one (None for the first)."""

    def __init__(self):
        self.st = 'INIT'
        self.cur = None

    def feed(self, blk):
        prev, self.cur = self.cur, blk
        if prev is None:
            return None
        d, c, r = prev
        nxt_sc = blk[2] in 'SC'
        st = self.st
        if st == 'D':
            ok = {'D': 'D', 'T': 'T' if nxt_sc else None}.get(r)
        elif st == 'E':
            ok = {'C': 'C', 'D': 'D', 'T': 'T' if nxt_sc else None}.get(r)
        else:
            ok = {'C': 'C', 'S': 'D'}.get(r)
        if ok is None:
            self.st = 'E'
            return (E_D, 0xFF)
        self.st = ok
        return (d, c)


def frame_stream(rng, n_frames, min_len=60, max_len=200, os_rate=0.3):
    """XGMII transfers for n_frames random frames with idles and ordered sets
    between them. Starts land on lane 0 or 4 and never share a block with
    the previous terminate (no block format holds both); terminates land on
    any lane. The gaps produce every control block type."""
    lanes, ctl = [], []

    def put(b, cflag):
        lanes.append(b)
        ctl.append(cflag)

    def align(n):
        while len(lanes) % n:
            put(I, 1)

    def oset():
        put(rng.choice((SEQ_OS, SIG_OS)), 1)
        put(0, 0); put(0, 0); put(rng.choice((1, 2)), 0)

    for _ in range(8):
        put(I, 1)
    for _ in range(n_frames):
        align(8)
        for _ in range(rng.randint(0, 1) * 8):
            put(I, 1)
        # lane 0 / lane 4 contents of the block before (or holding) the start
        if rng.random() < os_rate:
            kind = rng.randrange(4)
            if kind == 0:       # O0 + idles (0x4B), start next block
                oset(); align(8)
            elif kind == 1:     # idles + O4 (0x2D), start next block
                align(4); put(I, 1); put(I, 1); put(I, 1); put(I, 1); oset()
            elif kind == 2:     # O0 + O4 (0x55)
                oset(); oset()
            else:               # O0 + S4 (0x66)
                oset()
        if len(lanes) % 8 == 0 and rng.random() < 0.5:
            for _ in range(4):  # idles + S4 (0x33)
                put(I, 1)
        put(S, 1)
        for _ in range(6):
            put(0x55, 0)
        put(0xD5, 0)
        for _ in range(rng.randint(min_len, max_len)):
            put(rng.randrange(256), 0)
        put(T, 1)
        for _ in range(rng.randint(1, 12)):
            put(I, 1)
    while len(lanes) % 8:
        put(I, 1)
    for _ in range(16):
        put(I, 1)
    out = []
    for i in range(0, len(lanes), 8):
        out.append(xgmii(lanes[i:i + 8], ctl[i:i + 8]))
    return out
