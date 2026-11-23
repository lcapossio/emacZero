# Simulation

Requires [Icarus Verilog](http://iverilog.icarus.com/) (`iverilog` + `vvp` in
PATH), Verilator (`verilator` in PATH, or WSL `verilator` on Windows), and
Python 3. The normal test command runs Icarus lint, Verilator lint, and the full
directed simulation regression; Verilator runs before simulation so interface
drift such as missing module pins is caught early.

```bash
python build_and_test.py
```

`build_and_test.py` compiles with `-DSIM` so the behavioral DDR I/O models in
`ddr_input.v` / `ddr_output.v` are selected. For **synthesis** you must define a
target instead (`XILINX_7SERIES` for 7-series `IDDR`/`ODDR`,
`XILINX_ULTRASCALE_PLUS` for UltraScale+ `IDDRE1`/`ODDRE1`, or supply a real
vendor DDR atom); the `SIM` models are not synthesizable and the `INTEL_CYCLONE`
branch is a flagged stub, not a real Altera DDIO instance.

Where Vivado is on `PATH`, `PHASE 1b` also reruns the RGMII testbenches on
Vivado's own models of the DDR cells, for each family the wrappers support, so
the behavioral models cannot drift from the real cells unnoticed.
`python build_and_test.py --impl` also implements `rgmii_if` alone on an
xc7a100t and an xczu7ev for each `RGMII_SPEEDS` (about 10 minutes): every DDR
output cell must drive only its output buffer, place and route must complete,
and the internal paths must meet timing. No board build uses RGMII, so run it
after changing `rgmii_if.v` or the DDR wrappers.

`PHASE 2` runs the cocotb suites ([cocotb/](cocotb/)) on the Verilog
under Icarus. They include a port of every core testbench in `sim/tb/`, with
the same checks, plus directed and randomized suites with reference models.

The VHDL port ([rtl/vhdl/](../rtl/vhdl/)) is checked by three more phases, each
skipped, not failed, when its tool is missing:

- `PHASE 0d` analyses and elaborates it with GHDL, as VHDL-93, for every vendor
  target, then does the same for the L3 and board VHDL. Before that, without
  GHDL, it checks the generated parity models and the sensitivity lists of the
  combinational processes.
- `PHASE 1c` reruns the core testbenches against it in Vivado xsim.
- `PHASE 2b` runs the same cocotb suites against it under GHDL, so both
  languages pass exactly the same tests.

GHDL is used from `PATH`, or from WSL on Windows. The formal equivalence
proofs run separately (use GHDL 4.1 for them; with GHDL 6.0.0 four of them do
not close) with
[translateHDL](https://github.com/lcapossio/translateHDL), one manifest per
module and configuration in [parity/](parity/); see
[docs/vhdl_port.md](../docs/vhdl_port.md#reproducing-the-proofs).

## Core testbenches

The directed testbenches in [tb/](tb/), run under Icarus by
`build_and_test.py` (and against the VHDL port in xsim, `PHASE 1c`). The
cocotb suites are listed in [cocotb/README.md](cocotb/README.md).

| Test | Description | Checks |
|------|-------------|--------|
| CRC32 | Known test vectors, residue verification | 3 |
| ASYNC-FIFO | Async FIFO pointer, full/empty, wraparound behavior | 11 |
| ETH-MAC-FCS | FCS generation for multiple frame sizes | 4 |
| ETH-MAC-TX-PAD | Minimum-frame padding in `eth_mac_tx` and `mii_tx_saf`: 14/58/59/60/61-byte frames, wire length, zero pad, FCS | 31 |
| ETH-MAC-MULTIFRAME | Back-to-back frames, minimum padding, IFG | 1 |
| ETH-MAC-JUMBO | Jumbo-frame TX/RX behavior | 6 |
| MII-TX-BRIDGE | GMII-to-MII byte-to-nibble conversion | 1 |
| MII-TX-BURST-BACKPRESSURE | MII TX burst pacing under downstream stalls | 4 |
| MII-TX-SAF | Store-and-forward MII TX: bubbles, pad, byte-exact FCS | 6 |
| MII-TX-SAF-BURST-STALL | Many small frames backed up: committed-frame counter must not wrap/stall | 1 |
| MII-STORE-FORWARD | Store-and-forward CDC, frame toggle | 7 |
| MII-LOOPBACK | Full TX-to-RX loopback through MII | 1 |
| MII-RX-REPLAY-STRESS | RX frame-ready accounting under replay stalls | 7 |
| ETH-STATS | Statistics counters: increment, saturation, clear | 19 |
| AXILITE-REGS | AXI4-Lite CSR: all register behaviors | 35 |
| GMII-CDC | GMII CDC bridge: loopback, data integrity, back-to-back | 7 |
| ETH-MAC-SYS | Full integration: AXI-Lite config, MII loopback, stats, MDIO | 27 |
| RGMII-IF | RGMII DDR pin packing/unpacking at 1G | 14 |
| RGMII-IF-100M | 100M then 10M RGMII pin loopback, RX clocked by the forwarded TXC: low-nibble-first TX, byte-exact RX pairing, one unbroken `gmii_rx_dv` envelope per burst, TXC period and duty cycle, TXC edges >= 8 ns from data changes | 13 |
| RGMII-IF-SPEED-SWITCH | `cfg_speed` changed between every pair of 1G / 100M / 10M at all 50 TX counter phases (100M <-> 10M also through `11` for a cycle): every TXC high time is a full pulse of a speed in flight, no short low time, TXC low through reset, a byte-exact burst after each change | 6 |
| MCAST-FILTER | Multicast hash filter accept/drop behavior | 6 |
| ETH-MAC-RX-BACKPRESSURE | RX path holds frames when downstream stalls | 3 |
| ETH-MAC-RX-JUMBO-GATE | RX jumbo enable/disable length gate; 1518 untagged / 1522 VLAN-tagged standard limit; jumbo with a 1518 limit keeps the VLAN allowance; oversize stat pulses | 15 |
| ETH-MAC-RX-BYTE0 | RX byte-zero/start-of-frame handling | 4 |
| MDIO-MASTER | MDIO master read/write protocol, 1-bit shift fix | 10 |
| TX-CSUM-OFF | TX checksum inserter: exact IPv4 header and UDP checksums on a known frame | 5 |
| NET-RX | Ethernet/IPv4/ICMP/UDP parser coverage: IPv4 header and ICMP checksums, payload cut at the IPv4 total length, `terror` and truncated frames flagged, a frame cut at the end of its IPv4 header not affecting the next | 39 |
| ICMP-ECHO | ICMP echo responder packet generation | 35 |
| UDP-IPERF-SINK | iperf2 UDP header parsing, counters, gap tracking | 16 |
| UDP-BLAST-TRIGGER | trigger payload parsing and busy/port filtering | 13 |
| UDP-BLAST-START-DELAY | First-packet delay after UDP blast trigger | 7 |
| ARTY-TX-ARBITER | Arty six-source TX arbitration and blast holdoff | 9 |
| AXIL-ARB2 | 2:1 AXI4-Lite arbiter: independent RW channels, concurrency, hammer | 24 |
| UDP-BLAST-PATH | UDP trigger frame through `net_rx` into `udp_blast` TX | 9 |
| UDP-STATS-REPLY | binary stats query/clear responder packet generation | 19 |
| ETH-MAC-SYS-CSUM | Integrated TX checksum-offload path with `TX_CSUM_OFFLOAD=1`: exact IPv4 and UDP checksums on the wire | 7 |
| ETH-MAC-SYS-CSUM-BYPASS | Default `TX_CSUM_OFFLOAD=0` path ignores `CTRL[7]` and preserves checksums | 6 |
| ETH-MAC-SYS-CSUM-LOOP | TX and RX offload through MII loopback: inserted checksums accepted, wrong ones flagged with `terror` and counted in `RX_ERR_CSUM` / `RX_ERR` only with CTRL[9], counter clear; an IPv6 UDP checksum of 0 passes unjudged, a wrong one is flagged | 24 |
| ETH-MAC-SYS-JUMBO | Integrated jumbo-frame system path | 3 |
| GMII-CDC-100M | 100M rate adaptation pacing in gmii_cdc | 4 |
| GMII-CDC-10M | 10M rate adaptation pacing in gmii_cdc | 4 |
| RGMII-IF-VARIANTS | `RGMII_SPEEDS` variants: TX_CTL activity per variant, 8 ns TXC for `"1G_ONLY"`, 40 ns TXC from `clk_125` for `"10_100"` | 6 |
| RGMII-LOOPBACK | Full system + RGMII PHY loopback at 1G | 5 |
| RGMII-100M-LOOPBACK | Full system + RGMII pin-level loopback at 100M, RXC = forwarded TXC: min/MTU/back-to-back/9018-byte jumbo byte-exact, IFG >= 12 byte times, TXC period / duty / TXC-to-data distance | 15 |
| RGMII-10M-LOOPBACK | As RGMII-100M-LOOPBACK at 10M (no jumbo) | 14 |
| GMII-CDC-RX-OVERFLOW | RX CDC FIFO overflow: truncation tagged with `rx_er` on the last kept byte, whole-frame drop, EOF-only frames, no merged frames, recovery | 31 |
| GMII-LOOPBACK | Full system + GMII pin-level loopback at 1G: small/MTU/4000-byte/9018-byte jumbo byte-exact, back-to-back frames with IFG >= 12 byte times, oversize gate, GTX_CLK integrity | 27 |
| ETH-MAC-SYS-MAX-FRAME | `eth_mac_sys` with `MAX_FRAME=2000`: RX jumbo limit follows `MAX_FRAME`, VLAN-tagged 1522-byte frame accepted with jumbo off, `RX_ERR_OVERSIZE` | 8 |
| GMII-RX-LINE-RATE | Sustained 1G RX at line rate (minimum IFG, PHY clock +100 ppm, `clk` 125 MHz -100 ppm): 60 min/MTU/9018-byte frames byte-exact, no errors | 8 |
| ZCU106-I2C-INIT | ZCU106 Si5328 I2C write sequence against the register list, NACK retry at the alternate address | 3 |
| ZCU106-SFP-LB | ZCU106 loopback tester against the emacZero demo back to back: ARP / ICMP / UDP requests all answered exactly, a corrupted reply caught, frames for another MAC / IP / port or with a bad checksum / FCS / `tx_er` ignored, short (padded) payloads echoed exactly | 15 |
| ZCU106-PERF | ZCU106 demo throughput blocks on GMII at 1G: UDP blast of 1518- and 64-byte frames at exactly 100% of line rate (every gap 12 byte times, FCS and iperf2 sequence checked), iperf2 sink counting line-rate traffic, both at once, stats replies during a blast, a trigger during a burst's last frame ignored, MAC TX frame count read over AXI4-Lite | 17 |
