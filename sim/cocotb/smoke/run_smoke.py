# SPDX-License-Identifier: Apache-2.0
# Standalone runner for the toolchain smoke (no pytest needed).
from pathlib import Path
from cocotb_tools.runner import get_runner

HERE = Path(__file__).parent


def main():
    runner = get_runner("icarus")
    runner.build(
        verilog_sources=[str(HERE / "dff.v")],
        hdl_toplevel="dff",
        build_dir=str(HERE / "sim_build"),
        timescale=("1ns", "1ps"),
        always=True,
    )
    runner.test(
        test_module="test_smoke",
        hdl_toplevel="dff",
        test_dir=str(HERE),
        build_dir=str(HERE / "sim_build"),
    )


if __name__ == "__main__":
    main()
