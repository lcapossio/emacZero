# Changelog

All notable changes to emacZero are recorded here for downstream integrators.
This project does not yet maintain long-lived release branches.

## Unreleased

### Added

- `ddr_input` / `ddr_output`: an `XILINX_ULTRASCALE_PLUS` branch using
  `IDDRE1` / `ODDRE1`. Without a vendor define both modules are empty, and
  a Vivado block-design build keeps the GMII `gmii_txc` forwarder as a
  black box that fails opt_design DRC even when the pin is unused. The
  ZCU106 build now defines it; there the unused forwarder is removed by
  opt_design and the routed result is unchanged. `IDDRE1`, used only by RGMII,
  has been checked only by placing the bare wrapper on a ZCU106 part; RGMII on
  UltraScale+ is untested.
- `fpga/zcu106/`: AMD ZCU106 board port over SFP cage 0 (1000BASE-X). It uses
  `PHY_INTERFACE="GMII"` behind the AMD 1G/2.5G Ethernet PCS/PMA IP on a GTH,
  with the MAC and the ARP/ICMP/UDP-echo demo on the 125 MHz transceiver
  clock. The GTH reference clock defaults to the USER_MGT_SI570 (156.25 MHz,
  no setup); `-tclargs si5328` instead programs the Si5328 to 125 MHz over I2C
  with `i2c_init` (simulated by `ZCU106-I2C-INIT`). `-tclargs lb` adds an
  SFP0 <-> SFP1 fiber loopback test: a second PCS/PMA on SFP1 and
  `sfp_lb_tester`, which ARPs, pings and UDP-echoes the demo and checks every
  reply, read over JTAG with the fcapz EIO (`scripts/sfp_lb_test.py`,
  simulated by `ZCU106-SFP-LB`). The tester also sends frames the demo
  must ignore and short payloads, and the EIO can switch the lasers off,
  reset the SFP1 core and turn auto-negotiation off or restart it; the
  script runs these as a test suite over one hw_server session. Tested on
  a ZCU106 with both reference clocks and 10GBASE-SR modules: 10-minute
  soaks of about 32 million requests each, all correct; links recover from
  resets and AN changes. The bugs these tests found are fixed below.
- `fcapz` submodule updated to the current fpgacapZero main.
- **ZCU106 throughput test.** `zcu106_eth_demo` has the Arty demo's iperf2
  UDP sink (UDP/5001), its stats (UDP/9996) and the line-rate UDP blast
  (trigger on UDP/9997). The blast is the lowest-priority transmit source,
  so the Arty's idle service window is off here. New
  `fpga/zcu106/scripts/sfp_perf_test.py` runs it from a host in Python and
  reads the NIC's counters; new `ZCU106-PERF` simulates it. Through a
  1000BASE-T copper SFP to a PC: a 10-minute full-duplex run, 48.8 million
  1472-byte datagrams each way, FPGA -> host at 957.1 Mb/s (100.00% of line
  rate) and host -> FPGA at the host's 954.9 Mb/s, with no frame lost and no
  FCS error (bit error rate < 2.5e-12).
- **ZCU106 board counters.** `zcu106_eth_demo` brings the MAC's AXI4-Lite
  CSR port out (it was tied off) and counts the blast frames it generates.
  `zcu106_top` connects the CSRs to an fcapz JTAG-to-AXI bridge in both
  builds, and the throughput build adds an fcapz EIO with PCS/PMA event
  counters (link down, sync loss, RUDI(INVALID), disparity and not-in-table
  errors, GMII `rx_er`). New `fpga/zcu106/scripts/sfp_counters.py` reads and
  clears them, to tell a frame lost in the FPGA from one lost on the link.
  `ZCU106-PERF` checks the MAC's TX frame count against every frame on GMII.
- `udp_blast_trigger` takes an optional UDP payload size in trigger bytes
  9..10 (`payload_size` output, `DEFAULT_PAYLOAD` parameter). Shorter
  triggers behave as before.
- **Arty GMII fabric-loopback self-test** (`fpga/arty_a7/rtl/gmii_lb_selftest.v`,
  built with `fpga/arty_a7/scripts/build_arty_gmii_lb.tcl`). A second
  `eth_mac_sys` in GMII mode (`MAX_FRAME=9018`, 125 MHz from an MMCM) has its
  GMII TX looped to its RX inside the fabric. A generator sends sequence-numbered
  frames of 46-9000 byte payloads and a checker verifies every byte, the
  sequence and `tuser`; results are read over the debug EIO by
  `fpga/arty_a7/scripts/gmii_lb_selftest.py`. This exercises the 125 MHz
  `gmii_cdc` paths and jumbo frames on silicon without a gigabit PHY (the Arty
  has only a 10/100 MII PHY). On an Arty A7-100T it returned 1,772,990 of
  1,772,990 frames exact in 60 s, 664,870 of them above 4083 bytes and the
  largest 9018 bytes with FCS. `GMII-LB-SELFTEST` simulates it, including an
  injected RX corruption that the checker must flag.
- **Selectable async FIFO storage.** `async_fifo` takes `RAM_STYLE`:
  `"DISTRIBUTED"` (the previous combinational-read design, LUTRAM; still the
  default, so the MII FIFOs are unchanged) or `"BLOCK"` (registered read into
  a one-word first-word-fall-through output stage, block RAM). The interface is
  identical; in `"BLOCK"` mode `rd_empty` clears one read clock later, and the
  loaded output word adds one to capacity (DEPTH+1). `gmii_cdc` gains
  `FIFO_RAM_STYLE` and `eth_mac_sys` gains `CDC_RAM_STYLE`, both defaulting to
  `"BLOCK"`. New `ASYNC-FIFO-BLOCK` and `GMII-CDC-RX-OVERFLOW-DIST` runs cover
  the non-default style of each.
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
    `rgmii_txc`. Uses only the existing `clk_125` input; `clk_125_90`,
    `clk_25` and `clk_2_5` are unused on this branch.
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
  - The `"MII"` and `"RGMII"` branches keep their hierarchical instance
    names (`gen_mii.*`, `gen_rgmii.*`), which existing testbenches and debug
    probes reference by path.
- `sim/tb/tb_gmii_loopback.v` (`GMII-LOOPBACK`, 26 checks). Closes the loop at
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

- **Breaking: gigabit builds need `clk` >= 125 MHz.** `eth_mac_sys` gains
  `CLK_FREQ_HZ` (default 100 MHz) and exposes `RGMII_SPEEDS` (default `"ALL"`).
  A build that can run at 1G - `PHY_INTERFACE="GMII"`, or `"RGMII"` with
  `RGMII_SPEEDS` other than `"10_100"` - now fails elaboration when
  `CLK_FREQ_HZ` is below 125 MHz, with an unknown-module error naming
  `EMACZERO_CONFIG_ERROR_1G_needs_CLK_FREQ_HZ_at_least_125MHz_or_RGMII_SPEEDS_10_100`.
  The RX CDC reader moves one byte per `clk` cycle plus a few cycles per
  frame; at 100 MHz it falls behind a 125 MB/s wire, and back-to-back traffic
  overflowed the RX CDC FIFO and truncated frames. MII and RGMII 10/100-only
  builds are unaffected. New `GMII-RX-LINE-RATE` drives sustained
  minimum-IFG frames (minimum, MTU and 9018-byte) from a PHY clock 100 ppm
  fast into a `clk` 100 ppm slow of 125 MHz and requires every frame
  byte-exact; run with `clk` at 100 MHz it loses frames. The pause-quanta
  timer (`eth_pause` `TICK_DIV_*`, now 16-bit) and the MDC divider
  (`mdio_master` `CLK_FREQ_HZ`) are derived from `CLK_FREQ_HZ` instead of
  assuming 100 MHz, rounded up exactly for any frequency; at 100 MHz they are
  unchanged. The LiteX wrapper (`clk_freq`, `rgmii_speeds`) passes both
  parameters and raises `ValueError` on a 1G-capable build below 125 MHz. The
  FuseSoC core's `default` and `with_l3` targets now list their parameters
  (`PHY_INTERFACE`, `RGMII_SPEEDS`, `CLK_FREQ_HZ`, `MAX_FRAME`,
  `MCAST_HASH_FILTER`); before, none of the declared parameters could be set
  through FuseSoC. The Arty
  GMII loopback self-test now runs its MAC on the 125 MHz clock.
- Reset and toggle synchronizer flops in `gmii_cdc`, `rgmii_if`, `mii_if` and
  `mii_tx_saf` carry `ASYNC_REG = "TRUE"`, so Vivado places each pair together
  and reports MTBF on them.
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

- **1G transmit ran at 14-byte inter-frame gaps, not 12.** `eth_mac_tx` held
  TX_EN low for its 12 `S_IFG` cycles and then two more in `S_IDLE` (one to
  raise `s_axis_tready`, one for the handshake), so back-to-back frames left
  every 1G path at most 99.87% of line rate with 1518-byte frames and 97.6%
  with 64-byte frames. `S_IFG` now counts those two cycles, for exactly 12.
  At GMII / RGMII, `gmii_cdc` still sets the gap on the wire (exactly 12
  byte times); the MII paths never took their gap from this count. Found by
  `ZCU106-PERF`.
- **`icmp_echo` corrupted or dropped pings over 248 bytes of data.** It
  buffered 256 bytes of ICMP and counted the length in 9 bits: a ping with
  249..503 bytes of data was answered with every byte from 248 on wrong and a
  bad checksum, and one of 504 bytes or more (512+ bytes of ICMP) got no
  reply. An ICMP message arriving while a reply was going out also overwrote
  the buffer and the length mid-reply. The buffer is now `MAX_LEN` bytes
  (parameter, default 1480: a full 1500-byte IPv4 packet). A request that is
  longer, or that starts arriving before the previous reply has gone out, is
  dropped whole and leaves the buffer alone. Found pinging the ZCU106 demo
  from a PC through a 1000BASE-T SFP. New `ICMP-ECHO-SIZES` checks
  8..1480-byte requests byte for byte, oversize and jumbo requests, and
  traffic during a stalled reply; `sfp_lb_tester` now pings with 18..1472
  bytes of data. The buffer is now distributed RAM (240 LUTs on the ZCU106)
  rather than flip-flops, so the ZCU106 demo uses fewer LUTs and registers
  than before.
- `fpga/zcu106/scripts/build_zcu106.tcl` failed when rerun into an existing
  build directory (`synth_ip` would not overwrite the PCS/PMA checkpoint, and
  with `-force` it kept the old netlist). It now deletes its PCS/PMA IP
  folders first.
- `net_rx` passed ICMP / UDP payload up to the end of the Ethernet frame,
  so the echo blocks sent the padding of a short request back as payload. It
  now stops at the IPv4 total length.
- `net_rx` checks the IPv4 header (version 4, IHL >= 5, header checksum,
  total length) and drops a bad one, and checks the ICMP checksum. New
  outputs `icmp_err` / `udp_err`, valid with `icmp_last` / `udp_last`, flag
  a bad ICMP checksum, a frame with `terror` (bad FCS or `rx_er`, which were
  answered before) and a frame shorter than its IPv4 total length. A frame
  that ends on its last IPv4 header byte does not affect the next frame.
  `icmp_echo`, `udp_echo`, `udp_iperf_sink`, `udp_blast_trigger` and
  `udp_stats_reply` take the matching `*_rx_err` input and drop the message.
  Integrators instantiating these blocks must connect the new ports.
- `eth_mac_tx` padded a 59-byte frame to 61 bytes instead of 60 (the FCS was
  valid, the frame one byte long). New `ETH-MAC-TX-PAD` checks 14- to
  61-byte frames through both TX framers for wire length, zero pad and FCS;
  `mii_tx_saf` was not affected.
- `udp_echo` never asserted `tlast` on the reply to a 1-byte datagram, which
  hung the transmit path.
- **1G inter-frame gap was 10 byte times, not 12.** `gmii_cdc` waited 8
  media cycles before a queued frame, and with the cycle that closes the
  previous frame and the one that loads the next, TX_EN was low for only 10
  cycles - 80 bit times against the 96 IEEE 802.3 requires. The code assumed
  the MAC framer's own IFG spaced frames at 1G, but the store-and-forward TX
  FIFO absorbs it; any frame already queued when the previous one ended went
  out 10 byte times later. The 1G start delay is now 10 cycles, for exactly
  12 byte times on the wire. Affects GMII and RGMII at 1G; 100M/10M already
  had 12.2 byte times. `GMII-LOOPBACK` now queues frames back to back and
  requires a gap of at least 12 GTX_CLK cycles at the pins.
- **RGMII at 10/100 Mbps now works end to end.** Three defects, none reachable
  at 1G and none covered by a pin-level test before:
  - RX split every byte into its own frame. `rgmii_if` pairs two RXC cycles
    into a byte and pulsed `gmii_rx_dv` once per byte; `gmii_cdc` read each
    dv-low cycle as end of frame. `rgmii_if` now holds `gmii_rx_dv` for the
    whole frame and adds a `gmii_rx_ce` byte strobe, and `gmii_cdc` gains a
    matching `gmii_rx_ce_in` (tied high on the GMII path and at 1G). Code
    that instantiates `gmii_cdc` directly must tie `gmii_rx_ce_in` high;
    left unconnected, RX writes nothing.
  - TX never sent the high nibble. At 10/100 `rgmii_if` drove `TXD[3:0]` in
    both TXC cycles of each paced byte. It now sends `TXD[3:0]` then
    `TXD[7:4]`, with the nibble and TX_CTL registered in the TXC domain.
    `clk_25` / `clk_2_5` must share a source with `clk_125` (as from one MMCM).
  - Back-to-back TX frames merged. `gmii_cdc` idled TX_EN for a fixed 8
    media cycles (64 ns) between frames, shorter than one 10M TXC period. The
    gap is now 12 byte times when paced (960 ns at 100M, 9.6 us at 10M).
  New `RGMII-100M-LOOPBACK` and `RGMII-10M-LOOPBACK` loop `eth_mac_sys` at the
  RGMII pins and check min/MTU/back-to-back (and 9018-byte jumbo at 100M)
  frames byte-exact plus the wire IFG; each of the three defects, reinstated
  alone, fails them. `RGMII-IF-100M` now checks exact bytes instead of "some
  bytes arrived".
- **GMII/RGMII builds with jumbo `MAX_FRAME` did not fit in LUTs or close
  timing.** `async_fifo` read its memory combinationally, so Vivado built the
  16K-word `gmii_cdc` CDC FIFOs from LUTRAM: about 7,200 LUTs for the pair,
  and write-decode paths that failed 100 MHz on the TX FIFO (a pre-existing
  16K FIFO) and 125 MHz on the RX FIFO. Found by the first synthesized GMII
  build, a fabric-loopback self-test on the Arty. `gmii_cdc` now uses
  `RAM_STYLE="BLOCK"` storage (see Added).
- **`gmii_cdc` RX overflow check was on the FIFO write-enable path.** The
  "keep a slot for the EOF" test (Gray-to-binary conversion, subtract,
  compare) fed the RX FIFO write enable combinationally and failed 125 MHz
  timing. It is now registered; to cover the one write it can miss, data is
  refused at DEPTH-2 words instead of DEPTH-1.
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
  carries a truncation flag. The reader raises `rx_er` on the last kept byte of
  a truncated frame, so the MAC delivers it with `m_axis_terror` and counts it
  in `RX_ERR_ALIGN` instead of relying on a CRC miss. No extra byte is added,
  so `RX_BYTE_CNT` and the frame-size statistics see only bytes that arrived. A frame that finds the FIFO
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
