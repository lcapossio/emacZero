# emacZero — Missing Features

A snapshot of what is **not yet implemented** in the IP, grouped by area.
Items marked _(parametric)_ are conditionally compiled and present only when
the corresponding parameter is set.

## MAC core

- **802.3x PAUSE / flow control** — implemented. RX-side parses PAUSE frames
  and gates `eth_mac_tx`; TX-side emits one PAUSE on demand via `PAUSE_CTRL`.
  No automatic high-water-mark trigger from RX FIFO occupancy yet.
- **MAC Control sublayer** (EtherType `0x8808`) — only PAUSE (opcode `0x0001`)
  is parsed. PFC (802.1Qbb, opcode `0x0101`) not implemented.
- **VLAN tag** (802.1Q) insert/strip — none. Tagged frames pass through opaque.
- **Unicast address table** beyond the single primary MAC — none. Filtering
  knobs are: primary MAC match, broadcast, promiscuous (`CTRL[2]`), passthrough
  (`CTRL[8]`, sniffer mode), and parametric 64-bit multicast hash.
- **Statistics breakdown** — implemented. Three error counters
  (`RX_ERR_ALIGN/OVERFLOW/OVERSIZE`), seven RX size buckets
  (64 / 65–127 / 128–255 / 256–511 / 512–1023 / 1024–1518 / jumbo), and
  RX bcast/mcast counters. **TX bcast/mcast** counters and **per-priority**
  histograms still missing.
- **TSN / 802.1Qbv / preemption** — out of scope.

## PHY / line-side

- **Pure GMII** path — only RGMII (with the IDDR/ODDR DDR helpers) is wired up.
- **SGMII** — not present.
- **RMII** — not present.
- **MDIO clause-45** — implemented. Both C22 (default) and C45 framing are
  selectable via `MDIO_CMD[12]` (`c45_en`); C45 OP encoded in `MDIO_CMD[14:13]`.

## Network layer (`rtl/net/`)

- **ARP request / cache** — `arp_responder.v` (FPGA top) only replies to
  requests; no outbound resolution.
- **IP fragmentation / reassembly** — none. Oversize datagrams are dropped.
- **UDP / TCP offload** — partial UDP demo support exists (`udp_echo`,
  `udp_blast`, `udp_iperf_sink`, `udp_stats_reply`). TX checksum insertion
  exists for IP/UDP via `tx_csum_off.v` when `TX_CSUM_OFFLOAD=1`; the
  default build removes it. No TCP state machines.
- **DHCP / IGMP** — none.
- **PTP / 1588** — no RX or TX timestamping path.

## Software

- **Linux netdev driver** — only the bare-metal C driver in `sw/emaczero/`.
  No DT binding, no `ethtool` ops, no NAPI poll.
- **Zephyr / FreeRTOS** glue — none.
- **lwIP** shim — none.

## Verification

- **Cocotb / UVM** — current regression is 36 directed Icarus tests.
- **Formal** properties on AXIS and FSM stalls — none (e.g. `assume`/`assert`
  for tvalid stability).
- **Verilator lint** — CI runs `verilator --lint-only -Wall` on
  `rtl/eth_mac_sys.f` with a small set of style-only waivers. The Arty demo
  top and optional L3 helpers are still covered by Icarus lint/simulation.
- **Throughput measurement** — Arty A7 UDP tests are present. Recent
  100 Mbps MII runs measured 95.14 Mbps FPGA-to-host UDP payload with 0 loss,
  94.2 Mbit/s host-to-FPGA iperf2 traffic with FPGA-side counters, and
  95.13/95.74 Mbps simultaneous bidirectional payload throughput over 60 s.

## Build / portability

- No bundled external **AXI-Stream store-forward** integration block. This is
  intentional for the standalone MAC: the MII path already has internal
  frame-aware CDC buffering. Add an upstream store-forward block in a parent
  SoC only when the packet producer can underrun mid-frame.
- Only **Vivado** has been exercised. **Yosys + nextpnr** (ECP5 / iCE40)
  not tried.
- No project templates for **Quartus**, **Gowin**, or **Efinix**.
- No **tagged release** / SemVer git tag yet.
- No standalone IP **resource report** sheet — only the Arty A7 top is
  characterised.

## Documentation

- No **register reference** auto-generated from `axilite_regs.v` (drift risk).
  → see `docs/registers.md` (manual).
- No **per-block** doc beyond `docs/architecture.svg`.
- No **integration walkthrough** beyond `examples/eth_mac_sys_minimal/`.

---

## Suggested next four (effort vs. value)

1. **ARP cache + outbound resolve** — required for any TX beyond broadcast.
2. **cocotb harness** — unblocks broader packet-level verification.
3. **VLAN tag insert/strip** — common feature, modest RTL.
4. **Auto PAUSE trigger** — wire RX FIFO occupancy to `eth_pause`'s
   `cfg_pause_tx_send` so back-pressure is generated without firmware help.
