# cocotb verification suite

The emacZero simulation in Python with [cocotb](https://www.cocotb.org/). Every
suite runs on both languages: on the Verilog RTL in `rtl/` under Icarus, and on
the VHDL port in `rtl/vhdl/` under GHDL. The two get exactly the same tests;
only the simulator and the source list change.

There are two kinds of suite:

- **Ports of the Verilog testbenches.** Each core bench in `sim/tb/` (the 44
  core entries of `build_and_test.py`) has a cocotb twin that drives the same
  DUT with the same parameters, clocks, stimulus timing and checks. The
  Verilog benches stay and keep running on Icarus (phase 1) and, against the
  VHDL, in Vivado xsim (phase 1c).
- **Directed + constrained-random suites** with reference models
  (`mii_tx_saf`, `eth_mac_rx*`, `gmii_cdc`, `csum_calc`, `tx_csum_off`),
  described under [Randomized suites](#randomized-suites).
- **Directed suites without a bench**: `eth_mac_sys_rx_en` checks that
  CTRL[1] changes apply only at frame boundaries of `m_axis` (no frame cut
  when RX is disabled, no tail delivered when it is enabled mid-frame).

## Layout

```
sim/cocotb/
  run.py          build + run entry point (finds the SUITES of every test module)
  tests/          one test_<name>.py per bench or suite, each with its SUITES
  hdl/            wiring harnesses, one .v + .vhd pair each (see below)
  lib/            shared Python
    bench.py         Checks (the benches' pass/fail counters) and VERSION
    axil_master.py   AXI4-Lite master with the benches' axi_write/axi_read timing
    hier.py          internal-signal lookup across Verilog and VHDL spellings
    mac_sys_a.py, mac_sys_b.py, rgmii_tb.py, rx_loop.py, txpath_bench.py,
    mii_bench.py     clocks, drivers and captures shared by a group of bench ports
    eth.py, frame_gen.py, axis_*.py, gmii_*.py, mii_monitor.py, csum.py,
    model.py, rx_model.py, gmii_cdc_model.py
                     drivers, monitors and reference models of the random suites
  smoke/          toolchain smoke (cocotb + Icarus VPI sanity)
```

## Running

```bash
python sim/cocotb/run.py --list                   # suite names
python sim/cocotb/run.py                          # every suite, Verilog (Icarus)
python sim/cocotb/run.py --hdl vhdl               # every suite, VHDL port (GHDL)
python sim/cocotb/run.py --hdl both -j 8          # both, 8 simulations at a time
python sim/cocotb/run.py --suite eth_mac_sys --hdl both
python sim/cocotb/run.py --seed 2506875794        # replay a logged random seed
python sim/cocotb/run.py --suite mii_tx_saf --test random_heavy_bubble --waves
```

Requires `cocotb>=2.0` with Icarus Verilog for `--hdl verilog`, and GHDL
(tested: 4.1) for `--hdl vhdl`. `build_and_test.py` runs every suite on both
languages (phases 2 and 2b, all CPUs in parallel); phase 2b runs in WSL when
GHDL is not on the Windows `PATH`. CI (`.github/workflows/sim.yml`) runs both.
A full run of the 54 suites on both languages takes about 9 minutes at
`-j 6`. `gmii_loopback` is the slowest: about 8 minutes on Icarus and 4 on
GHDL, because a Python coroutine models its PHY on each of about 3 million
clock edges.

## Declaring a suite

Each test module declares the suites it backs in a literal dict, which
`run.py` reads without importing the module:

```python
SUITES = {
    "eth_mac_sys_csum": {
        "toplevel": "eth_mac_sys",
        "sources": ["rtl/crc32.v", ..., "rtl/eth_mac_sys.v"],   # Verilog, in order
        "params": {"PHY_INTERFACE": "MII", "TX_CSUM_OFFLOAD": 1},
        "env": {"TB_TX_CSUM_OFFLOAD": "1"},                       # test-side variant
    },
}
```

The VHDL source list is derived: `rtl/**/<n>.v` maps to `rtl/vhdl/<n>.vhd`,
any other `<dir>/<n>.v` to `<dir>/<n>.vhd`, and the target and utility packages
come first. `"vhdl_sources"` overrides it, `"target"` picks the vendor target
(default `SIM`), and `"skip_vhdl": "<reason>"` keeps a suite on Verilog only
(no suite needs it today). The full format is in `run.py`'s docstring.

## Ports of the Verilog testbenches

Every port names its bench and `build_and_test.py` entry in its docstring and
lists the checks in the bench's order. Rules the ports follow:

- **Same DUT, parameters and timing.** Clock periods and phases are the
  bench's, inputs are driven at the same point relative to the clock, and a
  `-D` variant of a bench is its own suite (a parameter, a target or an `env`
  switch). Outputs are read settled (`ReadOnly`) at the point the bench samples
  them. Where the benches print a time or a count, the port reproduces it.
- **No writes to internal signals.** GHDL's VPI keeps a value written to an
  internal signal for good (a release has no effect), so the ports reach every
  corner by stimulus or by a smaller parameter. Internal signals are only read,
  through `lib/hier.py`.
- **Harnesses only wire.** A bench with several DUT instances gets a harness in
  `hdl/` in both languages that holds only the instances, the bench's nets and
  its tie-offs. Each harness pair is formally proven equivalent with
  translateHDL (`sim/parity/harness_*`). `hdl/xpm_*_model.vhd` are VHDL twins
  of the bench's XPM simulation models, proven against them the same way
  (`sim/parity/harness_xpm_models`).

| `build_and_test.py` bench | Suite(s) | Top |
| --- | --- | --- |
| CRC32 | `crc32` | `crc32` |
| ASYNC-FIFO, -BLOCK | `async_fifo`, `async_fifo_block` | `async_fifo` |
| AXILITE-REGS | `axilite_regs` | `axilite_regs` |
| MDIO-MASTER | `mdio_master` | `mdio_master` |
| ETH-STATS | `eth_stats`, `eth_stats_sat` | `eth_stats` |
| ETH-MAC-FCS | `eth_mac_fcs` | `eth_mac_tx` |
| ETH-MAC-TX-PAD | `eth_mac_tx_pad` | `h_eth_mac_tx_pad` |
| MII-TX-BRIDGE | `mii_tx_bridge` | `h_mii_tx_bridge` |
| MII-TX-BURST-BACKPRESSURE | `mii_tx_burst_backpressure` | `h_mii_tx_bridge` |
| MII-TX-SAF, -BURST-STALL, -OVERSIZE | `mii_tx_saf_tb`, `mii_tx_saf_burst_stall`, `mii_tx_saf_oversize` | `mii_tx_saf` |
| TX-CSUM-OFF | `tx_csum_off_tb` | `tx_csum_off` |
| MCAST-FILTER | `mcast_filter` | `h_eth_mac_rx_loop` |
| ETH-MAC-RX-BACKPRESSURE | `eth_mac_rx_backpressure` | `h_eth_mac_rx_loop` |
| ETH-MAC-RX-BYTE0 | `eth_mac_rx_byte0` | `h_eth_mac_rx_loop` |
| ETH-MAC-RX-JUMBO-GATE | `eth_mac_rx_jumbo_gate` | `h_eth_mac_rx_jumbo_gate` |
| ETH-MAC-SYS-JUMBO | `eth_mac_sys_jumbo` | `h_eth_mac_rx_loop` |
| GMII-CDC | `gmii_cdc_loopback` | `gmii_cdc` |
| GMII-CDC-RX-OVERFLOW, -DIST | `gmii_cdc_rx_overflow`, `gmii_cdc_rx_overflow_dist` | `gmii_cdc` |
| GMII-CDC-100M, -10M | `gmii_cdc_100m`, `gmii_cdc_10m` | `gmii_cdc` |
| RGMII-IF | `rgmii_if` | `h_rgmii_if` |
| RGMII-IF-100M | `rgmii_if_100m` | `h_rgmii_if_100m` |
| RGMII-IF-SPEED-SWITCH | `rgmii_if_speed_switch` | `h_rgmii_if_100m` |
| RGMII-IF-VARIANTS | `rgmii_if_variants` | `h_rgmii_if_variants` |
| ETH-MAC-MULTIFRAME | `eth_mac_multiframe` | `eth_mac` |
| ETH-MAC-JUMBO | `eth_mac_jumbo` | `eth_mac` |
| MII-STORE-FORWARD | `mii_store_forward` | `eth_mac` |
| MII-LOOPBACK | `mii_loopback` | `h_mii_loopback` |
| MII-RX-REPLAY-STRESS | `mii_rx_replay_stress` | `mii_if` (XILINX_7SERIES, XPM models) |
| ETH-MAC-SYS | `eth_mac_sys` | `eth_mac_sys` |
| ETH-MAC-SYS-CSUM, -BYPASS | `eth_mac_sys_csum`, `eth_mac_sys_csum_bypass` | `eth_mac_sys` |
| ETH-MAC-SYS-CSUM-LOOP | `eth_mac_sys_csum_loop` | `eth_mac_sys` |
| ETH-MAC-SYS-MAX-FRAME | `eth_mac_sys_max_frame` | `eth_mac_sys` |
| ETH-MAC-SYS-PAUSE | `eth_mac_sys_pause` | `eth_mac_sys` |
| RGMII-LOOPBACK | `rgmii_loopback` | `eth_mac_sys` |
| RGMII-100M-LOOPBACK, -10M | `rgmii_10_100_loopback_100m`, `_10m` | `eth_mac_sys` |
| GMII-LOOPBACK | `gmii_loopback` | `eth_mac_sys` |
| GMII-RX-LINE-RATE | `gmii_rx_line_rate` | `eth_mac_sys` |

Where a port differs from its bench, its docstring says so. The differences
that change what is covered:

- `eth_stats_sat`: the bench forces a counter to `0xFFFFFFFE` to test
  saturation. The port builds `eth_stats` with `STAT_CNT_W=3` and counts up to
  the maximum instead, so saturation is simulated on the VHDL too.
- `rgmii_loopback`: the bench forces `gmii_cdc`'s RX inputs from its TX
  outputs, bypassing `rgmii_if`'s receive path. The port loops the TX stream
  back DDR-encoded on the RGMII RX pins, so the receive path is exercised as
  well and the frames arrive two cycles later (the bench does not check
  latency).
- The benches use no `$random`, so no seeds differ.
- `gmii_rx_line_rate` has a `GMII_RX_SLOW_SYS` variant that is expected to
  fail (as in the bench, which has no `build_and_test.py` entry for it).
  Run it by hand with `GMII_RX_SLOW_SYS=1` in the environment.

## Randomized suites

### `eth_mac_rx` (RX datapath)

Drives whole GMII wire frames, predicts delivery/`terror`/stats with the RX
reference model, and checks the AXIS output + per-frame stat pulses:

- **Filtering** — unicast-match, broadcast, foreign (dropped), multicast, plus
  `promisc`/`passthrough`; a filtered frame yields no AXIS output and no stat.
- **Error paths** — bad FCS, `rx_er` alignment, and oversize each deliver with
  `terror` on `tlast` and the matching `stat_err_*` (the MAC flags, the wrapper
  drops).
- **Backpressure** — random `tready` stalls during reception (gated so a single
  frame stays within the RX FIFO); frames stay byte-exact.
- **Randomized** — seed-logged mix of destinations, sizes, and injected errors.

Mutation-checked: corrupting the FCS residue constant fails all tests; defeating
the MAC filter fails exactly the tests that send frames which should be dropped.

A separate `eth_mac_rx_robust` suite covers overflow/edge behavior the main suite
avoids: a jumbo frame received under held backpressure overruns the RX FIFO yet
is still terminated with `terror` and does not corrupt the next frame; a runt is
delivered with `terror`; `rx_er` on the SFD byte is reported; and a frame past
the 14-bit `byte_cnt` wrap point does not inject a phantom SOF. Every fix is
mutation-checked (disabling the reserved headroom drops the closing TLAST so the
overflow frame merges; removing the undersize/`rx_er`/saturation logic fails the
matching test).

A separate `eth_mac_rx_mcast` suite builds the module with `MCAST_HASH_FILTER=1`
and drives the 64-bit hash table directly (the default suite runs the filter off,
and `rx_model.py` does not model it). It pins the hash-admit gate to the I/G bit:
a hashed group address is admitted (even with an even last octet), an unhashed
group address is dropped, and a unicast that collides with a set bucket is not
leaked. Mutation-checked: reverting the admit bit to `mac_chk[0]` fails the
admit-a-group and don't-leak-a-unicast cases in opposite directions.

### `mii_tx_saf` (TX store-and-forward)

Each test drives AXIS stimulus, predicts the transmitted frames with the
`model.saf_expected` reference model, and checks the MII wire (payload + recomputed
FCS) against that prediction:

- **Directed boundaries** — every size corner: 1, the min-frame edge (59/60/61),
  the `MAX_FRAME` edge (±1), and around the FIFO depth; plus explicit merged-frame
  (dropped `tlast`) and oversized (> FIFO) runs.
- **Bubbled** — the same corners under heavy random `tvalid` bubbling (the
  store-and-forward promise: the source may stall mid-frame with no wire underrun).
- **Randomized** — seed-logged runs with boundary-weighted sizes, random bubbles,
  and a tunable dropped-`tlast` rate that exercises the `MAX_FRAME` cap.

The reference model encodes the DUT's commit/truncate/drop policy, so a randomized
run has a precise expected result — not just a "didn't hang" check. The suite is
**mutation-checked**: disabling the oversize-guard cap in the RTL makes it fail
(wedge → per-test timeout), confirming it would catch a regression of that bug.

### `gmii_cdc` (TX store-and-forward CDC)

Drives contiguous GMII frames on the sys-clock input and checks the paced
media-side output is byte-for-byte identical, in order, across 1G/100M/10M (the
CDC is a content-identity re-timer). The monitor is byte-exact at 1G; at 100M/10M
repeated payload bytes are indistinguishable from a held byte, so it checks the
delivered frame count and each frame's length (inferred from the `tx_en` span).

- **TX directed** — mixed sizes byte-exact at 1G; length/count-exact at 100M/10M.
- **TX burst probe** — 20 back-to-back small frames at 100M: the sys side commits
  many frames before the paced media side drains them, stressing the
  committed-frame counter (the `mii_tx_saf`-class wrap hazard).
- **RX directed** — media-side frames byte-exact on the sys output (the RX
  readout is unpaced), plus per-byte `rx_er` alignment through the CDC.
- **RX burst probe** — tight media-side frames drained by a deliberately slow sys
  clock, so committed frames pile up past 16 and stress `rx_frames_pending`.
- **Error passthrough** — `gmii_tx_er_in`/`rx_er` must ride the CDC on the same
  byte they were asserted (byte-exact at 1G).
- **Paced last-byte hold** — at 100M the final byte must occupy the full pace
  interval (raw `tx_en` span = `len*period`), not a single cycle.
- **Randomized** — seed-logged size/gap/speed mix.

**Mutation-checked**, and every mutation is a real bug this suite found:
narrowing the TX committed counter to 4 bits wedges its burst probe at 4/20
(= 20 mod 16); removing the paced EOF-advance drops every TX frame after the
first at 100M/10M; narrowing `rx_frames_pending` to 4 bits wedges the RX burst
at 15/30; reverting the RX readout to re-align at each EOF drops byte 0 of every
frame after the first; hard-wiring `gmii_tx_er_out` to 0 fails the error
passthrough; closing out the paced frame one cycle early shortens the last
byte's span from `len*period` to `(len-1)*period+1`.

## Adding a suite

Add `tests/test_<name>.py` with a `SUITES` dict and the tests; `run.py` finds
it. Reuse `lib/` (`bench.Checks`, `axil_master`, the drivers and monitors), keep
DUT-specific reference models in `lib/`, and read internals only through
`lib/hier.py`. Run it on both languages (`--hdl both`) before committing.
A new harness in `hdl/` needs both languages and a proof in
`sim/parity/harness_<name>/`.
