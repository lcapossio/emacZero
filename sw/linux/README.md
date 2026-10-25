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
  its memory bus width, and an skb's Ethernet header usually is not. Since
  the copy happens anyway, the driver offers scatter-gather and
  `NETIF_F_HW_CSUM` and fills in the checksum during the copy
  (`skb_copy_and_csum_dev()`), so the stack skips its own linearising copy
  and checksum pass. The buffers come from `dma_alloc_noncoherent()`, within
  the DMA channel's address mask.
- **RX page pool.** Each RX buffer is a 2 KB fragment of a page from a page
  pool (two per page with 4 KB pages), which maps the page once, recycles
  it when all its fragments come back and syncs it for the device then.
  When the DMA channel cannot address all of memory (an AXI DMA with a
  32-bit address width on a board with RAM above 4 GB, as on the ZCU106),
  the pages come from `GFP_DMA32`, so SWIOTLB never bounces them. NAPI hands
  refilled descriptors to the provider every 16, so a channel that ran out
  restarts without waiting for the end of the poll.
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
  the CTRL speed code; the MAC is full duplex only. No flow control: the
  probe turns off PAUSE reception, which a previous user may have left on.
- **RX filter.** Promiscuous mode, and the 64-bit multicast hash when the
  core is built with `MCAST_HASH_FILTER=1` (the driver detects it). Without
  the hash, any multicast subscription (IPv6 needs one) turns on promiscuous
  mode.
- **Statistics.** Software counters for the interface, and the MAC's own
  counters under `ethtool -S`. The MAC's counters are 32-bit and saturate,
  and writing one clears its whole group (TX, RX or pause), so once a
  second the driver checks them, and when any counter of a group has passed
  2^31 it adds the group into 64-bit totals and clears it. It does this for as long as it is bound, not
  only while the interface is up: the MAC counts received frames even with
  RX disabled. The totals count from driver load (the probe clears the
  MAC's counters). What a counter takes between its read and the clear is
  lost from the totals; the driver reads the busiest counters last, with
  interrupts off, to keep that window to a few bus cycles.

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

The kernel needs `CONFIG_PHYLINK`, `CONFIG_XILINX_DMA`, `CONFIG_PAGE_POOL`
and, for a `link-gpios` fixed link on an AXI GPIO, `CONFIG_GPIO_XILINX`.
`CONFIG_PAGE_POOL` has no prompt: an in-tree driver that needs it selects
it. The linux-xlnx 6.12 `xilinx_defconfig` does not have it; any option
that selects it adds it, for example `CONFIG_VETH=y`.

## Benchmark

[scripts/linux_bench.py](scripts/linux_bench.py) runs iperf3 from a host
against the board and reads the board's counters before and after each test
(over its serial console or ssh), so every result comes with the MAC's and
the interface's view of the same frames:

```sh
python sw/linux/scripts/linux_bench.py --board 192.168.237.50 --bind 192.168.237.1 \
    --serial /dev/ttyUSB1 --tests tcp-rx,tcp-tx,udp-rx,udp-tx,bidir,soak \
    --conditions "<board, kernel, link, host>" --out results/<name>.md
```

The board needs `iperf3` and `ethtool`; the script starts `iperf3 -s` on it.
It waits two seconds after each test before reading the counters, marks a
test invalid when a counter is missing or went backwards, and exits
non-zero unless every test agrees. Read the counters over the serial console
or another interface: ssh over the interface under test adds frames between
the readings. `--raw` saves the counter snapshots. Records are kept in
[results/](results/).

## Status

Results are from before the throughput work of 2026-10-25 unless stated;
that work and the final build's results are at the end of this section.

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
- With both directions busy (this build, before the throughput work below)
  the board receives less than it sends, and the MAC drops RX frames for
  lack of room (about 0.1 % of the frames in the soak);
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
  counters) grows with the ring. A hypothesis, not traced: while a channel
  is busy, `xilinx_dma` gives the hardware new descriptors only from its
  interrupt handler, after walking the completed ones (`issue_pending`
  starts them only on an idle channel), so when the hardware runs out first
  the gap before the restart grows with the number of descriptors to walk. Neither
  the batch sizes in steady state nor what an interrupt finds have been
  measured, and a 256-entry start is a special case (the provider skips
  setting the interrupt threshold above 255). Starting the ring in two
  halves made no measurable difference. A larger ring without the loss
  would most likely need changes in the provider. (Handing refilled
  descriptors over every 16 instead of once per poll, added later, raised
  what the board receives with both directions busy; see below. The ring
  sizes were not measured again.)
- Throughput work (2026-10-25). A `perf` profile of the build above with
  both directions busy showed the NAPI core spending most of its time on
  copies the hardware did not need: the ZCU106 has 2 GB of RAM above 4 GB,
  out of reach of the AXI DMA's 32-bit addresses, so SWIOTLB bounced about
  half the RX buffers (a copy on map and on unmap) and TX bounce buffers (a
  copy on every sync); and without scatter-gather the stack copied and
  checksummed every TCP segment in software before the driver copied it
  again. The changes, in order: buffers within the DMA mask (TX from
  `dma_alloc_noncoherent()`, RX from the DMA zone), scatter-gather with the
  checksum filled in during the bounce copy, handing RX descriptors over
  every 16, and the RX page pool with two buffers per page. Measured after a kernel
  rebuild with `CONFIG_PAGE_POOL` (module binaries of the earlier builds
  unchanged), same board and PC, the board's iperf3 server pinned to CPU2,
  DMA interrupt affinity at the default; 10 s per one-direction test, two
  20 s runs in both directions per NAPI mode:

  | Build | TCP received / sent | UDP 950 Mb/s offered: board sends | Both directions, NAPI in softirq | Both directions, threaded NAPI |
  |---|---:|---:|---:|---:|
  | Before (the build above) | 941 / 933 | 902 | 382 / 718, 394 / 663 | 628 / 716, 612 / 721 |
  | Buffers within the DMA mask, SG and checksum | 941 / 963 | 765 | 609 / 861, 592 / 861 | 706 / 920, 722 / 924 |
  | + RX descriptors handed over every 16 | 941 / 963 | 759 | 689 / 866, 673 / 844 | 818 / 918, 817 / 920 |
  | + page pool, two buffers per page | 941 / 967 | 748 | 741 / 890, 718 / 889 | 840 / 922, 834 / 922 |

  Both-direction cells are Mb/s received / sent. TCP in one direction had
  no retransmits in any build, and UDP towards the board (950 Mb/s
  offered) lost no frame between the MAC and the interface in any build.
  The UDP rate the board sends varies from run to run between two levels,
  about 750 and about 940 Mb/s: six runs of the page-pool build gave 746,
  936, 917, 886, 751 and 949 Mb/s with scatter-gather on, and six with it
  off (`ethtool -K eth1 sg off tx off`) a steady 778 to 789 Mb/s. The single
  values in the table are one run each; what sets the level was not traced.
- UDP towards the board with the board's iperf3 not pinned (free to share
  the NAPI core), 950 Mb/s offered, three 10 s runs per build: the build
  above dropped 5.3 to 7.1 % of the datagrams at the receiving socket (its
  receive buffer full; the driver delivered every frame), the final build
  0.4 to 3.3 %. A page pool with one buffer per page dropped 5.3 % in one
  run: each frame was charged a whole 4 KB page against the socket, which
  is why the driver puts two buffers in a page.
- Threaded NAPI against softirq NAPI, last build, both directions, 20 s
  per run, the board's iperf3 on CPU2 (thread and interrupt affinity
  checked before each run; Mb/s received / sent):

  | NAPI | NAPI thread | DMA interrupts | Received / sent |
  |---|---|---|---:|
  | softirq | | default | 699 / 882, 685 / 910 |
  | softirq | | CPU1 | 725 / 912 |
  | threaded | any CPU | default | 831 / 914, 794 / 913 |
  | threaded | CPU1 | default | 836 / 929 |
  | threaded | CPU3 | default | 816 / 912, 765 / 935 |
  | threaded | CPU3 | CPU1 | 808 / 933 |
  | threaded | CPU3 | CPU3 | 700 / 897 |

  Threaded NAPI (`echo 1 > /sys/class/net/eth1/threaded`) adds about
  100 Mb/s received with both directions busy and costs nothing in one
  direction (final build: TCP 937 Mb/s received, 942 Mb/s sent, no
  retransmits); pinning the thread adds
  nothing, and sharing a core with both DMA interrupts takes the gain away.
  The driver leaves the choice to the user. RX copybreak (frames up to 256
  bytes copied into a small skb, the page posted again) made no difference
  measurable against the run-to-run spread and is not in the driver.
- What the NAPI core still spends its time on with the page pool, both
  directions, softirq (`perf`, 20 s): the `xilinx_dma` descriptor path (tasklet, per-descriptor
  allocation, prep, submit, `issue_pending`) about a quarter, the TCP
  checksum of received segments in GRO plus the TX copy-and-checksum about
  12 %, and the TX bounce copy. The first needs a lighter provider path or
  a driver-owned DMA ring; the second, checksum offload in the hardware.
- Final build, after the throughput work (same board and PC, 2026-10-25,
  the kernel with `CONFIG_PAGE_POOL`):
  - Lifecycle: 20 `ifdown`/`ifup` cycles, unbind/bind and
    `rmmod`/`insmod`, no errors or page pool warnings, both DMA channels
    keep their interrupt enables, no memory lost.
  - Benchmark, recorded with the benchmark script in
    [results/zcu106-1000basex-2026-10-25.md](results/zcu106-1000basex-2026-10-25.md)
    (raw counters alongside; the board's iperf3 pinned to CPU2): TCP one
    direction at a time at 941 Mb/s received and 970 Mb/s sent with no
    retransmits; UDP at 950 Mb/s offered towards the board with every frame
    counted by the MAC reaching the interface (iperf3 reported 212 gaps, so
    those datagrams were lost above the driver); TCP in both directions for
    300 s at 679 Mb/s received and 911 Mb/s sent, with NAPI in softirq.
    With both directions busy the MAC still drops a few RX frames for lack
    of room (987 of 19.6 million in the soak), which TCP retransmits.
  - Counters: in every test the MAC's TX frames equalled the interface's TX
    packets, and in all but the soak the MAC's good RX frames equalled the
    interface's RX packets. Over the soak (about 14 folds of the RX group)
    the MAC's totals came out 2 RX frames short: the frames the MAC counted
    between the read of its frame counter and the clear. The fold runs with
    interrupts off, which made the TX totals exact over the soak (before,
    up to 10 frames short), but a frame landing in those few bus cycles is
    still lost; closing that needs a snapshot in the MAC.
  - TX stall: with the MAC's TX disabled by hand (CTRL TX_EN cleared) under
    1400-byte pings, the watchdog reported "TX DMA stalled, 2 frames in
    flight" and rebuilt the datapath once, within seconds. Before the stop
    path enabled the MAC's TX, the same test held a CPU for about 320 s in
    `xilinx_dma` (see [Known limits](#known-limits)).
  - RX stall: with the S2MM channel halted by hand (DMACR RS cleared) under
    500 Mb/s of UDP, the watchdog reported "RX DMA stalled (MAC dropped
    40422 frames)" at its next tick and rebuilt the datapath once. TCP ran
    at 940 / 942 Mb/s afterwards.
  - From the build before the throughput work, not repeated (the code
    involved did not change): PAUSE reception set by hand before a reload
    is off after it; with the board's interface down and the PC sending UDP
    at line rate, the MAC received 1,921,941 frames and 2,932,826,080 bytes
    (1,526 per frame, preamble and FCS included) and the totals kept every
    one, across a fold made while down.
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
  watchdog notices a stopped channel only through traffic: RX frames the
  MAC drops while NAPI receives nothing, or TX frames outstanding with the
  carrier up. A stopped channel with no traffic waits until traffic comes.
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
RGMII: 10/100/1000), full duplex only. The MAC cannot tell the driver which
speeds it was built with: for an RGMII build with `RGMII_SPEEDS="10_100"`,
set `max-speed = <100>` in the device tree. A `"1G_ONLY"` RGMII build is not
supported (the driver would offer 10 and 100 too).

## Licence

The driver and the device tree are dual licensed `GPL-2.0-only OR
Apache-2.0`, so they can be built into Linux and stay usable under the
project's Apache-2.0. The binding is `GPL-2.0-only OR BSD-2-Clause`, as
the kernel requires for bindings.
