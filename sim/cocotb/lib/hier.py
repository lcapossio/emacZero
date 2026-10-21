# SPDX-License-Identifier: Apache-2.0
"""Find an internal signal whose path differs between the Verilog and the VHDL.

Names inside the DUT mostly match across the two languages, but not always:
VHDL generates are two labelled blocks where Verilog has one if/else, a VHDL
entity reads back an output through an internal `<name>_i` signal, and so on.
Tests that peek inside the DUT list every spelling and take the first that
exists:

    cnt = hier(dut, "u_mii_if.u_rx_fifo.wr_ptr_bin",     # Verilog
                    "u_mii_if.u_rx.fifo.wr_ptr_bin")     # VHDL, SIM target

Never write a GHDL internal signal from a test: GHDL's VPI keeps a written
value for good (Release has no effect), so the design can no longer drive it.
Reaching a corner by stimulus or by a smaller parameter works in both
languages.
"""


def _walk(handle, path):
    for part in path.split("."):
        handle = getattr(handle, part)
    return handle


def hier(dut, *paths):
    """The handle at the first of `paths` (dotted, relative to dut) that exists."""
    errors = []
    for path in paths:
        try:
            return _walk(dut, path)
        except AttributeError as exc:
            errors.append(f"{path}: {exc}")
    raise AttributeError("no such signal in this design:\n  " + "\n  ".join(errors))
