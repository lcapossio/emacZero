# Changelog

All notable changes to emacZero are recorded here for downstream integrators.
This project does not yet maintain long-lived release branches.

## Unreleased

### Added

- `STATUS[3]` (`mdio_cmd_dropped`): an MDIO `GO` written while the MDIO master
  is busy no longer fails silently — it sets this sticky bit (cleared by the
  next successfully-issued `GO`) so software can detect the dropped command.
- `async_fifo` exposes an exact write-side `wr_data_count` (`wr_ptr` minus the
  synchronized read Gray pointer); leave it unconnected when not needed.

### Changed

- `gmii_cdc` TX fill level / `tx_busy` now use `async_fifo.wr_data_count`
  instead of a per-byte read toggle synchronizer, which could drop counts when
  `media_clk` (125 MHz) outran `sys_clk` (100 MHz) at 1G.

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
