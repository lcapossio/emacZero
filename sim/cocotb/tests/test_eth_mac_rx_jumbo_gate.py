# SPDX-License-Identifier: Apache-2.0
"""cocotb port of sim/tb/tb_eth_mac_rx_jumbo_gate.v
(build_and_test.py: ETH-MAC-RX-JUMBO-GATE).

RX frame-size limits. Harness h_eth_mac_rx_jumbo_gate: one eth_mac_tx
(defaults) feeding, through the bench's negedge GMII loopback, u_rx (RX
defaults, jumbo limit 9018) and u_rx2 (MAX_FRAME_JUMBO 1518, as eth_mac_sys
builds it for MAX_FRAME 1518); both with our_mac FF:FF:FF:FF:FF:FF, promisc 0,
passthrough 0, rx_csum_en 0, m_axis_tready 1, jumbo_en from the test.

Frame bytes: 0..5 = FF (broadcast), 12..13 = the TPID when non-zero, all
others idx & 0xFF. Lengths are AXIS bytes; the wire adds the 4-byte FCS.
Each send clears the TLAST flags, sends the frame and waits 200 us. Per RX the
test keeps the last TLAST's terror and counts stat_done && stat_err_oversize.

Checks, in the bench's order:
  1. 1600 bytes, jumbo_en=0: u_rx ends it with terror
  2. 1600 bytes, jumbo_en=1: u_rx ends it without terror
  then 12 check_frame cases (len, TPID, want u_rx terror / u_rx2 terror); each
  passes when both RXs reached TLAST, each terror is as wanted and each RX's
  oversize-pulse count rose by exactly the wanted terror:
     jumbo_en=0: (1514,0000,0,0) (1518,0000,1,1) (1518,8100,0,0)
                 (1518,88A8,0,0) (1519,8100,1,1) (1518,9100,1,1)
     jumbo_en=1: (1514,0000,0,0) (1515,0000,0,1) (1518,8100,0,0)
                 (1518,88A8,0,0) (1519,88A8,0,1) (1596,0000,0,1)
The bench uses no $random. Its u_rx2 TLAST flags are not reset-gated; here
every sampler runs only while rst_n is high (no frame is sent in reset, and
send_frame clears the flags first, so this changes nothing).
"""
import cocotb
from cocotb.triggers import Timer

from lib.rx_loop import NegedgeLoop, start_clock, send_negedge_style, is1


# Suites this module backs (read by run.py; see its docstring).
SUITES = {
    "eth_mac_rx_jumbo_gate": {
        "toplevel": "h_eth_mac_rx_jumbo_gate",
        "sources": ["rtl/crc32.v", "rtl/eth_mac_tx.v", "rtl/sync_fifo.v",
                    "rtl/net/csum_calc.v", "rtl/eth_mac_rx.v",
                    "sim/cocotb/hdl/h_eth_mac_rx_jumbo_gate.v"],
        "params": {},
    },
}


def frame_bytes(n, tpid):
    out = []
    for idx in range(n):
        if idx < 6:
            out.append(0xFF)
        elif idx == 12 and tpid != 0:
            out.append(tpid >> 8)
        elif idx == 13 and tpid != 0:
            out.append(tpid & 0xFF)
        else:
            out.append(idx & 0xFF)
    return out


class State:
    def __init__(self, dut):
        self.dut = dut
        self.ovs1 = 0
        self.ovs2 = 0
        self.saw_last = self.saw_terror = False
        self.saw_last2 = self.saw_terror2 = False
        self.rx_byte_cnt = 0

    def sample(self):
        d = self.dut
        if is1(d.stat_done1) and is1(d.stat_ovs1):
            self.ovs1 += 1
        if is1(d.stat_done2) and is1(d.stat_ovs2):
            self.ovs2 += 1
        if is1(d.rx2_tvalid) and is1(d.rx2_tlast):
            self.saw_last2 = True
            self.saw_terror2 = is1(d.rx2_terror)
        if is1(d.rx_tvalid):
            self.rx_byte_cnt += 1
            if is1(d.rx_tlast):
                self.saw_last = True
                self.saw_terror = is1(d.rx_terror)


@cocotb.test(timeout_time=8, timeout_unit="ms")
async def rx_jumbo_gate(dut):
    start_clock(dut)
    dut.tx_tvalid.value = 0
    dut.tx_tlast.value = 0
    dut.tx_tdata.value = 0
    dut.jumbo_en.value = 0
    dut.rst_n.value = 0

    s = State(dut)
    loop = NegedgeLoop(dut)
    loop.samplers.append(s.sample)
    loop.start()

    await Timer(100, "ns")
    dut.rst_n.value = 1
    await Timer(50, "ns")

    jumbo = [0]
    failures = []

    def set_jumbo(v):
        jumbo[0] = v
        dut.jumbo_en.value = v

    async def send_frame(n, tpid):
        s.saw_last = s.saw_terror = False
        s.saw_last2 = s.saw_terror2 = False
        s.rx_byte_cnt = 0
        await send_negedge_style(dut, frame_bytes(n, tpid))
        await Timer(200_000, "ns")

    async def check_frame(n, tpid, want1, want2):
        b1, b2 = s.ovs1, s.ovs2
        await send_frame(n, tpid)
        d1, d2 = s.ovs1 - b1, s.ovs2 - b2
        ok = (s.saw_last and s.saw_terror == want1
              and s.saw_last2 and s.saw_terror2 == want2
              and d1 == int(want1) and d2 == int(want2))
        tag = (f"{n + 4}-byte frame, TPID {tpid:04X}, jumbo_en={jumbo[0]}")
        if ok:
            dut._log.info(f"PASS: {tag}: {'oversize' if want1 else 'accepted'} / "
                          f"{'oversize' if want2 else 'accepted'}")
        else:
            dut._log.error(f"FAIL: {tag}: terror {int(s.saw_terror)}/{int(s.saw_terror2)} "
                           f"(last {int(s.saw_last)}/{int(s.saw_last2)}), "
                           f"oversize pulses +{d1}/+{d2}")
            failures.append(tag)

    # Frame 1: jumbo_en = 0, 1600 bytes
    set_jumbo(0)
    await send_frame(1600, 0)
    if s.saw_last and s.saw_terror:
        dut._log.info("PASS: 1600-byte frame rejected with terror at jumbo_en=0")
    elif not s.saw_last:
        dut._log.error("FAIL: jumbo_en=0 frame never reached RX last")
        failures.append("frame 1")
    else:
        dut._log.error("FAIL: jumbo_en=0 1600-byte frame did NOT raise terror")
        failures.append("frame 1")

    # Frame 2: jumbo_en = 1
    set_jumbo(1)
    await send_frame(1600, 0)
    if s.saw_last and not s.saw_terror:
        dut._log.info("PASS: 1600-byte frame accepted cleanly at jumbo_en=1")
    elif not s.saw_last:
        dut._log.error("FAIL: jumbo_en=1 frame never reached RX last")
        failures.append("frame 2")
    else:
        dut._log.error("FAIL: jumbo_en=1 1600-byte frame had terror set")
        failures.append("frame 2")

    # VLAN allowance at the standard limit (jumbo_en = 0)
    set_jumbo(0)
    await check_frame(1514, 0x0000, False, False)   # 1518 untagged: at the limit
    await check_frame(1518, 0x0000, True, True)     # 1522 untagged: oversize
    await check_frame(1518, 0x8100, False, False)   # 1522 802.1Q: accepted
    await check_frame(1518, 0x88A8, False, False)   # 1522 802.1ad: accepted
    await check_frame(1519, 0x8100, True, True)     # 1523 802.1Q: oversize
    await check_frame(1518, 0x9100, True, True)     # 0x9100 is not a recognised TPID

    # jumbo_en = 1: u_rx goes to 9018; u_rx2 keeps the VLAN allowance
    set_jumbo(1)
    await check_frame(1514, 0x0000, False, False)   # 1518 untagged
    await check_frame(1515, 0x0000, False, True)    # 1519 untagged
    await check_frame(1518, 0x8100, False, False)   # 1522 802.1Q
    await check_frame(1518, 0x88A8, False, False)   # 1522 802.1ad
    await check_frame(1519, 0x88A8, False, True)    # 1523 802.1ad
    await check_frame(1596, 0x0000, False, True)    # 1600 untagged

    assert not failures, f"failed: {failures}"
