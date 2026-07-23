# SPDX-License-Identifier: Apache-2.0
"""Reference model + scoreboard + stats monitor for eth_mac_rx.

Policy (rtl/eth_mac_rx.v):
  * A frame is delivered on m_axis iff the MAC filter passes: promisc OR
    passthrough OR dst==our_mac OR dst==broadcast (OR mcast-hash when built with
    MCAST_HASH_FILTER=1 - not modelled here; this suite runs the default 0).
  * Errors never drop inside the MAC: a delivered frame carries terror on tlast =
    fcs | align(rx_er) | overflow | oversize. The wrapper does the actual drop.
  * A filtered-out frame produces NO m_axis output and NO stat_done pulse.
  * stat_len counts data+FCS wire bytes; is_mcast = dst[0].LSB & !broadcast.

NOTE: with MCAST_HASH_FILTER=1 the RTL gates the hash path on mac_chk[0] (LSB of
the *last* dst byte) rather than the I/G bit - a latent quirk, dormant at the
default 0. Left for a dedicated follow-up test rather than modelled here.
"""
from dataclasses import dataclass
from cocotb.triggers import RisingEdge, ReadOnly

from .eth import fcs_bytes  # noqa: F401  (kept for symmetry / driver parity)

BROADCAST = 0xFFFFFFFFFFFF


@dataclass
class RxFrame:
    payload: bytes          # dst(6) + src(6) + type(2) + data (no preamble/FCS)
    corrupt_fcs: bool = False
    align_err: bool = False


def _dst_int(payload: bytes) -> int:
    return int.from_bytes(payload[:6], "big")


def filter_pass(payload, our_mac, promisc, passthrough) -> bool:
    dst = _dst_int(payload)
    return bool(promisc or passthrough or dst == our_mac or dst == BROADCAST)


def rx_expected(frames, our_mac, promisc, passthrough, jumbo_en,
                max_std=1518, max_jumbo=9018):
    """Return (expected_axis_frames, expected_stat_records) in delivery order."""
    axis, stats = [], []
    for fr in frames:
        if not filter_pass(fr.payload, our_mac, promisc, passthrough):
            continue                                  # dropped: no output, no stat
        dst = _dst_int(fr.payload)
        byte_cnt = len(fr.payload) + 4                # data + FCS on the wire
        limit = max_jumbo if jumbo_en else max_std
        oversize = byte_cnt > limit
        is_bcast = dst == BROADCAST
        is_mcast = bool(fr.payload[0] & 1) and not is_bcast
        terror = fr.corrupt_fcs or fr.align_err or oversize
        axis.append({"payload": fr.payload, "terror": terror})
        stats.append({"len": byte_cnt, "fcs": fr.corrupt_fcs, "align": fr.align_err,
                      "overflow": False, "oversize": oversize,
                      "bcast": is_bcast, "mcast": is_mcast})
    return axis, stats


class StatsMonitor:
    def __init__(self, dut):
        self.dut = dut
        self.records = []

    async def run(self):
        dut = self.dut
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            if int(dut.stat_done.value):
                self.records.append({
                    "len": int(dut.stat_len.value),
                    "fcs": bool(int(dut.stat_err_fcs.value)),
                    "align": bool(int(dut.stat_err_align.value)),
                    "overflow": bool(int(dut.stat_err_overflow.value)),
                    "oversize": bool(int(dut.stat_err_oversize.value)),
                    "bcast": bool(int(dut.stat_is_bcast.value)),
                    "mcast": bool(int(dut.stat_is_mcast.value)),
                })


class RxScoreboard:
    def __init__(self, exp_axis, exp_stats):
        self.exp_axis = exp_axis
        self.exp_stats = exp_stats
        self.errors = []

    def check(self, got_axis, got_stats):
        self._check_axis(got_axis)
        self._check_stats(got_stats)
        return not self.errors

    def _check_axis(self, got):
        if len(got) != len(self.exp_axis):
            self.errors.append(
                f"axis frame count: exp {len(self.exp_axis)} got {len(got)}")
        for i, (e, g) in enumerate(zip(self.exp_axis, got)):
            if e["payload"] != g["payload"]:
                self.errors.append(
                    f"axis[{i}] payload: exp {len(e['payload'])}B got "
                    f"{len(g['payload'])}B ({_first_diff(e['payload'], g['payload'])})")
            if bool(e["terror"]) != bool(g["terror"]):
                self.errors.append(
                    f"axis[{i}] terror: exp {e['terror']} got {g['terror']}")
            if not g["sof"]:
                self.errors.append(f"axis[{i}] missing tsof")

    def _check_stats(self, got):
        if len(got) != len(self.exp_stats):
            self.errors.append(
                f"stat count: exp {len(self.exp_stats)} got {len(got)}")
        for i, (e, g) in enumerate(zip(self.exp_stats, got)):
            for k in ("len", "fcs", "align", "oversize", "bcast", "mcast"):
                if e[k] != g[k]:
                    self.errors.append(f"stat[{i}].{k}: exp {e[k]} got {g[k]}")


def _first_diff(a, b):
    for i in range(min(len(a), len(b))):
        if a[i] != b[i]:
            return f"@{i} exp=0x{a[i]:02x} got=0x{b[i]:02x}"
    return f"len {len(a)} vs {len(b)}"
