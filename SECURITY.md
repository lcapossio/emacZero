# Security Policy

emacZero is an open-source Verilog Ethernet MAC core. Security reports are
welcome, especially issues that can cause frame corruption, denial of service,
unsafe register behavior, clock-domain crossing failure, or integration hazards
in downstream FPGA or ASIC products.

## Supported Versions

The `main` branch is the active development branch. Tagged releases, once
published, should be treated as the supported integration points for downstream
products. Until a formal release train exists, integrators should pin a tested
commit and record the simulation, lint, synthesis, and hardware evidence used
for their product.

## Reporting a Vulnerability

Please report suspected vulnerabilities privately before opening a public issue.

- Email: hello@bard0.com
- Include: affected commit or tag, configuration parameters, toolchain, target
  FPGA or integration context, reproduction steps, and expected impact.
- Helpful artifacts: minimal testbench, waveform, packet capture, CSR trace, or
  synthesis/timing log.

Reports will be acknowledged as soon as practical. Fixes should be developed on
a private branch when disclosure before remediation would create avoidable risk
for downstream users.

## Disclosure Expectations

For confirmed vulnerabilities:

- Assign severity based on exploitability in realistic integrations.
- Document affected configurations and mitigations.
- Add or update regression tests that fail before the fix.
- Publish a changelog entry or advisory when a fixed commit or release is
  available.

## Security Scope

In scope:

- Ethernet frame parsing, filtering, CRC/FCS handling, padding, jumbo gating,
  PAUSE behavior, and statistics.
- AXI4-Stream TX/RX contracts, backpressure, frame boundaries, and error flags.
- AXI4-Lite control/status behavior, MDIO command handling, interrupts, and
  clear-on-write counters.
- MII/RGMII clock-domain crossings, async FIFO behavior, reset sequencing, and
  speed adaptation.
- Optional L3 demo helpers under `rtl/net/`.

Out of scope:

- Security of the host CPU, DMA engine, operating system, network stack, PHY,
  board design, clock generator, or downstream packet buffers.
- Secrets, authentication, encryption, secure boot, or anti-tamper features.
  emacZero does not implement those functions.
- Product-level CE marking or Cyber Resilience Act conformity. Those remain the
  responsibility of the manufacturer placing a product on the EU market.

## Hardening Guidance

Integrators should:

- Keep `promisc` disabled unless explicitly required.
- Set `MAX_FRAME` and `jumbo_en` to the smallest values needed by the product.
- Treat `m_axis_terror` frames as invalid and drop them at the system boundary.
- Respect AXI4-Stream backpressure and preserve `tlast` frame boundaries.
- Use the documented clock/reset topology for MII or RGMII mode.
- Run the full regression after changing parameters, wrappers, or toolchain
  versions.
- Review `docs/security_model.md` and `docs/cra-readiness.md` before shipping.
