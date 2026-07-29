# SPDX-License-Identifier: Apache-2.0
"""Sys-side RX monitor for gmii_cdc's GMII-to-MAC output (sys_clk domain).

The RX readout is not paced: once a whole frame is available the state machine
streams it out one byte per sys cycle with gmii_rx_dv_out high, so the output is
byte-exact at every speed (unlike the paced TX side). A frame is the run of bytes
while gmii_rx_dv_out is high; gmii_rx_er_out is captured per byte.

Exposes:
  * frames     - exact byte sequences, in delivery order
  * frame_ers  - per-frame list of rx_er flags (parallel to each frame's bytes)
  * count      - delivered frame count (the signal an rx_frames_pending wrap drops)
"""
from cocotb.triggers import RisingEdge, ReadOnly


class GmiiRxCdcMonitor:
    def __init__(self, dut):
        self.dut = dut
        self.frames = []
        self.frame_ers = []
        self.count = 0

    async def run(self):
        dut = self.dut
        prev_dv = 0
        cur = bytearray()
        cur_er = []
        while True:
            await RisingEdge(dut.sys_clk)
            await ReadOnly()
            dv = int(dut.gmii_rx_dv_out.value)
            if dv:
                cur.append(int(dut.gmii_rxd_out.value) & 0xFF)
                cur_er.append(int(dut.gmii_rx_er_out.value))
            elif prev_dv:                       # rx_dv fell -> frame complete
                self.count += 1
                self.frames.append(bytes(cur))
                self.frame_ers.append(cur_er)
                cur = bytearray()
                cur_er = []
            prev_dv = dv
