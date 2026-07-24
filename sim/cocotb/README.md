# cocotb verification suite

A directed **+** constrained-random verification layer for emacZero, written in
Python with [cocotb](https://www.cocotb.org/). It runs **alongside** the existing
hand-written Icarus testbenches in `sim/tb/` — it does not replace them.

## Why cocotb here

The suite is deliberately **backend-agnostic**: testbenches drive the DUT through
cocotb's language-neutral interface and sources are passed via `sources=`, so the
*same* Python re-runs against a VHDL port under GHDL — only the simulator name and
the RTL source files change. That is the point: the verification survives the
planned Verilog→VHDL port.

## Layout

```
sim/cocotb/
  lib/            reusable, DUT-independent building blocks
    eth.py           Ethernet framing + FCS (matches the RTL conventions)
    frame_gen.py     constrained-random frames (boundary-weighted) + merge/oversize
    axis_driver.py   AXIS master with randomized tvalid bubbles + dropped-tlast
    mii_monitor.py   MII nibble->byte, preamble/SFD strip, FCS check
    model.py         mii_tx_saf commit/truncate/drop reference model + scoreboard
    gmii_rx_driver.py  GMII input driver (preamble/SFD/FCS, FCS-corrupt, rx_er)
    axis_sink.py     AXIS slave with backpressure; reassembles frames + terror
    rx_model.py      eth_mac_rx filter/error/stats reference model + scoreboard
    gmii_tx_driver.py  contiguous GMII byte frames on the sys-clock TX input
    gmii_tx_monitor.py paced media-side monitor (byte-exact 1G; span->len 100M/10M)
    gmii_cdc_model.py  identity CDC reference model + scoreboard
  tests/
    test_mii_tx_saf.py   directed boundaries + seed-logged random (TX store-and-forward)
    test_eth_mac_rx.py   filter/error/backpressure + seed-logged random (RX datapath)
    test_gmii_cdc.py     paced TX CDC across 1G/100M/10M + committed-counter burst probe
  run.py          build + run entry point (SUITES table; Icarus today)
  smoke/          toolchain smoke (cocotb + Icarus VPI sanity)
```

## Running

```bash
# all suites
python sim/cocotb/run.py

# one suite
python sim/cocotb/run.py --suite eth_mac_rx

# reproduce a specific failure (seed is logged by every random test)
python sim/cocotb/run.py --seed 2506875794

# a single testcase, with waves
python sim/cocotb/run.py --test random_heavy_bubble --waves
```

Requires `cocotb>=2.0` and Icarus Verilog on `PATH` (both already present on the
dev bench). It is also wired into `build_and_test.py` as its own phase.

## Modules covered

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

- **Directed** — mixed sizes byte-exact at 1G; length/count-exact at 100M/10M.
- **Burst probe** — 20 back-to-back small frames at 100M: the sys side commits
  many frames before the paced media side drains them, stressing the
  committed-frame counter (the `mii_tx_saf`-class wrap hazard).
- **Randomized** — seed-logged size/gap/speed mix.

**Mutation-checked**: narrowing the committed counter back to 4 bits wedges the
burst probe at 4/20 (= 20 mod 16); removing the paced EOF-advance fix drops every
frame after the first at 100M/10M. Both are the real bugs this suite found.

## Adding a module

Reuse `lib/` and add `tests/test_<module>.py` plus a build target in `run.py`
(or a second runner). Keep DUT-specific reference models in `lib/model.py`.
