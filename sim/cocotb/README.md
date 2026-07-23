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
    eth.py          Ethernet framing + FCS (matches rtl/mii_tx_saf.v conventions)
    frame_gen.py    constrained-random frames (boundary-weighted) + merge/oversize
    axis_driver.py  AXIS master with randomized tvalid bubbles + dropped-tlast
    mii_monitor.py  MII nibble->byte, preamble/SFD strip, FCS check
    model.py        SAF commit/truncate/drop reference model + scoreboard
  tests/
    test_mii_tx_saf.py   pilot: directed boundaries + seed-logged random cases
  run.py          build + run entry point (Icarus today)
  smoke/          toolchain smoke (cocotb + Icarus VPI sanity)
```

## Running

```bash
# full pilot suite
python sim/cocotb/run.py

# reproduce a specific failure (seed is logged by every random test)
python sim/cocotb/run.py --seed 2506875794

# a single testcase, with waves
python sim/cocotb/run.py --test random_heavy_bubble --waves
```

Requires `cocotb>=2.0` and Icarus Verilog on `PATH` (both already present on the
dev bench). It is also wired into `build_and_test.py` as its own phase.

## What the pilot covers (`mii_tx_saf`)

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

## Adding a module

Reuse `lib/` and add `tests/test_<module>.py` plus a build target in `run.py`
(or a second runner). Keep DUT-specific reference models in `lib/model.py`.
