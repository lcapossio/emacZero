# emacZero Feature Checklist

Snapshot of implemented, optional, and missing features. Checked items are
present in this repo. Unchecked items are not implemented yet. Items marked
`optional` require the named parameter, register bit, or integration choice.

## MAC Core

- [x] Basic full-duplex Ethernet MAC TX/RX
- [x] AXI4-Stream TX/RX datapaths
- [x] AXI4-Lite CSR block
- [x] Runtime TX/RX enable, promiscuous mode, and sniffer passthrough
- [x] Ethernet FCS generation on TX
- [x] Ethernet FCS validation on RX with `m_axis_terror`
- [x] RX error tagging for FCS, receive error, FIFO overflow, and oversize
- [x] Jumbo-frame TX gate up to `MAX_FRAME` (GMII and RGMII paths; the MII 10/100
      path is standard-MTU only — its TX FIFO and RX replay buffer are 4096
      bytes and cannot hold a jumbo frame, so jumbo TX requires GMII or RGMII).
      **Jumbo RX is capped at ~4083 bytes on BOTH the GMII and RGMII paths** by
      `gmii_cdc`'s fixed 4096-word RX CDC FIFO - measured, pre-existing, and
      tracked as a known bug
- [x] 802.3x PAUSE frame parse and TX gating
- [x] Firmware-triggered PAUSE frame transmit through `PAUSE_CTRL`
- [x] Single primary unicast MAC address filter
- [x] Broadcast accept path
- [x] 64-bit multicast hash filter (`MCAST_HASH_FILTER=1`)
- [x] RX statistics: frame/byte counters, error breakdown, size buckets,
      broadcast, and multicast
- [ ] Automatic PAUSE trigger from RX FIFO high-water mark
- [ ] MAC Control sublayer beyond PAUSE, such as PFC / 802.1Qbb
- [ ] VLAN tag insert/strip
- [ ] Multiple unicast address table
- [ ] TX broadcast/multicast counters
- [ ] Per-priority statistics histograms
- [ ] TSN / 802.1Qbv / frame preemption

## PHY / Line Side

- [x] MII 10/100 path (standard MTU only; jumbo TX requires GMII or RGMII)
- [x] MII and RGMII (`gmii_cdc`) store-and-forward CDCs use EOF-sideband frame
      markers with a committed-frame counter, without separate length FIFOs
- [x] RGMII 10/100/1G path with runtime speed selection
- [x] RGMII build-time speed trimming through `RGMII_SPEEDS`
- [x] MDIO clause-22
- [x] MDIO clause-45 through `MDIO_CMD[12]` and `MDIO_CMD[14:13]`
- [x] Pure GMII top-level path (`PHY_INTERFACE="GMII"`, `rtl/gmii_if.v`):
      1000 Mbps only, registered SDR I/O, GTX_CLK forwarded from `clk_125`
      inverted (180 deg), placing its rising edge mid data-window.
      GMII is gigabit-only by definition - a tri-speed PHY exposing GMII
      reverts to 4-bit MII at 10/100, which is the existing `"MII"` mode - so
      this path pins `gmii_cdc` pacing to 1G and ignores the `cfg_speed` speed
      field. Jumbo TX works here as on RGMII (RX shares the cap noted
      above). Chief use: feeding a vendor
      1G PCS/PMA core, which presents GMII rather than PHY pins
- [ ] SGMII (reachable by attaching a vendor 1G PCS/PMA core to the GMII path
      above; no native serdes implementation in this repo)
- [ ] RMII

## Network Layer (`rtl/net/`)

- [x] ARP responder for the FPGA demo top
- [x] ICMP echo responder
- [x] UDP echo helper
- [x] UDP blast / iperf-style demo helpers
- [x] UDP stats reply helper
- [x] TX IPv4 header checksum generation in demo packet generators
- [x] TX UDP checksum set to zero where IPv4 permits it
- [x] Optional AXIS TX checksum patcher (`TX_CSUM_OFFLOAD=1`)
- [ ] ARP request generation and ARP cache for outbound resolution
- [ ] IPv4 header checksum validation on RX
- [ ] UDP checksum validation on RX
- [ ] ICMP checksum validation on RX
- [ ] IP fragmentation / reassembly
- [ ] TCP state machines or TCP offload
- [ ] DHCP
- [ ] IGMP
- [ ] PTP / IEEE 1588 RX or TX timestamping

## Software

- [x] Bare-metal C driver in `sw/emaczero/`
- [x] LiteX wrapper in `litex_emaczero/`
- [ ] Linux netdev driver
- [ ] Devicetree binding
- [ ] `ethtool` operations
- [ ] NAPI poll path
- [ ] Zephyr glue
- [ ] FreeRTOS glue
- [ ] lwIP shim

## Verification

- [x] Directed Icarus regression (`python build_and_test.py --sim-only`)
- [x] 46 directed simulation tests
- [x] Verilator lint in `build_and_test.py` and CI for `rtl/eth_mac_sys.f`
      with style waivers
- [x] Vivado RTL elaboration gate in `build_and_test.py` (skipped where
      Vivado is unavailable) - catches elaboration-only errors that both
      linters accept
- [x] Arty A7 UDP throughput tests
- [x] Recent 100 Mbps MII measurements:
      95.68 Mbps FPGA-to-host UDP payload with 0 loss;
      94.2 Mbit/s host-to-FPGA iperf2 traffic with FPGA-side counters;
      95.68/95.78 Mbps simultaneous bidirectional payload over 60 s with 0 gaps
      in both directions, after the MII EOF-sideband FIFO cleanup, XPM FIFO
      advanced-feature trim, 13-bit TX FIFO count fix, and the AXIS `tlast`
      back-pressure fix in the L3 frame generators
- [ ] Cocotb packet-level harness
- [ ] UVM environment
- [ ] Formal AXIS/FSM stall properties
- [ ] Verilator lint coverage for every optional L3 helper and demo top

## Build / Portability

- [x] Vivado Arty A7-100T reference build
- [x] Routed Arty A7 resource/timing numbers in `README.md`
- [x] No bundled external AXI-Stream store-forward integration block by design
- [ ] Standalone IP-only resource report sheet
- [ ] Yosys + nextpnr build flow
- [ ] ECP5 / iCE40 validation
- [ ] Quartus project template
- [ ] Gowin project template
- [ ] Efinix project template
- [ ] Tagged release / SemVer git tag

## Documentation

- [x] README overview, register summary, tests, and resource snapshot
- [x] Manual register reference in `docs/registers.md`
- [x] Architecture diagrams
- [x] Minimal `eth_mac_sys` integration example
- [x] Arty A7 integration notes
- [x] Standalone boundary notes: no MIG/DDR and no required external
      AXI-Stream store-forward block
- [ ] Register reference auto-generated from `axilite_regs.v`
- [ ] Per-block documentation for every RTL module
- [ ] Full integration walkthrough beyond `examples/eth_mac_sys_minimal/`

---

## Known Issues

- **MII TX wedge under sustained small-frame load (`mii_tx_saf`) — fixed.** The
  framer gates frame start on a committed-frame counter (`frame_pending`), and
  only starts a frame once its `tlast` has been written (committed) so it can
  never underrun. Two deadlocks were found and fixed:
  - *Counter wrap:* a prior 4-bit committed-frame counter aliased to a false
    "equal" once 16 frames backed up in the 4 KB FIFO, parking the framer in
    idle. Fixed by widening the counter to `FIFO_ADDR_WIDTH+1` bits (regression
    `tb_mii_tx_saf_burst_stall`).
  - *Unbounded uncommitted data:* the write side wrote every accepted byte but
    only committed on `tlast`, with no bound on the uncommitted run. A contiguous
    run of bytes with no `tlast` that reached the FIFO depth — an oversized frame,
    or several frames merged by a dropped `tlast` upstream — filled the FIFO with
    uncommitted data: `frame_pending` never rose, the framer stayed in idle,
    `wr_full` stuck, and the **whole** TX path deadlocked permanently (captured on
    Arty A7 via the `SAF_DBG` CSR during a 64-byte UDP echo flood: committed ==
    drained, `rd_empty=0`, `tx_fifo_level > MAX_FRAME`, framer idle, `mii_tx_clk`
    still running; cleared only on reprogram). Fixed by an oversized-frame guard:
    the in-flight (uncommitted) run is capped at `MAX_FRAME`; on the `MAX_FRAME`-th
    byte with no real `tlast` the write side forces a synthetic EOF (commits a
    truncated frame) and drops the rest of the runaway frame until its real
    `tlast`. Because `MAX_FRAME` < FIFO depth the forced commit always finds room,
    so uncommitted data can never fill the FIFO and the framer can always make
    progress — a permanent wedge is structurally impossible. Well-formed frames
    (`<= MAX_FRAME`) are untouched. Deterministic regression
    `tb_mii_tx_saf_oversize` reproduces the wedge on the old RTL and passes on the
    fixed RTL. Re-validated on Arty A7: the 64-byte UDP echo flood that used to
    wedge the board at 300 Mbps (echo loss ~99%) now sustains 300-400 Mbps with
    <1% loss, `RX_ERR=0`, and `SAF_DBG` returning to clean idle (committed ==
    drained, `rd_empty=1`) after every burst.

---

## Suggested Next Four

1. ARP cache + outbound resolve - required for general TX beyond broadcast.
2. Cocotb harness - broadens packet-level verification.
3. VLAN tag insert/strip - common feature with modest RTL scope.
4. Auto PAUSE trigger - drive `eth_pause` from RX FIFO occupancy.
