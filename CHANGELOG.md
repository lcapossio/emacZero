# Changelog

All notable changes to emacZero are recorded here for downstream integrators.
This project does not yet maintain long-lived release branches.

## Unreleased

### Added

- Vivado RTL elaboration gate in the regression (`PHASE 0c`, via
  `fpga/arty_a7/scripts/elab_check.tcl`). It elaborates the Arty top - which
  pulls in the whole MAC and the optional L3 helpers - without synthesizing,
  placing or routing, in about 30 seconds. Neither linter covers this class of
  defect: an out-of-range part-select passed `iverilog -Wall` and Verilator for
  two months and surfaced only when Vivado refused to elaborate it, by which
  point no Arty bitstream could be built. The phase is SKIPPED, not failed,
  where Vivado is not on PATH, so CI and contributors without the toolchain
  still get the rest of the suite.
- **GMII PHY interface** (`PHY_INTERFACE="GMII"`, new `rtl/gmii_if.v`). A third
  media option alongside `"MII"` and `"RGMII"`, structurally the RGMII branch
  with the DDR stage replaced by registered SDR I/O: the same cut-through
  `eth_mac_tx` framer and the same `gmii_cdc` store-and-forward CDC, so jumbo
  TX and RX work exactly as they do on RGMII (jumbo RX needed the `gmii_cdc`
  RX FIFO fix under Fixed below).
  - 1000 Mbps only, which is what GMII means - a tri-speed PHY exposing GMII
    reverts to 4-bit MII at 10/100, and that is the existing `"MII"` mode. The
    branch therefore pins `gmii_cdc` pacing to 1G and **ignores the `cfg_speed`
    speed field**; a CSR write selecting 100M/10M has no effect here.
  - New pins `phy_gmii_txd/tx_en/tx_er/txc` and
    `phy_gmii_rx_clk/rxd/rx_dv/rx_er`. The transmit clock is the signal IEEE
    802.3 Clause 35 calls GTX_CLK, but the port is named `txc` rather than
    `gtx_clk`: "gtx" collides with the Xilinx GTX serial transceivers, so a
    wildcard constraint such as `[get_ports *gtx*]` aimed at those would
    otherwise pick up this Ethernet pin. It also matches the existing
    `rgmii_txc`. Reuses the existing `clk_125` /
    `clk_125_90` inputs; `clk_25` / `clk_2_5` are unused on this branch.
    GTX_CLK is forwarded out of a DDR cell driven by `clk_125` with the
    waveform inverted (`d1=0`/`d2=1`), putting its rising edge at `clk_125`'s
    falling edge - ~4 ns into the 8 ns data window, leaving ~4 ns each of setup
    and hold against the IEEE 802.3 Clause 35.5.2 requirement of 2.5 ns setup /
    0.5 ns hold **at the signal source** (this MAC's own pins), which relaxes to
    2.0 ns / 0 ns at the PHY after the 500 ps board length-matching budget.
    (Forwarding `clk_125_90` is the RGMII convention and gives only ~2 ns, below
    the 2.5 ns required at the source; an edge-aligned `d1=1`/`d2=0` leaves no
    deliberate phase margin either way. The inverted waveform is 50% duty, well
    inside Clause 35's 35%-75%.) Board trace skew still has to be
    budgeted in the XDC, and the I/O registers are plain single-stage flops so
    `set_property IOB TRUE` can pack them. The TX output registers use an
    async-assert / sync-deassert reset synchroniser into `clk_125`, since
    `rst_n` is generated in the system-clock domain.
  - `eth_pause`'s speed-dependent prescaler is fed a forced `2'b00` on the GMII
    branch (`cfg_speed_eff`), so a CSR write selecting 10M cannot stretch
    received PAUSE quanta ~100x while the datapath keeps running at 1G.
  - Principal use is feeding a vendor 1G PCS/PMA core for SGMII / 1000BASE-X,
    which presents a GMII bus rather than PHY pins.
  - The `"MII"` and `"RGMII"` branches are untouched, including their
    hierarchical instance names (`gen_mii.*`, `gen_rgmii.*`), which existing
    testbenches and debug probes reference by path.
- `sim/tb/tb_gmii_loopback.v` (`GMII-LOOPBACK`, 20 checks). Closes the loop at
  the actual GMII pins rather than forcing internal `gmii_cdc` nets - GMII is
  single-data-rate, so no DDR behavioural model sits in the path and
  `gmii_if` itself is covered. Verifies byte-exact payload and FCS-stripped
  length for small (64 B), standard-MTU (1514 B) and jumbo (4014 B) frames,
  zero CRC errors, stats counters, and that clearing `jumbo_en` makes the same
  jumbo frame arrive flagged with `terror` and counted in `RX_ERR_OVERSIZE`.
  The stand-in PHY captures the TX pins on the **rising edge of GTX_CLK**, as
  Clause 35 specifies, so a stuck or mis-clocked GTX_CLK breaks the datapath
  rather than being bypassed. GTX_CLK is additionally checked for phase (each
  rising edge must land 2.5-7.5 ns after the clk_125 that launched the data),
  for continuity against a clk_125 edge count, and for pulse widths within
  Clause 35's 35%-75% duty allowance. Validated against two mutants: an
  edge-aligned GTX_CLK scores ~907k phase violations, and a 62.5 MHz GTX_CLK
  that is correctly phased - which the phase check alone passes - is caught by
  the edge-count and pulse-width checks.
- `rtl/gmii_if.v` added to `emaczero.core`'s `rtl_core` fileset, so the
  published FuseSoC core can actually elaborate `PHY_INTERFACE="GMII"`.

- `mii_tx_saf`: a fully store-and-forward MII transmit path built on a **single**
  async frame FIFO (`{tlast,data}`) feeding a media-side framer (preamble/SFD/
  CRC/pad/FCS/IFG + nibble output). The framer starts only once a whole frame is
  committed, so the AXIS input MAY bubble (deassert `tvalid` mid-frame) with no
  wire underrun and no transmit error - unlike the cut-through `eth_mac_tx` it is
  intended to replace on the MII path. Standalone-validated by `MII-TX-SAF`
  (byte-exact framing + recomputed FCS under per-byte gaps and a 40-cycle
  mid-frame stall).
- `IP_ADDR` CSR (`0x40`, RW): the demo L3 stack IPv4 (`cfg_ip_addr`) is now
  AXI-writable, so a board can be retargeted to a new subnet at runtime without
  a rebuild. Unused by the bare MAC.
- `SAF_DBG` CSR (`0x94`, RO): a synchronized snapshot of the `mii_tx_saf`
  framer/FIFO state (committed/drained frame counts, `rd_empty`, framer state)
  for on-hardware TX diagnosis. Reads `0` on the RGMII build.
- `axil_arb2`: a 2:1 AXI4-Lite arbiter, used to share the CSR bus between the
  test sequencer and an EJTAG-AXI debug bridge on the Arty A7 debug build.

### Changed

- `eth_mac_sys` MII path now transmits through `mii_tx_saf` instead of the
  cut-through `eth_mac_tx`, so a bubbling TX AXIS source can no longer cause a
  mid-frame underrun / bad frame on the wire. `eth_mac_tx` is retained on the
  RGMII path. TX stats (`tx_byte_cnt`/`tx_frame_cnt`), `STATUS.tx_active`, the
  TX-done IRQ, and inbound-PAUSE TX gating are preserved (wire-byte semantics
  unchanged).
- `mii_if` gained a `TX_ENABLE` parameter (default 1). The MII path in
  `eth_mac_sys` sets `TX_ENABLE=0` so `mii_if`'s now-idle internal TX FIFO is
  compiled out (not merely tied off): its RAMB36 is reclaimed (Arty A7 debug
  build 6.5 -> 5.5 BRAM tiles) and the MII TX path now has a single FIFO. The
  legacy `eth_mac` wrapper and the MII TX testbenches keep the default
  `TX_ENABLE=1`.
- `STATUS[3]` (`mdio_cmd_dropped`): an MDIO `GO` written while the MDIO master
  is busy no longer fails silently — it sets this sticky bit (cleared by the
  next successfully-issued `GO`) so software can detect the dropped command.
- `async_fifo` exposes an exact write-side `wr_data_count` (`wr_ptr` minus the
  synchronized read Gray pointer); leave it unconnected when not needed.

### Changed

- `gmii_cdc` TX fill level / `tx_busy` now use `async_fifo.wr_data_count`
  instead of a per-byte read toggle synchronizer, which could drop counts when
  `media_clk` (125 MHz) outran `sys_clk` (100 MHz) at 1G.
- `gmii_cdc` TX path now uses a single EOF-sideband packet FIFO (9-bit: data
  byte + EOF marker) with a gray-coded committed-frame counter to gate the
  store-and-forward start, replacing the separate 14-bit length FIFO and its
  length accumulator. This matches the MII adapter and `gmii_cdc`'s own RX path.
  The paced media-side waveform (1G/100M/10M) is byte-for-byte unchanged, and
  BRAM usage is unchanged (the EOF bit occupies the spare 9th bit of the
  16K-deep data FIFO). Validated by the GMII-CDC 1G/100M/10M loopback tests.

- `eth_mac_sys` / `eth_mac` now scale the RX AXIS buffer with `MAX_FRAME` via a
  new `RX_AXIS_ADDR_WIDTH` parameter (defaults to one full frame, 2048-byte
  floor), so a jumbo frame can be absorbed under sustained downstream
  backpressure instead of overflowing the fixed 2048-byte buffer. Standard
  builds (`MAX_FRAME <= 2048`) are unchanged.
- `eth_stats` counter width is now parameterizable via `STAT_CNT_W` (default 32,
  unchanged) and the saturation logic uses an all-ones detect instead of a
  full-width equality comparator.
- Behavioral DDR I/O models (`ddr_input` / `ddr_output`) are now gated behind a
  `SIM` define; synthesis requires `XILINX_7SERIES` (or a real vendor atom).
  `build_and_test.py` passes `-DSIM` for lint and simulation. The
  `INTEL_CYCLONE` branch is explicitly flagged as a non-synthesizable stub.
- Pinned the Arty A7 MII demo to `MAX_FRAME=1518` and documented jumbo as
  RGMII-only. The MII 10/100 path is standard-MTU in both directions: its
  4096-byte TX FIFO and RX replay buffer cannot hold a jumbo frame while the
  slow MII side drains it (README, `docs/missing_features.md`, and a note at
  the `eth_mac_sys` MII branch).

### Fixed

- **Jumbo RX truncated above ~4083 bytes on the GMII and RGMII paths.**
  `gmii_cdc`'s RX CDC FIFO is store-and-forward (the sys side waits for a
  frame's EOF marker) but was fixed at 4096 words, so any frame longer than
  that, preamble included, could not fit. It is now sized from a new
  `MAX_FRAME` parameter (passed down from `eth_mac_sys`): 16K words at the
  9018-byte default, with a 4K floor so standard-MTU builds keep their
  previous depth. `RX_FIFO_ADDR_WIDTH` can override it. On GMII/RGMII builds
  with jumbo `MAX_FRAME` the RX CDC FIFO grows 4x; set `MAX_FRAME=1518` if
  jumbo RX is not needed. `GMII-LOOPBACK` now checks a full 9018-byte frame
  byte-exact; with the old depth it arrives as 4084 bytes.
- **RX CDC FIFO overflow could merge two frames.** Writes were gated only by
  `full`, so on overflow the frame's EOF marker could be dropped while the
  frame toggle still fired, and the sys side read two frames as one. Data words
  are now written only while two slots are free, so an EOF always fits; once a
  byte is refused the rest of that frame is dropped (no holes), and its EOF
  carries a truncation flag. The reader appends one `rx_er` beat to a truncated
  frame, so the MAC delivers it with `m_axis_terror` and counts it in
  `RX_ERR_ALIGN` instead of relying on a CRC miss. A frame that finds the FIFO
  full is dropped whole, without trace.
- **`gmii_cdc` RX reader could start a partially written frame, or wedge.** At
  an EOF, `rx_frames_pending` still counted the frame being retired, so the
  reader kept going into whatever followed - cut-through into a frame whose
  EOF had not been written yet. At RGMII 10/100, where the media side is
  slower than the reader, that can underflow mid-frame. Going idle also issued
  a speculative pop that silently ate the next word: harmless when it was a
  preamble byte, but when it was the EOF of a frame dropped whole by overflow
  it left `rx_frames_pending` stuck, and the reader never went idle again.
  Readiness now excludes the frame being retired (and any done pulse in
  flight), and the reader goes idle without popping. New
  `GMII-CDC-RX-OVERFLOW` testbench
  (`sim/tb/tb_gmii_cdc_rx_overflow.v`) covers truncation, whole-frame drops,
  EOF-only frames, overflowing bursts and recovery.
- **Half of all FPGA-to-host frames were dropped at line rate.** `udp_blast`,
  `udp_echo`, `udp_stats_reply` and `icmp_echo` arm `src_last` one cycle ahead
  of the final payload byte, but their 1-deep AXIS output slice only samples
  `src_*` while `src_ready` is high. `src_last` was cleared unconditionally on
  every cycle, so whenever the sink stalled on exactly that beat the `tlast`
  evaporated: the frame merged with the next one, `mii_tx_saf`'s oversize guard
  truncated the pair, and **one frame went out for every two generated**. The
  generators now hold `tlast` until the slice captures it. Measured on an Arty
  A7-100T at 100 Mbps: a 20000-frame blast delivered 10002 frames (50.0% loss,
  58 Mbps) before the fix and 20000/20000 (0 loss, 95.69 Mbps - the theoretical
  UDP payload maximum) after; the 60 s bidirectional stress went from 31 gaps
  to 0. The defect was rate-dependent and invisible to a never-stalling sink,
  so every existing testbench passed. Four new testbenches close that blind
  spot - `UDP-BLAST-BACKPRESSURE`, `ICMP-ECHO-BACKPRESSURE`,
  `UDP-ECHO-BACKPRESSURE` and `UDP-STATS-REPLY-BACKPRESSURE` - each sweeping a
  one-cycle sink stall across every beat position of the frame (386 checks).
  Without the fix each one fails precisely at the beat where `src_last` is
  armed. `udp_echo` had no directed testbench at all before this.

- `mii_tx_saf` synthesizes again: `tx_fifo_level` sliced `fifo_count[12:0]` from
  a counter whose width is `FIFO_ADDR_WIDTH+1`, so Vivado rejected it with
  `[Synth 8-524] part-select [12:0] out of range` and **no Arty A7 bitstream
  could be built**. The slice had been exact while `eth_mac_sys` bound
  `FIFO_ADDR_WIDTH(12)`; deriving the width from `MAX_FRAME` made it 11 for
  `MAX_FRAME=1518` (12-bit counter, slice out of range) and 14 for the 9018
  default (15-bit counter, silently truncated). The count is now zero-padded to
  a width that keeps both part-selects in range for any `FIFO_ADDR_WIDTH`, and
  saturates at `13'h1FFF` rather than truncating - a truncated occupancy of
  8192 would have been reported as 0, matching the `gmii_cdc` convention.
  Both linters accept the old form, so only a Vivado elaboration catches this
  class of defect; the simulation suite was green throughout.

- `eth_mac_rx` framing survives RX-FIFO overflow: the readout reserves headroom
  so a frame's SOF and closing TLAST words are never the ones dropped when the
  2 KB FIFO fills. Overrun data is dropped and the frame is flagged `terror`, but
  it always starts and terminates cleanly - a dropped SOF used to leave the sink
  unable to delimit and a dropped TLAST merged the frame into the next. New
  `eth_mac_rx_robust` suite (`overflow_framing`).
- `eth_mac_rx` runt handling: a frame shorter than 64 wire bytes is now delivered
  with `terror` (undersize) instead of as a clean frame with a garbage FCS, so
  the wrapper's error-drop stage discards it. Regression `runt_terror`.
- `eth_mac_rx` `byte_cnt` no longer wraps: the 14-bit counter saturates at
  0x3FFF, so a frame past 16383 wire bytes cannot re-enter the `byte_cnt==5`
  decision, re-capture the dst MAC and inject a phantom SOF that corrupts the
  following frame. Regression `bytecnt_no_wrap`.
- `eth_mac_rx` reports `rx_er` asserted on a preamble/SFD byte (was only sampled
  in `S_DATA`), so such a frame carries `terror` + `stat_err_align`. Regression
  `preamble_rx_er`.
- `mii_tx_saf` now fails elaboration if `MAX_FRAME >= FIFO_DEPTH` (an `initial`
  `$finish`): the oversize cap relies on that invariant, and violating it silently
  reintroduces the permanent TX wedge.
- `eth_mac_sys` sizes the MII `mii_tx_saf` frame FIFO from `MAX_FRAME`
  (`$clog2`-derived) instead of a fixed 4096 entries. The old fixed size wedged
  the MII TX path on frames between 4096 and `MAX_FRAME` (9018) bytes; the FIFO
  now holds one whole frame, and a standard build (`MAX_FRAME=1518`) pays only for
  a 2048-deep FIFO - the jumbo cost is incurred only when jumbo is built.
- `eth_mac_rx` multicast-hash filter gated on the wrong bit: the hash-admit term
  tested `mac_chk[0]` (LSB of the last dst octet) instead of `mac_chk[40]` (the
  I/G bit, dst byte 0 LSB) - so with `MCAST_HASH_FILTER=1` a genuine group address
  whose last octet was even was rejected, and a unicast with an odd last octet and
  a colliding hash bucket was admitted. Both admit sites now use `mac_chk[40]`,
  matching the neighboring `is_mcast_r`. Regression suite `eth_mac_rx_mcast`.
- `gmii_cdc` TX error input was dropped: `gmii_tx_er_in` was never captured and
  `gmii_tx_er_out` was hard-wired 0, so a MAC-signalled transmit error never
  reached the media side (the RX path already carried `rx_er`). The TX FIFO word
  gained a per-byte error lane (9 -> 10 bits) that re-drives `gmii_tx_er_out`.
  Regression `test_gmii_cdc.tx_error_flag`.
- `gmii_cdc` paced-TX held the final (EOF) byte for only 1 media cycle instead of
  the full pace interval at 100M/10M, so a paced downstream could mis-sample the
  last byte. The frame now closes out at the next `pace_tick`, giving the last
  byte its full `period`. Regression `test_gmii_cdc.paced_last_byte_hold_100m`.
- `gmii_cdc` RX multi-frame byte-drop: the sys-side readout returned to idle at
  each frame's EOF and re-ran its "align" pre-consume on the next frame - correct
  on a cold start out of empty, but on a frame boundary (next frame already
  buffered, first-word-fall-through FIFO) it consumed and dropped that frame's
  first byte. Every frame after the first lost byte 0. The readout now stays in
  its reading state across the EOF marker so the following frame's first byte is
  taken by the normal data path. Regression `test_gmii_cdc.rx_directed`.
- `gmii_cdc` RX committed-frame-counter wrap (same class as the TX/`mii_tx_saf`
  fixes): a 4-bit `rx_frames_pending` counter aliased once 16 frames buffered, so
  under a slow sys drain small frames piled up past 16 long before the 4K RX FIFO
  filled - `rx_frame_ready` read false and the readout stalled. Widened to
  `ADDR_WIDTH+1` (13) bits. Regression `test_gmii_cdc.rx_burst_wrap_probe`.
- `gmii_cdc` paced-TX phantom-frame stall: in 100M/10M the read pointer was left
  parked on a frame's EOF word (its per-byte prefetch is suppressed on EOF), so
  the next paced frame emitted that stale EOF byte, ended after one cycle, and
  orphaned the real frame in the FIFO - dropping every frame after the first.
  The frame close-out now advances the read pointer past the EOF word in the
  paced modes only (1G's every-cycle prefetch already realigns it). Regression
  `test_gmii_cdc.directed_100m` / `directed_10m`.
- `gmii_cdc` paced-TX committed-counter wrap (same class as the `mii_tx_saf` fix
  below): a 4-bit committed-frame counter aliased once 16 whole frames backed up
  in the 16 KB TX FIFO, deasserting the store-and-forward start gate and wedging
  the media side long before the FIFO filled. Widened the counter and its gray
  CDC to `ADDR_WIDTH+1` (15) bits so the byte FIFO fills first. Regression
  `test_gmii_cdc.burst_small_frames_100m` (20 small frames).
- `mii_tx_saf` TX deadlock (committed-frame counter wrap): a 4-bit committed
  frame counter aliased to a false "equal" once 16 frames backed up in the 4 KB
  FIFO, parking the framer in idle. Widened the counter to `FIFO_ADDR_WIDTH+1`
  bits. Regression `tb_mii_tx_saf_burst_stall`.
- `mii_tx_saf` permanent TX wedge on oversized / uncommitted frames: the write
  side committed only on `tlast` with no bound on the uncommitted run, so a
  no-`tlast` run reaching the FIFO depth (an oversized frame, or frames merged
  by a dropped `tlast` upstream) filled the FIFO with uncommitted data - the
  framer never started and the whole TX path deadlocked (reproduced on Arty A7
  under a 64-byte UDP echo flood). Capped the in-flight run at `MAX_FRAME` (force
  a synthetic EOF, drop the runaway tail); since `MAX_FRAME` < FIFO depth a
  permanent wedge is now structurally impossible. Regression
  `tb_mii_tx_saf_oversize`; re-validated on hardware at 300-400 Mbps, `<1%` loss.
- Removed a dead `crc32` instance from `eth_mac_tx` (the TX FCS is computed by
  the local `crc_step_byte`/`crc_accum` lookahead; the instance and its driver
  registers were unused).
- `ddr_output` non-Xilinx fallback no longer drives one register from both clock
  edges (a multiply-driven, non-synthesizable pattern); it uses two single-edge
  registers muxed by the clock.
- `rgmii_if` synchronizes the system reset into the `rgmii_rxc` domain (async
  assert, 2-FF deassert) instead of using `rst_n` directly, removing a
  metastable reset-release path on the RX nibble-pairing state.

## v0.1.0 - 2026-06-10

Initial tagged integration baseline for the open-source Verilog Ethernet MAC.

### Security

- Added CRA-oriented security readiness documentation covering intended use,
  trust boundaries, security assumptions, residual risks, evidence expectations,
  and release traceability.
- Added private vulnerability reporting guidance, acknowledgement targets, and
  coordinated-disclosure expectations.
- Documented production hardening guidance for promiscuous mode, jumbo mode,
  checksum offload, debug capture, AXI4-Stream error handling, and regression
  evidence.

### Fixed

- Ran Verilator lint through WSL when launched from git-bash on Windows, so
  PHASE 0b can use either native Verilator or an auto-detected WSL install.
- Declared RTL signals ahead of first use to clear synthesis warnings.
- Made the Arty hardware smoke-test ARP check non-fatal when ICMP passes.
- Fixed jumbo testbench AXI4-Stream handshake coverage.
- Fixed MII TX FIFO count width handling.
- Collapsed MII length FIFOs and trimmed TX FIFO XPM features.
- Fixed MII RX replay buffering and per-run simulation output handling.

### Evidence

- Release tag: `v0.1.0`
- Commit: `0518aeb5eacd4d6050e3c04b501574fcbfe7192a`
- Regression entry point: `python build_and_test.py`
- Hardware evidence: Arty A7 build/test flow and checked logs where applicable.
