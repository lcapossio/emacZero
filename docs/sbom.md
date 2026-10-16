# SBOM Guidance

emacZero does not yet publish a generated SPDX or CycloneDX SBOM. Until one is
attached to each release, downstream integrators should treat this file as the
repository's component-inventory guide and generate their own SBOM from the
exact release tag or commit they integrate.

## Recommended Format

Use CycloneDX JSON or SPDX 2.3. For RTL-centric products, include the HDL
source files of the selected target configuration, plus any scripts,
simulation models, generated files, and third-party IP that the product's
build or evidence flow uses.

Recommended component coordinates:

- Supplier: `bard0 design` (GitHub owner `lcapossio`)
- Component name: `emacZero`
- Component type: `library`
- Version: release tag, such as `v0.2.0`, or the full commit hash when no tag is
  used. The VERSION CSR (`0x00`) reads `0x0002454D` for `v0.2.x`.
- Licence: `Apache-2.0`
- Primary package URL, if supported by the SBOM tool:
  `pkg:github/lcapossio/emacZero@v0.2.0`
- FuseSoC VLNV: `bard0:eth:emaczero:0.2.0`

## Inventory Scope

The FuseSoC core file `emaczero.core` is the authoritative list of HDL files
per configuration: the `default` target uses the `rtl_core` fileset, and
`with_l3` adds the optional L3 helpers in `rtl_l3`. List the files of the
target you build, not the whole repository.

| Area | Include | Notes |
|------|---------|-------|
| MAC RTL | `rtl/` per the `rtl_core` fileset, plus `rtl/version.vh` | Core MAC, PHY interfaces, CSR, CDC/FIFO, checksum offload. |
| Optional L3 RTL | `rtl/net/` per the `rtl_l3` fileset | Demo ICMP/UDP helpers; only when built. |
| Software | `sw/emaczero/` | C register map and driver helpers, if the product uses them. |
| LiteX wrapper | `litex_emaczero/` | Only for LiteX-based products. |
| Board ports | `fpga/arty_a7/`, `fpga/zcu106/` | Reference designs, not part of the core. The ZCU106 port generates AMD's 1G/2.5G Ethernet PCS/PMA IP at build time; list it as third-party IP if a product reuses that port. |
| Debug submodule | `fcapz` (fpgacapZero, pinned by the submodule commit) | Used only by the board debug builds, never by the core. |
| Verification | `build_and_test.py`, `sim/tb/`, `sim/cocotb/`, `tests/` | Executable verification intent and evidence. |
| Build scripts | `fpga/*/scripts/`, `fpga/scripts/` | Synthesis, implementation, and hardware-test flows. |
| Documentation | `README.md`, `SECURITY.md`, `CHANGELOG.md`, `docs/` | Integration, security, register, and evidence guidance. |
| Examples | `examples/` | Only examples used by the downstream product or evidence flow. |

The core has no third-party HDL dependencies. On Xilinx targets the DDR I/O
wrappers (`ddr_input`, `ddr_output`) instantiate vendor primitives (`IDDR`,
`ODDR`, `IDDRE1`, `ODDRE1`) that come from the synthesis tool's library.

Do not list host operating system packages, FPGA vendor tools, Python
installations, WSL distributions, or board files as emacZero components unless
they are vendored into the repository. Record those, with their versions, as
product build-environment dependencies instead; the synthesis tool version
matters for RTL because it produces the bitstream.

## Release Evidence

For each downstream integration, retain:

- The release tag or full commit hash.
- The generated SBOM file and tool/version used to create it.
- `python build_and_test.py` output, including Verilator PHASE 0b status (each
  GitHub release from `v0.2.0` carries this log for its commit).
- Synthesis, implementation, timing, and hardware-test logs for the target
  FPGA, PHY mode, and parameter set.
- Any local patches applied after the tagged release.

## Open Work

- Generate the SBOM in CI from the `emaczero.core` filesets.
- Attach generated SPDX or CycloneDX SBOM files to each GitHub release.
- Define whether generated diagrams, logs, and vendor output products are
  included in release SBOMs or stored only as evidence artifacts.
