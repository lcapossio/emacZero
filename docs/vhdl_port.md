# VHDL port

`rtl/vhdl/` holds a VHDL-93 translation of the emacZero core (`rtl/eth_mac_sys.f`).
The Verilog in `rtl/` stays the golden source. Each VHDL file is checked against
its Verilog original with the [translateHDL](https://github.com/lcapossio/translateHDL)
parity ladder, whose main evidence is a formal sequential-equivalence proof
(Yosys `equiv_induct`).

Status: all 20 modules of `rtl/eth_mac_sys.f` are ported, on `feat/vhdl-port`.
Every proof is against the Verilog of v0.2.0 (23d39e8). The `rtl/net/` L3
add-ons are not ported yet.

## Status

Every module passes L0 (interface), L1 (lint) and L2 (formal equivalence)
with `--strict`, and L4 (synthesised cell count within the listed tolerance)
wherever it is enabled. Parameters not listed are the Verilog defaults.

| Module | Proven configs (L2) | L4 tol. |
| --- | --- | --- |
| `crc32` | default | 10% |
| `csum_calc` | default | 10% |
| `sync_fifo` | DW=4/AW=2, DW=11/AW=3 | 10% |
| `async_fifo` | DW=4/AW=2, DW=10/AW=3; RAM_STYLE DISTRIBUTED and BLOCK | 10% |
| `ddr_output` | SIM, INTEL_CYCLONE, XILINX_7SERIES, XILINX_ULTRASCALE_PLUS (NONE: output deliberately undriven, L0/L1/L4 only) | 10% (vendor targets: n/a) |
| `ddr_input` | SIM, INTEL_CYCLONE, XILINX_7SERIES, XILINX_ULTRASCALE_PLUS (NONE: output deliberately undriven, L0/L1/L4 only) | 10% (vendor targets: n/a) |
| `gmii_if` | SIM, INTEL_CYCLONE (no logic of its own depends on the target; the Xilinx DDR branches are proven in `ddr_output`) | 10% |
| `rgmii_if` | RGMII_SPEEDS ALL, 1G_ONLY, 10_100 | 10% |
| `mii_if` | MII_DEBUG=0 with TX_ENABLE 1 and 0; XILINX_7SERIES (XPM models) and the other targets (RX frame RAM cut to 8 words) | 10% |
| `mii_tx_saf` | MAX_FRAME 7/31 at FIFO AW=5, MAX_FRAME 100 at AW=7 | 10% |
| `mdio_master` | default, CLK_FREQ_HZ 125 MHz and 1 MHz | 25% |
| `axilite_regs` | MCAST_HASH_FILTER 0 and 1 | 40% |
| `eth_stats` | default, STAT_CNT_W=3 | 10% |
| `eth_pause` | default, two TICK_DIV sets (incl. 0 and 17-bit dividers) | 30% |
| `eth_mac_tx` | MAX_FRAME 1518 and 9018 | 10% |
| `eth_mac_rx` | MCAST_HASH_FILTER × RX_CSUM_OFFLOAD, RX FIFO AW 2 to 4 | 10% |
| `tx_csum_off` | MAX_FRAME 6/20/60, buffer AW 3 to 6 | 10% |
| `gmii_cdc` | default, MAX_FRAME=1518 | 10% |
| `eth_mac` | MAX_FRAME=1518, MII_DEBUG=0, flattened | 15% |
| `eth_mac_sys` | PHY_INTERFACE MII (100 MHz), GMII and RGMII (125 MHz), MAX_FRAME=1518, flattened | 15% |

Not proven:
- `MII_DEBUG=1`. Its debug capture arrays are split per word by Yosys and kept
  whole by GHDL, so the state cannot pair by name. It is used by two
  testbenches only.
- `mii_if`'s inline 4096x9 RX frame RAM at full depth on the non-Xilinx
  targets. The solver does not finish. The proofs use a generated copy with
  the RAM cut to 8 words on both sides; the addressing logic keeps its full
  width.

The higher L4 tolerances are for state machines: GHDL lowers a `case` to a
one-hot decode, roughly doubling the `$eq` cells. Flop counts match.

`sim/parity/harness_*` hold proofs for the simulation side: the wiring
harnesses of the cocotb suites (`sim/cocotb/hdl/`) and the VHDL twins of the
XPM simulation models, each against its Verilog original.

## Reproducing the proofs

Needs GHDL, Python 3 with `pyyaml`, and a Yosys with `rename -unescape`
(tested: GHDL 4.1, yowasp-yosys 0.63). translateHDL must be at be0ba18 or
later, which adds string parameters, a flattened L4, name-collision and
generate-scope pairing, and checks the base case of every induction proof
from the initial state. Point `YOSYS`/`GHDL` at the binaries if they are not
on `PATH` under those names.

Last full run: every manifest as VHDL-93 (61 configurations proven), GHDL 4.1
with yowasp-yosys 0.63 under WSL, translateHDL be0ba18 (2026-10-20). With GHDL 6.0.0 on Windows, `eth_mac`,
`eth_mac_rx`, `eth_mac_sys` and `tx_csum_off` leave `$equiv` cells unproven
(the same with older translateHDL); use GHDL 4.1 for those.

```sh
# everything (module directories in parallel, -j N), or name some modules
python sim/parity/run_all.py --translatehdl <translateHDL> [-j N] [module ...]
# one manifest
cd sim/parity/<module>
python <translateHDL>/skills/translate-hdl/scripts/parity.py parity.yml --strict
```

Each manifest in [sim/parity/](../sim/parity/) lists its modules and parameter
sets. Run the manifests of one directory one after another: they share a GHDL
work library there. `run_all.py` does that, then runs any `prove_*.py` in the
directory: proofs that drive translateHDL's L2 directly where a manifest
cannot express them (`rgmii_if` with the real DDR cells of every target). It
exits 1 if anything does not pass.

CI runs every manifest on every push and pull request to `main`
([.github/workflows/parity.yml](../.github/workflows/parity.yml), one job
running `run_all.py -j 4`, Ubuntu 24.04's GHDL 4.1). translateHDL and yowasp-yosys are pinned in
that workflow. Bump them there, and rerun everything when you do.

## Proof assumptions

- **Clock model `clk2fflogic`.** Clocks and async resets are solver inputs. The
  proof covers every interleaving of every clock, and a register on the wrong
  clock, edge or reset is a divergence.
- **Small parameter sets.** The RAMs are mapped to flops for the solver, so
  FIFOs are proven at depths of 4 to 8 words. The RTL is parametric in width
  and depth. Production sizes are covered by simulation only (see below).
- **Uninitialised state** (RAM contents, unreset output registers) is assumed
  equal on both sides. It is paired by name after `rename -unescape`.
- **String parameters** (`PHY_INTERFACE`, `RGMII_SPEEDS`) are set directly in
  the manifests. `async_fifo.RAM_STYLE = "BLOCK"` still goes through the
  one-instance wrapper in `sim/parity/async_fifo/`.
- **Stand-ins**, read identically by both sides:
  - `sim/parity/gmii_cdc/async_fifo_smallmem.{v,vhd}`: `async_fifo` with only
    the memory clamped to 8 words. Pointers, Gray synchronisers and flags keep
    their real widths. It is used where a 4K- or 16K-word FIFO would not fit
    the solver (`gmii_cdc`, `mii_if`, `eth_mac`, `eth_mac_sys`), and is itself
    proven equivalent across languages at those parameter sets.
  - `sim/parity/mii_if/mii_if_smallram.{v,vhd}`: `mii_if` with the RX frame
    RAM cut to 8 words, generated from the real files by `gen_smallram.py`.
    `build_and_test.py` fails if the copies are out of date. Used by the
    `mii_if`, `eth_mac` and `eth_mac_sys` (MII) proofs.
  - `sim/parity/stubs/ddr_standin.{v,vhd}`: stateless DDR cells inside
    `rgmii_if`'s for-generates in the `eth_mac_sys` proof.
  - `sim/parity/stubs/xilinx_ddr_prims.{v,vhd}` and `xpm_macros.{v,vhd}`:
    behavioural models of ODDR/IDDR/ODDRE1/IDDRE1 and the XPM macros, so the
    vendor branches can be proven. They check the wiring around the primitive,
    not the primitive itself.
- **Hierarchy.** Each module is proven on its own. `eth_mac` and `eth_mac_sys`
  are also proven flattened with all their submodules, which covers their glue
  logic and the generic plumbing.
- **Vendor target.** The golden side reads `sim/parity/defines/<target>.vh`
  before the RTL. The candidate side reads the matching
  `rtl/vhdl/target/emz_target_<target>.vhd`.

## Simulation of the VHDL

The VHDL is also simulated at production sizes, which the proofs do not use
(full-depth FIFOs and the 4096x9 `mii_if` RX frame RAM, MAX_FRAME up to 9018):

- **cocotb** (`sim/cocotb/`, phases 2 and 2b of `build_and_test.py`): every
  suite runs on both languages, the Verilog under Icarus and the VHDL under
  GHDL (`python sim/cocotb/run.py --hdl both`). The 53 suites include a port of
  each of the 44 core Verilog testbenches, with the same DUT, parameters,
  timing and checks, so both languages pass exactly the same tests. All 106
  runs pass. Benches with several DUT instances use small wiring harnesses
  (`sim/cocotb/hdl/`), each proven equivalent across the two languages
  (`sim/parity/harness_*`). The ports never write a signal inside the design:
  GHDL keeps a value written through its VPI for good. The two benches that
  force internals are ported without the force:
  - `ETH-STATS` forces a counter to test saturation. Its port builds
    `eth_stats` with `STAT_CNT_W=3` and counts up to the maximum.
  - `RGMII-LOOPBACK` forces `gmii_cdc`'s RX inputs. Its port loops the TX
    stream back through the RGMII RX pins instead, which also covers
    `rgmii_if`'s receive path.

  See [sim/cocotb/README.md](../sim/cocotb/README.md).
- **Verilog testbenches in xsim** (`sim/tb/`, phase 1c, needs Vivado): each
  core bench drives the VHDL DUT in Vivado xsim (mixed language, SIM target;
  `MII-RX-REPLAY-STRESS` uses XILINX_7SERIES with the bench's XPM models).
  43 of the 44 pass. `RGMII-LOOPBACK` runs on Verilog only, because xsim cannot
  write to a VHDL object from Verilog, and `ETH-STATS` leaves out its
  saturation test for the same reason (`TB_NO_HIER_FORCE`). xsim reads VHDL
  internals through hierarchical references, but returns 0 for a bit-select
  taken directly on one (`uut.vec[8]`); the benches read the whole vector into
  a wire first.

Not covered: the vendor DDR reruns on the Xilinx unisim models, which run on
Verilog only.

## Translation conventions

- Entity, generic and port names, order and widths match the Verilog exactly.
  Internal signal names match the Verilog regs and wires, which lets the proof
  pair state by name.
- Resets are kept exactly as written, async active-low (`rst_n = '0'` outside
  `rising_edge`). This is a faithful port. The project rule to prefer
  synchronous resets applies to new RTL, not to translations.
- The files are VHDL-93: they analyse with `ghdl --std=93` (strict, without
  `-fsynopsys`) and with Vivado's default `xvhdl` mode. They use
  `ieee.numeric_std` only and explicit sensitivity lists, and add an internal
  signal when a module reads back one of its own outputs.
- A Verilog parameter whose default is computed from another parameter cannot
  be a VHDL-93 generic default. Those generics default to 0, and the
  architecture uses `auto_or(generic, derived)` from `emz_util_pkg`, so 0
  gives the Verilog default:
  - `RX_AXIS_ADDR_WIDTH` in `eth_mac` and `eth_mac_sys`
  - `RX_FIFO_ADDR_WIDTH` in `gmii_cdc`
  - `BUF_ADDR_WIDTH` in `tx_csum_off`

  An explicit value works as in Verilog. Address width 0 is not a valid
  setting, so 0 is free to mean "derive".
- VHDL-93 has no `else generate`. An `if`/`else` choice is two `if` generates
  with opposite conditions. Where the branches instantiate a module, their
  labels are chosen so that the instance flattens to the Verilog's name on
  either branch: `u` + `rx_fifo` and `u_rx` + `fifo` both give `u_rx_fifo`.
  The proof pairs state by those names.
- Verilog's implicit width extension is made explicit, and every intermediate
  keeps the Verilog width (`unsigned` arithmetic wraps at the declared width).
- `(* ASYNC_REG *)`, `(* ram_style *)` and `(* IOB *)` become VHDL attributes
  with the same names and values. Vivado honours them in VHDL.
- `` `ifdef `` vendor selection becomes `if EMZ_TARGET = "..." generate`.
  `EMZ_TARGET` comes from `package emz_target_pkg`, one file per target under
  `rtl/vhdl/target/`, and the file list picks exactly one (VHDL has no
  preprocessor). Vendor primitives (ODDR, IDDR, ODDRE1, IDDRE1, XPM) are
  declared as local components, so GHDL analyses without vendor libraries and
  Vivado binds them to unisim/XPM. Those files also `use work.all`: VHDL-93 binds a
  component by default only to a directly visible entity, so without it a
  simulation model compiled into `work` (as in the proofs) would stay unbound.
- Latent Verilog bugs found during the port are reproduced as-is, logged, and
  fixed on both sides in a separate change.
