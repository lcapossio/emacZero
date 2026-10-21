# SPDX-License-Identifier: Apache-2.0
"""cocotb port of sim/tb/tb_eth_mac_rx_backpressure.v
(build_and_test.py: ETH-MAC-RX-BACKPRESSURE).

eth_mac_tx -> negedge GMII loopback -> eth_mac_rx (harness h_eth_mac_rx_loop,
default parameters: AXIS FIFO 2048 bytes; our_mac FF:FF:FF:FF:FF:FF, promisc
0, passthrough 0, jumbo_en 1, rx_csum_en 0, mcast_hash_table 0). The frame is
74 bytes: broadcast dst, src 02:00:00:00:00:01, type 0x0800, then bytes i.

Checks, in the bench's order:
  (throughout, while rst_n) stat_done and stat_drop never in the same cycle
  1. rx_tready held low until 20 cycles after rx_tvalid first rises, while the
     frame is sent: 74 bytes received after the stall
  2. the received bytes equal the frame
  3. the last TLAST of that frame had no terror
  FIFO held full (rx_tready low, 32 frames for us back to back, then 100
  cycles), with full_frames = (2048 - 4) / 74 = 27:
  4. stat_done + stat_drop == 32
  5. stat_done == 28
  6. stat_done with stat_err_overflow == 1
  7. stat_drop == 4
  8. a frame for 02:00:00:00:00:99 while full: stat_done + stat_drop == 0
  9. after rx_tready goes high and 3000 cycles: 28 TLAST handshakes
 10. ... of which 1 with terror
The bench uses no $random.
"""
import cocotb
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer

from lib.rx_loop import NegedgeLoop, start_clock, send_posedge_style, is1


# Suites this module backs (read by run.py; see its docstring).
SUITES = {
    "eth_mac_rx_backpressure": {
        "toplevel": "h_eth_mac_rx_loop",
        "sources": ["rtl/crc32.v", "rtl/eth_mac_tx.v", "rtl/sync_fifo.v",
                    "rtl/net/csum_calc.v", "rtl/eth_mac_rx.v",
                    "sim/cocotb/hdl/h_eth_mac_rx_loop.v"],
        "params": {},
    },
}

FRAME_LEN = 74
N_FRAMES = 32
FULL_FRAMES = (2048 - 4) // FRAME_LEN    # 27 for FRAME_LEN = 74


def base_frame():
    f = [0xFF] * 6 + [0x02, 0x00, 0x00, 0x00, 0x00, 0x01, 0x08, 0x00]
    f += [i & 0xFF for i in range(14, FRAME_LEN)]
    return f


class Tally:
    """The bench's posedge always blocks: stat/TLAST tallies and RX capture."""

    def __init__(self, dut):
        self.dut = dut
        self.n_done = self.n_overflow = self.n_drop = 0
        self.n_tlast = self.n_tlast_err = 0
        self.same_cycle = 0            # stat_done && stat_drop (bench: FAIL)
        self.rx_count = 0
        self.rx_buf = [None] * FRAME_LEN
        self.last_rx_error = False

    def clear(self):
        self.n_done = self.n_overflow = self.n_drop = 0
        self.n_tlast = self.n_tlast_err = 0

    def sample(self):
        d = self.dut
        done = is1(d.stat_done)
        drop = is1(d.stat_drop)
        if done:
            self.n_done += 1
        if done and is1(d.stat_err_overflow):
            self.n_overflow += 1
        if drop:
            self.n_drop += 1
        if done and drop:
            d._log.error("FAIL: stat_done and stat_drop in the same cycle")
            self.same_cycle += 1
        if is1(d.rx_tvalid) and is1(d.rx_tready):
            if is1(d.rx_tlast):
                self.n_tlast += 1
                if is1(d.rx_terror):
                    self.n_tlast_err += 1
            # RX capture (async-reset block in the bench)
            if self.rx_count < FRAME_LEN:
                self.rx_buf[self.rx_count] = int(d.rx_tdata.value)
            self.rx_count += 1
            if is1(d.rx_tlast):
                self.last_rx_error = is1(d.rx_terror)


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def rx_backpressure(dut):
    start_clock(dut)
    dut.tx_tvalid.value = 0
    dut.tx_tlast.value = 0
    dut.tx_tdata.value = 0
    dut.rx_tready.value = 0
    dut.our_mac.value = 0xFFFFFFFFFFFF
    dut.promisc.value = 0
    dut.passthrough.value = 0
    dut.jumbo_en.value = 1
    dut.rx_csum_en.value = 0
    dut.mcast_hash_table.value = 0
    dut.rst_n.value = 0

    t = Tally(dut)
    loop = NegedgeLoop(dut)
    loop.samplers.append(t.sample)
    loop.start()

    await Timer(100, "ns")
    dut.rst_n.value = 1
    await Timer(100, "ns")

    failures = []

    def check(name, ok, msg):
        if ok:
            dut._log.info(f"PASS: {name}")
        else:
            dut._log.error(f"FAIL: {name}: {msg}")
            failures.append(name)

    def check_int(name, actual, expected):
        check(f"{name} = {actual}", actual == expected, f"expected {expected}")

    frame = base_frame()

    async def release_tready():
        # wait (rx_tvalid); repeat (20) @(posedge clk); @(negedge clk); rx_tready = 1;
        while True:
            await ReadOnly()
            if is1(dut.rx_tvalid):
                break
            await RisingEdge(dut.clk)
        for _ in range(20):
            await RisingEdge(dut.clk)
        await FallingEdge(dut.clk)
        dut.rx_tready.value = 1

    # fork send_frame / release_tready join
    rel = cocotb.start_soon(release_tready())
    await send_posedge_style(dut, frame)
    await rel

    for _ in range(200):
        await RisingEdge(dut.clk)

    check("received payload bytes after stall", t.rx_count == FRAME_LEN,
          f"received {t.rx_count} payload bytes, expected {FRAME_LEN}")
    check("stalled RX data integrity", t.rx_buf == frame, "stalled RX data mismatch")
    check("no RX error after backpressure", not t.last_rx_error,
          "RX error asserted after backpressure")

    # ---- FIFO held full ----
    await FallingEdge(dut.clk)
    dut.rx_tready.value = 0
    t.clear()
    for _ in range(N_FRAMES):
        await send_posedge_style(dut, frame)
    for _ in range(100):
        await RisingEdge(dut.clk)

    check_int("done + drop (FIFO full)", t.n_done + t.n_drop, N_FRAMES)
    check_int("stat_done (FIFO full)", t.n_done, FULL_FRAMES + 1)
    check_int("stat_err_overflow (FIFO full)", t.n_overflow, 1)
    check_int("stat_drop (FIFO full)", t.n_drop, N_FRAMES - FULL_FRAMES - 1)

    # A frame for another MAC while the FIFO is full: no stat at all
    other = [0x02, 0x00, 0x00, 0x00, 0x00, 0x99] + frame[6:]
    t.n_done = 0
    t.n_drop = 0
    await send_posedge_style(dut, other)
    for _ in range(100):
        await RisingEdge(dut.clk)
    check_int("done + drop (other MAC)", t.n_done + t.n_drop, 0)

    # Drain
    await FallingEdge(dut.clk)
    dut.rx_tready.value = 1
    for _ in range(3000):
        await RisingEdge(dut.clk)
    check_int("TLAST handshakes after drain", t.n_tlast, FULL_FRAMES + 1)
    check_int("terror TLASTs after drain", t.n_tlast_err, 1)

    check_int("cycles with stat_done and stat_drop together", t.same_cycle, 0)
    assert not failures, f"failed: {failures}"
