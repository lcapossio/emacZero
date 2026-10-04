# SPDX-License-Identifier: Apache-2.0
"""Raw-GMII media-side RX driver for gmii_cdc (media_rx_clk domain).

gmii_cdc buffers whatever bytes appear between rx_dv assertions verbatim - it does
no preamble/SFD/FCS handling on the RX path (that is the MAC's job downstream), so
this driver just frames raw bytes: hold rx_dv high for the payload, drop it for the
inter-frame gap. `gap` is the number of idle (rx_dv=0) media_rx cycles between
frames; gap=0 packs frames back-to-back, the condition that piles up the RX FIFO.
"""
from cocotb.triggers import RisingEdge


class GmiiRxCdcDriver:
    def __init__(self, dut):
        self.dut = dut
        dut.gmii_rxd_in.value = 0
        dut.gmii_rx_dv_in.value = 0
        dut.gmii_rx_er_in.value = 0
        # One byte per rx_dv cycle, as on GMII / RGMII at 1G.
        dut.gmii_rx_ce_in.value = 1

    async def idle(self, n):
        self.dut.gmii_rx_dv_in.value = 0
        self.dut.gmii_rx_er_in.value = 0
        for _ in range(n):
            await RisingEdge(self.dut.media_rx_clk)

    async def send_frame(self, data, gap=0, er=None):
        """Drive one frame: bytes with rx_dv=1, then `gap` idle cycles.

        er: optional iterable of 0/1 rx_er values, one per byte (defaults all 0).
        """
        dut = self.dut
        er = list(er) if er is not None else [0] * len(data)
        for i, b in enumerate(data):
            dut.gmii_rxd_in.value = b & 0xFF
            dut.gmii_rx_dv_in.value = 1
            dut.gmii_rx_er_in.value = er[i]
            await RisingEdge(dut.media_rx_clk)
        dut.gmii_rx_dv_in.value = 0
        dut.gmii_rx_er_in.value = 0
        dut.gmii_rxd_in.value = 0
        for _ in range(gap):
            await RisingEdge(dut.media_rx_clk)
