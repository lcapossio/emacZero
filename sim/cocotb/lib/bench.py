# SPDX-License-Identifier: Apache-2.0
"""Bookkeeping shared by the cocotb ports of the sim/tb/ Verilog benches.

- Checks:  the benches' pass_cnt / fail_cnt. Every check is logged and counted,
           and finish() fails the test if any check failed, so a test runs all
           of its checks the way the bench does.
- VERSION: the VERSION CSR value built from rtl/version.vh, which the benches
           `include.

    chk = Checks(dut._log)
    chk.check("frames received", n == 3, f"got {n}")
    chk.eq("RX_FRAME_CNT", await axil.read(0x60), 3)
    chk.finish()
"""
import re
from pathlib import Path

_VH = Path(__file__).resolve().parents[3] / "rtl" / "version.vh"


def _version() -> int:
    txt = _VH.read_text(encoding="utf-8")
    val = {}
    for name in ("MAJOR", "MINOR", "ID"):
        m = re.search(rf"`define\s+EMZ_VERSION_{name}\s+\d+'h([0-9A-Fa-f]+)", txt)
        assert m, f"EMZ_VERSION_{name} not found in {_VH}"
        val[name] = int(m.group(1), 16)
    return (val["MAJOR"] << 24) | (val["MINOR"] << 16) | val["ID"]


VERSION = _version()


def _fmt(x):
    return f"0x{x:08x}" if isinstance(x, int) else str(x)


class Checks:
    def __init__(self, log):
        self.log = log
        self.passed = 0
        self.failed = []

    def check(self, name, cond, detail=""):
        """Record one check. Returns cond, so a test can skip dependent checks."""
        msg = f"{name} ({detail})" if detail else name
        if cond:
            self.passed += 1
            self.log.info("PASS: %s", msg)
        else:
            self.failed.append(msg)
            self.log.error("FAIL: %s", msg)
        return bool(cond)

    def eq(self, name, actual, expected):
        """check(actual == expected). A value with X/U bits, passed as its
        string form, never equals an int, as with `===` in the bench."""
        return self.check(name, actual == expected,
                          f"{_fmt(actual)}, expected {_fmt(expected)}")

    def finish(self):
        assert not self.failed, (f"{len(self.failed)} check(s) failed "
                                 f"({self.passed} passed):\n  "
                                 + "\n  ".join(self.failed))
        self.log.info("ALL TESTS PASSED (%d checks)", self.passed)
