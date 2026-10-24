# emacZero — Linux driver

Out-of-tree netdev driver for `eth_mac_sys` on Linux 6.12 or later, first
brought up on the ZCU106 (Cortex-A53, AMD AXI DMA, 1000BASE-X SFP). Work in
progress: probe, link handling, TX and RX are tested on hardware against a PC
(see [Status](#status)).

| Path | Purpose |
|------|---------|
| [emaczero/emaczero.c](emaczero/emaczero.c) | The driver (`emaczero.ko`) |
| [emaczero/Makefile](emaczero/Makefile) | Kbuild and out-of-tree build |
| [bindings/bard0,emaczero.yaml](bindings/bard0,emaczero.yaml) | Device tree binding (draft) |
| [dts/zcu106-emaczero.dts](dts/zcu106-emaczero.dts) | ZCU106 board tree plus the PL nodes of the 1G shell |
| [scripts/linux_bench.py](scripts/linux_bench.py) | Host-side benchmark: iperf3 plus the board's counters |
| [results/](results/) | Benchmark records, with their test conditions |

## Design

- **DMA through dmaengine.** The MAC has no DMA engine. The driver takes a
  `tx` and an `rx` channel from a dmaengine provider, one descriptor per
  frame. RX length is the buffer length minus the residue the provider
  reports in `callback_result`, so the provider must complete an RX
  descriptor at the end of each frame, including a short one, and report an
  accurate residue. Only the AXI DMA with `xilinx_dma` has been tested.
- **NAPI.** DMA callbacks only record the result and schedule NAPI, which
  completes TX, delivers RX through GRO and refills the ring. TX uses BQL.
- **TX bounce buffers.** Each frame is copied into an aligned per-slot buffer:
  an AXI DMA built without its realignment engine needs buffers aligned to
  its memory bus width, and an skb's Ethernet header usually is not. No
  scatter-gather and no checksum offload in this version.
- **Channels per ifup.** The channels are requested on `ifup` and released
  on `ifdown`, as `xilinx_axienet` does. Stopping an AXI DMA channel resets the
  whole core, so stopping the second channel clears the interrupt enables of
  the first; requesting both channels again turns both sets back on.
- **Recovery.** A DMA error halts the channel, and `xilinx_dma` recovers it
  only by resetting the whole core, so on a failed completion the driver
  stops submitting to both channels and rebuilds both, with fresh rings. The
  provider can also halt a channel without a failed completion, so a
  once-a-second watchdog backs this up. It rebuilds the datapath when the MAC
  drops RX frames for lack of room while NAPI receives nothing, or when TX
  frames are outstanding, the carrier is up and no TX completion arrives for
  three seconds. The netdev TX timeout does the same. If the rebuild itself
  fails (no memory, no channel), the driver logs it and closes the
  interface. See [Known limits](#known-limits) for what this cannot cover.
- **Link through phylink.** Copper PHYs on the MAC's MDIO master (an `mdio`
  child node, clause 22 and 45), or a `fixed-link`, for example with
  `link-gpios` on a GPIO that carries the PCS link status. `mac_link_up` sets
  the CTRL speed code; the MAC is full duplex only.
- **RX filter.** Promiscuous mode, and the 64-bit multicast hash when the
  core is built with `MCAST_HASH_FILTER=1` (the driver detects it). Without
  the hash, any multicast subscription (IPv6 needs one) turns on promiscuous
  mode.
- **Statistics.** Software counters for the interface, and the MAC's own
  counters under `ethtool -S`. The MAC's counters are 32-bit and saturate,
  and writing one clears its whole group (TX, RX or pause), so the watchdog
  adds a group into 64-bit totals and clears it once any of its counters
  passes 2^31. The totals count from driver load (the probe clears the MAC's
  counters). A frame counted between the read and the clear is lost from
  the totals; the driver reads the busiest counters last to keep that
  window short.

The MAC comes out of reset with TX and RX enabled. The driver disables them
at probe, enables them on `ifup` and disables them on `ifdown`.

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
  at once, when that is 255 or fewer (the driver starts its whole 128-entry
  RX ring; above 255 the provider keeps the previous threshold). It leaves
  the delay timer off by default, so a lone frame could wait for
  completions that never come. The timer counts idle time on the stream; the
  ZCU106 tree uses 12 (10 us at a 150 MHz SG clock).

## Build

Against a configured and built kernel tree (for example Buildroot's
`output/build/linux-*`):

```sh
make -C sw/linux/emaczero KDIR=<kernel tree> ARCH=arm64 CROSS_COMPILE=aarch64-linux-
```

The kernel needs `CONFIG_PHYLINK`, `CONFIG_XILINX_DMA` and, for a
`link-gpios` fixed link on an AXI GPIO, `CONFIG_GPIO_XILINX`.

## Benchmark

[scripts/linux_bench.py](scripts/linux_bench.py) runs iperf3 from a host
against the board and reads the board's counters before and after each test
(over its serial console or ssh), so every result comes with the MAC's and
the interface's view of the same frames:

```sh
python sw/linux/scripts/linux_bench.py --board 192.168.237.50 --bind 192.168.237.1     --serial /dev/ttyUSB1 --tests tcp-rx,tcp-tx,udp-rx,udp-tx,bidir,soak     --conditions "<board, kernel, link, host>" --out results/<name>.md
```

The board needs `iperf3` and `ethtool`; the script starts `iperf3 -s` on it.
Records are kept in [results/](results/).

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
- Link partner: a PC's 1000BASE-X SFP port, fibre, iperf3 3.16 on the PC.
  Phylink raised the carrier from the PCS link GPIO when the cable was
  plugged in with the driver loaded.
- Ping, including 1472-byte unfragmented: no loss.
- iperf3 with the driver defaults (no RPS, NAPI in softirq), 10 s per run
  unless stated:

  | Test | Board receives | Board sends |
  |---|---:|---:|
  | TCP, one direction at a time | 941 Mb/s, 0 retransmits | 933 Mb/s, 0 retransmits |
  | TCP, both directions, 20 s | 343 Mb/s | 762 Mb/s |
  | UDP 1472-byte, 950 Mb/s offered, one direction | 946 Mb/s, 0 of 806,668 lost | 855 Mb/s (sender limited) |

  In the UDP runs the MAC's frame counters matched the interface's packet
  counts exactly in both directions, so the 0.11 % the PC reported lost when
  the board sent was not lost between the board's TX queue and the MAC.

- Soak: TCP in both directions for 300 s (292 Mb/s received, 787 Mb/s
  sent). The MAC's TX_FRAME count matched the interface's TX packets exactly
  (20,877,806); MAC RX frames minus the MAC's RX overflow count matched the
  interface's RX packets exactly (11,294,911); no kernel messages, BQL drained
  to 0, free memory and slab unchanged.
- Multicast: the core has no hash filter, so the driver ran the MAC
  promiscuous; IPv4 multicast to 224.0.0.1 was delivered.
- With both directions busy the board receives less than it sends, and the
  MAC drops RX frames for lack of room (about 0.1 % of the frames in the soak);
  TCP recovers through retransmits. Each frame the MAC passed on reached the
  driver (the MAC counts the rest as RX dropped for FIFO full, or RX
  overflow); the counters do not cover the stack above the driver. One A53
  core at 1.2 GHz runs the NAPI poll at close to 100 %, paying per frame for
  a `xilinx_dma` descriptor, a callback, a buffer allocation and DMA
  mapping, plus TCP, so the likely cause is NAPI falling behind until the
  shell's RX buffering (about 6 KB, 50 us at 1G) fills. The RX stall
  watchdog does not fire, since NAPI keeps making progress. Threaded NAPI
  (`echo 1 > /sys/class/net/eth1/threaded`) raised what the board receives to
  545 Mb/s (714 Mb/s sent); RPS to another core (`rps_cpus`) to 381 Mb/s
  (785 Mb/s sent).
- RX ring size, measured with each size started as one batch (three 10 s runs
  of TCP towards the board, and one 20 s run in both directions):

  | RX ring | TCP towards the board: retransmits per run | Longest S2MM stall | Both directions: received / sent |
  |---:|---:|---:|---:|
  | 128 | 0 | 50 us | 340 / 759 Mb/s |
  | 192 | 0 to 6 | 84 us | 483 / 697 Mb/s |
  | 256 | 70 to 143 | 98 us | 580 / 624 Mb/s |

  A larger ring gives NAPI more slack when both directions are busy, but at
  line rate in one direction it loses frames, so the driver uses 128. The
  stall (the longest run of S2MM back-pressure, from the shell's stream
  counters) grows with the ring. A hypothesis, not traced: `xilinx_dma`
  gives the hardware new descriptors only from its interrupt handler, after
  walking the completed ones, so when the hardware runs out first the gap
  before the restart grows with the number of descriptors to walk. Neither
  the batch sizes in steady state nor what an interrupt finds have been
  measured, and a 256-entry start is a special case (the provider skips
  setting the interrupt threshold above 255). Starting the ring in two
  halves made no measurable difference. A larger ring without the loss
  would most likely need changes in the provider.
- Final build, after a review of the driver (same board and PC, 2026-10-24;
  all but the soak ran on the build before the last change, which only
  reordered the counter reads of a fold):
  - Lifecycle: 20 `ifdown`/`ifup` cycles, unbind/bind and
    `rmmod`/`insmod`, no errors, both DMA channels keep their interrupt
    enables.
  - TCP one direction at a time: 941 Mb/s received, 942 Mb/s sent, 0
    retransmits. UDP 950 Mb/s towards the board: 940 Mb/s, 22 of 820,035
    lost, all counted by the MAC (21 RX dropped for FIFO full, 1 RX
    overflow). UDP sent by the board: 743 to 887 Mb/s over three runs
    (sender limited, varies from run to run).
  - Soak: TCP in both directions for 300 s (289 Mb/s received, 803 Mb/s
    sent), recorded with the benchmark script in
    [results/zcu106-1000basex-2026-10-24.md](results/zcu106-1000basex-2026-10-24.md):
    the MAC counted exactly as many TX frames as the interface sent
    (21,468,821), and its RX frames minus its RX overflow count matched the
    interface's RX packets (11,030,514); no kernel messages, BQL drained to
    0, memory flat. The MAC's TX counters folded about 15 times and its RX
    counters about 8 times, and the counts agreed in every test of the
    record. An earlier
    build, which read the busiest counters first, lost one to three frames
    from its totals over similar runs.
  - TX stall: with the MAC's TX disabled by hand (CTRL TX_EN cleared) under
    1400-byte pings, the watchdog reported "TX DMA stalled, 2 frames in
    flight" and rebuilt the datapath within seconds; TCP ran at 941 / 937
    Mb/s afterwards. Before the stop path enabled the MAC's TX, the same test
    held a CPU for about 320 s in `xilinx_dma` (see
    [Known limits](#known-limits)).
  - RX stall: with the S2MM channel halted by hand (DMACR RS cleared) under
    500 Mb/s of UDP, the watchdog reported "RX DMA stalled (MAC dropped
    43058 frames)" at its next tick and rebuilt the datapath; iperf3 lost
    52,511 frames over the stall and the rebuild. TCP (941 Mb/s) and UDP at
    950 Mb/s (0 of 409,997 lost) ran afterwards.
- Not tested yet: IPv6 (the PC port had IPv6 off), the link going down with
  traffic running, the multicast hash filter (needs a core built with
  `MCAST_HASH_FILTER=1`), recovery after an error the DMA reports, a netdev
  TX timeout, a failed rebuild, PHY-managed (copper) links.

## Known limits

These come from the `xilinx_dma` provider in Linux 6.12 and cannot be fixed
in the driver alone:

- A DMA error that only raises the error interrupt produces no completion,
  so the driver does not see it. The next submit to that channel makes the
  provider reset the whole DMA core, under the other channel's feet. The
  watchdog then catches the stall of whichever direction stops, after a few
  seconds.
- When the provider cannot stop or reset a channel during `ifdown` or a
  rebuild, it logs "Cannot stop channel" but still reports success, and the
  driver frees the buffers. If the hardware really keeps running, it can
  write into freed memory.
- When a submit hits a failed core reset, the provider leaks that
  descriptor.
- Stopping a channel waits, without sleeping, for its stream to finish the
  frame in progress. The driver enables the MAC's TX before stopping TX for
  this reason. If something outside the MAC blocks a stream, a stop can hold
  a CPU for minutes.

The driver accepts only `fixed-link` or PHY-managed links; it has no PCS of
its own, so it rejects `managed = "in-band-status"`. It offers the speeds
the PHY interface allows (MII: 10/100; GMII, SGMII, 1000BASE-X: 1000;
RGMII: 10/100/1000), full duplex only.

## Licence

The driver and the device tree are dual licensed `GPL-2.0-only OR
Apache-2.0`, so they can be built into Linux and stay usable under the
project's Apache-2.0. The binding is `GPL-2.0-only OR BSD-2-Clause`, as
the kernel requires for bindings.
