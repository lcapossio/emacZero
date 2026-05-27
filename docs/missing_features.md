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
- [x] Jumbo-frame gate up to `MAX_FRAME`
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

- [x] MII 10/100 path
- [x] MII store-and-forward CDC uses EOF-sideband frame markers without
      separate MII length FIFOs
- [x] RGMII 10/100/1G path with runtime speed selection
- [x] RGMII build-time speed trimming through `RGMII_SPEEDS`
- [x] MDIO clause-22
- [x] MDIO clause-45 through `MDIO_CMD[12]` and `MDIO_CMD[14:13]`
- [ ] Pure GMII top-level path
- [ ] SGMII
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
- [x] 37 directed simulation tests
- [x] Verilator lint in `build_and_test.py` and CI for `rtl/eth_mac_sys.f`
      with style waivers
- [x] Arty A7 UDP throughput tests
- [x] Recent 100 Mbps MII measurements:
      95.14 Mbps FPGA-to-host UDP payload with 0 loss;
      94.2 Mbit/s host-to-FPGA iperf2 traffic with FPGA-side counters;
      95.15/95.71 Mbps simultaneous bidirectional payload over 60 s after
      the MII EOF-sideband FIFO cleanup
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

## Suggested Next Four

1. ARP cache + outbound resolve - required for general TX beyond broadcast.
2. Cocotb harness - broadens packet-level verification.
3. VLAN tag insert/strip - common feature with modest RTL scope.
4. Auto PAUSE trigger - drive `eth_pause` from RX FIFO occupancy.
