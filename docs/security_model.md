# emacZero Security Model

This document describes the intended security posture of emacZero as an RTL
component. It is written for integrators who need to decide whether the core is
appropriate for a product and what evidence they must keep around it.

## Intended Use

emacZero is a Verilog 2001 Ethernet MAC core for FPGA or ASIC designs. It
provides MII or RGMII PHY-facing logic, AXI4-Stream packet interfaces,
AXI4-Lite control/status registers, MDIO management, statistics, optional
checksum offload, and optional demo L3 helpers.

The core is intended to sit below a trusted system wrapper, CPU, DMA engine, or
packet-processing pipeline. It does not authenticate peers, encrypt traffic, or
make network-layer security decisions.

## Assets

The core is expected to protect:

- Frame integrity across TX/RX datapaths.
- Frame boundaries and error indication on AXI4-Stream interfaces.
- Availability of the MAC datapath under legal Ethernet traffic and bounded
  malformed input.
- Correctness of control/status registers and statistics.
- Isolation between PHY clock domains and the system clock domain.

The core does not protect secrets. Any secret-bearing protocol must be
implemented above emacZero.

## Trust Boundaries

Untrusted inputs:

- MII/RGMII receive pins and all Ethernet frame contents.
- MDIO read data from the external PHY.
- AXI4-Lite writes from system software unless the integrator restricts access.
- AXI4-Stream TX input if it is driven by software, DMA, or another untrusted
  block.

Trusted or integration-controlled inputs:

- Clocks, resets, and PHY mode selection.
- Static parameters such as `PHY_INTERFACE`, `MAX_FRAME`, `MCAST_HASH_FILTER`,
  `TX_CSUM_OFFLOAD`, and `MII_DEBUG`.
- Board timing constraints and vendor primitive selection.

## Security Assumptions

emacZero assumes:

- The system supplies valid, stable clocks for the selected PHY mode.
- Resets are asserted long enough for all clock domains and FIFOs.
- AXI4-Stream producers obey the ready/valid contract and eventually assert
  `tlast` for each frame.
- AXI4-Stream consumers either accept frames or apply backpressure within the
  documented buffering limits.
- Product software treats CRC/error-marked RX frames as invalid.
- The PHY and board-level timing satisfy the relevant Ethernet electrical and
  timing requirements.

Violating these assumptions can create denial of service, dropped frames,
truncated frames, or corrupted packet streams.

## Threats Considered

The regression suite and architecture focus on these realistic RTL threats:

- Malformed, undersized, oversized, or CRC-invalid Ethernet frames.
- Back-to-back packets, minimum-frame padding, IFG enforcement, and jumbo frame
  gating.
- RX backpressure and downstream stalls.
- TX producer starvation or FIFO pressure during MII store-and-forward
  operation.
- Async FIFO full/empty behavior and clock-domain crossing replay hazards.
- RGMII speed adaptation at 10/100/1000 Mbps.
- CSR misuse, interrupt clearing, and counter saturation/clear behavior.
- MDIO transaction sequencing.
- Optional L3 demo parser behavior for ICMP and UDP helper blocks.

## Non-Goals

emacZero does not provide:

- Cryptographic authentication, confidentiality, or replay protection.
- Firewall, ACL, TCP/IP stack, TLS, MACsec, or secure management-plane logic.
- Protection against malicious privileged software that can freely write the
  control registers.
- A complete product safety case, product risk assessment, or regulatory
  conformity assessment.

## Security-Relevant Configuration

Key controls for product integrators:

| Setting | Security impact |
|---------|-----------------|
| `MAX_FRAME` | Caps accepted RX frame size. Use the smallest product-compatible value. |
| `jumbo_en` | Enables frames above standard Ethernet size. Keep disabled unless needed. |
| `promisc` | Accepts frames outside the configured MAC/filter. Keep disabled by default. |
| `MCAST_HASH_FILTER` | Adds multicast acceptance surface. Program only required groups. |
| `TX_CSUM_OFFLOAD` | Lets hardware overwrite IPv4 header and TCP / UDP / ICMP / ICMPv6 checksums (CTRL[7]). Validate software expectations. |
| `RX_CSUM_OFFLOAD` | With CTRL[9], drops frames whose IP / L4 checksum is wrong. It does not check fragments, IPv6 extension headers or tunnels, so software that trusts it must still verify those. |
| `MII_DEBUG` | Keeps extra debug capture logic. Keep disabled in production builds. |

## Evidence Already Present

The repository includes directed simulation coverage for:

- CRC/FCS generation and checking.
- Async FIFO behavior.
- MII and RGMII datapaths.
- Backpressure, jumbo gating, multicast filtering, and byte-zero handling.
- AXI4-Lite register behavior.
- MDIO master behavior.
- Integrated system paths, checksum offload, and optional L3 demo helpers.

Run:

```bash
python build_and_test.py
```

On Windows, PHASE 0b requires either a native Verilator install or a WSL
Verilator install, which `build_and_test.py` auto-detects. Product evidence
should record whether Verilator lint, synthesis, timing, and hardware tests were
run for the exact commit and target.

## Residual Risks

Before using emacZero in a product, integrators should close or explicitly
accept these gaps:

- No machine-readable SBOM is checked in yet.
- No signed release process exists yet, and no GHSA has been published yet.
- No fuzzing or formal verification harness is currently checked in.
- Standalone resource/timing matrices are not yet maintained for every target
  FPGA, PHY mode, and parameter set.
- Optional L3 helpers are demo-oriented and should be reviewed before product
  use.
