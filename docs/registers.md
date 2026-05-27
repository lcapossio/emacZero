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
| `0x30` | RX_FRAME | RO/WC | `0x00000000` | RX frame count |
| `0x34` | RX_BYTE | RO/WC | `0x00000000` | RX byte count |
| `0x38` | RX_ERR | RO/WC | `0x00000000` | RX error count |
| `0x3C` | SCRATCH | RW | `0x00000000` | Scratch register |
| `0x44` | MCAST_LO | RW* | `0x00000000` | `mcast_hash_table[31:0]` |
| `0x48` | MCAST_HI | RW* | `0x00000000` | `mcast_hash_table[63:32]` |
| `0x4C` | RX_ERR_ALIGN | RO/WC | `0x00000000` | RX frames with `rx_er` asserted |
| `0x50` | RX_ERR_OVERFLOW | RO/WC | `0x00000000` | RX frames lost to FIFO overflow |
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
| `0x84` | PAUSE_CTRL | RW | `0x00000000` | 802.3x PAUSE control |
| `0x88` | PAUSE_QUANTA | RW | `0x00000000` | Quanta payload of next emitted PAUSE frame |
| `0x8C` | PAUSE_RX_CNT | RO/WC | `0x00000000` | Received PAUSE frames |
| `0x90` | PAUSE_TX_CNT | RO/WC | `0x00000000` | Transmitted PAUSE frames |

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

## 0x28 / 0x2C / 0x30 / 0x34 / 0x38 - Statistics

| Offset | Name | Counts |
|-------:|------|--------|
| `0x28` | TX_FRAME | Frames accepted by TX. |
| `0x2C` | TX_BYTE | Payload + header bytes transmitted. |
| `0x30` | RX_FRAME | Frames passed to AXIS sink. |
| `0x34` | RX_BYTE | Bytes accepted by RX FIFO. |
| `0x38` | RX_ERR | RX frames dropped. |

Writing any value to a TX counter clears both TX counters. Writing any value
to an RX counter clears all RX counters in the `eth_stats` RX block.

## 0x3C - SCRATCH

32-bit RW with no hardware side effects. Useful for software self-tests.

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
