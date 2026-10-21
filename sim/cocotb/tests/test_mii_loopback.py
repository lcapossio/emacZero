# SPDX-License-Identifier: Apache-2.0
"""cocotb port of sim/tb/tb_mii_loopback.v (build_and_test.py bench
MII-LOOPBACK): eth_mac_tx -> mii_if -> MII TX pins looped to MII RX pins ->
mii_if -> eth_mac_rx, through the harness sim/cocotb/hdl/h_mii_loopback.{v,vhd}
(the bench's DUT wiring; equivalence proof in sim/parity/harness_mii_loopback/).
One 74-byte broadcast frame (ICMP-ping sized) checks the CRC through the
complete nibble path.

Same clocks: clk 100 MHz and mii_tx_clk 25 MHz low at t=0, mii_rx_clk 25 MHz
low until 10 ns and then toggling (10 ns behind mii_tx_clk). Reset release at
100 ns, frame start 500 ns later (bench AXIS loop, no idle after), verdict at
200.2 us. The checker mirrors the bench's posedge-clk always block (no reset;
pre-edge values, sampled here on the falling edge).

Check (the bench's only pass/fail condition):
  1. a frame ended (mac_rx_last seen) and m_axis_terror was low on the last
     such beat ("MII loopback CRC OK").
The bench only prints the rest and so does this test, without asserting:
the RX data mismatch count against the sent frame, eth_mac_rx's internal
crc_out / mac_ok / rx_er_seen (read through lib.hier), the GMII TX / RX byte
counts and any GMII TX vs RX raw byte difference.
No random stimulus.
"""
import cocotb
from cocotb.triggers import FallingEdge, Timer

from lib.hier import hier
from lib.mii_bench import bench_clock, byte_or_none, is1, level, send_frame_posedge

# Suites this module backs (read by run.py; see its docstring).
SUITES = {
    "mii_loopback": {
        "toplevel": "h_mii_loopback",
        "sources": ["rtl/crc32.v", "rtl/async_fifo.v", "rtl/mii_if.v", "rtl/sync_fifo.v",
                    "rtl/net/csum_calc.v", "rtl/eth_mac_rx.v", "rtl/eth_mac_tx.v",
                    "sim/cocotb/hdl/h_mii_loopback.v"],
        "params": {},
    },
}

FRAME_LEN = 74
FRAME = bytes([0xFF] * 6 + [0x02, 0x00, 0x00, 0x00, 0x00, 0x01, 0x08, 0x00]
              + [i & 0xFF for i in range(14, FRAME_LEN)])


class RxChecker:
    """The bench's always @(posedge clk) RX checker (no reset)."""

    def __init__(self, dut):
        self.dut = dut
        self.rx_cnt = 0
        self.gmii_tx_byte_cnt = 0
        self.gmii_rx_byte_cnt = 0
        self.rx_frame_done = False
        self.rx_had_error = "0"
        self.rx_mac_ok = "0"
        self.rx_crc_raw_at_last = 0
        self.rx_mismatch = 0
        self.gmii_tx_buf = {}
        self.gmii_rx_buf = {}
        self.mac_ok = hier(dut, "u_mac_rx.mac_ok")
        self.crc_out = hier(dut, "u_mac_rx.crc_out")

    async def run(self):
        dut = self.dut
        while True:
            await FallingEdge(dut.clk)
            if is1(dut.gmii_tx_en):
                if self.gmii_tx_byte_cnt < 128:
                    self.gmii_tx_buf[self.gmii_tx_byte_cnt] = byte_or_none(dut.gmii_txd)
                self.gmii_tx_byte_cnt += 1
            if is1(dut.gmii_rx_dv):
                if self.gmii_rx_byte_cnt < 128:
                    self.gmii_rx_buf[self.gmii_rx_byte_cnt] = byte_or_none(dut.gmii_rxd)
                self.gmii_rx_byte_cnt += 1
            if is1(dut.mac_rx_valid):
                got = byte_or_none(dut.mac_rx_data)
                if self.rx_cnt < FRAME_LEN and got != FRAME[self.rx_cnt]:
                    dut._log.info(f"RX mismatch at byte {self.rx_cnt}: got {got} "
                                  f"expected {FRAME[self.rx_cnt]:02x}")
                    self.rx_mismatch += 1
                self.rx_cnt += 1
            if is1(dut.mac_rx_last):
                self.rx_frame_done = True
                self.rx_had_error = level(dut.mac_rx_error)
                self.rx_mac_ok = level(self.mac_ok)
                self.rx_crc_raw_at_last = byte_or_none(self.crc_out)


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def mii_loopback(dut):
    """74-byte frame TX -> MII loopback -> RX: frame received without CRC error."""
    dut.rst_n.value = 0
    dut.tx_valid.value = 0
    dut.tx_last.value = 0
    await bench_clock(dut.clk, 5)
    await bench_clock(dut.mii_tx_clk, 20)
    chk = RxChecker(dut)
    cocotb.start_soon(chk.run())

    async def rx_clk():
        await bench_clock(dut.mii_rx_clk, 20, delay_ns=10)

    async def reset():
        await Timer(100, unit="ns")
        dut.rst_n.value = 1

    async def tx():
        await Timer(100 + 500, unit="ns")       # @(posedge rst_n); #500;
        await send_frame_posedge(dut.clk, dut.tx_ready, dut.tx_data, dut.tx_valid,
                                 dut.tx_last, FRAME, idle_after=0)

    cocotb.start_soon(rx_clk())
    cocotb.start_soon(reset())
    cocotb.start_soon(tx())

    await Timer(200 + 200_000, unit="ns")

    passed = chk.rx_frame_done and chk.rx_had_error == "0"
    if chk.rx_frame_done:
        crc = chk.rx_crc_raw_at_last
        dut._log.info(f"RX CRC raw register = "
                      f"{('0x%08X' % crc) if crc is not None else 'X'}")
        dut._log.info(f"rx_er_seen={level(hier(dut, 'u_mac_rx.rx_er_seen'))} "
                      f"mac_ok={chk.rx_mac_ok}")
        dut._log.info(f"rx_mismatch={chk.rx_mismatch}")
        dut._log.info(f"gmii_tx_byte_cnt={chk.gmii_tx_byte_cnt}")
        dut._log.info(f"gmii_rx_byte_cnt={chk.gmii_rx_byte_cnt}")
        for i in range(min(chk.gmii_tx_byte_cnt, 96)):
            tx_b = chk.gmii_tx_buf.get(i)
            rx_b = chk.gmii_rx_buf.get(i) if i < chk.gmii_rx_byte_cnt else None
            if i >= chk.gmii_rx_byte_cnt or tx_b != rx_b:
                dut._log.info(f"RAW mismatch at byte {i}: tx={tx_b} rx={rx_b}")
        dut._log.info("Expected 0x2144DF1C or 0xDEBB20E3")
        if chk.rx_had_error == "1":
            dut._log.error(f"FAIL: CRC ERROR on MII loopback! rx_bytes={chk.rx_cnt}")
        else:
            dut._log.info(f"PASS: MII loopback CRC OK, rx_bytes={chk.rx_cnt}")
    else:
        dut._log.error("FAIL: No frame received after 200us")

    assert passed, (f"rx_frame_done={chk.rx_frame_done} "
                    f"rx_had_error={chk.rx_had_error}")
