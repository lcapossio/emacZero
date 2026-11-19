# Contributing to emacZero

## Before a change

- Run `python build_and_test.py` (lint, the Icarus regression and the cocotb
  suites); see [sim/README.md](sim/README.md). A change to the VHDL port also
  needs its parity proofs ([docs/vhdl_port.md](docs/vhdl_port.md)).
- Update the docs and [CHANGELOG.md](CHANGELOG.md) with the change.

## Versioning

The MAJOR/MINOR/ID values that build the VERSION CSR (`0x00`) are defined
exactly once in [`rtl/version.vh`](rtl/version.vh):

```verilog
`define EMZ_VERSION_MAJOR 8'h00
`define EMZ_VERSION_MINOR 8'h02
`define EMZ_VERSION_ID    16'h454D  // ASCII "EM"
```

`axilite_regs.v` `` `include "version.vh" `` builds the 32-bit constant from
the three defines, so the simulator and synthesised CSR always agree.

Three derived files mirror the same numbers:

- [`sw/emaczero/emaczero.h`](sw/emaczero/emaczero.h) — `EMZ_VERSION_MAJOR /
  MINOR / ID` for the bare-metal driver.
- [`emaczero.core`](emaczero.core) — `name: bard0:eth:emaczero:<MAJOR>.<MINOR>.0`
  for FuseSoC.
- [`rtl/vhdl/emz_version_pkg.vhd`](rtl/vhdl/emz_version_pkg.vhd) — the same
  constants for the VHDL port.

`build_and_test.py`'s `PHASE 0a: Version consistency` parses all four on
every run and fails if they disagree, so you cannot ship a mismatched bump.
To change the version, edit `rtl/version.vh` and update the three mirrored
constants in lockstep.

Releases are published as tags and GitHub releases
(https://github.com/lcapossio/emacZero/releases), each with the regression
log of its commit; [CHANGELOG.md](CHANGELOG.md) lists the changes and
security-relevant fixes of each one. The latest release is the supported
version.
