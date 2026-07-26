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
    gmii_rx_cdc_driver.py  raw-GMII media-side RX driver (rx_dv-delimited frames)
    gmii_rx_cdc_monitor.py sys-side RX monitor (byte-exact; per-byte rx_er)
    gmii_cdc_model.py  identity CDC reference model + scoreboard
  tests/
    test_mii_tx_saf.py       directed boundaries + seed-logged random (TX store-and-forward)
    test_eth_mac_rx.py       filter/error/backpressure + seed-logged random (RX datapath)
    test_eth_mac_rx_robust.py FIFO-overflow framing, runt, preamble rx_er, byte_cnt wrap
    test_eth_mac_rx_mcast.py multicast hash filter (MCAST_HASH_FILTER=1 build)
    test_gmii_cdc.py         TX+RX CDC across 1G/100M/10M + committed-counter burst probes
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

## Adding a module

Reuse `lib/` and add `tests/test_<module>.py` plus a build target in `run.py`
(or a second runner). Keep DUT-specific reference models in `lib/model.py`.
