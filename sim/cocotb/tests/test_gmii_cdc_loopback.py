# SPDX-License-Identifier: Apache-2.0
"""cocotb mirror of sim/tb/tb_gmii_cdc.v (build_and_test.py bench GMII-CDC).

gmii_cdc at 1G (cfg_speed=00) with its media-side TX looped back into its
media-side RX: sys_clk GMII TX -> TX FIFO -> media_clk GMII -> loopback ->
RX FIFO -> sys_clk GMII RX. Frames carry byte[k] = k & 0xFF.

Checks, in the order of the bench (all in one cocotb test, as the bench runs
them back to back on one reset):
  1. frame_1 length      - 64-byte frame: 1 frame received, 64 bytes
  2. frame_1 integrity   - rx byte[i] == i
  3. frame_2 length      - 1500-byte frame: 1 frame received, 1500 bytes
  4. frame_2 integrity   - rx byte[i] == i & 0xFF
  5. back_to_back count  - 10-byte frame, #200, 20-byte frame: 2 frames received
  6. back_to_back bytes  - 30 bytes total over the two frames

Differences from the bench, none of which changes what is checked:
  * The loopback nets (gmii_txd_out/tx_en_out/tx_er_out -> gmii_rxd_in/
    rx_dv_in/rx_er_in) are copied by a coroutine on every media_clk falling
    edge. The media outputs change only on the media_clk rising edge, so the RX
    side sees the same value at every rising edge as through a wire.
  * media_clk and media_rx_clk (one net in the bench) are toggled by one
    coroutine in the same delta.
  * The sys-side capture samples after each sys_clk rising edge has settled
    (RisingEdge + ReadOnly), i.e. it sees one edge earlier what the bench's
    always block sees at the next edge; the totals it accumulates are the same.
  * The bench has no watchdog; the test has a 2 ms timeout_time, above the
    bench's own worst case (three 50000-cycle wait_rx_frame caps = 1.5 ms).
"""
import cocotb
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer


SUITES = {
    "gmii_cdc_loopback": {
        "toplevel": "gmii_cdc",
        "sources": ["rtl/async_fifo.v", "rtl/gmii_cdc.v"],
        "params": {},
    },
}

SYS_HALF_NS = 5     # always #5 sys_clk   = ~sys_clk;  (100 MHz)
MEDIA_HALF_NS = 4   # always #4 media_clk = ~media_clk; (125 MHz)


async def _clock(sigs, half_ns):
    """initial clk = 0; always #half clk = ~clk; (drives every sig in `sigs`)."""
    level = 0
    for s in sigs:
        s.value = 0
    while True:
        await Timer(half_ns, "ns")
        level ^= 1
        for s in sigs:
            s.value = level


class _Capture:
    """The bench's rx_buf/rx_idx/rx_frame_cnt/rx_capturing always block."""

    def __init__(self, dut):
        self.dut = dut
        self.rx_buf = [None] * 2048
        self.rx_idx = 0
        self.rx_frame_cnt = 0
        self.rx_capturing = 0

    async def run(self):
        dut = self.dut
        while True:
            await RisingEdge(dut.sys_clk)
            await ReadOnly()
            if not int(dut.sys_rst_n.value):
                self.rx_idx = 0
                self.rx_frame_cnt = 0
                self.rx_capturing = 0
            elif int(dut.gmii_rx_dv_out.value):
                if self.rx_idx < 2048:
                    self.rx_buf[self.rx_idx] = int(dut.gmii_rxd_out.value)
                self.rx_idx += 1
                self.rx_capturing = 1
            elif self.rx_capturing:
                self.rx_frame_cnt += 1
                self.rx_capturing = 0


async def _loopback(dut):
    """Media TX outputs -> media RX inputs (the bench's loopback wires)."""
    while True:
        await FallingEdge(dut.media_clk)
        dut.gmii_rxd_in.value = dut.gmii_txd_out.value
        dut.gmii_rx_dv_in.value = dut.gmii_tx_en_out.value
        dut.gmii_rx_er_in.value = dut.gmii_tx_er_out.value


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def tb_gmii_cdc(dut):
    results = []

    def check(name, cond):
        dut._log.info(f"{'PASS' if cond else 'FAIL'}: {name}")
        results.append((name, bool(cond)))

    cocotb.start_soon(_clock([dut.sys_clk], SYS_HALF_NS))
    cocotb.start_soon(_clock([dut.media_clk, dut.media_rx_clk], MEDIA_HALF_NS))
    dut.cfg_speed.value = 0b00           # 1G
    dut.gmii_rx_ce_in.value = 1
    dut.gmii_rxd_in.value = 0
    dut.gmii_rx_dv_in.value = 0
    dut.gmii_rx_er_in.value = 0

    dut.sys_rst_n.value = 0
    dut.gmii_txd_in.value = 0
    dut.gmii_tx_en_in.value = 0
    dut.gmii_tx_er_in.value = 0
    dut.gmii_ctl_txd_in.value = 0
    dut.gmii_ctl_tx_en_in.value = 0
    dut.gmii_ctl_tx_er_in.value = 0
    dut.tx_hold.value = 0
    cap = _Capture(dut)
    cocotb.start_soon(cap.run())
    cocotb.start_soon(_loopback(dut))
    await Timer(100, "ns")
    dut.sys_rst_n.value = 1
    await Timer(200, "ns")

    async def send_frame(length):
        await FallingEdge(dut.sys_clk)
        for k in range(length):
            dut.gmii_txd_in.value = k & 0xFF
            dut.gmii_tx_en_in.value = 1
            dut.gmii_tx_er_in.value = 0
            await FallingEdge(dut.sys_clk)
        dut.gmii_tx_en_in.value = 0
        dut.gmii_txd_in.value = 0

    async def wait_rx_frame(expected_cnt):
        timeout = 0
        while cap.rx_frame_cnt < expected_cnt and timeout < 50000:
            await RisingEdge(dut.sys_clk)
            timeout += 1

    # ---- Test 1: single 64-byte frame loopback --------------------------
    frame_len = 64
    cap.rx_idx = 0
    cap.rx_frame_cnt = 0
    await send_frame(frame_len)
    await wait_rx_frame(1)
    check(f"frame_1 length (rx_cnt={cap.rx_frame_cnt} rx_idx={cap.rx_idx}, "
          f"expected cnt=1 len={frame_len})",
          cap.rx_frame_cnt == 1 and cap.rx_idx == frame_len)
    bad = 0
    for i in range(frame_len):
        if cap.rx_buf[i] != (i & 0xFF):
            if bad < 5:
                dut._log.info(f"  byte[{i}] got {cap.rx_buf[i]}, expected 0x{i & 0xFF:02x}")
            bad += 1
    check(f"frame_1 data integrity ({bad} bytes wrong)", bad == 0)

    await Timer(500, "ns")

    # ---- Test 2: 1500-byte frame ----------------------------------------
    frame_len = 1500
    cap.rx_idx = 0
    cap.rx_frame_cnt = 0
    await send_frame(frame_len)
    await wait_rx_frame(1)
    check(f"frame_2 length (rx_cnt={cap.rx_frame_cnt} rx_idx={cap.rx_idx}, "
          f"expected cnt=1 len={frame_len})",
          cap.rx_frame_cnt == 1 and cap.rx_idx == frame_len)
    bad = any(cap.rx_buf[i] != (i & 0xFF) for i in range(frame_len))
    check("frame_2 data integrity", not bad)

    await Timer(500, "ns")

    # ---- Test 3: back-to-back short frames ------------------------------
    cap.rx_idx = 0
    cap.rx_frame_cnt = 0
    await send_frame(10)
    await Timer(200, "ns")
    await send_frame(20)
    await wait_rx_frame(2)
    check(f"back_to_back 2 frames received (rx_cnt={cap.rx_frame_cnt})",
          cap.rx_frame_cnt == 2)
    check(f"back_to_back total bytes = {cap.rx_idx} (expected 30)", cap.rx_idx == 30)

    await Timer(100, "ns")
    failed = [n for n, ok in results if not ok]
    dut._log.info(f"{len(results) - len(failed)} passed, {len(failed)} failed")
    assert not failed, "failed checks: " + "; ".join(failed)
