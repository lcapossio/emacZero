# Changelog

All notable changes to emacZero are recorded here for downstream integrators.
This project does not yet maintain long-lived release branches.

## Unreleased

### Added

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
