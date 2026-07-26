# SPDX-License-Identifier: Apache-2.0
"""Robustness suite for rtl/eth_mac_rx.v - edge cases the main suite does not hit:

  * FIFO-overflow framing: a frame that overruns the RX FIFO must still be
    terminated (TLAST) and flagged terror, and must NOT corrupt the next frame.
  * runt: an undersized frame (< 64 wire bytes) is delivered with terror, not as
    a clean frame with a garbage FCS.
  * preamble/SFD rx_er: an error on a non-data byte is still reported.
  * byte_cnt saturation: a frame longer than the 14-bit counter must not wrap and
    inject a phantom SOF that corrupts the following frame.
"""
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly

from lib.gmii_rx_driver import GmiiRxDriver
from lib.rx_model import StatsMonitor
from lib.eth import PREAMBLE_LEN

CLK_NS = 10
OUR_MAC = 0x020000000001


def _mac(v):
    return v.to_bytes(6, "big")


def _payload(dst_int, size, tag=0xC0):
    src = _mac(0x0A0B0C0D0E0F)
    etype = b"\x08\x00"
    data = bytes([(tag + i) & 0xFF for i in range(max(0, size - 14))])
    return _mac(dst_int) + src + etype + data


class GatedSink:
    """AXIS slave with an externally controllable tready (self.ready). Reassembles
    frames from tsof..tlast and records per-frame terror, like AxisSink."""
    def __init__(self, dut):
        self.dut = dut
        self.ready = False
        self.frames = []
        dut.m_axis_tready.value = 0

    async def run(self):
        dut = self.dut
        cur = bytearray()
        err = False
        while True:
            dut.m_axis_tready.value = 1 if self.ready else 0
            await ReadOnly()
            if self.ready and int(dut.m_axis_tvalid.value):
                if int(dut.m_axis_tsof.value):
                    cur = bytearray()
                    err = False
                cur.append(int(dut.m_axis_tdata.value) & 0xFF)
                if int(dut.m_axis_terror.value):
                    err = True
                if int(dut.m_axis_tlast.value):
                    self.frames.append({"payload": bytes(cur), "terror": err})
                    cur = bytearray()
                    err = False
            await RisingEdge(dut.clk)


async def _setup(dut, jumbo=0):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    dut.our_mac.value = OUR_MAC
    dut.promisc.value = 0
    dut.passthrough.value = 0
    dut.jumbo_en.value = jumbo
    dut.mcast_hash_table.value = 0
    dut.gmii_rxd.value = 0
    dut.gmii_rx_dv.value = 0
    dut.gmii_rx_er.value = 0
    dut.m_axis_tready.value = 0
    dut.rst_n.value = 0
    for _ in range(8):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    for _ in range(4):
        await RisingEdge(dut.clk)


@cocotb.test(timeout_time=40, timeout_unit="ms")
async def overflow_framing(dut):
    """A jumbo frame received with tready held low overruns the 2 KB RX FIFO. It
    must still be terminated with terror, and the next (clean) frame must arrive
    intact - proving SOF/TLAST framing survives overflow."""
    await _setup(dut, jumbo=1)
    sink = GatedSink(dut)
    stats = StatsMonitor(dut)
    cocotb.start_soon(sink.run())
    cocotb.start_soon(stats.run())
    drv = GmiiRxDriver(dut)
    await drv.idle(4)

    big = _payload(OUR_MAC, 3000, tag=0x10)     # > 2048-byte FIFO, <= jumbo max
    await drv.send_frame(big)                   # tready is low -> FIFO overflows
    # Keep draining OFF a while longer so the closing TLAST is pushed while the
    # FIFO is still full: only the reserved-headroom path keeps it (and thus the
    # frame's termination) alive. Without the reserve, TLAST is dropped here.
    for _ in range(16):
        await RisingEdge(dut.clk)
    sink.ready = True
    for _ in range(3000):                       # fully drain the ~2K buffered frame
        await RisingEdge(dut.clk)
    small = _payload(OUR_MAC, 64, tag=0xA0)
    await drv.send_frame(small)
    for _ in range(400):
        await RisingEdge(dut.clk)

    assert len(sink.frames) == 2, \
        f"expected 2 delimited frames (overflow + clean), got {len(sink.frames)}"
    assert sink.frames[0]["terror"], "overflowed frame must carry terror"
    assert len(sink.frames[0]["payload"]) < 3000, "overflowed frame must be truncated"
    assert sink.frames[1]["payload"] == small and not sink.frames[1]["terror"], \
        "the frame after an overflow must be intact and error-free"
    dut._log.info(f"OK: overflow frame terror+terminated ({len(sink.frames[0]['payload'])}B), "
                  f"next frame intact")


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def runt_terror(dut):
    """A 20-byte runt that passes the filter is delivered with terror, not as a
    clean short frame; a following full frame is unaffected."""
    await _setup(dut)
    sink = GatedSink(dut)
    sink.ready = True
    cocotb.start_soon(sink.run())
    drv = GmiiRxDriver(dut)
    await drv.idle(4)
    await drv.send_frame(_payload(OUR_MAC, 20, tag=0x30))   # 20+4 = 24 wire bytes < 64
    await drv.idle(64)
    good = _payload(OUR_MAC, 64, tag=0x70)
    await drv.send_frame(good)
    await drv.idle(64)
    for _ in range(200):
        await RisingEdge(dut.clk)

    assert len(sink.frames) == 2, f"expected 2 frames, got {len(sink.frames)}"
    assert sink.frames[0]["terror"], "runt must be delivered with terror"
    assert sink.frames[1]["payload"] == good and not sink.frames[1]["terror"], \
        "full frame after a runt must be clean"
    dut._log.info("OK: runt flagged terror; following frame clean")


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def preamble_rx_er(dut):
    """rx_er asserted on the SFD byte (wire index 7) must be reported: the frame
    carries terror and stat_err_align, even though the error is not in S_DATA."""
    await _setup(dut)
    sink = GatedSink(dut)
    sink.ready = True
    stats = StatsMonitor(dut)
    cocotb.start_soon(sink.run())
    cocotb.start_soon(stats.run())
    drv = GmiiRxDriver(dut)
    await drv.idle(4)
    await drv.send_frame(_payload(OUR_MAC, 64, tag=0x40), er_wire_idx=PREAMBLE_LEN)
    await drv.idle(64)
    for _ in range(200):
        await RisingEdge(dut.clk)

    assert len(sink.frames) == 1, f"expected 1 frame, got {len(sink.frames)}"
    assert sink.frames[0]["terror"], "SFD-byte rx_er must set terror"
    assert stats.records and stats.records[0]["align"], \
        "SFD-byte rx_er must set stat_err_align"
    dut._log.info("OK: preamble/SFD rx_er reported")


@cocotb.test(timeout_time=60, timeout_unit="ms")
async def bytecnt_no_wrap(dut):
    """A frame longer than the 14-bit byte counter (>16383 wire bytes) must not
    wrap and inject a phantom SOF. A clean matching frame after it must arrive
    intact and singular - no corruption or extra delivery from the giant frame."""
    await _setup(dut, jumbo=1)
    sink = GatedSink(dut)
    sink.ready = True
    cocotb.start_soon(sink.run())
    drv = GmiiRxDriver(dut)
    await drv.idle(4)
    # 16600 payload bytes -> ~16604 wire bytes, past the 16384 counter wrap point.
    await drv.send_frame(_payload(OUR_MAC, 16600, tag=0x01))
    for _ in range(400):
        await RisingEdge(dut.clk)
    good = _payload(OUR_MAC, 64, tag=0x90)
    await drv.send_frame(good)
    for _ in range(400):
        await RisingEdge(dut.clk)

    # Exactly two frames: the giant one delivered once with terror (its oversize
    # flag survives because byte_cnt saturates instead of wrapping to a small
    # value), then the clean frame intact. A wrap injects a phantom SOF and
    # collapses the oversize flag, changing this count and/or leaking the giant
    # frame as a non-terror delivery.
    assert len(sink.frames) == 2, \
        f"expected 2 frames (giant+terror, clean); got {len(sink.frames)} " \
        f"lens={[len(f['payload']) for f in sink.frames]} " \
        f"terr={[f['terror'] for f in sink.frames]}"
    assert sink.frames[0]["terror"], "the oversize/overflow giant frame must carry terror"
    assert sink.frames[1]["payload"] == good and not sink.frames[1]["terror"], \
        "the clean frame after the giant frame must be intact"
    dut._log.info("OK: byte_cnt saturated; giant frame terror'd once, next frame intact")
