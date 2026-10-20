# SPDX-License-Identifier: Apache-2.0
"""cocotb mirror of sim/tb/tb_gmii_cdc_rx_overflow.v.

build_and_test.py benches GMII-CDC-RX-OVERFLOW (suite gmii_cdc_rx_overflow,
FIFO_RAM_STYLE="BLOCK") and GMII-CDC-RX-OVERFLOW-DIST (suite
gmii_cdc_rx_overflow_dist). The bench's -DGMII_CDC_DISTRIBUTED only selects
FIFO_RAM_STYLE="DISTRIBUTED" and KEPT, so it maps to that parameter/generic
plus the GMII_CDC_RAM_STYLE env var the test derives KEPT from.

gmii_cdc with RX_FIFO_ADDR_WIDTH=6 (64-word RX FIFO); the media RX side is
driven directly (preamble + SFD + payload[i] = (id + i) & 0xFF) and sys_clk is
slowed from 100 MHz to 10 MHz to force overflow. KEPT = data words of an
overflowing frame that fit: 64 for BLOCK (the FIFO output-stage word), 63 for
DISTRIBUTED.

Checks, in the order of the bench (one cocotb test; the sections share state):
  T1  one frame delivered; frame exact and clean
  T2  only B's EOF was committed (C/D EOFs refused); exactly one frame out of
      B/C/D; B delivered as a valid truncated prefix; B's last byte carries
      rx_er; B is short (KEPT - 8 payload bytes); B is exactly KEPT beats; no
      stray beats; rx_frames_pending == 0; reader idle (!rx_reading)
  T3  two frames delivered (n_frames == 4); first exact and clean; second exact
      and clean
  T3b exactly one frame out of E/F/G; E exact and clean; F reached the FIFO as
      an EOF-only frame; no stray beats; pending == 0; reader idle
  T4  16 x 46-byte burst: at least one delivered; every delivered frame exact
      or truncated+rx_er, in order; no stray beats; pending == 0
  T5  24 x 54-byte burst: some clean; overflow exercised; every delivered frame
      exact or truncated+rx_er, in order; no stray beats; pending == 0
  T6  frame after the storm exact and clean
  (plus the bench's 2 ms simulation watchdog -> the test's timeout_time)

Differences from the bench, none of which changes what is checked:
  * The sys-side capture and the ovf_eofs coverage probe sample after each
    rising edge has settled (RisingEdge + ReadOnly), i.e. one edge earlier
    than the bench's always blocks see the same values; the accumulated totals
    are read only after wait_idle's settle time.
  * media_clk and media_rx_clk (one net in the bench) are toggled by one
    coroutine in the same delta; sys_clk is a coroutine that re-reads its half
    period every toggle, like `always #(sys_half)`.
  * Internal signals (rx_wr_accept, rx_wr_is_eof, rx_fifo_din,
    rx_frames_pending, rx_reading, rx_rd_empty) are read through lib.hier;
    they have the same names in rtl/gmii_cdc.v and rtl/vhdl/gmii_cdc.vhd.
    rx_fifo_din is read whole and bit 8 taken in Python, as the bench does.
"""
import os

import cocotb
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer

from lib.hier import hier


SUITES = {
    "gmii_cdc_rx_overflow": {
        "toplevel": "gmii_cdc",
        "sources": ["rtl/async_fifo.v", "rtl/gmii_cdc.v"],
        "params": {"RX_FIFO_ADDR_WIDTH": 6, "FIFO_RAM_STYLE": "BLOCK"},
        "env": {"GMII_CDC_RAM_STYLE": "BLOCK"},
    },
    "gmii_cdc_rx_overflow_dist": {
        "toplevel": "gmii_cdc",
        "sources": ["rtl/async_fifo.v", "rtl/gmii_cdc.v"],
        "params": {"RX_FIFO_ADDR_WIDTH": 6, "FIFO_RAM_STYLE": "DISTRIBUTED"},
        "env": {"GMII_CDC_RAM_STYLE": "DISTRIBUTED"},
    },
}

AW = 6
RAM_STYLE = os.environ.get("GMII_CDC_RAM_STYLE", "BLOCK")
KEPT = (1 << AW) - 1 if RAM_STYLE == "DISTRIBUTED" else (1 << AW)
MEDIA_HALF_NS = 4   # always #4 media_clk = ~media_clk; (125 MHz)


class _Bench:
    """State of tb_gmii_cdc_rx_overflow's capture/probe always blocks."""

    def __init__(self, dut):
        self.dut = dut
        self.sys_half = 5                 # integer sys_half (variable sys_clk)
        # capture
        self.cap_d = [None] * 256
        self.cap_er = [None] * 256
        self.cap_len = 0
        self.capturing = 0
        # per-frame results, by delivery order (unwritten = X in the bench)
        self.n_frames = 0
        self.fr_id = [None] * 64
        self.fr_plen = [None] * 64
        self.fr_len = [None] * 64
        self.fr_trunc = [False] * 64
        self.fr_ok = [False] * 64
        self.stray_beats = 0
        self.ovf_eofs = 0
        # internal probes
        self.rx_wr_accept = hier(dut, "rx_wr_accept")
        self.rx_wr_is_eof = hier(dut, "rx_wr_is_eof")
        self.rx_fifo_din = hier(dut, "rx_fifo_din")
        self.rx_frames_pending = hier(dut, "rx_frames_pending")
        self.rx_reading = hier(dut, "rx_reading")
        self.rx_rd_empty = hier(dut, "rx_rd_empty")

    # ---- clocks --------------------------------------------------------
    async def sys_clock(self):
        clk = self.dut.sys_clk
        level = 0
        clk.value = 0
        while True:
            await Timer(self.sys_half, "ns")
            level ^= 1
            clk.value = level

    async def media_clock(self):
        level = 0
        self.dut.media_clk.value = 0
        self.dut.media_rx_clk.value = 0
        while True:
            await Timer(MEDIA_HALF_NS, "ns")
            level ^= 1
            self.dut.media_clk.value = level
            self.dut.media_rx_clk.value = level

    # ---- coverage probe: error-flagged EOF words committed to the FIFO --
    async def probe(self):
        while True:
            await RisingEdge(self.dut.media_clk)
            await ReadOnly()
            if not int(self.dut.sys_rst_n.value):
                continue
            din = int(self.rx_fifo_din.value)
            if int(self.rx_wr_accept.value) and int(self.rx_wr_is_eof.value) and (din >> 8) & 1:
                self.ovf_eofs += 1

    # ---- sys-side capture + per-frame check ----------------------------
    async def capture(self):
        dut = self.dut
        while True:
            await RisingEdge(dut.sys_clk)
            await ReadOnly()
            if not int(dut.sys_rst_n.value):
                self.cap_len = 0
                self.capturing = 0
            elif int(dut.gmii_rx_dv_out.value):
                if self.cap_len < 256:
                    self.cap_d[self.cap_len] = int(dut.gmii_rxd_out.value)
                    self.cap_er[self.cap_len] = int(dut.gmii_rx_er_out.value)
                self.cap_len += 1
                self.capturing = 1
            elif self.capturing:
                length = self.cap_len
                self.capturing = 0
                self.cap_len = 0
                self.analyse(length)

    def analyse(self, length):
        """Strip leading 0x55, require the SFD, check payload[i] = payload[0] + i.

        rx_er on the last byte marks truncation (that byte is content-checked
        like the rest); rx_er anywhere else is a failure.
        """
        cap_d, cap_er = self.cap_d, self.cap_er
        ok = True
        last = length
        pre = 0
        for j in range(length - 1):
            if cap_er[j]:
                ok = False
        while pre < last and cap_d[pre] == 0x55:
            pre += 1
        if pre >= last or cap_d[pre] != 0xD5 or pre < 6:
            ok = False
        p = last - pre - 1                   # payload bytes delivered
        if ok and p > 0:
            for j in range(1, p):
                if cap_d[pre + 1 + j] != ((cap_d[pre + 1] + j) & 0xFF):
                    ok = False
        n = self.n_frames
        if n < 64:
            self.fr_id[n] = cap_d[pre + 1] if (ok and p > 0) else -1
            self.fr_plen[n] = p
            self.fr_len[n] = length
            self.fr_trunc[n] = length > 0 and bool(cap_er[length - 1])
            self.fr_ok[n] = ok
        if not ok:
            self.stray_beats += length
        self.n_frames += 1


@cocotb.test(timeout_time=2_000_000, timeout_unit="ns")
async def tb_gmii_cdc_rx_overflow(dut):
    results = []

    def check(name, cond):
        dut._log.info(f"{'PASS' if cond else 'FAIL'}: {name}")
        results.append((name, bool(cond)))

    dut._log.info(f"FIFO_RAM_STYLE={RAM_STYLE} KEPT={KEPT}")
    tb = _Bench(dut)

    # Unused TX side and status, tied as in the bench.
    dut.cfg_speed.value = 0b00
    dut.gmii_txd_in.value = 0
    dut.gmii_tx_en_in.value = 0
    dut.gmii_tx_er_in.value = 0
    dut.gmii_rx_ce_in.value = 1

    dut.gmii_rxd_in.value = 0
    dut.gmii_rx_dv_in.value = 0
    dut.gmii_rx_er_in.value = 0
    dut.sys_rst_n.value = 0
    cocotb.start_soon(tb.sys_clock())
    cocotb.start_soon(tb.media_clock())
    cocotb.start_soon(tb.capture())
    cocotb.start_soon(tb.probe())
    await Timer(200, "ns")
    dut.sys_rst_n.value = 1
    await Timer(500, "ns")

    async def send_frame(fid, payload_len, ifg):
        await FallingEdge(dut.media_clk)
        for k in range(8 + payload_len):
            dut.gmii_rx_dv_in.value = 1
            dut.gmii_rx_er_in.value = 0
            dut.gmii_rxd_in.value = (0x55 if k < 7 else 0xD5 if k == 7
                                     else (fid + k - 8) & 0xFF)
            await FallingEdge(dut.media_clk)
        dut.gmii_rx_dv_in.value = 0
        dut.gmii_rxd_in.value = 0
        for _ in range(ifg):
            await FallingEdge(dut.media_clk)

    def busy():
        return (int(tb.rx_frames_pending.value) != 0 or int(tb.rx_reading.value)
                or not int(tb.rx_rd_empty.value) or tb.capturing)

    async def wait_idle():
        t = 0
        await ReadOnly()
        while busy() and t < 20000:
            await RisingEdge(dut.media_clk)
            await ReadOnly()
            t += 1
        for _ in range(200):
            await RisingEdge(dut.media_clk)

    async def sys_posedges(n):
        for _ in range(n):
            await RisingEdge(dut.sys_clk)

    def pending():
        return int(tb.rx_frames_pending.value)

    def reading():
        return int(tb.rx_reading.value)

    fr_ok, fr_trunc, fr_id = tb.fr_ok, tb.fr_trunc, tb.fr_id
    fr_plen, fr_len = tb.fr_plen, tb.fr_len

    # ---- T1: a frame that fits is delivered exact and clean --------------
    await send_frame(0x10, 20, 12)
    await wait_idle()
    check("T1 one frame delivered", tb.n_frames == 1)
    check("T1 frame exact and clean",
          fr_ok[0] and not fr_trunc[0] and fr_id[0] == 0x10 and fr_plen[0] == 20)

    # ---- T2: overflow with a slow sys side (10 MHz) ----------------------
    i = tb.ovf_eofs
    tb.sys_half = 50
    await sys_posedges(4)
    await send_frame(0x20, 100, 30)      # B
    await send_frame(0x40, 10, 30)       # C
    await send_frame(0x60, 10, 30)       # D
    await wait_idle()
    tb.sys_half = 5
    await sys_posedges(20)

    check("T2 only B's EOF was committed (C/D EOFs refused)", tb.ovf_eofs == i + 1)
    check("T2 exactly one frame out of B/C/D", tb.n_frames == 2)
    check("T2 B delivered as a valid truncated prefix", fr_ok[1] and fr_id[1] == 0x20)
    check("T2 B's last byte carries rx_er", fr_trunc[1])
    check("T2 B is short (KEPT words - 8 preamble/SFD)", fr_plen[1] == KEPT - 8)
    check("T2 B is exactly the KEPT words, no extra error byte", fr_len[1] == KEPT)
    check("T2 no stray beats from the dropped frames", tb.stray_beats == 0)
    check("T2 pending-frame count back to zero", pending() == 0)
    check("T2 reader idle", not reading())

    # ---- T3: normal traffic after overflow is intact ---------------------
    await send_frame(0x80, 20, 12)
    await send_frame(0x90, 30, 12)
    await wait_idle()
    check("T3 two frames delivered", tb.n_frames == 4)
    check("T3 first frame exact and clean",
          fr_ok[2] and not fr_trunc[2] and fr_id[2] == 0x80 and fr_plen[2] == 20)
    check("T3 second frame exact and clean",
          fr_ok[3] and not fr_trunc[3] and fr_id[3] == 0x90 and fr_plen[3] == 30)

    # ---- T3b: exact fit, then an EOF-only frame --------------------------
    base = tb.n_frames
    i = tb.ovf_eofs
    tb.sys_half = 50
    await sys_posedges(4)
    await send_frame(0xA0, KEPT - 9, 30)  # E
    await send_frame(0xC0, 10, 30)        # F
    await send_frame(0xE0, 10, 30)        # G
    await wait_idle()
    tb.sys_half = 5
    await sys_posedges(20)
    check("T3b exactly one frame out of E/F/G", tb.n_frames == base + 1)
    check("T3b E exact and clean",
          fr_ok[base] and not fr_trunc[base] and fr_id[base] == 0xA0
          and fr_plen[base] == KEPT - 9)
    check("T3b F reached the FIFO as an EOF-only frame", tb.ovf_eofs == i + 1)
    check("T3b no stray beats", tb.stray_beats == 0)
    check("T3b pending-frame count back to zero", pending() == 0)
    check("T3b reader idle", not reading())

    # ---- T4: burst of back-to-back frames at full rate -------------------
    base = tb.n_frames
    for i in range(16):
        await send_frame(i * 8, 46, 12)
    await wait_idle()

    bad = 0
    prev_id = -1
    i = base
    while i < tb.n_frames and i < 64:
        if not fr_ok[i]:
            bad += 1
        elif fr_id[i] <= prev_id:
            bad += 1
        elif not fr_trunc[i] and fr_plen[i] != 46:
            bad += 1
        elif fr_trunc[i] and fr_plen[i] >= 46:
            bad += 1
        prev_id = fr_id[i]
        i += 1
    dut._log.info(f"INFO: T4 delivered {tb.n_frames - base} of 16 burst frames")
    check("T4 delivered at least one burst frame", tb.n_frames > base)
    check("T4 every delivered frame exact or truncated+rx_er, in order", bad == 0)
    check("T4 no stray beats", tb.stray_beats == 0)
    check("T4 pending-frame count back to zero", pending() == 0)

    # ---- T5: overflowing burst -------------------------------------------
    base = tb.n_frames
    for i in range(24):
        await send_frame(i * 8, 54, 12)
    await wait_idle()

    bad = 0
    prev_id = -1
    trunc_n = 0
    clean_n = 0
    i = base
    while i < tb.n_frames and i < 64:
        if not fr_ok[i]:
            bad += 1
        elif fr_id[i] <= prev_id:
            bad += 1
        elif not fr_trunc[i] and fr_plen[i] != 54:
            bad += 1
        elif fr_trunc[i] and fr_plen[i] >= 54:
            bad += 1
        if fr_trunc[i]:
            trunc_n += 1
        else:
            clean_n += 1
        prev_id = fr_id[i]
        i += 1
    dut._log.info(f"INFO: T5 delivered {tb.n_frames - base} of 24 "
                  f"({clean_n} clean, {trunc_n} truncated)")
    check("T5 some frames delivered clean", clean_n > 0)
    check("T5 overflow actually exercised", trunc_n > 0 or tb.n_frames - base < 24)
    check("T5 every delivered frame exact or truncated+rx_er, in order", bad == 0)
    check("T5 no stray beats", tb.stray_beats == 0)
    check("T5 pending-frame count back to zero", pending() == 0)

    # ---- T6: recovery after the storm ------------------------------------
    base = tb.n_frames
    await send_frame(0x33, 40, 12)
    await wait_idle()
    check("T6 frame after overflow exact and clean",
          tb.n_frames == base + 1 and fr_ok[base] and not fr_trunc[base]
          and fr_id[base] == 0x33 and fr_plen[base] == 40)

    failed = [n for n, ok in results if not ok]
    dut._log.info(f"{len(results) - len(failed)} passed, {len(failed)} failed")
    assert not failed, "failed checks: " + "; ".join(failed)
