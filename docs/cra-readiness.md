# Cyber Resilience Act Readiness

This document maps emacZero repository practices to EU Cyber Resilience Act
(CRA) preparation tasks. It is not legal advice and it is not a declaration of
conformity. Last reviewed 2026-10-22, against release `v0.2.0` and `main`.

Regulation (EU) 2024/2847 entered into force on 2024-12-10. The vulnerability
and incident reporting obligations of Article 14 have applied since
2026-09-11: a manufacturer must report an actively exploited vulnerability or a
severe incident through ENISA's single reporting platform within 24 hours
(early warning), 72 hours (notification) and 14 days after a fix is available
(final report). The main product obligations apply from 2027-12-11. Official
references:

- European Commission: https://digital-strategy.ec.europa.eu/en/policies/cyber-resilience-act
- EUR-Lex Regulation text: https://eur-lex.europa.eu/eli/reg/2024/2847/oj
- Commission guidance on applying the CRA, C(2026) 5252 (2026-07-27), linked
  from the Commission page above.

## Scope Position

emacZero is an open-source RTL component, not a complete end-user product by
itself. A manufacturer that integrates this core into a product with digital
elements and places that product on the EU market remains responsible for the
product-level CRA obligations, CE marking, conformity assessment, user
documentation, vulnerability handling, and update process. That manufacturer
must also exercise due diligence on the components it integrates, including
open-source ones, and report vulnerabilities it finds in them to the
component's maintainer; `SECURITY.md` is that channel for emacZero.

A product whose core function is a network interface (a NIC, an FPGA
Ethernet board) is plausibly in Annex III, class I ("physical and virtual
network interfaces"; technical description in Implementing Regulation (EU)
2025/2392). Class I products cannot use self-assessment alone unless they
apply a harmonised standard, so integrators of such products may ask for more
evidence than a plain component would need. This is a reading of the category
text, not a classification of emacZero itself.

### Maintainer role

Which obligations fall on the emacZero maintainer depends on how the core is
supplied. The maintainer has not yet stated which of these applies:

| Position | Consequence for the core |
|----------|--------------------------|
| Free and open-source software, not monetised | Outside the CRA as a product. The work in this document exists to support downstream manufacturers' due diligence. |
| Open-source steward (a legal person that systematically supports the development of open source intended for commercial use) | A lighter regime: a documented cybersecurity policy, cooperation with market surveillance authorities, and reporting of actively exploited vulnerabilities and severe incidents to the extent the steward is involved in development. |
| Monetised (paid support or integration, or placed on the market in the maintainer's own products) | The maintainer is a manufacturer for those products, with the full obligations from 2027-12-11 and Article 14 reporting now. |

## Current Readiness

| Area | Status | Evidence / gap |
|------|--------|----------------|
| Intended use | Partial | README, `docs/security_model.md` |
| Security assumptions and threat model | Partial | `docs/security_model.md`; not yet mapped item by item to Annex I |
| Maintainer role under the CRA | Gap | Not yet stated (see above) |
| Versions integrators can pin | Good | `v0.2.0` published as a GitHub release with its regression log; `v0.1.0` tag pushed for history |
| Support period | Good | Stated in `SECURITY.md`: only the latest release is supported, and a release stops receiving fixes when the next one is published. No fixed end-of-support date |
| Vulnerability reporting | Good | `SECURITY.md`: email, or GitHub private vulnerability reporting (enabled 2026-10-22) |
| Handling of actively exploited issues | Partial | `SECURITY.md` asks reporters to flag them; no published turnaround for that case |
| Published fixes | Partial | `CHANGELOG.md` has a Security section from `v0.2.0`; no CVE or GHSA has been issued |
| Dependency inventory (SBOM) | Partial | `docs/sbom.md`; no generated SPDX/CycloneDX SBOM per release yet |
| Regression evidence | Good | `build_and_test.py` in CI on every push and pull request, including the cocotb suites on the VHDL port; log attached to each release |
| Hardware evidence | Partial | Arty A7 and ZCU106 results in the READMEs and CHANGELOG, measured on development commits, not re-run per release. The VHDL port ran on the Arty A7 (smoke, regression and a 30-minute soak) on 2026-10-21 |
| Secure defaults | Partial | `promisc`, `jumbo_en`, PAUSE RX, checksum offload and `MII_DEBUG` are off at reset. `eth_mac_sys` defaults to `MAX_FRAME=9018` (the FuseSoC core uses 1518), and the MAC leaves reset with TX and RX enabled on placeholder MAC `02:00:00:00:00:01` and IP `192.168.137.200` |
| Build reproducibility | Partial | CI pins GitHub Actions by major tag and the runner image (Ubuntu 24.04), and the parity workflow pins translateHDL and yowasp-yosys. `iverilog`, `verilator` and `ghdl` come from that image's apt, and `cocotb>=2.0` is unpinned |
| Fuzzing / formal evidence | Partial | The VHDL port is formally proven equivalent to the Verilog in CI (`sim/parity/`, translateHDL). That shows the two languages agree, not that the design is correct. The design itself has directed and randomised simulation only (cocotb suites with a replayable seed), and no fuzzing or property proofs |
| Release integrity | Gap | Tags and releases are not signed |
| Product documentation | Integrator task | Depends on downstream product |

## CRA-Oriented Controls

| CRA preparation need | emacZero action |
|----------------------|-----------------|
| Secure-by-design assumptions | Maintain `docs/security_model.md` with assets, trust boundaries, non-goals, and hardening guidance. |
| Known-vulnerability handling | Keep `SECURITY.md` current, use private reporting before public disclosure, and enable GitHub private vulnerability reporting for GHSA tracking. |
| Component identification | Maintain `docs/sbom.md`, then generate and publish an SBOM for each release from the FuseSoC filesets in `emaczero.core`. |
| Security update traceability | Publish each release as a tag and GitHub release, record security-relevant fixes under `### Security` in `CHANGELOG.md` with the affected versions, and state the support period. |
| Risk reduction by default | Keep promiscuous mode, jumbo mode, checksum offload, debug capture, and optional L3 helpers opt-in or controlled by documented configuration. |
| Evidence of testing | Attach the regression log to each release; keep synthesis, timing, and hardware-test results with the commit they were measured on. |
| User/integrator instructions | Document clock/reset, PHY, AXI, MDIO, register, and error-handling requirements. |

## Security Test Traceability

| Security property | Existing coverage |
|-------------------|-------------------|
| CRC/FCS correctness | `CRC32`, `ETH-MAC-FCS` |
| Minimum frame padding and IFG | `ETH-MAC-MULTIFRAME`, `ETH-MAC-TX-PAD`, `ETH-MAC-JUMBO` |
| RX frame limits, runts, counter saturation | `ETH-MAC-RX-JUMBO-GATE`, `ETH-MAC-SYS-JUMBO`, `ETH-MAC-SYS-MAX-FRAME`; cocotb `eth_mac_rx_robust` |
| RX backpressure and overflow framing | `ETH-MAC-RX-BACKPRESSURE`, `MII-STORE-FORWARD`; cocotb `eth_mac_rx_robust` |
| TX wedge and oversize protection | `MII-TX-SAF`, `MII-TX-SAF-BURST-STALL`, `MII-TX-SAF-OVERSIZE`, `MII-TX-BURST-BACKPRESSURE` |
| Multicast filtering | `MCAST-FILTER`; cocotb `eth_mac_rx_mcast` |
| 802.3x PAUSE validation | `ETH-MAC-SYS-PAUSE` |
| AXI4-Lite register behavior | `AXILITE-REGS`, `ETH-MAC-SYS` |
| Statistics/counter behavior | `ETH-STATS`, `ETH-MAC-SYS` |
| MDIO sequencing | `MDIO-MASTER`, `ETH-MAC-SYS` |
| CDC and FIFO behavior | `ASYNC-FIFO`, `ASYNC-FIFO-BLOCK`, `GMII-CDC`, `GMII-CDC-RX-OVERFLOW`, `GMII-CDC-RX-OVERFLOW-DIST`, `GMII-RX-LINE-RATE`, `MII-RX-REPLAY-STRESS` |
| RGMII speed handling | `RGMII-IF`, `RGMII-IF-100M`, `RGMII-IF-SPEED-SWITCH`, `RGMII-IF-VARIANTS`, `RGMII-LOOPBACK`, `RGMII-100M-LOOPBACK`, `RGMII-10M-LOOPBACK` |
| Optional L3 helper behavior | `NET-RX`, `ICMP-ECHO`, `ICMP-ECHO-SIZES`, `UDP-IPERF-SINK`, `UDP-BLAST-*`, `UDP-STATS-REPLY`, `*-BACKPRESSURE` |
| TX / RX checksum offload | `TX-CSUM-OFF`, `ETH-MAC-SYS-CSUM`, `ETH-MAC-SYS-CSUM-BYPASS`, `ETH-MAC-SYS-CSUM-LOOP`; cocotb `csum_calc`, `tx_csum_off`, `eth_mac_rx_csum` |

## Release Checklist

Before publishing a release for downstream product integration:

- Run `python build_and_test.py` on a clean checkout of the release commit and
  keep the full output; confirm the `sim` workflow passed on the same commit.
- Run synthesis, implementation, and timing for the supported target matrix.
- Run hardware smoke/regression tests for supported boards, or state in the
  release notes which commit the hardware results were measured on.
- Regenerate the SBOM using `docs/sbom.md` as the component-inventory guide.
- Review open security issues; list security-relevant fixes under
  `### Security` in `CHANGELOG.md` with the versions they affect.
- Bump `rtl/version.vh`, `sw/emaczero/emaczero.h` and `emaczero.core`
  together (`build_and_test.py` checks they agree).
- Update `README.md`, `docs/security_model.md`, and this file if behavior or
  support scope changed.
- Push an annotated tag and publish a GitHub release with the regression log
  attached.

## Backlog

Recommended next steps, most important first:

- State the maintainer's role under the CRA (see Maintainer role), and add a
  turnaround for actively exploited reports to `SECURITY.md`.
- Generate a CycloneDX or SPDX SBOM in CI from the `emaczero.core` filesets and
  attach it to each release.
- Make `MAX_FRAME=1518` the `eth_mac_sys` default, and consider leaving TX and
  RX disabled at reset until software has programmed the MAC address.
- Pin CI tool and action versions so release evidence can be reproduced.
- Add malformed-frame fuzz tests or a bounded formal harness for selected
  parser/FIFO properties.
- Sign release tags.
- Add standalone synthesis harnesses for `eth_mac`, `eth_mac_sys` MII, and
  `eth_mac_sys` RGMII configurations.
