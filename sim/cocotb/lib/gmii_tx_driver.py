# SPDX-License-Identifier: Apache-2.0
"""GMII TX driver for gmii_cdc: drive gmii_txd_in/tx_en_in on sys_clk.

gmii_cdc is a store-and-forward CDC re-timer, not a framer: a frame is just a
contiguous gmii_tx_en_in run of bytes (whatever the MAC produced - preamble,
data, FCS - passed through verbatim). tx_en_in dropping marks end-of-frame; the
DUT attaches the EOF sideband to the last byte. The GMII input cannot be
backpressured, so the driver simply streams at the sys clock rate.
"""
from cocotb.triggers import RisingEdge


class GmiiTxDriver:
    def __init__(self, dut):
        self.dut = dut
        dut.gmii_txd_in.value = 0
        dut.gmii_tx_en_in.value = 0
        dut.gmii_tx_er_in.value = 0

    async def _beat(self, data, en):
        self.dut.gmii_txd_in.value = data
        self.dut.gmii_tx_en_in.value = en
        self.dut.gmii_tx_er_in.value = 0
        await RisingEdge(self.dut.sys_clk)

    async def idle(self, cycles):
        for _ in range(cycles):
            await self._beat(0, 0)

    async def send_frame(self, data: bytes, gap=2):
        for b in data:
            await self._beat(b, 1)
        await self._beat(0, 0)        # tx_en low -> EOF on the last byte
        await self.idle(max(0, gap - 1))
