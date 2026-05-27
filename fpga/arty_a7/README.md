# Arty A7 Hardware Test

This directory contains the Digilent Arty A7-100T hardware test for emacZero.
The design targets the onboard TI DP83848J 10/100 MII Ethernet PHY and exercises
the MAC, AXI-Lite register block, MDIO, ARP, ICMP, UDP echo, UDP blast,
`udp_stats_reply`, the FPGA UDP iperf sink, and the `arty_tx_arbiter` TX
multiplexer that shares the MAC between those producers.

Hardware tests require a connected board and host NIC, so GitHub-hosted CI does
not run them. CI covers simulation and lint only.

## Hardware Setup

- Board: Digilent Arty A7-100T.
- PHY: onboard TI DP83848J, MII at 100 Mbps.
- USB: connect the Arty USB cable for JTAG and UART.
- Ethernet: connect the Arty Ethernet port to the host NIC or a switch.
- Demo FPGA MAC: `02:00:00:00:00:01`.
- Demo FPGA IP: `192.168.137.200`.
- Recommended host NIC IP: `192.168.137.1/24`.
- UART: 115200 baud, 8N1.
- Tested with Vivado 2025.2.

The board design is full duplex. The hardware sequencer enables PHY
autonegotiation.

This design does not instantiate a Xilinx MIG/DDR controller. The Arty
`CLK100MHZ` input is the system clock source, and the Ethernet path targets the
onboard 10/100 MII PHY rather than a DDR-backed packet buffer.

## Build and Program

Run from the repository root.

```bash
vivado -mode batch -source fpga/arty_a7/scripts/build_arty.tcl
vivado -mode batch -source fpga/arty_a7/scripts/program_arty.tcl
```

The release build does not require submodules. The debug build uses the
`fcapz/` submodule and defines `FCAPZ_DEBUG`:

```bash
git submodule update --init -- fcapz
vivado -mode batch -source fpga/arty_a7/scripts/build_arty_debug.tcl
vivado -mode batch -source fpga/arty_a7/scripts/program_arty_debug.tcl
```

The debug bitstream instantiates fpgacapZero ELA/EIO probes in
`arty_a7_top.v`. The current probes focus on reset, UART, sequencer state, and
AXI-Lite handshakes.

## Test Scripts

All scripts are Python and are run from the repository root. Hardware tests are
not part of normal CI because they require a connected board and host NIC.

| Script | Purpose |
|--------|---------|
| `serial_monitor.py` | UART hardware smoke test plus ARP/ICMP checks. |
| `udp_echo_test.py` | Host-driven UDP echo throughput and latency test on UDP/9999. |
| `udp_blast_test.py` | FPGA-to-host UDP payload throughput test using the FPGA blast generator. |
| `udp_iperf_stats.py` | Query or clear FPGA host-to-FPGA iperf sink counters on UDP/9996. |
| `udp_bidirectional_test.py` | Simultaneous Python-only FPGA-to-host and host-to-FPGA UDP test. |
| `run_hw_regression.py` | Named hardware regression profiles for board tests. |

Debug-only scripts under `scripts/debug/` are wire-level troubleshooting tools,
not normal regression steps:

- `scapy_test.py`: Scapy ARP/ICMP wire-level probe for bring-up debugging.
- `udp_blast_sniff.py`: UDP blast trigger/sniffer for checking FPGA-to-host
  packet arrival independent of the normal throughput summary.

## LEDs

| LED | Meaning |
|-----|---------|
| 0 | Link up |
| 1 | PHY ID verified |
| 2 | TX frame sent |
| 3 | RX frame received |

## UART Smoke Test

```bash
python fpga/arty_a7/scripts/serial_monitor.py
```

Use `--port PORT` if auto-detection picks the wrong serial adapter. The script
prefers the Digilent FT2232 channel-B UART but also accepts an explicit port.

The UART phase checks:

1. `VERSION` register readback, expected `0x0001454D`.
2. `SCRATCH` write/readback, expected `0xDEADBEEF`.
3. PHY ID registers, expected `0x2000` and `0x5C9x`.
4. BMCR readback, expected `0x1000` (autonegotiation enabled; restart bit
   self-clears after writing `0x1200`).
5. Link status, expected `UP`.
6. Sequencer TX counter after the board sends a gratuitous ARP.
7. Sequencer RX counter after the host sends ping traffic.

The network phase checks:

1. ARP resolution for `192.168.137.200`.
2. MAC address in the host neighbor table, expected `02:00:00:00:00:01`.
3. ICMP echo replies, default `20/20` expected.

An optional longer ping check is available:

```bash
python fpga/arty_a7/scripts/serial_monitor.py --sustained-ping-count 50
```

Use `--sustained-ping-count N` only when investigating bring-up. Once a UDP
blast claims the TX arbiter, ICMP traffic is gated by the blast service holdoff
window, so ping latency stops tracking real link health. Use the bidirectional
regression below for sustained data-path tests.

## UDP Port Map

| Port | Direction | RTL block | Function |
|------|-----------|-----------|----------|
| UDP/5001 | host -> FPGA | `udp_iperf_sink` | Passive iperf2-format UDP sink. |
| UDP/5002 | FPGA -> host | `udp_blast` | Default host receive port for blast tests. |
| UDP/9996 | host -> FPGA -> host | `udp_stats_reply` | Binary stats query/clear for the iperf sink. |
| UDP/9997 | host -> FPGA | `udp_blast_trigger` | Trigger and configure FPGA UDP blast. |
| UDP/9999 | host -> FPGA -> host | `udp_echo` | UDP echo responder. |

## UDP Echo Test

```bash
python fpga/arty_a7/scripts/udp_echo_test.py --mbps 50 --secs 10
```

This sends timestamped UDP payloads to UDP/9999. The FPGA echoes each packet
with Ethernet/IP/UDP source and destination fields swapped. The script reports:

- host transmit rate,
- host receive echo rate,
- packet loss,
- RTT min/avg/max.

This is a good functional RX/TX parser check. It is not the primary line-rate
measurement because echo traffic is host-paced and bidirectional on the same
flow.

## FPGA-To-Host UDP Blast

```bash
python fpga/arty_a7/scripts/udp_blast_test.py --secs 3
```

The script binds a UDP socket, sends one trigger datagram to UDP/9997, and then
counts the FPGA-generated UDP payloads. The trigger payload is:

- 3 bytes: extra inter-frame delay in 100 MHz FPGA cycles,
- 4 bytes: burst packet count,
- 2 bytes: destination UDP port override.

Shorter trigger payloads are accepted. Missing fields fall back to RTL defaults:
no payload uses defaults, 3 bytes set delay only, and 7 bytes set delay plus
packet count.

The FPGA emits 1472-byte UDP payloads in iperf2 UDP datagram format. Sequence
ID is used for gap and out-of-order accounting. With `--ifg-cycles 0`, the FPGA
sends as fast as the 100 Mbps MII path and MAC backpressure allow.

The expected payload throughput at 100 Mbps with 1472-byte UDP payloads is
about 95 Mbps because Ethernet preamble, IFG, headers, and FCS consume the rest
of the wire rate.

## Host-To-FPGA Iperf Sink

The FPGA accepts iperf2-format UDP payloads on UDP/5001. The stats query block
returns counters on UDP/9996.

```bash
python fpga/arty_a7/scripts/udp_iperf_stats.py --clear
iperf -u -c 192.168.137.200 -p 5001 -b 90M -l 1472 -t 5 --no-udp-fin
python fpga/arty_a7/scripts/udp_iperf_stats.py
```

If host iperf2 is not installed, use the Python bidirectional test below with
`--host-mbps N`. It generates the same iperf2-format UDP payload header and
needs no external install.

The FPGA does not run a complete iperf server process. It implements the UDP
payload header parsing and counters needed to interoperate with host iperf2 UDP
traffic.

Counters reported by `udp_iperf_stats.py`:

- packet count,
- byte count,
- first and last sequence IDs,
- sequence gaps,
- out-of-order packets,
- iperf final packets,
- last source IP/port.

## Python Bidirectional Test

```bash
python fpga/arty_a7/scripts/udp_bidirectional_test.py --secs 5
```

This is the preferred self-contained bidirectional test because it avoids host
iperf installation and firewall quirks while still using the same FPGA RTL
interfaces.

It runs two directions at the same time:

- FPGA -> host: receive UDP/5002 after triggering UDP/9997.
- Host -> FPGA: send iperf2-format UDP payloads to UDP/5001 and query UDP/9996.

Important options:

- `--secs`: test duration.
- `--host-mbps`: host-to-FPGA payload target rate.
- `--fpga-ifg-cycles`: extra FPGA inter-frame delay in 100 MHz cycles.
- `--fpga-packets`: explicit FPGA burst packet count.
- `--min-mbps`: minimum measured payload throughput per direction.
- `--max-loss-pct`: maximum allowed sequence loss per direction.

## Hardware Regression Profiles

List profiles:

```bash
python fpga/arty_a7/scripts/run_hw_regression.py --list
```

Default smoke profile:

```bash
python fpga/arty_a7/scripts/run_hw_regression.py --profile bidirectional-smoke
```

This expands to a 5-second simultaneous UDP test:

```bash
python fpga/arty_a7/scripts/udp_bidirectional_test.py --secs 5 --host-mbps 70 --fpga-ifg-cycles 8000 --min-mbps 60 --max-loss-pct 1
```

Long profile:

```bash
python fpga/arty_a7/scripts/run_hw_regression.py --profile bidirectional-long
```

This expands to the current 60-second stress test:

```bash
python fpga/arty_a7/scripts/udp_bidirectional_test.py --secs 60 --host-mbps 99 --fpga-ifg-cycles 8000 --min-mbps 50 --max-loss-pct 5
```

`run_hw_regression.py` first sends a UDP/9996 stats query as a board
reachability probe. A failed probe means the board is not programmed, the host
NIC is not on the demo subnet, the Ethernet cable/link is down, or host firewall
rules are blocking UDP replies.

## Current Passing Measurements

Measured on Arty A7-100T, DP83848J MII at 100 Mbps full duplex, FPGA IP
`192.168.137.200`, host on the same `192.168.137.0/24` subnet, 1472-byte UDP
payloads.

| Test | Conditions | Result |
|------|------------|--------|
| UART/CSR/ARP/ICMP smoke | `serial_monitor.py`, default ICMP count | PASS, `VER=0001454D`, ICMP `20/20` |
| Bidirectional smoke | 5 s, host target 70 Mbps, FPGA IFG 8000 cycles | FPGA->host 95.16 Mbps, host->FPGA 70.00 Mbps |
| Bidirectional long | 60 s, host target 99 Mbps, FPGA IFG 8000 cycles | FPGA->host 95.15 Mbps, host->FPGA 95.78 Mbps |

The FPGA-to-host numbers are UDP payload Mbps, not raw wire Mbps. Near 95 Mbps
payload is expected on a 100 Mbps Ethernet link with 1472-byte UDP payloads.

## Troubleshooting

- No UART output: specify `--port PORT`; confirm the Arty USB UART channel is
  visible to the OS.
- UART sees version but link is down: check Ethernet cable, switch/NIC link,
  and PHY autonegotiation.
- UDP stats probe times out: confirm the release bitstream is programmed, the
  host NIC is on `192.168.137.0/24`, and firewall rules allow UDP replies.
- FPGA->host blast has high loss: increase host socket buffers if needed,
  reduce other host traffic, or use `--fpga-ifg-cycles` to add spacing.
- Host->FPGA has gaps: lower `--host-mbps`, check NIC offload/firewall behavior,
  and confirm full-duplex link from the UART `LINK: UP`/BMCR output or host
  tools such as `ethtool` on Linux.
- Windows Firewall may drop FPGA-to-host traffic that does not look like a
  reply to an outbound flow. The UDP blast and bidirectional scripts work
  around this by triggering from the same socket that receives the FPGA stream.
