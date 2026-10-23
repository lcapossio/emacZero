# emacZero — Linux driver

Out-of-tree netdev driver for `eth_mac_sys` on Linux 6.12 or later, first
brought up on the ZCU106 (Cortex-A53, AMD AXI DMA, 1000BASE-X SFP). Work in
progress: probe, link handling and the TX path are tested on hardware; the RX
path is not yet (see [Status](#status)).

| Path | Purpose |
|------|---------|
| [emaczero/emaczero.c](emaczero/emaczero.c) | The driver (`emaczero.ko`) |
| [emaczero/Makefile](emaczero/Makefile) | Kbuild and out-of-tree build |
| [bindings/bard0,emaczero.yaml](bindings/bard0,emaczero.yaml) | Device tree binding (draft) |
| [dts/zcu106-emaczero.dts](dts/zcu106-emaczero.dts) | ZCU106 board tree plus the PL nodes of the 1G shell |

## Design

- **DMA through dmaengine.** The MAC has no DMA engine. The driver takes a
  `tx` and an `rx` channel from any dmaengine provider (on AMD parts the AXI
  DMA, `xilinx_dma`), one descriptor per frame. RX length is the buffer
  length minus the residue the provider reports in `callback_result`.
- **NAPI.** DMA callbacks only record the result and schedule NAPI, which
  completes TX, delivers RX through GRO and refills the ring. TX uses BQL.
- **TX bounce buffers.** Each frame is copied into an aligned per-slot buffer:
  an AXI DMA built without its realignment engine needs buffers aligned to
  its memory bus width, and an skb's Ethernet header usually is not. No
  scatter-gather and no checksum offload in this version.
- **Channels per ifup.** The channels are requested on `ifup` and released
  on `ifdown`, as `xilinx_axienet` does. Stopping an AXI DMA channel resets the
  whole core, which clears the other channel's interrupt enables, and
  `xilinx_dma` turns them on again only when a channel is allocated.
- **Recovery.** A DMA error halts the channel, and `xilinx_dma` recovers it
  only by resetting the whole core, so the driver stops submitting to both
  channels and rebuilds both, with fresh rings. The provider reports an error
  only through a descriptor completion, and a channel can halt without one,
  so two watchdogs back this up: the TX timeout, and an RX stall check (the
  MAC drops frames for lack of room while NAPI receives nothing). Recovery
  after a real DMA error has not been tested on hardware.
- **Link through phylink.** Copper PHYs on the MAC's MDIO master (an `mdio`
  child node, clause 22 and 45), or a `fixed-link`, for example with
  `link-gpios` on a GPIO that carries the PCS link status. `mac_link_up` sets
  the CTRL speed code; the MAC is full duplex only.
- **RX filter.** Promiscuous mode, and the 64-bit multicast hash when the
  core is built with `MCAST_HASH_FILTER=1` (the driver detects it). Without
  the hash, any multicast subscription (IPv6 needs one) turns on promiscuous
  mode.
- **Statistics.** Software counters for the interface; the MAC's own
  counters (32-bit, saturating) under `ethtool -S`.

The MAC starts with TX and RX disabled (`TXRX_EN_AT_RESET=0`); the driver
enables them on `ifup` and disables them on `ifdown`.

## Requirements on the hardware around the MAC

- TX: whole frames buffered in front of the MAC (`eth_mac_tx` treats a gap
  inside a frame as an underrun). The emacz_zephyr shells use a TX
  store-and-forward FIFO.
- RX: frames that end with `m_axis_terror` dropped before the DMA, since the
  error arrives with the last byte, after the data is in memory.
- The DMA channels' completion must report the received length (`xilinx_dma`
  does, through the descriptor status).
- With `xilinx_dma`, set `xlnx,irq-delay` on the channel nodes. The provider
  sets a channel's interrupt threshold to the number of descriptors it starts
  at once (the RX ring starts 128) and leaves the delay timer off by default,
  so a lone frame could wait for completions that never come. The ZCU106 tree
  uses 12 (10 us at a 150 MHz SG clock).

## Build

Against a configured and built kernel tree (for example Buildroot's
`output/build/linux-*`):

```sh
make -C sw/linux/emaczero KDIR=<kernel tree> ARCH=arm64 CROSS_COMPILE=aarch64-linux-
```

The kernel needs `CONFIG_PHYLINK`, `CONFIG_XILINX_DMA` and, for a
`link-gpios` fixed link on an AXI GPIO, `CONFIG_GPIO_XILINX`.

## Status

Tested on 2026-10-24 on a ZCU106 (xczu7ev, A53 at the Buildroot default
clocks), Linux 6.12.60 (linux-xlnx `xlnx_rebase_v6.12_LTS`, Buildroot
2026.02.3, JTAG boot), with the emacz_zephyr `zcu106_r5` block design:
emacZero rev 1 behind an AXI DMA 7.1 (SG, 32-bit memory side, 8-bit streams,
no DRE) at 150 MHz, PS DDR through S_AXI_HP0_FPD, non-coherent.

- Probe, `ethtool` (settings, driver info, MAC counters), 20 `ifdown`/`ifup`
  cycles, unbind/bind and `rmmod`/`insmod`: no errors, both DMA channels keep
  their interrupt enables, no memory growth.
- Link: with the SFP unplugged the PCS link bit stays 0 and phylink keeps the
  carrier off.
- TX, with a test device tree whose fixed link has no `link-gpios` (carrier
  always on; the frames leave towards the unconnected SFP), pktgen to a
  static neighbour:

  | Frame (bytes, no FCS) | pktgen burst | Rate | Of 1G line rate |
  |---:|---:|---:|---:|
  | 1514 | 1 | 81,211 pps, 983.6 Mb/s | 99.9 % |
  | 60 | 1 | 94,586 pps | 6.4 % |
  | 60 | 16 | 275,906 pps | 18.5 % |

  The MAC's TX_FRAME counter matched the interface's packet count exactly
  (2,339,917 frames over all runs), including across five `ifdown`/`ifup`
  cycles in the middle of a 1514-byte run; BQL drained to 0 every time.
  Small frames are limited by the per-descriptor cost of `xilinx_dma` and the
  per-frame interrupts it ends up with (about one MM2S interrupt per 1.5
  frames), not by the MAC.
- Not tested yet: RX (needs a link partner on the SFP), multicast, recovery
  after a DMA error, a TX timeout.

## Licence

The driver and the device tree are dual licensed `GPL-2.0-only OR
Apache-2.0`, so they can be built into Linux and stay usable under the
project's Apache-2.0. The binding is `GPL-2.0-only OR BSD-2-Clause`, as
the kernel requires for bindings.
