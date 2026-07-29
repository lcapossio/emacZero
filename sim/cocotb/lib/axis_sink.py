# SPDX-License-Identifier: Apache-2.0
"""AXIS slave that captures eth_mac_rx's m_axis output, with random backpressure.

Randomly drops tready (seeded) to exercise the RX FIFO's buffering under
downstream stalls. Reassembles frames from tsof..tlast and records per-frame
terror. Samples in the ReadOnly phase so the handshake is race-free.
"""
from cocotb.triggers import RisingEdge, ReadOnly


class AxisSink:
    def __init__(self, dut, rng, p_stall=0.2, max_stall=5, active_signal=None):
        self.dut = dut
        self.rng = rng
        self.p_stall = p_stall
        self.max_stall = max_stall
        # When given (e.g. gmii_rx_dv), only backpressure while the input is
        # active and stay fully ready between frames. That keeps a single frame
        # within the RX FIFO depth (no overflow) so the scoreboard is
        # deterministic, while still toggling tready mid-frame.
        self.active_signal = active_signal
        self.frames = []          # list of {"payload": bytes, "terror": bool, "sof": bool}
        dut.m_axis_tready.value = 0

    async def run(self):
        dut = self.dut
        cur = bytearray()
        err = False
        sof_seen = False
        stall = 0
        while True:
            gated_idle = (self.active_signal is not None
                          and not int(self.active_signal.value))
            if gated_idle:
                dut.m_axis_tready.value = 1        # drain fully between frames
                stall = 0
            elif stall > 0:
                dut.m_axis_tready.value = 0
                stall -= 1
            else:
                dut.m_axis_tready.value = 1
                if self.p_stall and self.rng.random() < self.p_stall:
                    stall = self.rng.randint(1, self.max_stall)

            await ReadOnly()
            if int(dut.m_axis_tvalid.value) and int(dut.m_axis_tready.value):
                if int(dut.m_axis_tsof.value):
                    cur = bytearray()
                    err = False
                    sof_seen = True
                cur.append(int(dut.m_axis_tdata.value) & 0xFF)
                if int(dut.m_axis_terror.value):
                    err = True
                if int(dut.m_axis_tlast.value):
                    self.frames.append(
                        {"payload": bytes(cur), "terror": err, "sof": sof_seen})
                    cur = bytearray()
                    err = False
                    sof_seen = False
            await RisingEdge(dut.clk)
