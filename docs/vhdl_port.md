# VHDL port

`rtl/vhdl/` holds a VHDL translation of the emacZero core (`rtl/eth_mac_sys.f`).
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
| `ddr_output` | SIM, NONE, INTEL_CYCLONE, XILINX_7SERIES, XILINX_ULTRASCALE_PLUS | 10% (vendor targets: n/a) |
| `ddr_input` | SIM, NONE, INTEL_CYCLONE, XILINX_7SERIES, XILINX_ULTRASCALE_PLUS | 10% (vendor targets: n/a) |
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

## Reproducing the proofs

Needs GHDL, Python 3 with `pyyaml`, and a Yosys with `rename -unescape`
(tested: GHDL 4.1, yowasp-yosys 0.63). translateHDL must be at f919ad5 or
later, which adds string parameters, a flattened L4, and name-collision and
generate-scope pairing. Point `YOSYS`/`GHDL` at the binaries if they are not
on `PATH` under those names.

```sh
python <translateHDL>/skills/translate-hdl/scripts/parity.py sim/parity/<module>/parity.yml --strict
```

Each manifest in [sim/parity/](../sim/parity/) lists its modules and parameter
sets.

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

The cocotb suites in `sim/cocotb/` run unchanged against the VHDL under GHDL
(`python sim/cocotb/run.py --hdl vhdl`, phase 2b of `build_and_test.py`). They
use production sizes, which the proofs do not: `mii_tx_saf` with MAX_FRAME
1518 and a 4096-entry FIFO, `eth_mac_rx` at MAX_FRAME 1518 with its full RX
FIFO, `gmii_cdc` with its real 16K-word FIFO, and `tx_csum_off` at MAX_FRAME
600. All 8 suites (39 tests, directed and seeded random) pass on both
languages.

Not simulated as VHDL: `mii_if`, `eth_mac`, `eth_mac_sys` and the PHY
interfaces. Their testbenches are the Verilog benches in `sim/tb/`, which
need a mixed-language simulator (xsim) to drive the VHDL.

## Translation conventions

- Entity, generic and port names, order and widths match the Verilog exactly.
  Internal signal names match the Verilog regs and wires, which lets the proof
  pair state by name.
- Resets are kept exactly as written, async active-low (`rst_n = '0'` outside
  `rising_edge`). This is a faithful port. The project rule to prefer
  synchronous resets applies to new RTL, not to translations.
- Files are analysed as VHDL-2008 but written in a VHDL-93 style:
  `ieee.numeric_std` only, explicit sensitivity lists, and an internal signal
  when a module reads back one of its own outputs.
- Verilog's implicit width extension is made explicit, and every intermediate
  keeps the Verilog width (`unsigned` arithmetic wraps at the declared width).
- `(* ASYNC_REG *)`, `(* ram_style *)` and `(* IOB *)` become VHDL attributes
  with the same names and values. Vivado honours them in VHDL.
- `` `ifdef `` vendor selection becomes `if EMZ_TARGET = "..." generate`.
  `EMZ_TARGET` comes from `package emz_target_pkg`, one file per target under
  `rtl/vhdl/target/`, and the file list picks exactly one (VHDL has no
  preprocessor). Vendor primitives (ODDR, IDDR, ODDRE1, IDDRE1, XPM) are
  declared as local components, so GHDL analyses without vendor libraries and
  Vivado binds them to unisim/XPM.
- Latent Verilog bugs found during the port are reproduced as-is, logged, and
  fixed on both sides in a separate change.
