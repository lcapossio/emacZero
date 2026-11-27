# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""Demo L3 stack behind a 64-bit MAC stream (fpga/zcu106/rtl/net_service64.v).

  net_service64  ARP requests for our address answered, others ignored;
                 pings of 0..1472 payload bytes echoed (IPv4 and ICMP
                 checksums checked, identifier, sequence and payload kept);
                 UDP datagrams to the echo port echoed with the ports
                 swapped, others ignored; a frame flagged bad (tuser) gets
                 no reply. Input with random gaps, short frames padded as the
                 MAC delivers them, every width of a frame's last beat, and
                 the output stalled at random; tkeep must be contiguous and
                 every reply whole. A burst of back-to-back pings: icmp_echo
                 drops those arriving while it sends a reply (one buffer, as
                 on the 1G demo), the replies stay whole and in order.
                 udp_echo: datagrams longer than its 1536-byte buffer, up
                 to 8193 bytes, dropped whole, and one arriving during a
                 reply dropped whole even when the reply ends first.
"""
import random
import struct

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly

SUITES = {
    "net_service64": {
        "toplevel": "net_service64",
        "sources": ["rtl/net/net_rx.v", "rtl/net/icmp_echo.v", "rtl/net/udp_echo.v",
                    "fpga/arty_a7/rtl/arp_responder.v",
                    "fpga/arty_a7/rtl/arty_tx_arbiter.v",
                    "fpga/zcu106/rtl/net_service64.v"],
        "skip_vhdl": "10G board blocks are Verilog only",
    },
}

OUR_MAC = bytes.fromhex("020000000001")
OUR_IP = bytes([192, 168, 10, 200])
PC_MAC = bytes.fromhex("a0b1c2d3e4f5")
PC_IP = bytes([192, 168, 10, 1])
ECHO_PORT = 9999


def csum(b):
    if len(b) % 2:
        b += b"\0"
    s = sum(struct.unpack("!%dH" % (len(b) // 2), b))
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def eth(dst, src, etype, payload):
    f = dst + src + struct.pack("!H", etype) + payload
    return f + bytes(max(0, 60 - len(f)))       # padded, as the MAC delivers it


def ipv4(src, dst, proto, payload, ident=0x1234):
    h = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(payload), ident, 0, 64,
                    proto, 0, src, dst)
    h = h[:10] + struct.pack("!H", csum(h)) + h[12:]
    return h + payload


def arp_req(tpa, spa=PC_IP, sha=PC_MAC):
    p = struct.pack("!HHBBH6s4s6s4s", 1, 0x0800, 6, 4, 1, sha, spa, bytes(6), tpa)
    return eth(b"\xff" * 6, sha, 0x0806, p)


def ping(dst_ip, ident, seq, data):
    icmp = struct.pack("!BBHHH", 8, 0, 0, ident, seq) + data
    icmp = icmp[:2] + struct.pack("!H", csum(icmp)) + icmp[4:]
    return eth(OUR_MAC, PC_MAC, 0x0800, ipv4(PC_IP, dst_ip, 1, icmp))


def udp(dst_ip, sport, dport, data):
    u = struct.pack("!HHHH", sport, dport, 8 + len(data), 0) + data
    pseudo = PC_IP + dst_ip + struct.pack("!BBH", 0, 17, len(u))
    c = csum(pseudo + u) or 0xFFFF
    u = u[:6] + struct.pack("!H", c) + u[8:]
    return eth(OUR_MAC, PC_MAC, 0x0800, ipv4(PC_IP, dst_ip, 17, u))


class Bench:
    def __init__(self, dut, seed):
        self.dut = dut
        self.rng = random.Random(seed)
        self.got = []
        self.ready_p = 1.0

    async def start(self):
        d = self.dut
        cocotb.start_soon(Clock(d.clk, 5, "ns").start())
        d.rst_n.value = 0
        d.our_mac.value = int.from_bytes(OUR_MAC, "big")
        d.our_ip.value = int.from_bytes(OUR_IP, "big")
        d.s_axis_tvalid.value = 0
        d.s_axis_tdata.value = 0
        d.s_axis_tkeep.value = 0
        d.s_axis_tlast.value = 0
        d.s_axis_tuser.value = 0
        d.m_axis_tready.value = 0
        await ClockCycles(d.clk, 5)
        d.rst_n.value = 1
        cocotb.start_soon(self.sink())
        await ClockCycles(d.clk, 5)

    async def send(self, frame, tuser=0, gap_p=0.3):
        d = self.dut
        beats = [frame[i:i + 8] for i in range(0, len(frame), 8)]
        i = 0
        while i < len(beats):
            await FallingEdge(d.clk)
            if self.rng.random() < gap_p:
                d.s_axis_tvalid.value = 0
                continue
            b = beats[i]
            d.s_axis_tdata.value = int.from_bytes(b.ljust(8, b"\0"), "little")
            d.s_axis_tkeep.value = (1 << len(b)) - 1
            d.s_axis_tlast.value = int(i == len(beats) - 1)
            d.s_axis_tuser.value = tuser if i == len(beats) - 1 else 0
            d.s_axis_tvalid.value = 1
            await ReadOnly()
            if int(d.s_axis_tready.value):
                i += 1
        await FallingEdge(d.clk)
        d.s_axis_tvalid.value = 0
        d.s_axis_tlast.value = 0
        d.s_axis_tuser.value = 0

    async def sink(self):
        d = self.dut
        cur = bytearray()
        while True:
            await FallingEdge(d.clk)
            d.m_axis_tready.value = int(self.rng.random() < self.ready_p)
            await ReadOnly()
            if int(d.m_axis_tvalid.value) and int(d.m_axis_tready.value):
                keep = int(d.m_axis_tkeep.value)
                n = bin(keep).count("1")
                assert keep == (1 << n) - 1, f"tkeep {keep:02x} not contiguous"
                cur += int(d.m_axis_tdata.value).to_bytes(8, "little")[:n]
                if int(d.m_axis_tlast.value):
                    self.got.append(bytes(cur))
                    cur = bytearray()
                else:
                    assert n == 8, "short beat before tlast"

    async def ask(self, frame, want_reply, tuser=0):
        """Send one frame; returns its reply (or None, after a wait long
        enough for one)."""
        n = len(self.got)
        await self.send(frame, tuser)
        for _ in range(3000 + 4 * len(frame)):
            await FallingEdge(self.dut.clk)
            if len(self.got) > n:
                break
        await ClockCycles(self.dut.clk, 50)
        assert len(self.got) <= n + 1, "more than one reply"
        r = self.got[n] if len(self.got) > n else None
        assert (r is not None) == want_reply, ("reply" if r else "no reply", frame[:42].hex())
        return r


def check_ip(r, proto):
    assert r[:6] == PC_MAC and r[6:12] == OUR_MAC and r[12:14] == b"\x08\x00"
    ip = r[14:]
    assert ip[0] == 0x45 and ip[9] == proto
    assert csum(ip[:20]) == 0, "IPv4 header checksum"
    assert ip[12:16] == OUR_IP and ip[16:20] == PC_IP
    tot = struct.unpack("!H", ip[2:4])[0]
    return ip[20:tot]


@cocotb.test()
async def service(dut):
    tb = Bench(dut, 1)
    await tb.start()
    rng = tb.rng
    for ready_p in (1.0, 0.4):
        tb.ready_p = ready_p
        # ARP
        r = await tb.ask(arp_req(OUR_IP), True)
        assert r[:6] == PC_MAC and r[6:12] == OUR_MAC and r[12:14] == b"\x08\x06"
        op, sha, spa, tha, tpa = struct.unpack("!6xH6s4s6s4s", r[14:42])
        assert (op, sha, spa, tha, tpa) == (2, OUR_MAC, OUR_IP, PC_MAC, PC_IP)
        await tb.ask(arp_req(bytes([192, 168, 10, 7])), False)
        # ping, short to a full frame
        # 23..30: frames of 65..72 bytes, every last-beat width
        for n in (0, 1, 18, 56, 57, 1000, 1472, *range(23, 31)):
            data = rng.randbytes(n)
            ident, seq = rng.randrange(65536), rng.randrange(65536)
            r = await tb.ask(ping(OUR_IP, ident, seq, data), True)
            icmp = check_ip(r, 1)
            assert csum(icmp) == 0, "ICMP checksum"
            t, c, i2, s2 = struct.unpack("!BBxxHH", icmp[:8])
            assert (t, c, i2, s2) == (0, 0, ident, seq) and icmp[8:] == data, n
            # the ARP responder starts only on tsof: one after every length
            await tb.ask(arp_req(OUR_IP), True)
        await tb.ask(ping(bytes([192, 168, 10, 7]), 1, 1, b"x" * 20), False)
        await tb.ask(ping(OUR_IP, 1, 2, b"y" * 20), False, tuser=1)
        # UDP echo
        for n in (1, 17, 18, 100, 1472):
            data = rng.randbytes(n)
            sport = rng.randrange(1024, 65536)
            r = await tb.ask(udp(OUR_IP, sport, ECHO_PORT, data), True)
            u = check_ip(r, 17)
            sp, dp, ln = struct.unpack("!HHH", u[:6])
            assert (sp, dp, ln) == (ECHO_PORT, sport, 8 + n) and u[8:] == data, n
        await tb.ask(udp(OUR_IP, 5000, ECHO_PORT + 1, b"z" * 30), False)
        await tb.ask(udp(OUR_IP, 5000, ECHO_PORT, b"w" * 30), False, tuser=1)
    # a burst of requests back to back: icmp_echo has one reply buffer, so
    # a request arriving while it sends a reply is dropped (as on the 1G
    # demo); the replies must still be whole, in order and one per request
    # answered, the first among them
    tb.ready_p = 0.7
    n0 = len(tb.got)
    seqs = list(range(20))
    for s in seqs:
        await tb.send(ping(OUR_IP, 7, s, rng.randbytes(rng.randint(0, 200))), gap_p=0.0)
    await ClockCycles(dut.clk, 6000)
    got = [struct.unpack("!H", check_ip(r, 1)[6:8])[0] for r in tb.got[n0:]]
    dut._log.info("burst of %d pings: %d replies", len(seqs), len(got))
    assert got == sorted(set(got)) and got and got[0] == 0, got
    # and the stack is free again afterwards
    r = await tb.ask(ping(OUR_IP, 9, 9, b"after"), True)
    assert check_ip(r, 1)[8:] == b"after"


@cocotb.test()
async def udp_limits(dut):
    """udp_echo's buffer (1536 bytes) and its single reply: a datagram
    longer than the buffer, of any length, is dropped whole (4096 and 8192
    bytes once wrapped the byte count); one whose first byte arrives while
    a reply goes out is dropped whole even when the reply ends first."""
    tb = Bench(dut, 2)
    await tb.start()
    rng = tb.rng

    async def echo(n):
        data = rng.randbytes(n)
        r = await tb.ask(udp(OUR_IP, 4000, ECHO_PORT, data), True)
        u = check_ip(r, 17)
        assert struct.unpack("!H", u[4:6])[0] == 8 + n and u[8:] == data, n

    await echo(1536)
    for n in (1537, 4095, 4096, 4097, 8192, 8193):
        await tb.ask(udp(OUR_IP, 4000, ECHO_PORT, rng.randbytes(n)), False)
        await echo(20)
    # a short datagram, then a long one straight after it: the long one
    # starts while the short one's reply goes out, and outlasts the reply
    n0 = len(tb.got)
    a = rng.randbytes(100)
    await tb.send(udp(OUR_IP, 4001, ECHO_PORT, a), gap_p=0.0)
    await tb.send(udp(OUR_IP, 4002, ECHO_PORT, rng.randbytes(1400)), gap_p=0.0)
    await ClockCycles(dut.clk, 4000)
    assert len(tb.got) == n0 + 1, ("replies", len(tb.got) - n0)
    assert check_ip(tb.got[n0], 17)[8:] == a
    await echo(30)
