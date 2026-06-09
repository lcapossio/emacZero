# Cyber Resilience Act Readiness

This document maps emacZero repository practices to EU Cyber Resilience Act
(CRA) preparation tasks. It is not legal advice and it is not a declaration of
conformity.

Regulation (EU) 2024/2847 entered into force on 2024-12-10. Vulnerability
reporting obligations apply from 2026-09-11, and the main product obligations
apply from 2027-12-11. Official references:

- European Commission: https://digital-strategy.ec.europa.eu/en/policies/cyber-resilience-act
- EUR-Lex Regulation text: https://eur-lex.europa.eu/eli/reg/2024/2847/oj

## Scope Position

emacZero is an open-source RTL component, not a complete end-user product by
itself. A manufacturer that integrates this core into a product with digital
elements and places that product on the EU market remains responsible for the
product-level CRA obligations, CE marking, conformity assessment, user
documentation, vulnerability handling, and update process.

This repository can still make that manufacturer work easier by maintaining
clear security documentation, component inventory, test evidence, vulnerability
handling, and release traceability.

## Current Readiness

| Area | Status | Evidence |
|------|--------|----------|
| Intended use | Partial | README, `docs/security_model.md` |
| Security assumptions | Partial | `docs/security_model.md` |
| Vulnerability reporting | Partial | `SECURITY.md`, `.github/SECURITY.md`; GitHub private vulnerability reporting must still be enabled in repo settings |
| Regression evidence | Good | `build_and_test.py`, README test matrix |
| Hardware evidence | Partial | Arty A7 README and checked logs, but not release-packaged |
| Dependency inventory | Partial | `docs/sbom.md`; no generated SPDX/CycloneDX SBOM checked in yet |
| Release support policy | Partial | `v0.1.0` tag exists; no long-lived support lifecycle yet |
| Advisory/changelog process | Partial | `CHANGELOG.md`, `.github/ISSUE_TEMPLATE/security_advisory.md`; no published GHSA yet |
| Fuzzing/formal evidence | Gap | Directed tests only |
| Product documentation | Integrator task | Depends on downstream product |

## CRA-Oriented Controls

| CRA preparation need | emacZero action |
|----------------------|-----------------|
| Secure-by-design assumptions | Maintain `docs/security_model.md` with assets, trust boundaries, non-goals, and hardening guidance. |
| Known-vulnerability handling | Keep `SECURITY.md` current, use private reporting before public disclosure, and enable GitHub private vulnerability reporting for GHSA tracking. |
| Component identification | Maintain `docs/sbom.md`, then generate and publish an SBOM for RTL, scripts, simulation models, examples, and optional submodules. |
| Security update traceability | Tag releases, record fixed vulnerabilities, and document supported branches. |
| Risk reduction by default | Keep promiscuous mode, jumbo mode, checksum offload, debug capture, and optional L3 helpers opt-in or controlled by documented configuration. |
| Evidence of testing | Preserve simulation, lint, synthesis, timing, and hardware-test results for each release. |
| User/integrator instructions | Document clock/reset, PHY, AXI, MDIO, register, and error-handling requirements. |

## Security Test Traceability

| Security property | Existing coverage |
|-------------------|-------------------|
| CRC/FCS correctness | `CRC32`, `ETH-MAC-FCS` |
| Minimum frame padding and IFG | `ETH-MAC-MULTIFRAME`, `ETH-MAC-JUMBO` |
| RX backpressure | `ETH-MAC-RX-BACKPRESSURE`, `MII-STORE-FORWARD` |
| Jumbo frame gating | `ETH-MAC-RX-JUMBO-GATE`, `ETH-MAC-SYS-JUMBO` |
| Multicast filtering | `MCAST-FILTER` |
| AXI4-Lite register behavior | `AXILITE-REGS`, `ETH-MAC-SYS` |
| Statistics/counter behavior | `ETH-STATS`, `ETH-MAC-SYS` |
| MDIO sequencing | `MDIO-MASTER`, `ETH-MAC-SYS` |
| CDC and FIFO behavior | `ASYNC-FIFO`, `GMII-CDC`, `MII-RX-REPLAY-STRESS` |
| RGMII speed handling | `RGMII-IF`, `RGMII-IF-100M`, `RGMII-IF-VARIANTS`, `RGMII-LOOPBACK` |
| Optional L3 helper behavior | `NET-RX`, `ICMP-ECHO`, `UDP-IPERF-SINK`, `UDP-BLAST-*`, `UDP-STATS-REPLY` |
| TX checksum offload | `TX-CSUM-OFF`, `ETH-MAC-SYS-CSUM`, `ETH-MAC-SYS-CSUM-BYPASS` |

## Release Checklist

Before declaring a commit suitable for downstream product integration:

- Run `python build_and_test.py` and record the full output.
- Run synthesis, implementation, and timing for the supported target matrix.
- Run hardware smoke/regression tests for supported boards.
- Regenerate the SBOM using `docs/sbom.md` as the component-inventory guide.
- Review open security issues and document known residual risks.
- Update `README.md`, `docs/security_model.md`, and this file if behavior or
  support scope changed.
- Tag the release and record the commit hash in downstream product evidence.

## Backlog

Recommended next steps:

- Generate an SPDX or CycloneDX SBOM as a release artifact.
- Enable GitHub private vulnerability reporting in repository Settings >
  Security so GHSA draft advisories can be created.
- Publish the first GHSA if a confirmed vulnerability is fixed.
- Define a support policy for release branches and end-of-support dates.
- Add malformed-frame fuzz tests or a bounded formal harness for selected
  parser/FIFO properties.
- Add standalone synthesis harnesses for `eth_mac`, `eth_mac_sys` MII, and
  `eth_mac_sys` RGMII configurations.
