# Changelog

All notable changes to emacZero are recorded here for downstream integrators.
This project does not yet maintain long-lived release branches.

## Unreleased

### Added

- Linux netdev driver (work in progress) in `sw/linux/`: an out-of-tree module
  for Linux 6.12 or later that moves frames through dmaengine channels (AMD AXI
  DMA), with threaded NAPI, a page pool for RX buffers, scatter-gather and TX
  checksum computed over the TX bounce copy, the MAC's RX checksum checker and,
  behind the private flag `mac-tx-csum`, its TX inserter when the core reports
  them in CAPS, BQL, phylink, the MAC counters as 64-bit totals in `ethtool -S`
  and a watchdog that rebuilds a stalled DMA datapath, plus a draft device tree
  binding (`bard0,emaczero`) and a ZCU106 device tree for the 1000BASE-X shell,
  and a host-side benchmark script (`sw/linux/scripts/linux_bench.py`) that
  checks iperf3 runs against the board's counters. TX and RX are tested on a
  ZCU106 against a PC.
- CAPS register at `0x98` (read-only): whether the core was built with the
  multicast hash filter, the TX checksum inserter and the RX checksum
  checker, and its `MAX_FRAME`. `CTRL[7]` and `CTRL[9]` read back as written
  in every build, so software could not tell. Older cores read 0 there.
  VERSION is unchanged. Added to the Verilog and the VHDL port, proven
  equivalent.
- VHDL-93 port of the MAC IP (`rtl/eth_mac_sys.f`) in `rtl/vhdl/`, with the
  filelist `rtl/eth_mac_sys_vhdl.f` and FuseSoC target `vhdl`. Vendor
  selection uses one target package per vendor in `rtl/vhdl/target/`. Every
  module is formally proven equivalent to the v0.2.0 Verilog with translateHDL
  (manifests in `sim/parity/`; see `docs/vhdl_port.md`). Generics whose Verilog
  default is computed from `MAX_FRAME` default to 0 in VHDL, which selects
  that same value. Not yet run on hardware.
- VHDL-93 ports of the L3 helpers (`rtl/eth_mac_sys_l3_vhdl.f`, FuseSoC
  fileset `rtl_vhdl_l3`; all but `net_rx`), `axil_arb2`, and the board
  modules `clk_gen`, `uart_tx`, `arp_responder`, `test_sequencer`,
  `gmii_lb_selftest` (Arty A7) and `i2c_init`, `sfp_lb_tester`, `zcu106_top`
  (ZCU106; `zcu106_top_lb.vhd` is the `ZCU106_SFP1_LB` build). Each is
  formally proven equivalent to its Verilog, the tops with their children
  replaced by stateful stand-ins. `net_rx`, `arty_tx_arbiter`, `arty_a7_top`
  and `zcu106_eth_demo` are not ported yet, so board builds stay mixed
  language. `udp_blast`'s delay generics are VHDL integers: pass a delay of
  2^31 cycles or more as its negative 32-bit equivalent.
- **Arty RGMII pad-loopback self-test** (`fpga/arty_a7/rtl/rgmii_lb_selftest.v`,
  built with `fpga/arty_a7/scripts/build_arty_rgmii_lb.tcl`). A second
  `eth_mac_sys` in RGMII mode (`MAX_FRAME=9018`) drives TXD[3:0], TX_CTL and
  TXC out of six Pmod JC pins and reads each pad back through its own IOBUF
  as RXD, RX_CTL and RXC, so `rgmii_if` runs on silicon with real ODDR/IDDR
  cells and I/O buffers. RXD and RX_CTL pass through an IDELAYE2 whose tap
  `fpga/arty_a7/scripts/rgmii_lb_selftest.py` sweeps at 1G before it runs the
  `gmii_lb_selftest` generator and checker at 1G, 100M and 10M. Nothing may be
  plugged into JC. On an Arty A7-100T taps 20-31 of 0-31 passed at 1G (19-31
  on earlier runs); at tap 26 every frame came back exact for 20 s at each
  speed (648,999 at 1G, 70,231 at 100M, 7,029 at 10M, the largest 9018 bytes
  with FCS). No JC pin is clock-capable, so RXC reaches its BUFG over general
  routing and post-route STA reports RX hold violations at the IDELAY_INIT
  tap; the sweep is the check. The taps load `IDELAY_INIT` after each reset
  (`VAR_LOAD` ignores `IDELAY_VALUE`): a build with `IDELAY_INIT=25` passed at
  1G with no tap set by the host, where the same build without that load
  passed no frame.
  At each speed the MAC also sends PAUSE frames to itself. Each comes back
  with the destination, type, opcode and quanta it was sent with (the source
  address is not checked), and the longest gap between frames the MAC
  accepts from the generator shows TX pausing for the quanta sent (0x2000
  quanta: 4196 us at 1G, 42.3 ms at 100M, 423 ms at 10M, each within two
  longest-frame times of 0x2000 x 512 bit times) and not pausing with
  `PAUSE_CTRL` rx_en clear. With a 0xFFFF pause held for 0.5 s and then
  quanta 0, the longest stall lies within bounds from host timestamps of the
  JTAG writes: from the first 0xFFFF frame to the quanta-0 frame, ending
  within two frame times (+1 ms) of it, with each refresh shown to land
  before the previous pause could run out, and short of where the pause
  would have run out had quanta 0 been ignored. It is a coarse check.
  `RGMII-LB-SELFTEST` simulates it at all three speeds, PAUSE at 1G and 100M,
  and an injected RX corruption. The VHDL port, `rgmii_lb_selftest.vhd`, is
  formally proven equivalent with `eth_mac_sys` and the Xilinx primitives
  replaced by stateful stand-ins (new: `sim/parity/stubs/xilinx_io_standin`
  for IOBUF, IDELAYE2 and IDELAYCTRL). L2 runs on a split-pad model that
  `sim/parity/rgmii_lb_selftest/gen_split.py` generates from the real files.
  `rgmii_lb_selftest.xdc` matches the cells as `u?bufg_rxc` / `u?mmcm`, so it
  applies to both (Vivado names the VHDL's generate cells `u.bufg_rxc`,
  `u.mmcm`). An Arty build with the VHDL self-test in place of the Verilog
  passed the same run: taps 20-31, every frame exact at all three speeds, and
  all PAUSE checks. Post-route WNS is about -0.2 ns on these builds, from 10
  `rgmii_if` flops in the 90-degree TXC domain released straight from reset
  (see Known issues).
- `build_and_test.py` analyses and elaborates the VHDL port with GHDL for each
  vendor target, and checks `emz_version_pkg.vhd` against `rtl/version.vh`.
  The phase is skipped when GHDL is not installed. It also analyses and
  elaborates the L3 and board VHDL, checks the generated parity models, and
  fails on a VHDL process whose sensitivity list misses a signal it reads,
  or, for a clocked process, its clock or asynchronous reset
  (`sim/parity/sens_check.py`).
- cocotb ports of all 44 core Verilog testbenches (`sim/cocotb/tests/`), with
  the same DUT, parameters, timing and checks. Every cocotb suite runs on both
  the Verilog (Icarus) and the VHDL port (GHDL): `sim/cocotb/run.py --hdl both
  -j N`, phases 2 and 2b of `build_and_test.py`. All 53 suites pass on both
  languages. Multi-instance benches use wiring harnesses in `sim/cocotb/hdl/`,
  each proven equivalent across the languages (`sim/parity/harness_*`). The
  `sim/tb/` benches are unchanged and still run.
- Each test module declares its suites in a `SUITES` dict that `run.py` reads;
  `run.py` runs suites in parallel (`-j`) and on both languages (`--hdl both`).
- `build_and_test.py` phase 1c reruns the core Verilog testbenches against
  the VHDL port in Vivado xsim (skipped without xsim on `PATH`). 43 of 44 pass;
  `RGMII-LOOPBACK` forces DUT internals and stays Verilog-only.
- CI installs GHDL 4.1, so the GHDL checks and the cocotb suites of the VHDL
  port run on every push and pull request. A new `parity` workflow runs every
  formal equivalence proof in `sim/parity/` in one job
  (`sim/parity/run_all.py`), with translateHDL and yowasp-yosys pinned. CI runs on Ubuntu 24.04 instead of
  `ubuntu-latest`.

### Changed

- The parity stand-ins for `eth_mac_sys`, MMCME2_BASE/BUFG and
  IDELAYE2/IDELAYCTRL (`sim/parity/sfp_lb_tester/eth_mac_sys_standin`,
  `sim/parity/stubs/xilinx_clk_standin`, `xilinx_io_standin`) also XOR into
  each register bit the AND of two bits no output shows. With the rotation
  alone, each output was the output below it one cycle earlier, XOR a
  constant (`m_axis_tlast` was `m_axis_tvalid` one cycle late), so nothing in
  the stand-in told a registered `tlast` taken from `tvalid` from the real
  one. (On `rgmii_lb_selftest` that mutant ended BOUNDED, a failure under
  `--strict`, with the old stand-ins too; the solver did not close it.) The
  `clk_gen`, `sfp_lb_tester`, `gmii_lb_selftest` and
  `rgmii_lb_selftest` proofs pass with them. This removes that one-cycle
  correlation; equivalence still holds only against deterministic
  stand-ins. The `zcu106_top` children
  stand-ins still use the rotation alone.
- `tb_gmii_cdc_rx_overflow.v` reads its FIFO-word probe through a wire, and
  `tb_eth_stats.v` can leave out its force-based saturation test
  (`TB_NO_HIER_FORCE`), so both also run against a VHDL DUT in xsim.
- `fcapz` submodule updated from 0.4.9 (1d65741) to fpgacapZero main
  (478d7c8, 0.5.0 plus fixes). It includes the fix for an ELA built with the
  default single-chain burst reading zeros on Zynq UltraScale+ MPSoC; the
  committed ZCU106 build has no ELA, but a local one now works. The cores the
  board builds use keep their existing ports and parameter defaults (0.5.0 adds
  an ELA `RLE_W` parameter, off by default). fcapz 0.5.0 host tools are
  recommended; 0.4.9 still reads these bitstreams.

### Known issues

- `rgmii_if`: its TXC-domain speed and TX-reset synchronizers (`spd_s1`,
  `spd_s2`, `spd_s3`, `spd_run`, `tx_rst_n_s1`, `tx_rst_n_s2`) take `rst_n`
  as an asynchronous reset with no release synchronizer. In a 1G build with
  TXC 90 degrees behind the system clock, the release has a 2 ns window and
  fails recovery timing (WNS -0.2 to -0.35 ns on the Arty RGMII self-test
  builds). It has not shown up on hardware.
- `udp_echo` (Verilog, and the VHDL port, which reproduces it): at `BUF_SIZE`
  1536 the received payload length wraps every 4096 bytes. A payload of
  exactly 4096 or 8192 bytes is accepted with length 0, and the echo then
  transmits until reset; payloads of 4097 to 5632 and 8193 to 8972 bytes get a
  truncated reply. Only a build that can receive such a frame is affected:
  the ZCU106 demo (MAX_FRAME 9018) once `jumbo_en` is set, not the Arty build
  (MAX_FRAME 1518).

### Fixed

- **Received PAUSE frames now hold TX within the 802.3 Annex 31B bound on
  every PHY.** A received PAUSE frame was recognized only after the RX CDC
  FIFO had delivered it, behind any frames received before it, and on GMII
  and RGMII it only stopped frames entering the TX CDC FIFO, so frames
  already in it (up to about 7 KB) still went out; this was the known limit
  listed under v0.2.0. Measured in simulation from RX_DV falling at the PHY
  pins to the TX gate, GMII 1G with a 125 MHz sys clock: 42 ns, for a lone
  PAUSE frame (was 714 ns) and for one right behind a 1514-byte frame (was
  12.26 us). On an Arty A7 (MII, 100M, PHY in MII loopback, 100 MHz sys
  clock) the gate closed 130 ns after RX_DV fell at the FPGA pins, with
  1518-byte frames queued at line rate. On a ZCU106 (1000BASE-X, GMII 1G,
  125 MHz sys clock, PCS/PMA transceiver in internal loopback) it closed
  48 ns after RX_DV fell at the MAC's GMII, also with 1518-byte frames
  queued at line rate. The changes, alike in Verilog and VHDL:
  - New `eth_pause_rx` recognizes PAUSE frames on the PHY receive stream in
    the receive clock domain, before the RX FIFO, and hands the quanta to
    `eth_pause` through a toggle synchronizer. `eth_pause` keeps the TX gate
    timer and the PAUSE generator; its receive inputs are replaced by
    `rx_pause_tgl` / `rx_pause_quanta`. `mii_if` gains `mii_rxd_q`,
    `mii_rx_dv_q`, `mii_rx_er_q` (its registered receive inputs). On MII,
    `eth_pause_rx` finds the SFD after an odd or an even number of preamble
    nibbles, and rejects a frame with `rx_er` on any nibble, including a
    trailing odd one.
  - On GMII and RGMII, `gmii_cdc` gains `tx_hold`: while it is high no data
    frame starts at the media side, and a data frame waiting in its start gap
    is put back. `eth_mac_sys` drives it from the TX gate. `eth_pause`'s
    `tx_paused` is now a flop, since it is synchronized into the TX clock
    domain.
  - PAUSE frames from `PAUSE_CTRL[0]` take their own path: a second
    `eth_mac_tx` (`MAX_FRAME` 60) and a control-frame FIFO in `gmii_cdc`
    (`gmii_ctl_*_in`, `tx_ctl_busy`), and a control-frame AXIS input and FIFO
    in `mii_tx_saf` (`ctl_axis_*`). Once a control frame is complete in its
    FIFO and has crossed to the media side, it starts ahead of queued data
    frames the media side has not yet committed to, also while TX is held. Behaviour change: a PAUSE frame
    requested while a user frame is still entering the TX FIFO can now go out
    before that frame, if it reaches the media side before that frame is
    committed; before, it always went out after. The PAUSE-priority mux in `eth_mac_sys`
    is gone.
  - The pause quantum prescaler restarts on each received PAUSE frame, so a
    frame holds TX for at least its quanta; it could end up to one quantum
    early.
  - `gmii_cdc`'s TX start limit left 12 bytes too little room for a
    `MAX_FRAME` frame with its preamble, SFD and FCS; with TX held the FIFO
    can now fill that far. It is now `16383 - max(MAX_FRAME, 9018) - 13`, and
    `MAX_FRAME` above 16370 is an elaboration error on GMII and RGMII (a held
    frame that long cannot fit; before, such a frame could overrun the FIFO
    at 10/100 even without PAUSE).
  - `eth_stats` takes a second set of TX events (`gmii_tx_en2`,
    `tx_frame_done2`), so TX_FRAME and TX_BYTE count both framers when they
    run in the same clock.
  New cocotb suites `eth_mac_sys_pause_rx_gmii`, `_mii`, `_rgmii100`,
  `_rgmii10`, `gmii_cdc_hold` and `gmii_cdc_hold_big`; `ETH-MAC-SYS-PAUSE`
  check 3b now expects the PAUSE frame first. New proof
  `sim/parity/eth_pause_rx`; `eth_pause`, `eth_stats`, `mii_if`, `gmii_cdc`,
  `mii_tx_saf`, `eth_mac_tx` (`MAX_FRAME` 60) and `eth_mac_sys` re-proven.
- `eth_mac_sys`: CTRL[0] (`tx_en`) gated `s_axis` combinationally, so
  clearing it while the source was part-way through a frame stalled that
  frame. With `TX_CSUM_OFFLOAD=0` on GMII / RGMII the cut-through framer
  then sent 0x00 bytes with `tx_er`, aborted the frame, and once TX was
  enabled again sent the rest of it as a frame of its own with a valid FCS.
  CTRL[0] now applies only between frames of `s_axis` (and not while a first
  beat is offered and not yet taken): a frame in progress is taken whole and
  sent, and no new frame starts while TX is disabled. The source must still
  not leave gaps inside a frame. Verilog and VHDL changed alike; the
  `eth_mac_sys` proof was rerun. New cocotb suites `eth_mac_sys_tx_en` and
  `eth_mac_sys_tx_en_csum` (`TX_CSUM_OFFLOAD` 0 and 1), on both languages.
- `eth_mac_sys`: CTRL[1] (`rx_en`) gated `m_axis` combinationally, so
  clearing it while a frame was part-way out cut that frame (the sink had a
  prefix with no TLAST and the rest was drained inside the core), and
  setting it mid-frame handed the sink a tail with no start. A sink that
  assembles frames until TLAST then merged the prefix and a later frame into
  one corrupted frame, with the FCS already stripped. The gate now changes
  only between frames of the MAC's RX stream, and never while `m_axis`
  offers a beat the sink has not taken: a frame in flight (or whose first
  beat is offered) when RX is disabled is delivered whole, and one in flight
  when RX is enabled is drained whole. Verilog and VHDL changed alike; the `eth_mac_sys` proofs
  were rerun. New cocotb suite `eth_mac_sys_rx_en`, on both languages.
- RX checksum offload (`RX_CSUM_OFFLOAD=1`, CTRL[9]) no longer fails an IPv6
  UDP datagram whose checksum is 0: it ended with `m_axis_terror` and counted
  in `RX_ERR_CSUM`, so it was dropped before software could apply its policy.
  RFC 6935/6936 let a receiver accept such datagrams per socket (Linux
  `udp6zerocsumrx`, e.g. VXLAN). A UDP checksum of 0 is now passed unjudged
  over IPv4 and IPv6 and left to software, which must not report it as
  verified. Wrong nonzero checksums still fail. Verilog and VHDL changed
  alike; `eth_mac_rx` and the proofs that contain it were re-proven.
  `ETH-MAC-SYS-CSUM-LOOP` adds IPv6 cases (checksum 0 passes, a wrong one is
  flagged), and the `eth_mac_rx_csum` cocotb suite checks both.
- `eth_mac_tx` (GMII and RGMII builds): when `tx_start_ok` fell on the cycle a
  frame's first byte was handshaken, the framer dropped that byte, though the
  source had seen it accepted, and once `tx_start_ok` rose sent the frame from
  its second byte with a valid FCS. In `eth_mac_sys` this happened when an
  inbound PAUSE frame (with `PAUSE_CTRL[1]` set) loaded the pause timer on
  that cycle. The framer now keeps the byte and starts the frame once
  `tx_start_ok` is high again. Same fix in the VHDL port. New cocotb suite
  `eth_mac_tx_start`.
- `docs/registers.md`: TX_FRAME was described as frames "accepted"; it counts
  frames once they have ended, PAUSE frames and (on GMII and RGMII) aborted
  frames included, at the wire on MII and at the framer's output, ahead of
  the TX CDC FIFO, on GMII and RGMII. TX_BYTE was described as payload and
  header bytes; it counts every byte with TX_EN at the same point, preamble,
  SFD, padding and FCS included. PAUSE_TX_CNT is now described too.
- `emaczero.core`: `rtl_core` did not list `rtl/mii_tx_saf.v`, so FuseSoC
  builds of the `default` and `with_l3` targets could not elaborate
  `eth_mac_sys` on its default MII path.

## v0.2.0 - 2026-10-16

First release published on GitHub (`v0.1.0` was tagged locally only). VERSION
reads `0x0002454D`. Breaking: 1G-capable builds need `CLK_FREQ_HZ` >= 125 MHz,
and direct instantiations of `eth_mac_rx`, `gmii_cdc` and the L3 helpers gain
ports (see Changed and Fixed).

### Security

These fixes change behaviour a peer on the link can trigger. All of them
affect `v0.1.0` and every earlier commit. No CVE or GitHub advisory has been
assigned; integrators on `v0.1.0` should update. Details are under Fixed.

- A received frame longer than 16383 bytes wrapped the `eth_mac_rx` byte
  counter, re-captured the destination MAC and injected a phantom start of
  frame that corrupted the following frame.
- With `MCAST_HASH_FILTER=1` the hash filter tested the wrong address bit, so
  unicast frames for other stations could be admitted when their hash bucket
  was set, and valid multicast frames could be rejected.
- A runt (under 64 bytes) was delivered as a clean frame instead of with
  `terror`.
- RX FIFO overflow in `eth_mac_rx` could drop a frame's first or last word,
  merging it into the next frame; RX CDC FIFO overflow in `gmii_cdc` (GMII and
  RGMII) could drop an EOF marker with the same result.
- The RX jumbo limit ignored `MAX_FRAME`, so a build with a smaller
  `MAX_FRAME` and `jumbo_en=1` accepted frames larger than its buffers were
  sized for; a limit above 16382 was never enforced at all.
- Optional L3 demo (`with_l3`): `net_rx` answered frames with a bad FCS or a
  malformed IPv4 header and echoed the 802.3 pad bytes of short requests back
  as payload; `icmp_echo` overwrote its reply buffer when pings arrived during
  a reply or were longer than 248 bytes of data.

### Added

- `RX_DROP` CSR (`0x7C`, RO/WC): frames that passed the MAC filter but were
  dropped whole because the RX FIFO had no room at their start, which
  happens while the AXIS sink holds `m_axis_tready` low (e.g. a DMA with no
  free buffer). These frames produced no AXIS words and no stat pulse, so
  until now they were in no frame counter (only RX_BYTE saw their bytes). `eth_mac_rx` gains a `stat_drop`
  output and `eth_stats` an `rx_drop_cnt` counter in the RX clear group.
  Once the RX FIFO has drained, `RX_FRAME + RX_DROP` accounts for every frame
  for this station. The
  VERSION value is unchanged; `0x7C` reads 0 on older cores, so software can
  add it to its totals unconditionally (`EMZ_REG_RX_DROP` in `emaczero.h`).

- **RX checksum offload** (`RX_CSUM_OFFLOAD=1`, CTRL[9] `rx_csum_off`).
  `eth_mac_rx` verifies the IPv4 header checksum and the TCP / UDP / ICMP
  (IPv4) or TCP / UDP / ICMPv6 (IPv6) checksum of each frame, pseudo-header
  included, with one optional 802.1Q / 802.1ad tag and any IPv4 header length.
  A frame that fails is still delivered, ends with `terror`, and counts in
  `RX_ERR` and in the new `RX_ERR_CSUM` CSR at `0x80` (RO, write-any-to-clear
  with the RX group; frames with another error, such as a bad FCS, are not
  counted there). The consumer must discard frames that end with `terror`;
  `eth_mac_sys` does not. The check runs on the GMII bytes as they arrive, so
  it adds no latency. UDP is summed over its Length field, not the IP
  payload. The IPv4 header checksum is checked even when the datagram is
  longer than the frame. Not checked (left to software): the L4 checksum of
  IPv4 fragments, of IPv4 with a source route option, of UDP whose Length is
  below 8 or beyond the IP payload, and of a datagram longer than its frame;
  IPv6 packets with extension headers; tunnels. A UDP checksum of 0 means
  "none" over IPv4 and is an error over IPv6. `0x80` reads 0 on older
  cores.
  `sw/emaczero/emaczero.h`: `EMZ_REG_RX_ERR_CSUM`, `EMZ_CTRL_RX_CSUM_OFF`.
  LiteX: `rx_csum_offload`.
- `rtl/net/csum_calc.v`: the checksum engine shared by the TX inserter and
  the RX checker. New cocotb suites `csum_calc`, `tx_csum_off` and
  `eth_mac_rx_csum` check it, the inserter and the RX path against a Python
  reference (`sim/cocotb/lib/csum.py`) on random IPv4 / IPv6 / VLAN /
  fragmented / padded frames with right and wrong checksums, source bubbles
  and sink backpressure; `ETH-MAC-SYS-CSUM-LOOP` checks both directions and
  the CSRs through MII loopback.
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
- `build_and_test.py`: `PHASE 1b` reruns the RGMII testbenches on Vivado's
  models of the DDR cells (`IDDR` / `ODDR`, and `IDDRE1` / `ODDRE1` where the
  wrappers have the UltraScale+ branch); skipped without Vivado. `--impl`
  implements `rgmii_if` alone on xc7a100t and xczu7ev for every
  `RGMII_SPEEDS` (`fpga/scripts/rgmii_impl_check.tcl`) and checks the DDR
  output cells, place and route, and internal timing.
- README: RGMII clock and delay requirements (`clk_125_90` related to
  `clk_125`, 1G TXC skew against PHY TX delay, RX delay expected from the PHY
  or board).

### Changed

- **TX checksum offload is now full** (`TX_CSUM_OFFLOAD=1`, CTRL[7]).
  `tx_csum_off` used to write only the IPv4 header checksum of a 20-byte
  header and zero the UDP checksum. It now computes and inserts the IPv4
  header checksum for any header length and the TCP / UDP / ICMP / ICMPv6
  checksum over IPv4 or IPv6, with one optional VLAN tag; a UDP checksum that
  computes to 0 is sent as 0xFFFF. Software that relied on the UDP checksum
  being zeroed now gets a real one.
  - UDP is summed over its own Length field, which may be shorter than the IP
    payload. The L4 checksum is left as software wrote it for IPv4 fragments,
    IPv4 with a source route option (whose pseudo-header needs the route's
    final destination), UDP whose Length is below 8 or beyond the IP payload,
    and IPv6 packets with extension headers.
  - The stage now stores frames in a circular buffer with a separate queue of
    per-frame checksums, so the next frame comes in while the previous one
    goes out: about 1 byte per clock, against half that before.
  - With `TX_CSUM_OFFLOAD=1`, `eth_mac_sys` sends every frame through the
    stage and CTRL[7] is sampled at each frame's first byte. Before, CTRL[7]
    switched the datapath between two paths, which could split a frame if it
    changed mid-frame.
  - A frame longer than `MAX_FRAME` is cut at `MAX_FRAME` and sent without
    checksums, and the rest is discarded up to its TLAST. Before, its bytes
    were dropped silently.
- `eth_mac_sys` / `eth_mac_rx` / `eth_stats` / `axilite_regs`: new
  `RX_CSUM_OFFLOAD` parameter, `rx_csum_en` input, `stat_err_csum` output,
  `rx_err_csum_cnt` counter and `cfg_rx_csum_off` (CTRL is 10 bits; its reset
  value is unchanged). Instantiations of `eth_mac_rx` must add `rx_csum_en`
  and `stat_err_csum`, and source lists need `rtl/net/csum_calc.v`.
- `eth_mac_sys` no longer uses `clk_25` / `clk_2_5`: the 10/100 RGMII TXC is
  now made from `clk_125`. The ports stay, so existing instantiations still
  elaborate; they can be tied off. `rgmii_if` drops them. `clk_125_90` is
  unused for `RGMII_SPEEDS="10_100"`.
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

- **802.3x PAUSE did not work.** Five faults in `eth_pause` and its TX mux,
  none covered by a test until now (`tb_eth_mac_sys_pause`):
  - Received PAUSE frames were never recognized, so `PAUSE_CTRL[1]` (`rx_en`)
    had no effect and `PAUSE_RX_CNT` stayed 0. The parser expected the
    destination MAC as the first byte, but the RX bus it watches carries the
    preamble and SFD. It now waits for the SFD, as `eth_mac_rx` does.
  - A received PAUSE frame now acts only if it is valid: good FCS, no
    `rx_er` after the SFD, and at least 64 bytes. A corrupted frame could
    otherwise stall transmission for up to 65535 quanta.
  - A PAUSE frame sent with `PAUSE_CTRL[0]` lost `tlast` on its last byte
    whenever the TX path was ready (the usual case), so the frame ran on into
    the next user frame instead of ending at 64 bytes.
  - A PAUSE frame requested while a user frame was part-way into the MAC was
    spliced into it: the TX mux switched to the PAUSE frame at once. Both
    frames were corrupted. The PAUSE frame now waits for the user frame's
    `tlast`.
  - Writing `PAUSE_RX_CNT` or `PAUSE_TX_CNT` did not clear the counters as
    documented: the clear strobe was not connected.

  `eth_pause` gains `gmii_rx_er` and `stat_clr` inputs. CSRs and the VERSION
  value are unchanged. Known limit, still open: on GMII and RGMII a received
  PAUSE frame stops new frames entering the TX CDC FIFO, but frames already
  in it (up to about 7 KB) still go out. On MII the hold-off acts at the wire.
- **`RX_FRAME` and `RX_ERR` overcounted under RX backpressure.** They counted
  every cycle with `m_axis_tvalid && m_axis_tlast`, without `m_axis_tready`,
  so a TLAST word held at the RX FIFO head by a stalled sink was counted once
  per stall cycle. They now count one per TLAST handshake. The stat-pulse
  counters (`RX_ERR_*`, `RX_BCAST`, `RX_MCAST`, `RX_SIZE_*`) were not
  affected.
- RX accepts a full-size VLAN-tagged frame. A frame with an 802.1Q (0x8100)
  or 802.1ad (0x88A8) tag may be 1522 bytes on the wire with `jumbo_en=0`;
  RX used to flag it oversize (`terror`, `RX_ERR_OVERSIZE`), so a VLAN trunk
  lost every max-MTU frame. Untagged frames keep the 1518 limit.
- RX's jumbo limit now follows `MAX_FRAME`. `eth_mac_sys` and `eth_mac` pass
  it to `eth_mac_rx`, which used to keep its own 9018-byte limit, so a build
  with a smaller `MAX_FRAME` and `jumbo_en=1` accepted frames longer than its
  buffers were sized for. Both limits count the FCS. `jumbo_en` now only
  raises the limit: with `MAX_FRAME=1518` and `jumbo_en=1` a tagged 1522-byte
  frame is still accepted. Default builds (`MAX_FRAME=9018`) behave as
  before. TX still counts `MAX_FRAME` in AXIS bytes, before the FCS, so it
  can send 4 bytes more than RX accepts; README states both.
- `eth_mac_rx` rejects a frame limit above 16382 at elaboration (an
  `EMACZERO_CONFIG_ERROR_...` module), so `MAX_FRAME` must be at most 16382.
  Its byte counter stops at 16383, so a larger limit could never be exceeded
  and oversize frames would have passed clean.
- **RGMII could not be implemented on Xilinx parts.** `rgmii_if` had one set
  of DDR output cells per speed and picked a set with a mux after the cells,
  so a LUT sat between each `ODDR` and its pad. Vivado rejects that
  (`REQP-1884 ODDR_has_invalid_load` on 7-series, `Place 30-1902` on
  UltraScale+) for every `RGMII_SPEEDS` value, as `"1G_ONLY"` still gated the
  outputs with `cfg_speed`. RGMII had only run in simulation. Each TX pin now
  has one DDR cell with the speed select in front of its inputs: TXD and
  TX_CTL on `clk_125`, TXC on `clk_125_90` (`clk_125` for `"10_100"`). At
  10/100 a `clk_125` phase counter drives the nibbles and a TXC pattern
  through the cells, with each TXC edge at least 8 ns from a data change
  (10 ns at 100M with the 90-degree clock); the old 10/100 TXC rose at the
  instant the data changed. The TX side synchronizes `cfg_speed` and takes a
  new speed only at the end of a TXC period, so a speed change no longer
  sends a runt TXC pulse (as short as 4 ns), and TXC stays low through reset
  instead of running at 125 MHz. `rgmii_if` now places and routes on
  xc7a100t, and on xczu7ev with the `XILINX_ULTRASCALE_PLUS` DDR wrappers, for
  all three `RGMII_SPEEDS`. RGMII is still untested on hardware.
- `rgmii_if` RX read `cfg_speed` directly in the `rgmii_rxc` domain, with no
  synchronizer, for the nibble pairing and the output select. It now takes a
  synchronized copy on `rgmii_rxc`.
- **The simulation `ddr_output` model sampled `d2` on the falling edge.** The
  7-series `ODDR` (`SAME_EDGE`) and the UltraScale+ `ODDRE1` sample both
  inputs on the rising edge, and the model now does too. The 10/100 RGMII
  testbenches clocked RX from the 25 / 2.5 MHz source instead of the
  forwarded TXC, which hid the edge-aligned 10/100 TXC. They now loop TXC
  back as RXC and check the TXC period, duty cycle and TXC-to-data distance.
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

### Evidence

- Release tag: `v0.2.0` (the tag names the commit).
- Regression: `python build_and_test.py` on a clean checkout of the tagged
  commit; the full log is attached to the GitHub release, and the `sim`
  workflow ran on the same commit.
- Hardware: the Arty A7 and ZCU106 results above were measured on development
  commits leading up to this release, not re-run on the tagged commit. RGMII
  has not been tested on hardware.

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
