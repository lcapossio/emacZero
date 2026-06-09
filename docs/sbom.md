# SBOM Guidance

emacZero does not currently check in a generated SPDX or CycloneDX SBOM. Until
one is published as a release artifact, downstream integrators should treat this
file as the repository's component-inventory guide and generate their own SBOM
from the exact release tag or commit they integrate.

## Recommended Format

Use CycloneDX JSON or SPDX 2.3. For RTL-centric products, include the HDL source
tree, simulation models, build scripts, examples, checked-in generated
artifacts, and optional submodules or third-party IP used by the selected target
configuration.

Recommended component coordinates:

- Supplier: `lcapossio`
- Component name: `emacZero`
- Component type: `library`
- Version: release tag, such as `v0.1.0`, or the full commit hash when no tag is
  used.
- Primary package URL, if supported by the SBOM tool:
  `pkg:github/lcapossio/emacZero@v0.1.0`

## Inventory Scope

Include these repository areas when they are present in the selected release:

| Area | Include | Notes |
|------|---------|-------|
| RTL | `rtl/` | Core MAC, PHY interfaces, CSR, CDC/FIFO, and optional helpers. |
| Testbenches | `tb/` | Directed simulation evidence and executable verification intent. |
| Scripts | `build_and_test.py`, `scripts/`, example build scripts | Capture tool orchestration, lint, simulation, synthesis, and hardware flows. |
| Documentation | `README.md`, `SECURITY.md`, `docs/`, `CHANGELOG.md` | Capture integration, security, register, and evidence guidance. |
| Examples | `examples/` | Include only examples used by the downstream product or evidence flow. |
| GitHub metadata | `.github/` | Include workflows and vulnerability-reporting metadata when release-packaged. |

Do not list host operating system packages, FPGA vendor tools, Python
installations, WSL distributions, or board files as emacZero components unless
they are vendored into the repository. Record those as product build-environment
dependencies instead.

## Release Evidence

For each downstream integration, retain:

- The release tag or full commit hash.
- The generated SBOM file and tool/version used to create it.
- `python build_and_test.py` output, including Verilator PHASE 0b status.
- Synthesis, implementation, timing, and hardware-test logs for the target
  FPGA, PHY mode, and parameter set.
- Any local patches applied after the tagged release.

## Open Work

- Add an automated SBOM generation flow.
- Publish generated SPDX or CycloneDX SBOM files with release artifacts.
- Define whether generated diagrams, logs, and vendor output products are
  included in release SBOMs or stored only as evidence artifacts.
