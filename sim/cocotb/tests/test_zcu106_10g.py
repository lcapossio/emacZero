# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""ZCU106 10GBASE-R bring-up logic (fpga/zcu106/rtl/).

  gt10g_reset          the GT reset sequencer against a behavioural model of
                       the QPLL0 / channel reset handshakes: bring-up order,
                       RX restart without touching TX, recovery from a QPLL0
                       lock loss and from a reset done that never comes
  xgmii_test_loop      xgmii_test_gen -> pcs10gbr -> line loopback at a bit
                       offset -> pcs10gbr -> xgmii_test_chk: every frame
                       length class arrives good and in sequence; injected
                       payload and line errors are counted
  xgmii_test_loop_o63  the same at the largest bit offset
  mac10g_test_loop     one port of the board design (zcu106_10g_lane) in
                       MAC mode with a line loopback: axis_test_gen64 (200
                       MHz app clock) -> eth_mac_sys_10g -> pcs10gbr ->
                       loopback -> pcs10gbr -> eth_mac_sys_10g ->
                       axis_test_chk64: minimum frames at line rate through
                       both clock crossings, a length sweep, jumbo frames,
                       an injected payload error counted once, and the MAC's
                       counters read through axil_cmd_master
  mac10g_dual          both ports (two zcu106_10g_lane) with a fibre between
                       them, each direction on its own clock: traffic both
                       ways at once at line rate, every length 64..1518
                       with the FCS one way while jumbo frames go the other,
                       each port's checker and MAC counters against the
                       other port's generator; IPv4 / UDP datagrams both
                       ways, 1472-byte ones at line rate
"""
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, RisingEdge


SUITES = {
    "gt10g_reset": {
        "toplevel": "gt10g_reset",
        "sources": ["fpga/zcu106/rtl/gt10g_reset.v"],
        "params": {"HOLD_CYCLES": 8, "TIMEOUT_CYCLES": 3000},
        "skip_vhdl": "ZCU106 10G bring-up logic is Verilog only",
    },
    "xgmii_test_loop": {
        "toplevel": "h_xgmii_test_loop",
        "sources": ["rtl/pcs10gbr_enc.v", "rtl/pcs10gbr_dec.v",
                    "rtl/pcs10gbr_scrambler.v", "rtl/pcs10gbr_gearbox_tx.v",
                    "rtl/pcs10gbr_gearbox_rx.v", "rtl/pcs10gbr_block_lock.v",
                    "rtl/pcs10gbr_ber_mon.v", "rtl/pcs10gbr.v",
                    "fpga/zcu106/rtl/xgmii_test_gen.v",
                    "fpga/zcu106/rtl/xgmii_test_chk.v",
                    "sim/cocotb/hdl/h_xgmii_test_loop.v"],
        "params": {"OFFSET": 17, "BER_TIMER_CYCLES": 4000},
        "skip_vhdl": "ZCU106 10G bring-up logic is Verilog only",
    },
    "mac10g_test_loop": {
        "toplevel": "h_mac10g_test_loop",
        "sources": ["rtl/crc32_d64.v", "rtl/async_fifo.v",
                    "rtl/axis_async_frame_fifo.v", "rtl/cdc_event_count.v",
                    "rtl/eth_mac_10g_tx.v", "rtl/eth_mac_10g_rx.v", "rtl/eth_rs_10g.v",
                    "rtl/eth_mac_sys_10g.v",
                    "rtl/pcs10gbr_enc.v", "rtl/pcs10gbr_dec.v",
                    "rtl/pcs10gbr_scrambler.v", "rtl/pcs10gbr_gearbox_tx.v",
                    "rtl/pcs10gbr_gearbox_rx.v", "rtl/pcs10gbr_block_lock.v",
                    "rtl/pcs10gbr_ber_mon.v", "rtl/pcs10gbr.v",
                    "fpga/zcu106/rtl/xgmii_test_gen.v",
                    "fpga/zcu106/rtl/xgmii_test_chk.v",
                    "fpga/zcu106/rtl/axis_test_gen64.v",
                    "fpga/zcu106/rtl/axis_test_chk64.v",
                    "fpga/zcu106/rtl/axil_cmd_master.v",
                    "rtl/net/net_rx.v", "rtl/net/icmp_echo.v", "rtl/net/udp_echo.v",
                    "fpga/arty_a7/rtl/arp_responder.v",
                    "fpga/arty_a7/rtl/arty_tx_arbiter.v",
                    "fpga/zcu106/rtl/net_service64.v",
                    "fpga/zcu106/rtl/zcu106_10g_lane.v",
                    "sim/cocotb/hdl/h_mac10g_test_loop.v"],
        "params": {"OFFSET": 23, "BER_TIMER_CYCLES": 4000},
        "skip_vhdl": "ZCU106 10G bring-up logic is Verilog only",
    },
    "mac10g_dual": {
        "toplevel": "h_mac10g_dual",
        "sources": ["rtl/crc32_d64.v", "rtl/async_fifo.v",
                    "rtl/axis_async_frame_fifo.v", "rtl/cdc_event_count.v",
                    "rtl/eth_mac_10g_tx.v", "rtl/eth_mac_10g_rx.v", "rtl/eth_rs_10g.v",
                    "rtl/eth_mac_sys_10g.v",
                    "rtl/pcs10gbr_enc.v", "rtl/pcs10gbr_dec.v",
                    "rtl/pcs10gbr_scrambler.v", "rtl/pcs10gbr_gearbox_tx.v",
                    "rtl/pcs10gbr_gearbox_rx.v", "rtl/pcs10gbr_block_lock.v",
                    "rtl/pcs10gbr_ber_mon.v", "rtl/pcs10gbr.v",
                    "fpga/zcu106/rtl/xgmii_test_gen.v",
                    "fpga/zcu106/rtl/xgmii_test_chk.v",
                    "fpga/zcu106/rtl/axis_test_gen64.v",
                    "fpga/zcu106/rtl/axis_test_chk64.v",
                    "fpga/zcu106/rtl/axil_cmd_master.v",
                    "rtl/net/net_rx.v", "rtl/net/icmp_echo.v", "rtl/net/udp_echo.v",
                    "fpga/arty_a7/rtl/arp_responder.v",
                    "fpga/arty_a7/rtl/arty_tx_arbiter.v",
                    "fpga/zcu106/rtl/net_service64.v",
                    "fpga/zcu106/rtl/zcu106_10g_lane.v",
                    "sim/cocotb/hdl/h_mac10g_dual.v"],
        "params": {"OFFSET01": 23, "OFFSET10": 41, "BER_TIMER_CYCLES": 4000},
        "skip_vhdl": "ZCU106 10G bring-up logic is Verilog only",
    },
    "xgmii_test_loop_o63": {
        "toplevel": "h_xgmii_test_loop",
        "sources": ["rtl/pcs10gbr_enc.v", "rtl/pcs10gbr_dec.v",
                    "rtl/pcs10gbr_scrambler.v", "rtl/pcs10gbr_gearbox_tx.v",
                    "rtl/pcs10gbr_gearbox_rx.v", "rtl/pcs10gbr_block_lock.v",
                    "rtl/pcs10gbr_ber_mon.v", "rtl/pcs10gbr.v",
                    "fpga/zcu106/rtl/xgmii_test_gen.v",
                    "fpga/zcu106/rtl/xgmii_test_chk.v",
                    "sim/cocotb/hdl/h_xgmii_test_loop.v"],
        "params": {"OFFSET": 63, "BER_TIMER_CYCLES": 4000},
        "skip_vhdl": "ZCU106 10G bring-up logic is Verilog only",
    },
}

HOLD, TIMEOUT = 8, 3000


# ---------------------------------------------------------------------------
# gt10g_reset
# ---------------------------------------------------------------------------
class GtModel:
    """Cycle-level stand-in for the GTHE4 reset handshakes.

    QPLL0 locks LOCK_T cycles after QPLL0RESET falls. A path's PMA reset done
    (and so its user clock) comes PMA_T cycles after GTxXRESET falls, and its
    RESETDONE DONE_T cycles after USERRDY rises. Asserting a reset clears the
    path at once. withhold_rx > 0 swallows that many RX reset done events.
    """
    LOCK_T, PMA_T, DONE_T, PG_T = 120, 60, 40, 30

    def __init__(self, dut):
        self.dut = dut
        self.cycle = 0
        self.lock_at = None
        self.path = {p: {"pma_at": None, "done_at": None} for p in "tr"}
        self.withhold_rx = 0
        self.force_unlock = False
        self.violations = []
        self.rdy_prev = {"t": 0, "r": 0}

    async def run(self):
        d = self.dut
        for name in ("gtpowergood", "qpll0lock", "tx_usrclk_active",
                     "rx_usrclk_active", "txresetdone", "rxresetdone"):
            getattr(d, name).value = 0
        while True:
            await RisingEdge(d.clk)
            await ReadOnly()
            self.cycle += 1
            c = self.cycle
            pg = c >= self.PG_T
            # QPLL0
            if int(d.qpll0reset.value) or self.force_unlock:
                self.lock_at = None
            elif self.lock_at is None:
                self.lock_at = c + self.LOCK_T
            lock = self.lock_at is not None and c >= self.lock_at
            out = {"gtpowergood": int(pg), "qpll0lock": int(lock)}
            for p, gtr, urdy, act, done in (
                    ("t", "gttxreset", "txuserrdy", "tx_usrclk_active", "txresetdone"),
                    ("r", "gtrxreset", "rxuserrdy", "rx_usrclk_active", "rxresetdone")):
                st = self.path[p]
                reset = int(getattr(d, gtr).value) or not lock
                if reset:
                    st["pma_at"] = st["done_at"] = None
                elif st["pma_at"] is None:
                    st["pma_at"] = c + self.PMA_T
                active = st["pma_at"] is not None and c >= st["pma_at"]
                rdy = int(getattr(d, urdy).value)
                # the sequencer sees status through synchronizers, so judge
                # USERRDY when it rises, and against its own reset output
                if rdy and not self.rdy_prev[p] and not active:
                    self.violations.append((c, f"{urdy} rose before user clock active"))
                if rdy and int(getattr(d, gtr).value):
                    self.violations.append((c, f"{urdy} while {gtr}"))
                self.rdy_prev[p] = rdy
                if not rdy or not active:
                    st["done_at"] = None
                elif st["done_at"] is None:
                    if p == "r" and self.withhold_rx > 0:
                        self.withhold_rx -= 1
                        st["done_at"] = 10 ** 12
                    else:
                        st["done_at"] = c + self.DONE_T
                out[act] = int(active)
                out[done] = int(st["done_at"] is not None and c >= st["done_at"])
            await FallingEdge(d.clk)  # leave ReadOnly before driving
            for k, v in out.items():
                getattr(d, k).value = v


async def reset_setup(dut):
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    model = GtModel(dut)
    dut.rst.value = 1
    dut.tx_restart.value = 0
    dut.rx_restart.value = 0
    cocotb.start_soon(model.run())
    await ClockCycles(dut.clk, 5)
    dut.rst.value = 0
    return model


async def wait_for(dut, cond, limit, what):
    for _ in range(limit):
        await RisingEdge(dut.clk)
        if cond():
            return
    raise AssertionError(f"timeout waiting for {what}")


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def reset_bringup(dut):
    """Power good, QPLL0 reset pulse, lock, both paths done; order held."""
    if dut._name != "gt10g_reset":
        return
    model = await reset_setup(dut)
    # QPLL0RESET stays high until power good, then pulses for HOLD cycles
    rel = None
    for _ in range(400):
        await RisingEdge(dut.clk)
        if not int(dut.qpll0reset.value):
            rel = model.cycle
            break
    assert rel is not None and rel >= GtModel.PG_T + HOLD, f"QPLL0RESET released at {rel}"
    await wait_for(dut, lambda: int(dut.tx_done.value) and int(dut.rx_done.value),
                   2000, "tx_done and rx_done")
    assert int(dut.txuserrdy.value) and int(dut.rxuserrdy.value)
    assert not int(dut.gttxreset.value) and not int(dut.gtrxreset.value)
    assert not int(dut.txprogdivreset.value) and not int(dut.rxprogdivreset.value)
    await ClockCycles(dut.clk, 200)
    assert int(dut.tx_done.value) and int(dut.rx_done.value), "done did not hold"
    assert not model.violations, model.violations[:5]


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def reset_rx_restart(dut):
    """An RX restart resets only RX; TX stays done throughout."""
    if dut._name != "gt10g_reset":
        return
    model = await reset_setup(dut)
    await wait_for(dut, lambda: int(dut.tx_done.value) and int(dut.rx_done.value),
                   2000, "bring-up")
    dut.rx_restart.value = 1
    await ClockCycles(dut.clk, 3)
    dut.rx_restart.value = 0
    saw_rx_reset = False
    for _ in range(1000):
        await RisingEdge(dut.clk)
        assert int(dut.tx_done.value) and not int(dut.gttxreset.value), "TX disturbed"
        saw_rx_reset |= bool(int(dut.gtrxreset.value) and int(dut.rxprogdivreset.value))
        if saw_rx_reset and int(dut.rx_done.value):
            break
    assert saw_rx_reset, "GTRXRESET never pulsed"
    assert int(dut.rx_done.value), "RX did not come back"
    assert not model.violations, model.violations[:5]


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def reset_lock_loss(dut):
    """Losing QPLL0 lock drops both paths and re-runs the whole sequence."""
    if dut._name != "gt10g_reset":
        return
    model = await reset_setup(dut)
    await wait_for(dut, lambda: int(dut.tx_done.value) and int(dut.rx_done.value),
                   2000, "bring-up")
    model.force_unlock = True
    await wait_for(dut, lambda: not int(dut.tx_done.value) and not int(dut.rx_done.value),
                   20, "done to drop")
    await wait_for(dut, lambda: int(dut.qpll0reset.value), 50, "a new QPLL0 reset")
    model.force_unlock = False
    await wait_for(dut, lambda: int(dut.tx_done.value) and int(dut.rx_done.value),
                   2000, "recovery")
    assert not model.violations, model.violations[:5]


@cocotb.test(timeout_time=3, timeout_unit="ms")
async def reset_timeout_retry(dut):
    """An RX reset done that never comes is retried after the timeout."""
    if dut._name != "gt10g_reset":
        return
    model = await reset_setup(dut)
    model.withhold_rx = 1
    await wait_for(dut, lambda: int(dut.tx_done.value), 2000, "tx_done")
    assert not int(dut.rx_done.value)
    resets = 0
    prev = int(dut.gtrxreset.value)
    for _ in range(TIMEOUT + 1000):
        await RisingEdge(dut.clk)
        cur = int(dut.gtrxreset.value)
        resets += cur and not prev
        prev = cur
        if int(dut.rx_done.value):
            break
    assert int(dut.rx_done.value), "RX never recovered"
    assert resets == 1, f"expected one RX retry, saw {resets}"
    assert int(dut.tx_done.value)
    assert not model.violations, model.violations[:5]


# ---------------------------------------------------------------------------
# xgmii_test_loop
# ---------------------------------------------------------------------------
async def loop_setup(dut):
    cocotb.start_soon(Clock(dut.clk, 6.2, unit="ns").start())
    dut.rst_n.value = 0
    dut.enable.value = 0
    dut.len_words.value = 8
    dut.ipg_words.value = 0
    dut.inj_err.value = 0
    dut.line_flip.value = 0
    dut.clear.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await wait_for(dut, lambda: int(dut.block_lock.value), 3000, "block lock")
    await ClockCycles(dut.clk, 20)


async def run_frames(dut, n_frames, limit):
    start = int(dut.good_frames.value)
    dut.enable.value = 1
    await wait_for(dut, lambda: int(dut.good_frames.value) - start >= n_frames,
                   limit, f"{n_frames} good frames")
    dut.enable.value = 0
    await ClockCycles(dut.clk, 300)   # drain


def counts(dut):
    return {k: int(getattr(dut, k).value) for k in
            ("gen_frames", "good_frames", "bad_frames", "seq_gaps", "bad_words")}


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def loop_lengths(dut):
    """Every frame arrives good and in sequence for short, odd and long
    frames, back to back and with gaps."""
    if dut._name != "h_xgmii_test_loop":
        return
    await loop_setup(dut)
    for length, ipg in ((1, 0), (2, 0), (8, 0), (9, 3), (63, 1), (190, 0), (255, 7)):
        dut.len_words.value = length
        dut.ipg_words.value = ipg
        dut.clear.value = 1
        await ClockCycles(dut.clk, 2)
        dut.clear.value = 0
        n = max(4, 3000 // (length + 2 + ipg))
        await run_frames(dut, n, 40 * n * (length + 3 + ipg))
        c = counts(dut)
        assert c["bad_frames"] == 0 and c["seq_gaps"] == 0 and c["bad_words"] == 0, \
            (length, ipg, c)
        assert c["good_frames"] >= n, (length, ipg, c)
    assert not int(dut.hi_ber.value)


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def loop_line_rate(dut):
    """Back-to-back minimum frames: the generator fills every cycle the PCS
    accepts, and nothing is lost."""
    if dut._name != "h_xgmii_test_loop":
        return
    await loop_setup(dut)
    dut.len_words.value = 8
    dut.ipg_words.value = 0
    g0 = int(dut.gen_frames.value)
    dut.enable.value = 1
    await ClockCycles(dut.clk, 33 * 100)
    dut.enable.value = 0
    await ClockCycles(dut.clk, 300)
    sent = int(dut.gen_frames.value) - g0
    # 10 words per frame (start, 8, terminate), 32 words per 33 cycles
    assert sent >= (33 * 100 * 32 // 33) // 10 - 2, sent
    c = counts(dut)
    assert c["good_frames"] == c["gen_frames"], c
    assert c["bad_frames"] == 0 and c["seq_gaps"] == 0, c


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def loop_errors(dut):
    """A payload bit error injected at the generator makes exactly one bad
    frame; a line bit error in a payload block breaks one frame; the frames
    around them stay good, and a lost frame shows up as a sequence gap."""
    if dut._name != "h_xgmii_test_loop":
        return
    await loop_setup(dut)
    dut.len_words.value = 32
    dut.ipg_words.value = 2
    dut.enable.value = 1
    await ClockCycles(dut.clk, 500)
    base = counts(dut)
    dut.inj_err.value = 1
    await RisingEdge(dut.clk)
    dut.inj_err.value = 0
    await ClockCycles(dut.clk, 500)
    c = counts(dut)
    assert c["bad_frames"] - base["bad_frames"] == 1, (base, c)
    assert c["bad_words"] - base["bad_words"] == 1, (base, c)
    assert c["seq_gaps"] == base["seq_gaps"], (base, c)
    # one flipped line bit (a scrambled payload bit: corrupts 3 descrambled
    # bits of at most two blocks, or a sync header: an error block). With no
    # idles between frames every line bit belongs to some frame.
    dut.ipg_words.value = 0
    rng = random.Random(7)
    for _ in range(5):
        base = counts(dut)
        await ClockCycles(dut.clk, rng.randrange(50, 150))
        dut.line_flip.value = 1 << rng.randrange(64)
        await RisingEdge(dut.clk)
        dut.line_flip.value = 0
        await ClockCycles(dut.clk, 400)
        c = counts(dut)
        lost = (c["bad_frames"] - base["bad_frames"]) + (c["seq_gaps"] - base["seq_gaps"])
        assert 1 <= lost <= 3, (base, c)
        assert c["good_frames"] - base["good_frames"] >= 5, (base, c)
    dut.enable.value = 0
    assert int(dut.block_lock.value) and not int(dut.hi_ber.value)


# ---------------------------------------------------------------------------
# mac10g_test_loop
# ---------------------------------------------------------------------------
def mac_counts(dut):
    return {k: int(getattr(dut, k).value) for k in
            ("gen_frames", "good_frames", "bad_frames", "tuser_frames", "seq_gaps")}


async def mac_setup(dut):
    cocotb.start_soon(Clock(dut.clk, 6.2, unit="ns").start())
    cocotb.start_soon(Clock(dut.app_clk, 5.0, unit="ns").start())
    dut.rst_n.value = 0
    dut.app_rst_n.value = 0
    dut.enable.value = 0
    dut.len.value = 60
    dut.sweep.value = 0
    dut.ipg.value = 0
    dut.inj_err.value = 0
    dut.clear.value = 0
    dut.service.value = 0
    dut.csr_go.value = 0
    dut.csr_write.value = 0
    dut.csr_addr.value = 0
    dut.csr_wdata.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    dut.app_rst_n.value = 1
    await wait_for(dut, lambda: int(dut.block_lock.value), 3000, "block lock")
    await ClockCycles(dut.clk, 20)


async def app_pulse(dut, sig):
    """One app_clk cycle high, as the board's edge detectors make it."""
    await FallingEdge(dut.app_clk)
    sig.value = 1
    await FallingEdge(dut.app_clk)
    sig.value = 0


async def csr(dut, addr, data=None):
    """One CSR access through axil_cmd_master; returns the read value."""
    await FallingEdge(dut.app_clk)
    dut.csr_addr.value = addr
    dut.csr_write.value = int(data is not None)
    dut.csr_wdata.value = data or 0
    await FallingEdge(dut.app_clk)
    go = 1 - int(dut.csr_go.value)
    dut.csr_go.value = go
    for _ in range(200):
        await RisingEdge(dut.app_clk)
        if int(dut.csr_ack.value) == go:
            break
    assert int(dut.csr_ack.value) == go, "CSR access never finished"
    return int(dut.csr_rdata.value)


async def mac_run(dut, n_frames, limit):
    """Run until n_frames more good frames, return the cycles it took."""
    start = int(dut.good_frames.value)
    dut.enable.value = 1
    cycles = 0
    for _ in range(limit):
        await RisingEdge(dut.clk)
        cycles += 1
        if int(dut.good_frames.value) - start >= n_frames:
            break
    dut.enable.value = 0
    await mac_drain(dut)
    return cycles


async def mac_drain(dut, limit=200000):
    """Wait until the checker has seen every generated frame (the TX FIFO
    holds up to 32 KB of frames ahead of the line)."""
    for _ in range(limit // 100):
        await ClockCycles(dut.clk, 100)
        c = mac_counts(dut)
        if c["good_frames"] + c["bad_frames"] + c["seq_gaps"] >= c["gen_frames"]:
            break
    await ClockCycles(dut.clk, 400)


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def mac_line_rate(dut):
    """64-byte frames (60 + FCS) back to back: 84 line bytes each, so 8 *
    32/33 / 84 frames per cycle; all good, none lost, no underrun."""
    if dut._name != "h_mac10g_test_loop":
        return
    await mac_setup(dut)
    cycles = await mac_run(dut, 2000, 40000)
    rate = 2000 / cycles
    want = 8 * 32 / 33 / 84
    assert rate > want * 0.99, f"{rate:.5f} frames/cycle, line rate {want:.5f}"
    c = mac_counts(dut)
    assert c["bad_frames"] == 0 and c["seq_gaps"] == 0 and c["tuser_frames"] == 0, c
    assert c["good_frames"] == c["gen_frames"], c
    # the MAC's own counters, through the CSR port
    assert await csr(dut, 0xF0) == 0, "TX_UNDERRUN"
    assert await csr(dut, 0xD0) == 0, "RX_ERR_FCS"
    assert await csr(dut, 0xE8) == 0, "RX_DROP"
    assert await csr(dut, 0xB0) == c["gen_frames"], "TX_FRAMES"
    assert await csr(dut, 0xC0) == c["good_frames"], "RX_FRAMES"
    assert await csr(dut, 0xC8) == c["good_frames"] * 64, "RX_BYTES"
    await csr(dut, 0xC0, 0)
    assert await csr(dut, 0xC0) == 0, "RX_FRAMES clear"


@cocotb.test(timeout_time=40, timeout_unit="ms")
async def mac_sweep_and_jumbo(dut):
    """Lengths 60..400 one by one, then 9000-byte frames, with and without
    idle cycles between frames: all good and in sequence."""
    if dut._name != "h_mac10g_test_loop":
        return
    await mac_setup(dut)
    dut.sweep.value = 1
    dut.len.value = 400
    await mac_run(dut, 341 * 2, 200000)
    dut.sweep.value = 0
    dut.len.value = 9000
    dut.ipg.value = 3
    await mac_run(dut, 6, 60000)
    c = mac_counts(dut)
    assert c["bad_frames"] == 0 and c["seq_gaps"] == 0 and c["tuser_frames"] == 0, c
    assert c["good_frames"] == c["gen_frames"], c


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def mac_inject(dut):
    """An injected payload bit error (sent with a good FCS) is one bad frame
    at the checker, and clear resets the counters."""
    if dut._name != "h_mac10g_test_loop":
        return
    await mac_setup(dut)
    dut.len.value = 200
    dut.enable.value = 1
    await ClockCycles(dut.clk, 500)
    await app_pulse(dut, dut.inj_err)
    await ClockCycles(dut.clk, 1500)
    dut.enable.value = 0
    await mac_drain(dut)
    c = mac_counts(dut)
    assert c["bad_frames"] == 1 and c["tuser_frames"] == 0 and c["seq_gaps"] == 0, c
    assert c["good_frames"] + 1 == c["gen_frames"], c
    await app_pulse(dut, dut.clear)
    await ClockCycles(dut.app_clk, 6)
    assert mac_counts(dut)["bad_frames"] == 0


@cocotb.test(timeout_time=40, timeout_unit="ms")
async def mac_service_switch(dut):
    """Service mode switched on and off at random times during traffic:
    each of the MAC's streams changes hands only between frames, so the
    checker sees no bad or merged frame (frames that arrive while the
    service stack has the RX stream are lost to it, gaps), and afterwards
    the traffic runs clean."""
    if dut._name != "h_mac10g_test_loop":
        return
    await mac_setup(dut)
    rng = random.Random(7)
    dut.sweep.value = 1
    dut.len.value = 400
    dut.enable.value = 1
    for _ in range(60):
        await ClockCycles(dut.app_clk, rng.randint(10, 300))
        dut.service.value = 1
        await ClockCycles(dut.app_clk, rng.randint(10, 300))
        dut.service.value = 0
    dut.enable.value = 0
    await ClockCycles(dut.clk, 20000)
    c = mac_counts(dut)
    dut._log.info("after the switching: %s", c)
    assert c["bad_frames"] == 0 and c["tuser_frames"] == 0, c
    assert c["seq_gaps"] > 0, "the service stack never had the RX stream"
    assert c["good_frames"] < c["gen_frames"], c
    await mac_run(dut, 300, 100000)
    d = mac_counts(dut)
    assert d["bad_frames"] == 0 and d["seq_gaps"] == c["seq_gaps"], d
    assert d["good_frames"] - c["good_frames"] == d["gen_frames"] - c["gen_frames"], (c, d)


# ---------------------------------------------------------------------------
# mac10g_dual
# ---------------------------------------------------------------------------
# EIO control word bits (zcu106_10g_top.v)
B_GEN, B_INJ, B_CLEAR, B_MAC, B_SWEEP, B_CSR_GO, B_CSR_WRITE = 8, 9, 10, 13, 14, 120, 121
B_UDP = 15


class DualPort:
    """One port's EIO control word and counters in h_mac10g_dual."""

    def __init__(self, dut, p):
        self.dut, self.p = dut, p
        self.ctrl_sig = getattr(dut, f"ctrl{p}")
        self.word = 1 << B_MAC

    def sig(self, name):
        return getattr(self.dut, f"{name}{self.p}")

    def put(self):
        self.ctrl_sig.value = self.word

    def set(self, bit, on):
        self.word = (self.word | (1 << bit)) if on else (self.word & ~(1 << bit))
        self.put()

    def field(self, lsb, width, value):
        m = ((1 << width) - 1) << lsb
        self.word = (self.word & ~m) | ((value << lsb) & m)
        self.put()

    def counts(self):
        return {k: int(self.sig(k).value) for k in ("gen", "good", "bad", "tuser", "gaps")}

    async def csr(self, addr, data=None):
        d = self.dut
        await FallingEdge(d.app_clk)
        self.field(80, 8, addr)
        self.field(88, 32, data or 0)
        self.set(B_CSR_WRITE, data is not None)
        await FallingEdge(d.app_clk)
        go = 1 - ((self.word >> B_CSR_GO) & 1)
        self.set(B_CSR_GO, go)
        for _ in range(200):
            await RisingEdge(d.app_clk)
            if int(self.sig("csr_ack").value) == go:
                break
        assert int(self.sig("csr_ack").value) == go, "CSR access never finished"
        return int(self.sig("csr_rdata").value)

    async def csr64(self, addr):
        lo = await self.csr(addr)
        return lo | (await self.csr(addr + 4)) << 32


async def dual_setup(dut):
    cocotb.start_soon(Clock(dut.clk_a, 6.2, unit="ns").start())
    await ClockCycles(dut.clk_a, 1)
    await FallingEdge(dut.clk_a)     # clk_b half a cycle behind clk_a
    cocotb.start_soon(Clock(dut.clk_b, 6.2, unit="ns").start())
    cocotb.start_soon(Clock(dut.app_clk, 5.0, unit="ns").start())
    ports = [DualPort(dut, 0), DualPort(dut, 1)]
    dut.rst_n.value = 0
    dut.app_rst_n.value = 0
    for q in ports:
        q.field(64, 16, 60)
        q.put()
    await ClockCycles(dut.clk_a, 5)
    dut.rst_n.value = 1
    dut.app_rst_n.value = 1
    for _ in range(4000):
        await RisingEdge(dut.clk_a)
        if int(dut.block_lock0.value) and int(dut.block_lock1.value):
            break
    assert int(dut.block_lock0.value) and int(dut.block_lock1.value), "no block lock"
    await ClockCycles(dut.clk_a, 20)
    return ports


async def dual_drain(dut, ports, limit=400000):
    """Until each checker has seen every frame the other port generated."""
    def done():
        a, b = ports[0].counts(), ports[1].counts()
        return (b["good"] + b["bad"] + b["gaps"] >= a["gen"] and
                a["good"] + a["bad"] + a["gaps"] >= b["gen"])
    for _ in range(limit // 100):
        await ClockCycles(dut.clk_a, 100)
        if done():
            break
    await ClockCycles(dut.clk_a, 400)


async def dual_check(ports):
    """Each direction: every frame good and in order at the far checker, and
    both MACs' counters agree."""
    for tx, rx in ((ports[0], ports[1]), (ports[1], ports[0])):
        t, r = tx.counts(), rx.counts()
        assert r["bad"] == 0 and r["gaps"] == 0 and r["tuser"] == 0, (tx.p, r)
        assert r["good"] == t["gen"], (tx.p, t, r)
        assert await tx.csr64(0xB0) == t["gen"], "TX_FRAMES"
        assert await rx.csr64(0xC0) == t["gen"], "RX_FRAMES"
        assert await tx.csr64(0xB8) == await rx.csr64(0xC8), "TX_BYTES != RX_BYTES"
        # every error, drop and underrun counter, both ends
        for a in (0xD0, 0xD4, 0xD8, 0xDC, 0xE8, 0xEC, 0xF0, 0xF4, 0xF8):
            assert await rx.csr(a) == 0 and await tx.csr(a) == 0, f"counter 0x{a:02X}"


@cocotb.test(timeout_time=30, timeout_unit="ms")
async def dual_line_rate(dut):
    """64-byte frames (60 + FCS) both ways at once, back to back: each
    direction at line rate, all good, every frame accounted for by both
    checkers and all four MAC counters."""
    if dut._name != "h_mac10g_dual":
        return
    ports = await dual_setup(dut)
    for q in ports:
        q.set(B_GEN, True)
    n, cycles = 1500, 0
    start = [q.counts()["good"] for q in ports]
    for _ in range(40000):
        await RisingEdge(dut.clk_a)
        cycles += 1
        if all(q.counts()["good"] - s0 >= n for q, s0 in zip(ports, start)):
            break
    for q in ports:
        q.set(B_GEN, False)
    want = 8 * 32 / 33 / 84
    for q, s0 in zip(ports, start):
        rate = (q.counts()["good"] - s0) / cycles
        dut._log.info("port %d receives %.5f frames/cycle, line rate %.5f",
                      q.p, rate, want)
        assert rate > want * 0.99, f"port {q.p}: {rate:.5f} frames/cycle"
    await dual_drain(dut, ports)
    await dual_check(ports)


@cocotb.test(timeout_time=200, timeout_unit="ms")
async def dual_lengths(dut):
    """Port 0 sweeps every length 60..1514 (64..1518 with the FCS) while port
    1 sends 9014-byte jumbo frames back at it; then port 1 sweeps 60..300
    while port 0 sends 9000-byte frames with idle cycles between them."""
    if dut._name != "h_mac10g_dual":
        return
    ports = await dual_setup(dut)
    p0, p1 = ports
    p0.set(B_SWEEP, True)
    p0.field(64, 16, 1514)
    p1.field(64, 16, 9014)
    for q in ports:
        q.set(B_GEN, True)
    while p1.counts()["good"] < 1455:
        await ClockCycles(dut.clk_a, 1000)
    for q in ports:
        q.set(B_GEN, False)
    await dual_drain(dut, ports)
    c0, c1 = p0.counts(), p1.counts()
    dut._log.info("port 0 sent %d swept frames, port 1 %d jumbo", c0["gen"], c1["gen"])
    assert c1["good"] >= 1455 and c0["good"] > 0
    await dual_check(ports)
    # the other way round
    p0.set(B_SWEEP, False)
    p0.field(64, 16, 9000)
    p0.field(24, 8, 5)
    p1.set(B_SWEEP, True)
    p1.field(64, 16, 300)
    for q in ports:
        q.set(B_GEN, True)
    while p0.counts()["good"] - c0["good"] < 2 * 241:
        await ClockCycles(dut.clk_a, 1000)
    for q in ports:
        q.set(B_GEN, False)
    await dual_drain(dut, ports)
    await dual_check(ports)


@cocotb.test(timeout_time=60, timeout_unit="ms")
async def dual_udp(dut):
    """IPv4 / UDP datagrams both ways: port 0 sends 1472-byte datagrams
    (1514-byte frames) at line rate while port 1 sweeps 60..400-byte frames;
    every header and payload byte checked, both MACs' counters agree."""
    if dut._name != "h_mac10g_dual":
        return
    ports = await dual_setup(dut)
    p0, p1 = ports
    for q in ports:
        q.set(B_UDP, True)
    p0.field(64, 16, 1514)
    p1.set(B_SWEEP, True)
    p1.field(64, 16, 400)
    for q in ports:
        q.set(B_GEN, True)
    await ClockCycles(dut.clk_a, 2000)      # past the first frames
    g0, cycles = p1.counts()["good"], 0
    for _ in range(60000):
        await RisingEdge(dut.clk_a)
        cycles += 1
        if p1.counts()["good"] - g0 >= 150:
            break
    c1 = p1.counts()
    assert c1["good"] - g0 >= 150 and c1["bad"] == 0, c1
    rate = (c1["good"] - g0) / cycles
    for q in ports:
        q.set(B_GEN, False)
    want = 8 * 32 / 33 / (1514 + 24)
    dut._log.info("1514-byte UDP frames at %.6f frames/cycle, line rate %.6f",
                  rate, want)
    assert rate > want * 0.98, f"{rate:.6f} frames/cycle"
    await dual_drain(dut, ports)
    c0, c1 = p0.counts(), p1.counts()
    assert c0["good"] > 0 and c1["good"] > 0
    await dual_check(ports)


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def dual_inject(dut):
    """An error injected at port 0 is one bad frame at port 1 only."""
    if dut._name != "h_mac10g_dual":
        return
    ports = await dual_setup(dut)
    for q in ports:
        q.field(64, 16, 200)
        q.set(B_GEN, True)
    await ClockCycles(dut.clk_a, 500)
    await FallingEdge(dut.app_clk)
    ports[0].set(B_INJ, True)
    await ClockCycles(dut.app_clk, 4)
    ports[0].set(B_INJ, False)
    await ClockCycles(dut.clk_a, 1500)
    for q in ports:
        q.set(B_GEN, False)
    await dual_drain(dut, ports)
    c0, c1 = ports[0].counts(), ports[1].counts()
    assert c1["bad"] == 1 and c1["good"] + 1 == c0["gen"] and c1["gaps"] == 0, c1
    assert c0["bad"] == 0 and c0["good"] == c1["gen"], c0
