# SPDX-License-Identifier: Apache-2.0
"""AXIS master for the mii_tx_saf sys-clock input, with randomized bubbles.

Store-and-forward's headline promise is that the AXIS source MAY bubble
(deassert tvalid mid-frame) with no wire underrun. This driver exercises that
directly: between bytes it randomly drops tvalid for a random gap, controlled by
a seeded RNG so any failure is reproducible.

The handshake samples tready in the ReadOnly phase (end of cycle, all values
settled) and completes the transfer on the following RisingEdge - race-free
across simulators, and it honours FIFO backpressure exactly.
"""
from cocotb.triggers import RisingEdge, ReadOnly


class AxisMaster:
    def __init__(self, dut, rng, p_bubble: float = 0.25, max_gap: int = 6):
        self.dut = dut
        self.rng = rng
        self.p_bubble = p_bubble
        self.max_gap = max_gap
        dut.s_axis_tvalid.value = 0
        dut.s_axis_tlast.value = 0
        dut.s_axis_tdata.value = 0

    async def _idle(self, cycles: int):
        self.dut.s_axis_tvalid.value = 0
        self.dut.s_axis_tlast.value = 0
        for _ in range(cycles):
            await RisingEdge(self.dut.clk)

    async def send_segment(self, data: bytes, last: bool):
        """Drive one AXIS burst; assert tlast on the final byte iff `last`."""
        dut = self.dut
        n = len(data)
        for i, b in enumerate(data):
            if self.p_bubble and self.rng.random() < self.p_bubble:
                await self._idle(self.rng.randint(1, self.max_gap))
            dut.s_axis_tdata.value = b
            dut.s_axis_tvalid.value = 1
            dut.s_axis_tlast.value = 1 if (last and i == n - 1) else 0
            # Complete exactly one accepted beat (tvalid && tready at a rising edge).
            while True:
                await ReadOnly()
                ready = int(dut.s_axis_tready.value)
                await RisingEdge(dut.clk)
                if ready:
                    break
        dut.s_axis_tvalid.value = 0
        dut.s_axis_tlast.value = 0

    async def send_all(self, segments):
        for seg in segments:
            await self.send_segment(seg.data, seg.last)
        await self._idle(4)
