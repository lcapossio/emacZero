# SPDX-License-Identifier: Apache-2.0
"""cocotb port of sim/tb/tb_mii_rx_replay_stress.v (build_and_test.py bench
MII-RX-REPLAY-STRESS): raw MII RX nibbles go straight into mii_if (defaults:
MII_DEBUG 0, TX_ENABLE 1) built for XILINX_7SERIES, and the GMII RX byte
stream it replays is checked byte for byte.

As in the bench, XILINX_7SERIES selects the xpm_fifo_async /
xpm_memory_sdpram macros, bound to behavioural models whose FIFO drops
data_valid for one rd_clk after each read (the FWFT replay corner the plain
async_fifo does not model): the Verilog run uses the bench's
sim/tb/xpm_fifo_async_model.v and xpm_memory_sdpram_model.v, the VHDL run
their full-size VHDL-93 twins sim/cocotb/hdl/xpm_*_model.vhd (equivalence
proof in sim/parity/harness_xpm_models/).

Same clocks: clk 100 MHz and mii_tx_clk 25 MHz low at t=0; mii_rx_clk 25 MHz
low until 7 ns and then toggling. Reset release at 150 ns, 20 mii_rx_clk
rising edges, then three frames (L2 1518, 512, 1518 bytes; on the wire
preamble + SFD + L2 + 4 trailing bytes = 1530, 524, 1530), each nibble set on
the falling edge of mii_rx_clk, rx_dv low and 24 idle cycles after each frame.
Then wait up to 200000 clk cycles for the three frames. The bench's 5 ms
watchdog is the test timeout. The capture mirrors the bench's posedge-clk
always block (pre-edge values, sampled here on the falling edge).

Checks, in the bench's order (any failure fails the single test):
  - during capture: every gmii_rx_dv byte with gmii_rx_er high is a failure.
  1. replayed frame count == 3.
  2. per frame: replayed length (gmii_rx_dv run) == 1530 / 524 / 1530.
  3. per frame: every byte == the driven byte (first mismatch only).
No random stimulus.
"""
import cocotb
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from lib.mii_bench import bench_clock, byte_or_none, level

# Suites this module backs (read by run.py; see its docstring).
SUITES = {
    "mii_rx_replay_stress": {
        "toplevel": "mii_if",
        "target": "XILINX_7SERIES",
        "sources": ["sim/tb/xpm_fifo_async_model.v", "sim/tb/xpm_memory_sdpram_model.v",
                    "rtl/mii_if.v"],
        # mii_if.vhd instantiates entity work.async_fifo in its (off) non-Xilinx
        # generates, so async_fifo must be analysed too.
        "vhdl_sources": ["sim/cocotb/hdl/xpm_fifo_async_model.vhd",
                         "sim/cocotb/hdl/xpm_memory_sdpram_model.vhd",
                         "rtl/vhdl/async_fifo.vhd", "rtl/vhdl/mii_if.vhd"],
        "params": {},
    },
}

FRAME_COUNT = 3
MAX_FRAME_BYTES = 1530
L2_LEN = [1518, 512, 1518]
EXPECTED_LEN = [1530, 524, 1530]


def expected_byte(fidx, bidx):
    if bidx < 7:
        return 0x55
    if bidx == 7:
        return 0xD5
    if bidx < 8 + L2_LEN[fidx]:
        p = bidx - 8
        if p <= 5:
            return 0xF0 | (fidx & 0xF)
        hdr = {6: 0x02, 7: 0x00, 8: 0x00, 9: 0x00, 10: 0x00, 11: fidx & 0xFF,
               12: 0x08, 13: 0x00}
        if p in hdr:
            return hdr[p]
        return (p + fidx * 37) & 0xFF
    p = bidx - (8 + L2_LEN[fidx])
    return (0xA5 ^ (fidx & 0xFF) ^ (p & 0xFF)) & 0xFF


class ReplayCapture:
    """The bench's always @(posedge clk or negedge rst_n) GMII RX capture."""

    def __init__(self, dut, fails):
        self.dut = dut
        self.fails = fails
        self.rx_frame_count = 0
        self.rx_idx = 0
        self.prev_dv = "0"
        self.cap = [dict() for _ in range(FRAME_COUNT)]
        self.got_len = [None] * FRAME_COUNT

    async def run(self):
        dut = self.dut
        while True:
            await FallingEdge(dut.clk)
            dv = level(dut.gmii_rx_dv)
            new_idx, new_count = self.rx_idx, self.rx_frame_count
            if dv == "1":
                if self.rx_frame_count < FRAME_COUNT and self.rx_idx < MAX_FRAME_BYTES:
                    self.cap[self.rx_frame_count][self.rx_idx] = byte_or_none(dut.gmii_rxd)
                new_idx = self.rx_idx + 1
                if level(dut.gmii_rx_er) == "1":
                    msg = (f"gmii_rx_er asserted in frame {self.rx_frame_count} "
                           f"byte {self.rx_idx}")
                    dut._log.error("FAIL: " + msg)
                    self.fails.append(msg)
            if self.prev_dv == "1" and dv == "0":
                if self.rx_frame_count < FRAME_COUNT:
                    self.got_len[self.rx_frame_count] = self.rx_idx & 0xFFFF
                new_count = self.rx_frame_count + 1
                new_idx = 0
            self.prev_dv = dv
            self.rx_idx, self.rx_frame_count = new_idx, new_count


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def rx_replay_stress(dut):
    """Three MII RX frames through the XPM FWFT FIFO replay: count, length, data."""
    dut.rst_n.value = 0
    dut.mii_rxd.value = 0
    dut.mii_rx_dv.value = 0
    dut.mii_rx_er.value = 0
    dut.mii_col.value = 0
    dut.mii_crs.value = 0
    dut.gmii_txd.value = 0
    dut.gmii_tx_en.value = 0
    dut.gmii_tx_er.value = 0
    await bench_clock(dut.clk, 5)
    await bench_clock(dut.mii_tx_clk, 20)
    cocotb.start_soon(bench_clock(dut.mii_rx_clk, 20, delay_ns=7))
    await Timer(150, unit="ns")
    dut.rst_n.value = 1

    passes, fails = [], []
    cap = ReplayCapture(dut, fails)
    cocotb.start_soon(cap.run())

    for _ in range(20):
        await RisingEdge(dut.mii_rx_clk)

    for f in range(FRAME_COUNT):
        for k in range(EXPECTED_LEN[f]):
            value = expected_byte(f, k)
            await FallingEdge(dut.mii_rx_clk)
            dut.mii_rxd.value = value & 0xF
            dut.mii_rx_dv.value = 1
            dut.mii_rx_er.value = 0
            await FallingEdge(dut.mii_rx_clk)
            dut.mii_rxd.value = (value >> 4) & 0xF
            dut.mii_rx_dv.value = 1
            dut.mii_rx_er.value = 0
        await FallingEdge(dut.mii_rx_clk)
        dut.mii_rx_dv.value = 0
        dut.mii_rx_er.value = 0
        dut.mii_rxd.value = 0
        for _ in range(24):
            await FallingEdge(dut.mii_rx_clk)

    wait_cycles = 0
    while cap.rx_frame_count < FRAME_COUNT and wait_cycles < 200000:
        await RisingEdge(dut.clk)
        wait_cycles += 1

    def check_int(name, got, exp):
        if got == exp:
            passes.append(f"{name} = {got}")
        else:
            fails.append(f"{name} got {got} expected {exp}")

    check_int("replayed frame count", cap.rx_frame_count, FRAME_COUNT)
    for f in range(FRAME_COUNT):
        check_int("replayed frame length", cap.got_len[f], EXPECTED_LEN[f])
        mismatch = None
        for b in range(EXPECTED_LEN[f]):
            got = cap.cap[f].get(b)
            if got != expected_byte(f, b):
                mismatch = (f"frame {f} byte {b} got {got} "
                            f"expected {expected_byte(f, b):02x}")
                break
        if mismatch is None:
            passes.append(f"frame {f} replay data matched")
        else:
            fails.append(mismatch)

    for msg in passes:
        dut._log.info("PASS: " + msg)
    for msg in fails:
        dut._log.error("FAIL: " + msg)
    assert not fails, f"{len(passes)} passed, {len(fails)} failed: {fails}"
