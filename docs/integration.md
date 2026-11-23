# Integrating emacZero

How to wire `eth_mac_sys` into a design: its ports and parameters, bring-up,
the RGMII clocking rules, and the limits of jumbo frames and checksum offload.
The register-level detail is in [registers.md](registers.md).

## Bring-up

Default CTRL: tx_en=0, rx_en=0, promisc=0, speed=00 (1G), full_duplex=1,
jumbo_en=0, tx_csum_off=0, passthrough=0, rx_csum_off=0  ->  0x20, or 0x23
(tx_en and rx_en set) with `TXRX_EN_AT_RESET=1`. With TX disabled
`s_axis_tready` stays low; with RX disabled received frames are drained, not
delivered. Program the MAC address, then set tx_en and rx_en (`emz_init` in
`sw/emaczero/` does both).
Default MAC: 02:00:00:00:00:01 (locally administered).

## Source files

| Module | Description |
|--------|-------------|
| `eth_mac_sys.v` | **System wrapper**: CSR + stats + MAC + PHY IF + MDIO |
| `axilite_regs.v` | AXI4-Lite CSR block for configuration, counters, MDIO, multicast, and PAUSE |
| `eth_stats.v` | TX/RX frame, byte, and error counters |
| `eth_pause.v` | 802.3x PAUSE TX gate timer, PAUSE frame generator and automatic PAUSE from the RX FIFO level |
| `eth_pause_rx.v` | 802.3x PAUSE frame recognizer on the PHY receive stream, ahead of the RX FIFO |
| `eth_mac_tx.v` | TX path: preamble, SFD, data, padding, CRC, IFG |
| `eth_mac_rx.v` | RX path: preamble detect, data, CRC check, MAC filter |
| `mii_if.v` | MII PHY interface with store-and-forward CDC FIFOs |
| `sync_fifo.v` | Synchronous FIFO used by MAC RX/TX buffering |
| `gmii_cdc.v` | GMII clock domain crossing bridge (GMII and RGMII modes) |
| `rgmii_if.v` | RGMII DDR interface using vendor-agnostic wrappers |
| `gmii_if.v` | GMII pin interface: registered SDR I/O + transmit-clock (GTX_CLK) forwarding |
| `ddr_output.v` | Vendor-agnostic DDR output (Xilinx ODDR / Intel / behavioral) |
| `ddr_input.v` | Vendor-agnostic DDR input (Xilinx IDDR / Intel / behavioral) |
| `crc32.v` | IEEE 802.3 CRC-32 (reflected polynomial 0xEDB88320) |
| `async_fifo.v` | Gray-pointer async FIFO, first-word-fall-through; `RAM_STYLE="BLOCK"` (block RAM, registered read) or `"DISTRIBUTED"` (LUTRAM) |
| `mdio_master.v` | MDIO serial interface for PHY register access |
| `eth_mac.v` | Bare MAC wrapper (TX + RX + MII, no CSR) for simple designs |
| `csum_calc.v` | IPv4 header / TCP / UDP / ICMP / ICMPv6 checksum engine shared by TX insert and RX verify |
| `tx_csum_off.v` | TX checksum offload: stores each frame and inserts its checksums |
| `net_rx.v` | Ethernet/IPv4/ICMP/UDP parser used by the Arty demo |
| `icmp_echo.v` | ICMP echo responder |
| `udp_echo.v` | UDP echo responder |
| `udp_blast.v` | Line-rate UDP/iperf2-format packet generator |
| `udp_blast_trigger.v` | UDP/9997 control parser for `udp_blast` |
| `udp_iperf_sink.v` | Passive iperf2 UDP/5001 receiver/stat counter |
| `udp_stats_reply.v` | UDP/9996 binary stats query/clear responder |
| `arty_tx_arbiter.v` | Arty demo TX arbiter with blast-service holdoff |

## Port interface

```verilog
module eth_mac_sys #(
    parameter PHY_INTERFACE     = "MII",  // "MII", "GMII" or "RGMII"
    parameter MCAST_HASH_FILTER = 0,      // 1 = enable 64-bit multicast hash
    parameter MAX_FRAME         = 1518,   // standard; up to 9018 for jumbo (GMII/RGMII)
    // RX AXIS buffer depth (address width). Defaults to one full MAX_FRAME
    // frame (2048-byte floor) so a jumbo frame survives downstream
    // backpressure; lower to save BRAM on standard-MTU builds.
    parameter RX_AXIS_ADDR_WIDTH = ($clog2(MAX_FRAME) > 11) ? $clog2(MAX_FRAME) : 11,
    parameter TX_CSUM_OFFLOAD   = 0,      // 1 = synthesize TX checksum inserter
    parameter RX_CSUM_OFFLOAD   = 0,      // 1 = synthesize RX checksum checker
    parameter CDC_RAM_STYLE     = "BLOCK",// GMII/RGMII CDC FIFOs: "BLOCK" | "DISTRIBUTED"
    // clk frequency: sets the pause-quanta and MDC dividers. A build that can
    // run at 1G (GMII, or RGMII with RGMII_SPEEDS != "10_100") needs >= 125 MHz
    // and fails elaboration below that: a slower clk cannot drain the RX CDC
    // FIFO at gigabit line rate.
    parameter CLK_FREQ_HZ       = 100_000_000,
    parameter RGMII_SPEEDS      = "ALL",  // "ALL" | "1G_ONLY" | "10_100"
    parameter MII_DEBUG         = 0,      // 0 = debug capture/counters off
    // 0 = CTRL resets with tx_en/rx_en clear: no frame is sent or delivered
    // until software has programmed the MAC address and set them. 1 = both
    // set at reset (the pre-0.3 behaviour), for designs with no CPU.
    parameter TXRX_EN_AT_RESET  = 0
)(
    input  wire        clk,           // system clock, CLK_FREQ_HZ
    input  wire        rst_n,

    // AXI4-Lite CSR (32-bit data, 8-bit byte address)
    input  wire [7:0]  s_axi_awaddr, s_axi_araddr,
    // ... standard AXI4-Lite signals ...

    // AXI4-Stream TX (from network stack)
    input  wire [7:0]  s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,

    // AXI4-Stream RX (to network stack)
    output wire [7:0]  m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output wire        m_axis_terror,  // CRC error
    output wire        m_axis_tsof,    // start of frame

    // MII PHY pins (PHY_INTERFACE="MII")
    output wire [3:0]  mii_txd,
    output wire        mii_tx_en,
    input  wire        mii_tx_clk, mii_rx_clk,
    input  wire [3:0]  mii_rxd,
    input  wire        mii_rx_dv, mii_rx_er,
    input  wire        mii_col, mii_crs,

    // RGMII PHY pins (PHY_INTERFACE="RGMII")
    input  wire        clk_125, clk_125_90,
                                         // clk_125_90: 90 deg, same source; TXC
                                         // clock when 1G is built, unused for
                                         // RGMII_SPEEDS="10_100"
    input  wire        clk_25, clk_2_5,  // unused (10/100 TXC is made from
                                         // clk_125); kept for compatibility
    output wire [3:0]  rgmii_txd,
    output wire        rgmii_tx_ctl, rgmii_txc,
    input  wire [3:0]  rgmii_rxd,
    input  wire        rgmii_rx_ctl, rgmii_rxc,

    // GMII PHY pins (PHY_INTERFACE="GMII"; uses clk_125 above, not clk_125_90)
    output wire [7:0]  phy_gmii_txd,
    output wire        phy_gmii_tx_en, phy_gmii_tx_er,
    output wire        phy_gmii_txc,     // GTX_CLK: clk_125, inverted (180 deg)
    input  wire        phy_gmii_rx_clk,  // 125 MHz, PHY-sourced
    input  wire [7:0]  phy_gmii_rxd,
    input  wire        phy_gmii_rx_dv, phy_gmii_rx_er,

    // MDIO
    output wire        mdc,
    input  wire        mdio_i,
    output wire        mdio_o, mdio_oe,

    // Interrupt
    output wire        irq
);
```

`MII_DEBUG` defaults off. When enabled it keeps low-level MII capture counters
alive inside `mii_if` / `eth_mac` for testbench or bring-up probes; the
system wrapper (`eth_mac_sys`) does not export a board-level debug bus.

[examples/eth_mac_sys_minimal/](../examples/eth_mac_sys_minimal/) is a
copy-paste wrapper that exposes every host-side port (AXI-Lite, AXI-Stream
TX/RX, MII / RGMII, MDIO, IRQ) with no demo logic.

## RGMII clocks and delays

- `clk_125` and `clk_125_90` must come from the same MMCM or PLL, with
  `clk_125_90` 90 degrees (2 ns) behind. `rgmii_if` reads its TX phase counter
  and speed from `clk_125_90` into `clk_125` over a timed 6 ns path, so
  constrain the two as related clocks: never put them in asynchronous clock
  groups or set a false path between them.
- At 1G, TXC leaves 90 degrees after TXD / TX_CTL, which suits a PHY with no TX
  internal delay. If the PHY's TX delay is on (RGMII-ID or RGMII-TXID, often
  the strap default), turn it off over MDIO or with the straps, or drive
  `clk_125_90` from `clk_125` so TXC leaves edge-aligned. At 10/100 every TXC
  edge stays at least 8 ns from a data change either way.
- RX samples RXD / RX_CTL on RXC directly, with no IDELAY, so RXC must arrive
  centred on the data: turn on the PHY's RX internal delay, or delay RXC on
  the board.
- `cfg_speed` is synchronized separately into the TX and RX clocks, and the RX
  copy follows only while RXC runs. Change the speed only while the link is
  down. TXC switches only at the end of a period, so it never glitches. The TX
  side takes a speed only after reading it for 5 TX clock cycles running. With
  synchronizer metastability settling within a cycle (the usual MTBF
  assumption), a wrong mixed speed would need `cfg_speed` to change on 5
  consecutive cycles, which the CTRL register, written by software, does not.

## GMII

`PHY_INTERFACE="GMII"` (`rtl/gmii_if.v`) is 1000 Mbps only, with registered SDR
I/O and a forwarded GTX_CLK. A tri-speed PHY exposing GMII falls back to 4-bit
MII at 10/100, which is the `"MII"` mode, so this path pins the internal
pacing to 1G and ignores the `cfg_speed` field. Its main use is driving a
vendor 1G PCS/PMA core for SGMII / 1000BASE-X, which presents a GMII bus
rather than PHY pins.

## Jumbo frames

Jumbo frames (up to 9018 bytes, `MAX_FRAME`) work on TX and RX for the GMII
and RGMII paths. `gmii_cdc`'s store-and-forward RX
CDC FIFO is sized from `MAX_FRAME` (16K words at `MAX_FRAME=9018`, 4K floor),
so a full `MAX_FRAME` frame is received intact. If that FIFO does overflow
(sustained line-rate 1G reception when `clk` is slower than the 125 MHz
media clock - the reader drains one byte per `clk`), the
affected frame is truncated and tagged with `rx_er` - delivered with
`m_axis_terror` and counted in `RX_ERR_ALIGN` - or dropped whole; frame
boundaries are never merged. Builds that don't need jumbo RX keep the default
`MAX_FRAME=1518`, which holds the RX CDC FIFO at 4K words.

The MII 10/100 path is standard-MTU only: its 4096-byte TX FIFO and RX replay
buffer cannot buffer a jumbo frame while the slow MII side drains it, so keep
`MAX_FRAME=1518` for MII builds.

On RX, `MAX_FRAME` is the wire size with the FCS, like the 1518 standard
limit: with `jumbo_en=1` RX accepts up to `MAX_FRAME` bytes, with
`jumbo_en=0` 1518, or 1522 with an 802.1Q / 802.1ad tag. TX counts the same
parameter in AXIS bytes, before the FCS it appends, so it can send a frame
4 bytes longer than an identically built RX accepts. `MAX_FRAME` must be at
most 16382 (16370 on GMII and RGMII, where a whole frame must fit in the
16K-word TX CDC FIFO); a larger value is an elaboration error.

The RX AXIS buffer (`RX_AXIS_ADDR_WIDTH`) defaults to one full `MAX_FRAME`
frame with a 2048-byte floor, so `MAX_FRAME=9018` gives a 16384-byte buffer
that absorbs a jumbo frame under sustained downstream back-pressure. Override
`RX_AXIS_ADDR_WIDTH` to trade that buffering back for block RAM.

## Checksum offload

Optional, per direction. TX (`TX_CSUM_OFFLOAD=1`, `rtl/net/tx_csum_off.v`,
CTRL[7]) computes and inserts the IPv4 header checksum and the TCP / UDP /
ICMP (IPv4) or TCP / UDP / ICMPv6 (IPv6) checksum, pseudo-header included; RX
(`RX_CSUM_OFFLOAD=1`, CTRL[9]) verifies the same checksums and ends a frame
that fails with `m_axis_terror`, counting it in `RX_ERR_CSUM`. The core does
not drop it: the consumer must discard every frame that ends with `terror`.
Both handle one 802.1Q / 802.1ad tag and any IPv4 header length, and UDP is
summed over its own Length field. Not covered (left to software): IPv4
fragments and IPv4 with a source route option (header checksum only), UDP
whose Length is below 8 or beyond the IP payload, a datagram longer than its
frame (RX: header checksum only), IPv6 packets with extension headers, and
tunnels. RX does not judge a UDP checksum of 0, over IPv4 ("none") or IPv6
(allowed per socket by RFC 6935/6936), and leaves it to software; a UDP
checksum that computes to 0 is sent as 0xFFFF. The TX side stores each frame
whole before sending it (one `MAX_FRAME` of block RAM, a few cycles per
frame), since the checksum fields precede the bytes they cover. The checksum
logic is `rtl/net/csum_calc.v`.

## AXI-Stream frame contract

`emacZero` exposes byte-wide AXI4-Stream TX/RX ports, but this repository does
not include a separate `axis_store_forward` block. That block is useful in a
larger SoC when a DMA or packet producer can start a TX frame and then starve
before `tlast`; it belongs at that parent-system AXI-Stream boundary.

Inside this IP, the MII path already has its own frame-aware CDC buffering:
MII RX stores a complete frame before replaying it into the system clock
domain, and MII TX carries the frame boundary as an EOF sideband bit in its
CDC data FIFO before driving the PHY.
For normal standalone `eth_mac_sys` integration, do not add an external
`axis_store_forward` dependency unless your upstream producer cannot meet the
AXI-Stream frame contract under backpressure.
