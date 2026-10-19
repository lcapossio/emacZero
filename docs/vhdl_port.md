# VHDL port

`rtl/vhdl/` holds a VHDL translation of the emacZero core (`rtl/eth_mac_sys.f`).
The Verilog in `rtl/` stays the golden source. Each VHDL file is checked against
its Verilog original with the [translateHDL](https://github.com/lcapossio/translateHDL)
parity ladder, whose main evidence is a formal sequential-equivalence proof
(Yosys `equiv_induct`).

Status: in progress on `feat/vhdl-port`. The `rtl/net/` L3 add-ons are not
ported yet.

## Status

| Module | VHDL | L0 iface | L1 lint | L2 formal | Proven configs |
| --- | --- | --- | --- | --- | --- |
| `crc32` | [crc32.vhd](../rtl/vhdl/crc32.vhd) | PASS | PASS | **PASS** | default |
| `sync_fifo` | [sync_fifo.vhd](../rtl/vhdl/sync_fifo.vhd) | PASS | PASS | **PASS** | DW=4/AW=2, DW=11/AW=3 |
| `async_fifo` | [async_fifo.vhd](../rtl/vhdl/async_fifo.vhd) | PASS | PASS | **PASS** | DW=4/AW=2, DW=10/AW=3; RAM_STYLE DISTRIBUTED and BLOCK |

## Reproducing the proofs

Needs GHDL, Python 3 with `pyyaml`, and a Yosys with `rename -unescape`
(tested: GHDL 4.1, yowasp-yosys 0.63). Point `YOSYS`/`GHDL` at the binaries if
they are not on `PATH` under those names.

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
  and depth, and production depths are covered by simulation.
- **Uninitialised state** (RAM contents, unreset output registers) is assumed
  equal on both sides. It is paired by name after `rename -unescape`.
- **String parameters.** translateHDL passes integer parameters only. A
  one-instance wrapper per side pins string parameters such as
  `async_fifo.RAM_STYLE = "BLOCK"`. See `sim/parity/async_fifo/`.

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
- `` `ifdef `` vendor selection becomes one entity with one architecture per
  vendor, each in its own file, chosen by the file list. VHDL has no
  preprocessor.
- Latent Verilog bugs found during the port are reproduced as-is, logged, and
  fixed on both sides in a separate change.
