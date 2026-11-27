# cocotb verification suite

The emacZero simulation in Python with [cocotb](https://www.cocotb.org/). Every
suite runs on both languages: on the Verilog RTL in `rtl/` under Icarus, and on
the VHDL port in `rtl/vhdl/` under GHDL. The two get exactly the same tests;
only the simulator and the source list change.

There are three kinds of suite:

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
  when RX is disabled, no tail delivered when it is enabled mid-frame, no
  offered beat withdrawn); `eth_mac_sys_tx_en` and `eth_mac_sys_tx_en_csum`
  (`TX_CSUM_OFFLOAD` 0 and 1) check the same for CTRL[0] on `s_axis` and the
  GMII wire (no aborted or re-framed frame); `eth_mac_tx_start` checks that
  `eth_mac_tx` keeps a first byte handshaken on the cycle `tx_start_ok`
  falls; `eth_mac_sys_pause_rx_gmii`, `_mii`, `_rgmii100` and `_rgmii10`
  check 802.3 Annex 31B timing on each receive path, from the PHY pins: a
  received PAUSE frame gates TX within a quarter of the bound, also right
  behind a long frame, queued data frames are held at the TX pins, the MAC's
  own PAUSE frame still goes out, and both TX framers are counted (also
  with no preamble byte, on MII and RGMII 10/100 after an odd number of
  preamble nibbles, and not with `rx_er` on a trailing nibble); the same
  suites check automatic PAUSE against a link partner that obeys our PAUSE
  frames: with `m_axis` stalled the RX FIFO reaches XOFF, repeated XOFF
  frames keep the partner paused with no frame dropped or overflowed, and
  releasing `m_axis` sends one XON and delivers every frame; clearing
  `auto_en` sends XON, invalid settings raise `auto_cfg_err`, and a
  `tx_send` during a busy generator is held and sent; and a PAUSE frame
  received while our frame is on the wire counts its quanta from the end of
  that frame (802.3 Figure 31B-2), also with our own PAUSE frames going out
  after it and at 12 phases across a stream of minimum-size frames, while a
  PAUSE received with the wire idle is not stretched by our own PAUSE frame
  starting after it (also when that frame starts about an eighth of a
  quantum after it, checked between Q/16 and Q/4);
  `eth_mac_sys_pause_headroom_gmii` and `_mii` check the PAUSE_XOFF limit
  that `docs/registers.md` recommends for an 8 KB RX FIFO, with
  maximum-size frames from the partner and queued on `s_axis` (no overflow
  or drop, every frame delivered; `HEADROOM_XOFF` and `HEADROOM_TX_DELAY`
  vary the threshold and the phase of our frames);
  `eth_mac_sys_rx_nibble_mii`, `_rgmii100` and `_rgmii10` drive the 10/100
  receive pins nibble by nibble and check `m_axis`: `rx_er` on either nibble
  of a byte sets `terror`, and does not carry over to the next frame; a
  frame comes out intact after an odd or an even number of preamble
  nibbles, with no preamble byte, and with a trailing odd nibble, and with
  `terror` when that nibble has `rx_er`;
  `gmii_cdc_hold` and `gmii_cdc_hold_big` (`MAX_FRAME` 12000) fill the TX
  FIFO to its start limit while held, send the largest frame and check that
  it fits, and check that a control frame or `tx_hold` displaces a data frame
  waiting in its start gap;
  `eth_mac_sys_reset_txrx_off` and `eth_mac_sys_reset_txrx_on`
  (`TXRX_EN_AT_RESET` 0 and 1) check that CTRL's `tx_en` / `rx_en` and the
  frame-boundary gates leave reset together, with a frame offered across the
  reset release.

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
A full run of the 56 suites on both languages takes about 9 minutes at
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
delivered with `terror`; `rx_er` on the SFD byte is reported; a frame with 0 or
1 preamble bytes is received, with `terror` for `rx_er` on its first byte, and
one whose first byte is neither 0x55 nor 0xD5 is dropped whole; and a frame past
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

## 10GBASE-R

Verilog only for now (the suites skip the VHDL run).

- `pcs10gbr_enc`, `pcs10gbr_dec`, `pcs10gbr`: the PCS in `rtl/pcs10gbr*.v`
  against a reference model written from the IEEE 802.3 clause 49 tables
  (`lib/pcs10gbr_model.py`). The encoder and decoder are compared block by
  block with the model on every block type, junk and broken sequences; the
  whole PCS's TX stream is aligned and decoded by the model, and looped back
  to RX at several bit offsets; sync header errors drop and regain block
  lock and raise hi_ber.
- `gt10g_reset`: the ZCU106 GT reset sequencer
  (`fpga/zcu106/rtl/gt10g_reset.v`) against a model of the QPLL0 and channel
  reset handshakes: bring-up order (USERRDY never before the user clock runs,
  never while the path is in reset), an RX restart that leaves TX alone,
  recovery from a QPLL0 lock loss and a retry after an RX reset done that
  never comes.
- `xgmii_test_loop`, `xgmii_test_loop_o63`: the ZCU106 10G test generator,
  the PCS twice and the checker, the line looped back at bit offset 17 / 63:
  frames of 1 to 255 words with and without gaps all good and in sequence,
  back-to-back minimum frames at the full rate the PCS accepts, and injected
  payload and line bit errors counted.
- `crc32_d64`: the 8-byte CRC step (`rtl/crc32_d64.v`) against zlib for
  every byte count, and chained over random messages.
- `eth_mac_10g_tx`: the 64-bit transmit MAC's XGMII output parsed by the
  test (not by the RTL's rules): start lane, preamble, payload padded to 60
  bytes, FCS by zlib, terminate, idles; back-to-back frames must start
  exactly where the clause 46 deficit idle count puts them (84 line bytes
  per 64-byte frame), with ce always on, in the PCS's 32-of-33 pattern and
  random; a beat missing mid-frame corrupts only that frame with error
  characters, and tuser sends the frame with its payload and a wrong FCS.
  Removing the deficit idle count or the lane-4 start each fails it.
- `eth_mac_10g_rx`: the receive MAC against XGMII streams built by the test,
  starts in both lanes, gaps down to the 5-byte receive minimum, the
  decoder's valid gaps and random ones: payload with preamble and FCS
  removed, and tuser on a bad FCS, an error character, a bad SFD, a runt,
  an oversize frame (1518, 1522 tagged, jumbo), a runaway frame cut at
  16376 bytes, a frame cut short by idles, a fault ordered set or a new
  start, a start not preceded by idles or a sequence ordered set; frames of
  0 to 12 bytes in either lane never swallow the next frame; stats (length,
  error kind, broadcast, multicast). Ending frames only at a terminate, or
  accepting any start, each fails it.
- `eth_mac_10g_tx_loop`, `eth_mac_10g_loop`: the transmit MAC through the PCS
  and a line loopback at a bit offset, first checked on the received XGMII
  (frames and deficit idle count gaps intact), then through the receive MAC
  back to AXIS: every frame of a line-rate mix (minimum frames back to back,
  every short length, random up to 1500, a 9000-byte jumbo) comes back in
  order, padded, clean, and the tuser frames flagged, including tuser on the
  last beat of a short frame followed by a minimum frame at every end lane.
- `axis_async_frame_fifo`, `axis_async_frame_fifo_bp`: the store-and-forward
  frame FIFO behind and ahead of the 10G MACs (`rtl/axis_async_frame_fifo.v`),
  32 words, in drop mode and in backpressure mode: random frames, s_drop and
  reader stalls with the write clock faster, slower and nearly equal. Every
  frame is reported once (ok, drop or overflow), exactly the ok frames come
  out, whole, in order, and none before its last word was written; a stalled
  reader overflows the drop-mode FIFO at exactly the expected frame and holds
  off the writer in backpressure mode, where only frames longer than the
  FIFO are dropped. Letting the read side see uncommitted words fails it.
- `eth_mac_sys_10g_loop`: the 10G MAC system (`rtl/eth_mac_sys_10g.v`) with
  the PCS and a line loopback, the application clock (200 MHz) unrelated to
  the transceiver clock (161.13 MHz): the CSRs; 500 back-to-back 64-byte
  frames through both clock crossings at line rate (within 0.5%); every
  length 14..160, random ones to 1514 and jumbo frames, padded and counted;
  tuser frames dropped as bad, then delivered flagged with passthrough;
  oversize frames dropped; the address filter (station address, other
  unicast, broadcast, multicast in and out of the hash table), promisc and
  rx_en; RX FIFO overflow under m_axis backpressure, where what is delivered
  is whole and in order and every frame is either delivered or counted
  dropped; a TX frame too long for its FIFO dropped without blocking the
  next ones; a 111 MHz application clock, where the TX MAC must still never
  run dry; 64-bit counter reads and clears; a transceiver TX or RX reset
  alone, idle and in the middle of traffic, after which exactly the frames
  sent come out (none stale from the FIFO memory), nothing corrupt is
  delivered unflagged, and no counter jumps; a cut in the line in the
  middle of traffic: STATUS reports a local fault, remote fault sequences
  replace idles, no frame starts after the fault is seen and `s_axis` is
  held off; when the line returns the system reads its own remote fault,
  counts it and clears it, and traffic resumes in order with only the
  frames that were on the line at the cut missing. An always-open filter, a
  TX FIFO that publishes words before their frame is whole, an RX FIFO
  reset on one side only, or a TX gate that never closes, each fails it.
- `net_service64`: the demo L3 stack behind a 64-bit MAC stream
  (`fpga/zcu106/rtl/net_service64.v`): ARP requests for its address
  answered and others ignored; pings of 0 to 1472 payload bytes, every
  width of a frame's last beat, echoed with both checksums right and
  identifier, sequence and payload kept; UDP datagrams to the echo port
  echoed with the ports swapped, others ignored; no reply to a frame
  flagged bad. Input with random gaps and the output stalled at random. A
  burst of back-to-back pings: those arriving while a reply goes out are
  dropped (one reply buffer, as on the 1G demo), the replies stay whole and
  in order. UDP datagrams longer than `udp_echo`'s 1536-byte buffer, up to
  8193 bytes (4096 and 8192 among them), dropped whole and the stack
  answering after each; a long datagram arriving while a short one's reply
  goes out dropped whole although it outlasts the reply. An unpacker that
  loses the start of the frame after a 1-byte last beat, a byte count that
  wraps, or an accept decision taken again when a reply ends, each fails it.
- `eth_rs_10g`: 10G link fault signalling (`rtl/eth_rs_10g.v`, IEEE 802.3
  clause 46, figure 46-11) against a model of the rules kept as sequence
  positions: directed boundaries (127 versus 128 columns without a
  sequence before the fourth, sequences 100 columns apart, the 128-column
  clear, remote fault sequences keeping a local fault reported, both
  column positions in a word, reserved and malformed sequences, rx_valid
  gaps) and random column streams, dense and sparse, checked word by word;
  on TX, the MAC's words with one word of latency, and remote fault
  sequences only in all-idle words and only with a local fault. A
  threshold of three, a clear one column early, a count that runs from the
  first sequence instead of the last, the other type clearing a fault, or
  remote fault sequences with a remote fault, each fails it.
- `mac10g_test_loop`: the ZCU106 MAC-mode test path through the board's own
  port logic (`zcu106_10g_lane`, everything but the GT), `axis_test_gen64`
  (200 MHz) -> `eth_mac_sys_10g` -> PCS -> line loopback -> PCS ->
  `eth_mac_sys_10g` -> `axis_test_chk64`, with the board's settings:
  minimum frames at line rate, a 60..400 length sweep, 9000-byte frames, an
  injected payload error counted once, and the MAC's counters read and
  cleared through `axil_cmd_master` as the board's EIO does. Service mode
  switched on and off at random 120 times during traffic: no bad or merged
  frame at the checker, clean traffic afterwards; a mux that switches
  mid-frame fails it.
- `mac10g_dual`: two `zcu106_10g_lane`s crossed, each one's line output into
  the other's input (with different bit offsets, and each direction on its
  own transceiver clock), as SFP0 and SFP1 with a fibre between them:
  minimum frames at line rate both ways at once; port 0 sweeping 60..1514
  while port 1 sends 9014-byte frames, then port 0 sending 9000-byte frames
  with 5 idle cycles between them while port 1 sweeps 60..300; and an
  injected error counted only on the port that received it; IPv4 / UDP
  datagrams both ways, 1472-byte datagrams at line rate against a
  60..400-byte sweep. Each direction passes when every frame arrived good
  and in order and the sender's TX_FRAMES / TX_BYTES equal the receiver's
  RX_FRAMES / RX_BYTES.
- `axis_test64`: the ZCU106 test traffic blocks alone, `axis_test_gen64`
  and `axis_test_chk64`, in both formats (test frames and IPv4 / UDP
  datagrams). The generator's frames, under random backpressure, against a
  reference built in the test (IPv4 header checksum by RFC 1071 over the
  header bytes); the checker takes reference frames as good and in order,
  and counts as bad each frame with a bit flipped in any header byte or in
  the payload, an IPv4 identification other than its seq (checksum still
  right), a byte too few or too many, or tuser; a missing seq is one gap,
  and a frame with a broken header or seq byte is not taken as the next
  seq reference. A generator with a wrong checksum constant, or a checker
  without the IPv4 checksum, UDP length, identification or seq-complement
  check, or one that takes a broken-header frame's seq, each fails it.

## Reset defaults

`eth_mac_sys_reset_txrx_off` builds `eth_mac_sys` (MII, MII TX looped back to
RX) with its default parameters. It checks that CTRL resets to `0x20`, that a
frame offered on `s_axis` across the reset release is not accepted and nothing
is sent while `tx_en` is 0, that with only `tx_en` set the frame goes out but
its looped-back copy is not delivered, and that with both set a frame comes
back byte-exact. `eth_mac_sys_reset_txrx_on` sets `TXRX_EN_AT_RESET=1` and
checks that CTRL resets to `0x23` and the frame comes back with no CTRL write.
`axilite_regs_txrx_en` reruns the `axilite_regs` port with the same
parameter.

## Adding a suite

Add `tests/test_<name>.py` with a `SUITES` dict and the tests; `run.py` finds
it. Reuse `lib/` (`bench.Checks`, `axil_master`, the drivers and monitors), keep
DUT-specific reference models in `lib/`, and read internals only through
`lib/hier.py`. Run it on both languages (`--hdl both`) before committing.
A new harness in `hdl/` needs both languages and a proof in
`sim/parity/harness_<name>/`.
