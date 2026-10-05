# ZCU106 SFP Demo (1000BASE-X)

This directory runs emacZero on the AMD ZCU106 (`xczu7ev-ffvc1156-2-e`)
through **SFP cage 0** at 1 Gb/s. It uses the MAC's `PHY_INTERFACE="GMII"`
mode behind the AMD 1G/2.5G Ethernet PCS/PMA IP (1000BASE-X on a GTH
transceiver). The demo answers ARP and ping, echoes UDP on port 9999, and
has the Arty demo's throughput test: an iperf2 UDP sink and a line-rate UDP
generator.

> **Status: tested on hardware with both reference clocks (Si570 and
> Si5328) through the SFP0 <-> SFP1 loopback tests below (on an earlier
> build), and to a PC through a 1000BASE-T copper SFP in both directions at
> once: 100% of line rate from the FPGA, and as fast as the PC sends (99.8%)
> to it (see [Throughput test](#throughput-test)).**

## Data path

```
SFP0 <-> GTH (Quad 225, X0Y10) <-> PCS/PMA IP (1000BASE-X) <-GMII-> eth_mac_sys
                                                                     |
                               ARP responder, ICMP echo, UDP echo <--+
```

The whole MAC side runs on the PCS/PMA 125 MHz `userclk2`. That one clock is
the `eth_mac_sys` system clock and both of its GMII clocks, so the MAC and the
L3 demo are a single clock domain that keeps up with 1 Gb/s line rate.

A 50 MHz clock (the 300 MHz Si570 user clock divided by 6) runs a
transceiver bring-up watchdog, the PCS/PMA independent clock and, in the
Si5328 build, the Si5328 I2C setup.

## Reference clock

The GTH needs a reference clock; it is not the Ethernet clock. The GT
multiplies it up to the 1.25 Gb/s line rate and produces the 125 MHz
`userclk2` itself, so the MAC side is the same with either source.

| Build | Source | Pins | Frequency | Setup |
|-------|--------|------|-----------|-------|
| `si570` (default) | USER_MGT_SI570 (U56) via SI53340 (U51) | Quad 226 MGTREFCLK1, U10/U9 | 156.25 MHz | None: it starts at 156.25 MHz |
| `si5328` | Si5328 (U20) | Quad 225 MGTREFCLK1, W10/W9 | 125 MHz | Programmed over I2C at power-up |

The Si570 is the clock the AMD ZCU102 1000BASE-X example
([ZCU102-Ethernet](https://github.com/Xilinx-Wiki-Projects/ZCU102-Ethernet)
`pl_eth_1g`, `gtrefclkrate 156.25`) and the verilog-ethernet ZCU106 SFP+
example use. It enters on Quad 226 and reaches the SFP0 channel in Quad 225
over the GT reference clock routing between neighboring quads.

## Hardware Setup

- Board: AMD ZCU106. Jumper J16 ("SFP Enable") in its default position.
- A 1 Gb/s SFP module in **SFP0**. Use a 1000BASE-SX/LX fiber module, or a
  1000BASE-T copper module that runs in **1000BASE-X** mode. SGMII-mode
  copper modules are not supported by this build.
- Demo FPGA MAC: `02:00:00:00:00:01`.
- Demo FPGA IP: `192.168.137.200`. This is the `IP_ADDR` CSR reset value;
  nothing in this demo writes the CSRs.
- Host NIC: 1 Gb/s SFP port, a switch, or an RJ45 port through a 1000BASE-T
  copper SFP in SFP0, with an address such as `192.168.137.1/24`.
- 1000BASE-X auto-negotiation is on by default. Set **DIP switch 0** to
  turn it off for link partners that do not negotiate.

## Build

Run from the repository root:

```bash
vivado -mode batch -source fpga/zcu106/scripts/build_zcu106.tcl
```

For the Si5328 reference clock instead, add `-tclargs si5328`.

The script creates and synthesizes the PCS/PMA IP itself, so there are no
generated IP files in the repository. Output goes to `build_zcu106/`,
including `zcu106_top.bit`. Program it over JTAG with:

```bash
vivado -mode batch -source fpga/zcu106/scripts/program_zcu106.tcl
```

Then from the host:

```bash
ping 192.168.137.200
```

## LEDs

| LED | Meaning |
|----:|---------|
| 0 | Reference clock ready (always on in the `si570` build; Si5328 programmed in the `si5328` build) |
| 1 | At least one I2C NACK seen since reset (stays lit; `si5328` build only) |
| 2 | GTH reset done (the reference clock is running) |
| 3 | PCS link synchronization |
| 4 | 1000BASE-X link up |
| 5 | RX frame activity |
| 6 | TX frame activity |
| 7 | Heartbeat from the 125 MHz transceiver clock |

Bring-up normally shows LED 0, then LED 7 and LED 2 (in the `si5328` build,
possibly after up to ~20 s while the Si5328 locks), then LEDs 3 and 4 once a
link partner is connected.

## Throughput test

The demo has the Arty demo's throughput blocks, on the same ports:

| Port | Block | Use |
|-----:|-------|-----|
| UDP/9997 | `udp_blast_trigger` + `udp_blast` | A trigger datagram starts a bounded, back-to-back burst of iperf2-format datagrams to the sender. Its payload sets the extra gap, the frame count, the destination port and the payload size (18 to 1472 bytes). |
| UDP/5001 | `udp_iperf_sink` | Counts iperf2 datagrams: packets, bytes, sequence gaps, out of order |
| UDP/9996 | `udp_stats_reply` | `G` reads the sink counters, `C` reads and clears them |

The blast is the lowest-priority transmit source, so ARP, ping and stats
replies still go out between its frames. Its first frame comes 1 s after the
trigger, which gives a plain `iperf -u -s` time to start.

`scripts/sfp_perf_test.py` runs the test from the host in Python, with no
iperf needed. It also reads the NIC's own counters (`--nic`, the host's name
for the port facing the board), so frames the host stack drops are not
mistaken for link loss:

```bash
python fpga/zcu106/scripts/sfp_perf_test.py --nic <interface>
python fpga/zcu106/scripts/sfp_perf_test.py --nic <interface> --tests duplex --count 48800000
python fpga/zcu106/scripts/sfp_perf_test.py --nic <interface> --tests sweep
```

| Test | What it checks |
|------|----------------|
| `rx` | FPGA -> host, 1472-byte payloads at line rate: every datagram received, in sequence, right length; no NIC errors or loss |
| `tx` | Host -> FPGA, 1472-byte payloads as fast as the host sends: the FPGA counts every packet and byte |
| `duplex` | Both at the same time |
| `sweep` | Information only: one second of line-rate frames at each of 1518, 1024, 512, 256, 128 and 64 bytes, counted by the NIC |

Line rate for 1518-byte frames (1472-byte UDP payload) is 81,274 frames/s:
957.1 Mb/s of UDP payload, 987 Mb/s of Ethernet frames, 1000 Mb/s on the
wire with preamble and the 12-byte gap.

### Throughput results

ZCU106 (Si570 reference clock), a 1000BASE-T copper SFP in SFP0, an
Ethernet cable to a 1 Gb/s port on a PC:

| Run | FPGA -> host | Host -> FPGA |
|-----|--------------|--------------|
| 1 M frames each way, one direction at a time | 957.1 Mb/s, 100.00% of line rate, 0 lost | as fast as the host sends, all 1,000,000 counted by the FPGA, 0 lost |
| 10 min full duplex, 48.8 M frames each way | 957.1 Mb/s, 100.00% of line rate, 0 lost, 0 out of order, 0 NIC errors | 954.9 Mb/s (99.77%; the host's send rate), all 48,800,000 counted, 0 lost |

The 10-minute run moved about 1.19e12 bits with no FCS error in either
direction, so the bit error rate is below 2.5e-12 at 95% confidence. Its
host -> FPGA side had 36 datagrams arrive out of order: the host stack
reordered them (the FPGA receive path is a single in-order pipeline) and
none were lost.

During a 5-million-frame line-rate blast, 20 of 20 pings were answered in
under 1 ms and a stats query was answered, and the host still received all
5,000,000 blast datagrams in order at 957.1 Mb/s.

The host -> FPGA rate is the host's own send rate, measured over the run; on
a short run the host's send buffering can make it read slightly above line
rate.

The `sweep` test shows the host's limit, not the link's: the NIC counts every
frame at 1518 and 1024 bytes, but from 512 bytes down it tops out at a
roughly fixed 200-350 kframes/s whatever the frame size (64-byte frames reach
only about 170 Mb/s), the receive ceiling of one UDP flow on that PC. The FPGA sends
64-byte frames at the full 1.488 Mframe/s with exactly 12-byte gaps in the
`ZCU106-PERF` simulation, which this host cannot count.

## SFP0 <-> SFP1 loopback test

Without a 1G host on the other end of the fiber, the loopback build tests the
whole path on one board: plug a module into each cage and connect SFP0 to
SFP1 with a duplex fiber (TX to RX both ways).

```
emacZero demo  <-> PCS/PMA <-> SFP0 ==fiber== SFP1 <-> PCS/PMA <-> tester
(02:..:01, .200)                                          (02:..:02, .1)
```

`rtl/sfp_lb_tester.v` has its own MAC and plays the host: it sends ARP
requests, pings (18 to 1472 bytes of data) and UDP frames to port 9999 (18 to
1472 bytes), one at a time, and checks every reply byte by byte, including
its length, FCS, IPv4 header checksum and ICMP checksum. No reply within
about 1 ms counts as a timeout. The second PCS/PMA shares the first one's
reference clock and user clocks.

Build, program and run it (`-tclargs si5328 lb` for the Si5328 clock). The
script uses the fcapz host library from the `fcapz` submodule over one
hw_server session:

```bash
vivado -mode batch -source fpga/zcu106/scripts/build_zcu106.tcl -tclargs lb
vivado -mode batch -source fpga/zcu106/scripts/program_zcu106.tcl -tclargs build_zcu106_lb/zcu106_top.bit
python fpga/zcu106/scripts/sfp_lb_test.py                   # all tests
python fpga/zcu106/scripts/sfp_lb_test.py --tests links,soak --soak 3600
```

| Test | What it does |
|------|--------------|
| `links` | Bitstream identity, reference clock, userclk2 frequency, both links up |
| `traffic` | ARP / ICMP / UDP for `--seconds`; every reply must be correct |
| `negative` | Frames the demo must ignore, mixed with normal traffic (see below) |
| `short` | ICMP 0..17-byte and UDP 1..18-byte payloads (padded frames); every reply must be correct |
| `sfp1-laser`, `sfp0-laser` | Laser off for 1 s, links must recover; skipped when the link never drops |
| `sfp1-reset` | Resets the SFP1 PCS/PMA; both links must drop and recover |
| `an-off` | Auto-negotiation off on both cores, then back on; traffic each way |
| `an-restart` | Restarts auto-negotiation on both cores; links must recover |
| `soak` | Long traffic run (`--soak` seconds) with a bit error rate bound |

Every test that recovers a link then runs 5 s of traffic that must be
error-free. On a failure the script prints the first bad reply (reason, kind,
sequence number, byte) and GMII frame counters for each hop, which show
whether frames were lost on the way out or on the way back. LEDs in this
build:

| LED | Meaning |
|----:|---------|
| 0 | SFP0 link up |
| 1 | SFP1 link up |
| 2 | Both GTs reset done |
| 3 | Correct reply seen |
| 4 | Bad reply or timeout seen |
| 5 | Tester running |
| 6 | At least one failure counted since the last clear |
| 7 | Heartbeat |

The negative test sends eight variants, each one change from a valid ping
(or ARP, or UDP frame): 0 another destination MAC, 1 another destination
IP, 2 ARP for another IP, 3 UDP to another port, 4 bad IPv4 header checksum,
5 bad ICMP checksum, 6 bad FCS, 7 GMII `tx_er` in mid-frame. None of them
may get a reply.

The normal payloads start at 18 bytes, the smallest that needs no padding;
the `short` test covers the padded sizes below that. It sends no 0-byte UDP
datagram: `net_rx` passes UDP payload on byte by byte, with the end marked on
the last byte, so an empty datagram never reaches `udp_echo` and gets no
reply.
The `ZCU106-SFP-LB` simulation runs the same tester, in all its modes,
against the demo back to back.

**10GBASE-SR modules.** 1000BASE-SX modules are the right part. A 10GBASE-SR
SFP+ module is not specified for 1.25 Gb/s, but it has no CDR and the FPGA
does not read its ID EEPROM, so it often passes 1000BASE-X on an FPGA-to-FPGA
link with the same module at both ends. If the links do not come up with
10G modules, try 1000BASE-SX modules before suspecting the design.

### Results

With a pair of Cable Matters 10GBASE-SR modules, on both reference clocks:

| | Si570 (156.25 MHz) | Si5328 (125 MHz) |
|---|---|---|
| 10 min soak | 32,135,265 requests, all correct | 31,961,598 requests, all correct |
| Bit error rate (95% confidence) | < 2e-11 | < 1.8e-11 |
| Worst round trip | 59.3 us (1472-byte UDP) | 59.3 us |
| Negative variants 0..7 | all ignored | all ignored |
| Short payloads (5 s) | 583,048 of 583,048 correct | 580,698 of 580,698 correct |
| SFP1 reset, AN off / on, AN restart | links recover in 0.1-0.2 s, clean traffic after | same |
| Laser off (either cage) | no link drop: skipped | same |

The soak and bit error rate rows come from the build before the `net_rx` /
`eth_mac_tx` / `udp_echo` fixes below; the other rows are from a later build,
still before the `icmp_echo` fix, the 12-byte `eth_mac_tx` gap and the
throughput blocks. The loopback tests have not been rerun on hardware since
those changes; the throughput results above are from the current RTL.

The progress lines can show more replies than requests: counters change
during a JTAG read. Only the final read, after the tester stops, is checked.

Neither `TX_DISABLE` output drops the link on this board. For SFP0, jumper
J16 forces the laser on; SFP1 probably has the same kind of override.

### Found by these tests

The loopback tests found these bugs in the shared blocks, now fixed:

- `net_rx` took the ICMP / UDP payload up to the end of the Ethernet frame,
  not the IPv4 total length, so the padding of a short request was echoed
  back as payload. It now stops at the IPv4 total length.
- `eth_mac_tx` padded a 59-byte frame to 61 bytes instead of 60.
- `net_rx` did not check the IPv4 header checksum or the ICMP checksum, so
  requests with a bad checksum were answered. It now drops frames with a bad
  IPv4 header (version, IHL, checksum, total length) and flags an ICMP
  message with a bad checksum as an error.
- On a frame with `terror` (bad FCS, or `rx_er`), `net_rx` still passed the
  last byte on with `icmp_last` / `udp_last`, so the echo blocks answered
  the damaged frame. `net_rx` now marks the last byte with `icmp_err` /
  `udp_err` (also for a frame shorter than its IPv4 total length), and every
  consumer drops the message.
- `udp_echo` never ended its reply to a 1-byte datagram (no `tlast`), which
  hung the transmit path. The padding bug above had hidden it.

Pinging the demo from a PC through a 1000BASE-T SFP in SFP0 found one more,
also fixed: `icmp_echo` buffered only 256 bytes of ICMP, so pings with more
than 248 bytes of data came back corrupt, and from 504 bytes on not at all
(the loopback tester only sent up to 248). It now takes a full 1500-byte
packet, and the tester pings with 18 to 1472 bytes.

Still open:

- The UDP checksum is not checked (RFC 1122 says a nonzero one should be).
- The destination IP check in `net_rx` assumes a 20-byte IPv4 header.
- One earlier loopback build with the Si5328 clock (from the first version
  of this test) never got a reply, with both links up; it failed every time
  it was loaded, while later builds of both clocks passed every time. It has
  not been explained.

## Si5328 build

Only used with `-tclargs si5328`. The Si5328 (U20) drives Quad 225
MGTREFCLK1 (pins W10/W9). UG1244 says that is CKOUT1; other board notes say
CKOUT2, so the register list enables both outputs at 125 MHz. The Si5328 has
no non-volatile memory, so `rtl/i2c_init.v` programs it after configuration:

- Bus: PL IIC1 (AH19/AL21) -> TCA9548A U34 at `0x74`, channel 4.
- Mode: free-run from the 114.285 MHz crystal, CKOUT1 = CKOUT2 = 125 MHz. The divider
  values are the ones ARTIQ uses for 125 MHz from the same crystal. The full
  register list is in `rtl/zcu106_si5328_rom.vh`.
- Address: the Linux device tree says `0x69`, while UG1244 says `0x68`.
  The design tries `0x69` first and switches address on every retry. LED 1 on together with LED 0 means the first address was NACKed and
  the retry at the other one succeeded, which is fine.
- The Si5328 can take around 20 s to lock. Until the transceiver reports
  reset done, a watchdog re-pulses the PCS/PMA reset every 2 s.
- IIC1 is shared with the PS I2C1 controller and the board system controller.
  The design waits 1 s after configuration before its first I2C access.
  `i2c_init` cannot detect losing arbitration to another master, so keep
  other I2C1 traffic off the bus until LED 0 is on.

If LED 0 never lights, the I2C writes are not being acknowledged. If LED 0
lights but LED 2 and LED 7 never do, the Si5328 is not producing 125 MHz.
On the test board the loopback build's frequency meter read userclk2 at
125.000 MHz with the Si5328 clock.

## Files

| File | Purpose |
|------|---------|
| `rtl/zcu106_top.v` | Board top: clocks, refclk select (`REFCLK_SI5328`), PCS/PMA, LEDs; SFP1 loopback under `ZCU106_SFP1_LB` |
| `rtl/zcu106_eth_demo.v` | emacZero MAC (GMII) plus the ARP / ICMP / UDP-echo demo |
| `rtl/sfp_lb_tester.v` | Loopback tester: its own MAC, request generator and reply checker |
| `rtl/i2c_init.v` | Power-up I2C register writer with NACK retry |
| `rtl/zcu106_si5328_rom.vh` | I2C write list: mux select and Si5328 registers |
| `constraints/zcu106.xdc` | Pins (from the Vivado ZCU106 board files) and clocks |
| `constraints/refclk_si570.xdc` | Reference clock pins and period, `si570` build |
| `constraints/refclk_si5328.xdc` | Reference clock pins and period, `si5328` build |
| `constraints/sfp1_lb.xdc` | SFP1 pins and the fcapz JTAG clock, `lb` build |
| `scripts/build_zcu106.tcl` | Non-project Vivado build, including IP generation |
| `scripts/program_zcu106.tcl` | Program a bitstream (default `build_zcu106/zcu106_top.bit`) over JTAG |
| `scripts/sfp_lb_test.py` | Run the loopback tests through the fcapz EIO |
| `scripts/sfp_perf_test.py` | Host throughput test against the demo's iperf2 sink and UDP blast |

The ARP responder and TX arbiter are reused from `fpga/arty_a7/rtl/`.
The I2C sequence is simulated by `ZCU106-I2C-INIT` in `build_and_test.py`.
