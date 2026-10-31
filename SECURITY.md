# Security Policy

emacZero is an open-source Verilog Ethernet MAC core. Security reports are
welcome, especially issues that can cause frame corruption, denial of service,
unsafe register behavior, clock-domain crossing failure, or integration hazards
in downstream FPGA or ASIC products.

## Supported Versions

Releases are published at https://github.com/lcapossio/emacZero/releases, each
with the regression log of its commit. The latest release (currently `v0.2.0`)
is the supported integration point; security fixes land on `main` and ship in
the next release. There are no release branches, so older releases, including
`v0.1.0`, are not patched; update to the latest release. No end-of-support date
has been set yet.

Integrators should pin a release tag and record the simulation, lint,
synthesis, and hardware evidence used for their product. The `main` branch is
the active development branch.

## Reporting a Vulnerability

Please report suspected vulnerabilities privately before opening a public issue.

- Email: hello@bard0.com
- GitHub private vulnerability reporting:
  https://github.com/lcapossio/emacZero/security/advisories/new
  (if the link does not open a report form, use email)
- Include: affected commit or tag, configuration parameters, toolchain, target
  FPGA or integration context, reproduction steps, and expected impact.
- Helpful artifacts: minimal testbench, waveform, packet capture, CSR trace, or
  synthesis/timing log.

If the vulnerability is being actively exploited, or you are a manufacturer
with an EU Cyber Resilience Act reporting obligation for it, put "ACTIVELY
EXPLOITED" in the subject line so it is handled ahead of other reports.
Manufacturers that find a vulnerability in emacZero while integrating it are
asked to report it here as well.

Reports should be acknowledged within 7 calendar days. Confirmed issues should
receive a remediation plan or status update within 30 calendar days. When a fix
is available, a changelog entry or advisory should be published within 90 days
unless coordinated disclosure with affected downstream integrators requires a
different schedule.

Fixes should be developed on a private branch when disclosure before remediation
would create avoidable risk for downstream users.

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
- Set `MAX_FRAME` explicitly: `eth_mac_sys` defaults to 9018 (jumbo-capable
  buffers); use 1518 unless jumbo frames are required.
- Program a unique MAC address before relying on the receive filter. By
  default (`TXRX_EN_AT_RESET=1`) the MAC leaves reset with TX and RX enabled
  on the placeholder address `02:00:00:00:00:01` (and, for the L3 helpers, IP
  `192.168.137.200`).
- Treat `m_axis_terror` frames as invalid and drop them at the system boundary.
- Respect AXI4-Stream backpressure and preserve `tlast` frame boundaries.
- Use the documented clock/reset topology for MII or RGMII mode.
- Run the full regression after changing parameters, wrappers, or toolchain
  versions.
- Review `docs/security_model.md` and `docs/cra-readiness.md` before shipping.
