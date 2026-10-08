# emacZero Register Reference

AXI4-Lite slave at the `s_axi_*` port of `eth_mac_sys`. All registers are
32 bits wide and word-aligned; byte addressing is supported via `WSTRB`.
Reads of unimplemented addresses return `0x00000000`; writes are silently
dropped.

- **Bus**: AXI4-Lite, single-cycle response, always `OKAY`.
- **Address width**: 8 bits (`ADDR_WIDTH=8`), giving 256 bytes of CSR space.
- **Endianness**: little-endian byte lanes per AXI4 convention.

## Map

| Offset | Name | Access | Reset | Description |
|-------:|------|:------:|------:|-------------|
| `0x00` | VERSION | RO | `0x0001454D` | Version and unique ID |
| `0x04` | CTRL | RW | `0x00000023` | Master control bits |
| `0x08` | STATUS | RO | - | Live status |
| `0x0C` | MAC_LO | RW | `0x00000001` | `our_mac[31:0]` |
| `0x10` | MAC_HI | RW | `0x00000200` | `our_mac[47:32]`, upper 16 bits read as 0 |
| `0x14` | MDIO_CMD | RW | `0x00000000` | Clause-22/45 MDIO command |
| `0x18` | MDIO_WDATA | RW | `0x00000000` | MDIO write payload |
| `0x1C` | MDIO_RDATA | RO | - | MDIO read payload |
| `0x20` | IRQ_EN | RW | `0x00000000` | Interrupt enable mask |
| `0x24` | IRQ_STATUS | W1C | `0x00000000` | Interrupt latched status |
| `0x28` | TX_FRAME | RO/WC | `0x00000000` | TX frame count |
| `0x2C` | TX_BYTE | RO/WC | `0x00000000` | TX byte count |
| `0x30` | RX_FRAME | RO/WC | `0x00000000` | RX frames delivered to the AXIS sink |
| `0x34` | RX_BYTE | RO/WC | `0x00000000` | RX byte count |
| `0x38` | RX_ERR | RO/WC | `0x00000000` | RX frames delivered with terror |
| `0x3C` | SCRATCH | RW | `0x00000000` | Scratch register |
| `0x40` | IP_ADDR | RW | `0xC0A889C8` | Demo L3 stack IPv4 (`cfg_ip_addr`, default 192.168.137.200) |
| `0x44` | MCAST_LO | RW* | `0x00000000` | `mcast_hash_table[31:0]` |
| `0x48` | MCAST_HI | RW* | `0x00000000` | `mcast_hash_table[63:32]` |
| `0x4C` | RX_ERR_ALIGN | RO/WC | `0x00000000` | RX frames with `rx_er` asserted |
| `0x50` | RX_ERR_OVERFLOW | RO/WC | `0x00000000` | RX frames truncated by FIFO overflow |
| `0x54` | RX_ERR_OVERSIZE | RO/WC | `0x00000000` | RX frames longer than current MAX |
| `0x58` | RX_BCAST | RO/WC | `0x00000000` | RX broadcast frames |
| `0x5C` | RX_MCAST | RO/WC | `0x00000000` | RX multicast frames |
| `0x60` | RX_SIZE_64 | RO/WC | `0x00000000` | RX frames exactly 64 wire bytes |
| `0x64` | RX_SIZE_65_127 | RO/WC | `0x00000000` | RX frames 65-127 bytes |
| `0x68` | RX_SIZE_128_255 | RO/WC | `0x00000000` | RX frames 128-255 bytes |
| `0x6C` | RX_SIZE_256_511 | RO/WC | `0x00000000` | RX frames 256-511 bytes |
| `0x70` | RX_SIZE_512_1023 | RO/WC | `0x00000000` | RX frames 512-1023 bytes |
| `0x74` | RX_SIZE_1024_1518 | RO/WC | `0x00000000` | RX frames 1024-1518 bytes |
| `0x78` | RX_SIZE_JUMBO | RO/WC | `0x00000000` | RX frames > 1518 bytes |
| `0x7C` | RX_DROP | RO/WC | `0x00000000` | RX frames dropped whole (no FIFO room at their start) |
| `0x84` | PAUSE_CTRL | RW | `0x00000000` | 802.3x PAUSE control |
| `0x88` | PAUSE_QUANTA | RW | `0x00000000` | Quanta payload of next emitted PAUSE frame |
| `0x8C` | PAUSE_RX_CNT | RO/WC | `0x00000000` | Received PAUSE frames |
| `0x90` | PAUSE_TX_CNT | RO/WC | `0x00000000` | Transmitted PAUSE frames |
| `0x94` | SAF_DBG | RO | `0x00000000` | `mii_tx_saf` framer/FIFO debug snapshot (MII path; `0` on RGMII) |

`*` Present only when `MCAST_HASH_FILTER == 1`. When disabled, both multicast
hash registers read 0 and writes are ignored.

## 0x00 - VERSION

Current value: `0x0001_454D`. The constants live in
[`rtl/version.vh`](../rtl/version.vh) and are mirrored in
[`sw/emaczero/emaczero.h`](../sw/emaczero/emaczero.h) and
[`emaczero.core`](../emaczero.core); `build_and_test.py` enforces consistency
across all three on every run.

| Bits | Meaning |
|-----:|---------|
| `[31:24]` | Major version, currently `0x00`. |
| `[23:16]` | Minor version, currently `0x01`. |
| `[15:0]` | Unique identifier, currently `0x454D` (ASCII `"EM"`). |

## 0x04 - CTRL

| Bits | Name | Reset | Description |
|-----:|------|:-----:|-------------|
| `[0]` | `tx_en` | `1` | TX path enable. |
| `[1]` | `rx_en` | `1` | RX path enable. |
| `[2]` | `promisc` | `0` | Accept frames regardless of dst-MAC. |
| `[4:3]` | `speed` | `00` | `00` = 1G, `01` = 100M, `10` = 10M. |
| `[5]` | `full_duplex` | `1` | Informational only; MAC is full-duplex by construction. |
| `[6]` | `jumbo_en` | `0` | Accept frames up to `MAX_FRAME` instead of 1518. |
| `[7]` | `tx_csum_off` | `0` | Runtime select for TX checksum offload when `TX_CSUM_OFFLOAD=1`; no datapath effect when that parameter is 0. |
| `[8]` | `passthrough` | `0` | Sniffer mode: bypass MAC filter and deliver errored frames tagged via `m_axis_terror`. |
| `[31:9]` | reserved | `0` | Reads as 0; writes ignored. |

Reset value `0x23` = `tx_en | rx_en | full_duplex`.

## 0x08 - STATUS

| Bits | Name | Description |
|-----:|------|-------------|
| `[0]` | `tx_active` | TX FSM is currently transmitting a frame. |
| `[1]` | `tx_fifo_busy` | TX FIFO has buffered data not yet drained. |
| `[2]` | `mdio_busy` | MDIO controller has a transaction in flight. |
| `[31:3]` | reserved | Reads as 0. |

## 0x0C / 0x10 - MAC_LO / MAC_HI

Primary unicast MAC address used for filtering in non-promiscuous mode.

- `MAC_LO[31:0]` = bytes `[3:0]` of the MAC.
- `MAC_HI[15:0]` = bytes `[5:4]` of the MAC; `MAC_HI[31:16]` reads 0.
- Reset = `02:00:00:00:00:01`.

## 0x14 - MDIO_CMD

Writing with `go = 1` and `mdio_busy = 0` launches a transaction; `go` always
reads as `0`.

| Bits | Name | Description |
|-----:|------|-------------|
| `[4:0]` | `reg` | C22 register address, or C45 DEVAD. |
| `[9:5]` | `phy` | PHY port address, 0-31. |
| `[10]` | `write` | C22 only: `1` = write, `0` = read. |
| `[11]` | `go` | Set to start; reads back as `0`. |
| `[12]` | `c45_en` | `0` = clause-22, `1` = clause-45. |
| `[14:13]` | `c45_op` | C45: `00` ADDR, `01` WRITE, `10` READ-INC, `11` READ. |
| `[31:15]` | reserved | Writes ignored. |

## 0x18 / 0x1C - MDIO_WDATA / MDIO_RDATA

Both are 16-bit values in bits `[15:0]`; upper bits read as 0.

## 0x20 / 0x24 - IRQ_EN / IRQ_STATUS

| Bit | Source | Trigger |
|----:|--------|---------|
| `[0]` | `tx_done` | TX FSM finished a frame. |
| `[1]` | `rx_frame` | A complete RX frame was accepted. |
| `[2]` | `mdio_done` | MDIO transaction finished. |

`IRQ_EN` is a RW mask. `IRQ_STATUS` is W1C. Top-level `irq` is
`|(IRQ_STATUS & IRQ_EN)`.

## 0x28 / 0x2C / 0x30 / 0x34 / 0x38 / 0x50 / 0x7C - Statistics

| Offset | Name | Counts |
|-------:|------|--------|
| `0x28` | TX_FRAME | Frames accepted by TX. |
| `0x2C` | TX_BYTE | Payload + header bytes transmitted. |
| `0x30` | RX_FRAME | Frames delivered to the AXIS sink: one per TLAST handshake (`tvalid && tready`), errored frames included. |
| `0x34` | RX_BYTE | Bytes with `rx_dv` on the MAC's GMII input, whether or not the frame is delivered. |
| `0x38` | RX_ERR | Frames delivered with `m_axis_terror` (FCS, `rx_er`, overflow, oversize, runt). |
| `0x50` | RX_ERR_OVERFLOW | Frames that started with RX FIFO room and ran out mid-frame: truncated and delivered with terror, so also in RX_FRAME and RX_ERR. |
| `0x7C` | RX_DROP | Frames that passed the MAC filter but found no RX FIFO room at their start, because the sink held `m_axis_tready` low. Dropped whole: no AXIS words, so they are in no other RX counter. Counted whatever their FCS or length. |

Every frame that passes the MAC filter ends up in exactly one of RX_FRAME or
RX_DROP, so `RX_FRAME + RX_DROP` is the number of frames for this station, and
`RX_DROP + RX_ERR` is the number not delivered clean. Frames for other
addresses and fragments shorter than 6 bytes are in neither.

RX_DROP was added after the original map. On a core without it, `0x7C` reads
0 (unmapped offsets read 0), so software can add it to its totals
unconditionally.

Writing any value to a TX counter clears both TX counters. Writing any value
to an RX counter clears all RX counters in the `eth_stats` RX block.

## 0x3C - SCRATCH

32-bit RW with no hardware side effects. Useful for software self-tests.

## 0x40 - IP_ADDR

32-bit RW holding the IPv4 address (`cfg_ip_addr[31:0]`, byte order
`{a,b,c,d}` for `a.b.c.d`) used by the optional demonstration L3 stack for
ARP, ICMP, and UDP address matching. Reset value `0xC0A889C8`
(192.168.137.200). The bare MAC leaves `cfg_ip_addr` unconnected; the value is
still readable/writable in the CSR block. Because it is a live wire into the
L3 responders, changing it retargets the demo IP at runtime with no rebuild -
the Arty debug bitstream exercises exactly this over the fpgacapZero
JTAG-to-AXI bridge.

## 0x44 / 0x48 - MCAST_LO / MCAST_HI

When `MCAST_HASH_FILTER == 1`, an incoming multicast frame is hashed into a
64-bit table; the bit at that index gates acceptance.

## 0x84 - PAUSE_CTRL

| Bits | Name | Description |
|-----:|------|-------------|
| `[0]` | `tx_send` | W1S: emit one PAUSE frame using `PAUSE_QUANTA`. Reads 0. |
| `[1]` | `rx_en` | When `1`, received PAUSE frames load the local TX gate counter. |
| `[31:2]` | reserved | Reads as 0. |

## 0x88 - PAUSE_QUANTA

Bits `[15:0]` are the quanta value loaded into the next PAUSE frame. One
quantum is 512 bit-times of the current line rate.

## 0x8C / 0x90 - PAUSE_RX_CNT / PAUSE_TX_CNT

Saturating 32-bit counters. Writing any value to either register clears both
PAUSE counters together.

## 0x94 - SAF_DBG

Read-only debug snapshot of the store-and-forward MII transmit path
(`mii_tx_saf`), with the media-clock (`mii_tx_clk`) read-side state synchronized
into the AXI (`sys_clk`) domain so the word reads stable while the framer is
quiescent. Reads `0` on the RGMII build (no `mii_tx_saf`). Layout:

| Bits | Field | Meaning |
|-----:|-------|---------|
| `[5:0]` | committed | Committed-frame count (write side), low 6 bits |
| `[11:6]` | drained | Drained-frame count (read side, synced), low 6 bits |
| `[12]` | rd_empty | Frame FIFO read-side empty |
| `[15:13]` | state | Framer FSM: 0 IDLE, 1 PRE, 2 SFD, 3 DATA, 4 PAD, 5 FCS, 6 IFG |
| `[31:16]` | reserved | `0` |

A healthy idle read has `committed == drained`, `rd_empty = 1`, `state = IDLE`.
`committed == drained` with `rd_empty = 0` while idle indicates uncommitted data
stuck in the FIFO (the failure mode fixed by the oversized-frame guard).

## Arty UDP Demo Sideband Ports

These are not AXI4-Lite CSRs. They are UDP ports decoded by the Arty A7 demo
top (`fpga/arty_a7/rtl/arty_a7_top.v`) after `net_rx`.

| UDP Port | Block | Direction | Description |
|---------:|-------|-----------|-------------|
| `5001` | `udp_iperf_sink` | host -> FPGA | Passive iperf2 UDP receiver. |
| `9996` | `udp_stats_reply` | host -> FPGA -> host | Binary stats query/clear responder. |
| `9997` | `udp_blast_trigger` | host -> FPGA | Starts `udp_blast`. |
| `9999` | `udp_echo` | host -> FPGA -> host | UDP echo responder. |

The `udp_stats_reply` payload is 44 bytes:

| Bytes | Field |
|------:|-------|
| `0..3` | Magic `IPS0` |
| `4..7` | Packet count |
| `8..11` | Payload byte count |
| `12..15` | First iperf sequence ID |
| `16..19` | Last iperf sequence ID |
| `20..23` | Sequence gap count |
| `24..27` | Out-of-order count |
| `28..31` | iperf final datagram count |
| `32..35` | Last source IPv4 address |
| `36..37` | Last source UDP port |
| `38..39` | Flags/reserved |
| `40..43` | Magic `DONE` |

## C Header

The bare-metal driver header [`sw/emaczero/emaczero.h`](../sw/emaczero/emaczero.h)
mirrors this map and is the source of truth for offsets and bit fields. Keep
both files in sync when adding registers.
