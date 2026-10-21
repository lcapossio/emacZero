# VHDL port

`rtl/vhdl/` holds a VHDL-93 translation of the emacZero core (`rtl/eth_mac_sys.f`).
The Verilog in `rtl/` stays the golden source. Each VHDL file is checked against
its Verilog original with the [translateHDL](https://github.com/lcapossio/translateHDL)
parity ladder, whose main evidence is a formal sequential-equivalence proof
(Yosys `equiv_induct`).

Status: all 20 modules of `rtl/eth_mac_sys.f` are ported, on `feat/vhdl-port`.
Every proof is against the Verilog of v0.2.0 (23d39e8). So are the `rtl/net/`
L3 add-ons except `net_rx`, and the board modules of the Arty A7 and ZCU106
designs except `arty_tx_arbiter`, `arty_a7_top` and `zcu106_eth_demo` (see
[L3 and board modules](#l3-and-board-modules)).

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
  width, and each word keeps the high bits of its write address as a tag
  (see the stand-ins below), so a wrong address bit still shows.

The higher L4 tolerances are for state machines: GHDL lowers a `case` to a
one-hot decode, roughly doubling the `$eq` cells. Flop counts match.

`sim/parity/harness_*` hold proofs for the simulation side: the wiring
harnesses of the cocotb suites (`sim/cocotb/hdl/`) and the VHDL twins of the
XPM simulation models, each against its Verilog original.

## L3 and board modules

The L3 files are listed in `rtl/eth_mac_sys_l3_vhdl.f` (FuseSoC fileset
`rtl_vhdl_l3`); the board files sit next to their Verilog in
`fpga/<board>/rtl/`. Same ladder, same `--strict`:

| Module | Proven configs (L2) | L4 tol. |
| --- | --- | --- |
| `icmp_echo` | MAX_LEN 12, 15, 20 (production 1480: L4 only) | 10% |
| `udp_echo` | BUF_SIZE 6, 8 and 16 against a generated golden (see below); BUF_SIZE 8 with LISTEN_PORT 9999 (production 1536: L4 only) | 10% |
| `udp_blast` | default, START_DELAY_CYCLES 4 / 100M / 125M / 2^32-1, USEC_TICK_CYCLES 125 and 200 | 45% |
| `udp_blast_trigger` | default, and all four parameters changed (ports, count, payload) | 10% |
| `udp_iperf_sink` | LISTEN_PORT 0 (any port) and 5001 | 10% |
| `udp_stats_reply` | default | 60% |
| `axil_arb2` | AW=8/DW=32, AW=4/DW=16 | 10% |
| `uart_tx` (Arty) | 100 MHz / 115200, 1000 Hz / 100 | 10% |
| `clk_gen` (Arty) | default: primitive wiring and every MMCM parameter, MMCM stood in | 10% |
| `arp_responder` (Arty) | default, by `prove_arp_responder.py` (see below) | 10% |
| `test_sequencer` (Arty) | default, CLK_FREQ 125 MHz, against a generated golden (see below) | 15% |
| `gmii_lb_selftest` (Arty) | default, children stood in | 15% |
| `sfp_lb_tester` (ZCU106) | default, `eth_mac_sys` stood in | 35% |
| `i2c_init` (ZCU106) | production dividers and delays, defaults, small dividers, zero delays | 30% |
| `zcu106_top` (ZCU106) | REFCLK_SI5328 0 and 1, with and without `ZCU106_SFP1_LB`, children stood in | 10% |

Vector-typed parameters (`LISTEN_PORT` and the other UDP ports) cannot be set
from a manifest, and neither can a negative integer, so those values go
through one-instance wrapper pairs in the module's `sim/parity/` directory, as
`async_fifo`'s `RAM_STYLE` does.

`udp_blast`'s `START_DELAY_CYCLES` and `USEC_TICK_CYCLES` are `integer`
generics, where the Verilog has `[31:0]` and `[6:0]` parameters. The VHDL
takes the value modulo 2^32 (2^7), so a delay of 2^31 cycles or more is
passed as the negative integer with the same 32 bits (2^32-1 is -1).

Not proven, and why:
- `icmp_echo` at a power-of-two MAX_LEN. Its buffer is indexed by a counter
  one bit wider than it needs. Past the last word, a Verilog read is x and a
  write is dropped, while the VHDL synthesises a wrapped address. That state
  is unreachable (writes stop at `rx_cnt = LEN_MAX`), but induction starts
  from arbitrary state, and translateHDL takes a Verilog x as the one value
  Yosys folds it to. The proofs use other sizes; the production size is L4
  only.
- `arp_responder`'s capture buffer is a Verilog memory, which Yosys splits per
  word and GHDL keeps whole, so state cannot pair by name and its manifest
  runs no L2. `sim/parity/arp_responder/prove_arp_responder.py` runs it with
  alias wires added to the GHDL netlist; `run_all.py` (and so CI) runs it.
- `test_sequencer` and `udp_echo` read past the end of a memory: the
  42-word ARP ROM through an 8-bit index, and, at a BUF_SIZE that is not a
  power of two (the boards use 1536), the payload buffer through an ADDR_W-bit
  index. That read is x in Verilog and 0 in the VHDL. Because translateHDL
  takes an x as the one value Yosys folds it to, L2 proves the VHDL against
  `test_sequencer_x0.v` and `udp_echo_x0.v`, which `sim/parity/gen_goldens.py`
  generates from the real Verilog with that one read returning 0 past the end:
  a refinement of the x. L0, L1 and L4 use the real modules.
- `zcu106_top`'s open-drain I2C pins. The solver treats a `'Z'` as a constant,
  so a tri-state driver would prove whatever its enable was. L2 runs on
  `zcu106_top_split.{v,vhd}`, generated by `gen_split.py` from the real tops
  with each pin split into its enable and input; the script also checks that
  the two drivers are the same expression on both sides. The split models
  also bring the fcapz EIO's `probe_in` out on an extra output,
  `PARITY_PROBE_IN`, so every probe bit is compared directly (see the EIO
  stand-in below). The port is driven from whatever `probe_in` is actually
  wired to (the VHDL port map is read, not assumed), so a corrupted copy
  wired into the EIO is what gets compared.

What the board proofs cover: each top's own logic and every connection and
generic it passes to a child. The children are proven separately (or are
vendor IP, fcapz, or still Verilog). They are replaced by **stateful
stand-ins**, never by empty stubs: a port-only stub leaves its outputs
undriven, Yosys folds them to constants, and everything fed by them then
proves equal whatever it computes. Each stand-in is a register, clocked by
the child's own clock input, that every cycle takes its rotated self XOR
the inputs and a fingerprint of its generics, each at its own bits (the inputs
above the fingerprint), and drives every output from
that register (`sim/parity/sfp_lb_tester/eth_mac_sys_standin.{v,vhd}`,
`sim/parity/zcu106_top/zcu106_top_children.{v,vhd}`,
`sim/parity/stubs/xilinx_clk_standin.{v,vhd}`). The fingerprint gives each
generic its own full-width field (a real as round(value * 1000) in 32 bits, a
string as one bit per legal value), so two different legal settings never
give the same fingerprint, and since the inputs sit above it, a wrong generic
cannot be cancelled by an inverted input either. The limits: reals are
compared only to 0.001 (two MMCM settings that round to the same thousandth
look the same), an illegal string value sets no bit, and the fcapz EIO stand-in, which has no
clock, folds its 96-bit fingerprint and its `probe_in` onto 8 or 16 outputs,
where two wrong probe bits could cancel. That is why the `zcu106_top` proofs
compare `probe_in` itself through `PARITY_PROBE_IN`. The clocks a stand-in
puts out (MMCM outputs, the `BUFGCE_DIV` output, the 1000BASE-X PCS/PMA
`userclk`/`rxuserclk` outputs) are bits of that register, not wires from or
gates of its input clocks, so logic moved from one clock domain to another
diverges. A wrong
port, generic or clock therefore fails the proof. Deliberate mutants were run
against `clk_gen`, `sfp_lb_tester`, `gmii_lb_selftest` and `zcu106_top` (a
swapped port, a wrong generic, a wrong constant, a wrong MMCM divider, a
process moved to another clock, two generics changed so that an XOR
fingerprint would cancel, a wrong divide plus an inverted enable on
`BUFGCE_DIV`, a clock built from the two refclk pins with the AN
synchronizer moved onto it, a changed EIO probe word), and none of them
passes.

**Known Verilog bug, reproduced as-is.** `udp_echo` counts the received
payload in ADDR_W+1 bits (12 at BUF_SIZE 1536), and the count wraps. A
payload of exactly 4096 or 8192 bytes, which the ZCU106 build (MAX_FRAME
9018, payloads up to 8972 bytes) can receive once `jumbo_en` is set, is
accepted with length 0. The reply's end
test compares the 12-bit byte counter with the 32-bit `payload_len - 1` and
never matches, so the echo transmits until reset, reading past the buffer
(x in Verilog, 0 in VHDL). Payloads of 4097 to 5632 and 8193 to 8972 bytes
wrap to a short length and get a truncated reply. The Arty build (MAX_FRAME 1518) cannot
receive such a frame. The VHDL behaves the same; the fix, for both languages,
is a separate change.

`zcu106_top` has two VHDL files, `zcu106_top.vhd` and `zcu106_top_lb.vhd`,
both declaring entity `zcu106_top`: `ZCU106_SFP1_LB` adds ports, which a VHDL
generic cannot. Read the one for the build. The Si5328 register table is a
package (`zcu106_si5328_rom_pkg.vhd`), checked against the Verilog include by
`sim/parity/i2c_init/check_rom.py`.

Building a board from the VHDL needs mixed language for now: `net_rx`,
`arty_tx_arbiter`, `arty_a7_top` and `zcu106_eth_demo` are still Verilog,
and `zcu106_eth_demo` instantiates the Verilog `eth_mac_sys`, so the ZCU106
build keeps the Verilog core and `sfp_lb_tester.v`. The VHDL tops declare
every child (primitives, IP, fcapz, Verilog modules) as a local component.

`build_and_test.py` phase 0d analyses all of these files as strict VHDL-93
and elaborates each top. It fails if `gen_smallram.py`, `gen_smallmem.py`,
`gen_goldens.py`, `gen_split.py` or `check_rom.py` find their models stale,
or if `sim/parity/sens_check.py` finds a process whose sensitivity list
misses a signal it reads, or, in a clocked process, its clock or the
signals of its asynchronous reset (which only simulation would show; the
proofs run on netlists). The L3 and board VHDL is not
simulated yet: its Verilog testbenches drive the Verilog only.

## Reproducing the proofs

Needs GHDL, Python 3 with `pyyaml`, and a Yosys with `rename -unescape`
(tested: GHDL 4.1, yowasp-yosys 0.63). translateHDL must be at be0ba18 or
later, which adds string parameters, a flattened L4, name-collision and
generate-scope pairing, and checks the base case of every induction proof
from the initial state. Point `YOSYS`/`GHDL` at the binaries if they are not
on `PATH` under those names.

Last full run: `run_all.py -j 4`, all 58 manifests and proof scripts pass
(core, L3, board and harness modules), GHDL 4.1 with yowasp-yosys 0.63 under
WSL, translateHDL be0ba18 (2026-10-20, 16 minutes). With GHDL 6.0.0 on Windows, `eth_mac`,
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
cannot express them (`rgmii_if` with the real DDR cells of every target,
`arp_responder` with alias wires). It
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
    the memory clamped to 8 words, generated from the real files by
    `gen_smallmem.py`, which also requires every memory access in them to be
    the full-pointer index it rewrites (so an index bug in the real FIFO that
    the small-depth `async_fifo` proofs might not reach stops the script).
    Pointers, Gray synchronisers and flags keep their real widths. It is used where a 4K- or 16K-word FIFO would not fit
    the solver (`gmii_cdc`, `mii_if`, `eth_mac`, `eth_mac_sys`), and is itself
    proven equivalent across languages at those parameter sets.
  - `sim/parity/mii_if/mii_if_smallram.{v,vhd}`: `mii_if` with the RX frame
    RAM cut to 8 words, generated from the real files by `gen_smallram.py`.
    Eight words alone would hide address bits 11:3, so each word also keeps
    those bits of its write address, and a read returns the stored byte XOR
    (stored high bits XOR read address bits 11:3): the byte itself when the
    read address is the one written, a different value otherwise. The tag
    is a second array: an 18-bit word holding both stops the induction from
    closing. Checked on a one-module extract of the generated RAM block: a
    read address with bits 11:3 dropped, or a write address off by 8, fails
    with a counterexample (on the whole `mii_if` such a mutant was still in
    induction after 45 minutes).
    `build_and_test.py` fails if the copies are out of date. Used by the
    `mii_if`, `eth_mac` and `eth_mac_sys` (MII) proofs.
  - `sim/parity/stubs/ddr_standin.{v,vhd}`: stateless DDR cells inside
    `rgmii_if`'s for-generates in the `eth_mac_sys` proof.
  - `sim/parity/stubs/xilinx_ddr_prims.{v,vhd}` and `xpm_macros.{v,vhd}`:
    behavioural models of ODDR/IDDR/ODDRE1/IDDRE1 and the XPM macros, so the
    vendor branches can be proven. They check the wiring around the primitive,
    not the primitive itself. The XPM models also check every generic by
    value, including those whose behaviour they do not model (memory
    primitive, ECC, read latencies they do not implement): each folds a
    fingerprint of all its generics into bit 0 of its read data, so a
    generic that differs between the two sides fails the proof. A string
    longer than 24 characters, which the fingerprint could not tell apart,
    stops elaboration on both sides. The 8-word `xpm_memory_sdpram` keeps the
    same address tag as `mii_if_smallram`, so a wrong high address bit on
    either port changes the data read. It fails as BOUNDED rather than with a
    counterexample when the differing bit lies deep in the fingerprint
    (induction fails on the read data, and the short probe from reset cannot
    step that far through it); `--strict` counts both as failures. Checked
    with mutants on one-instance wrappers using `mii_if`'s generic maps: a
    wrong memory primitive, `READ_LATENCY_B` 0, `MEMORY_INIT_FILE`,
    a read or write address off by 8 or 2048,
    `FIFO_READ_LATENCY`, `FIFO_MEMORY_TYPE`, and `USE_ADV_FEATURES` "0x04"
    for "0004" (the same hex value) all fail. On the whole `mii_if`, one such
    mutant was still in induction after more than half an hour, so the
    mutants run on the wrappers instead.
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
- An input that can come from a pulled-up or open-drain pad (`mdio_i`,
  `sda_i`) passes through `to_X01` where it is first sampled. A simulator
  resolves a pull-up to `'H'`, which an `= '1'` or `= '0'` test treats as
  neither; Verilog sees a 1. Synthesis ignores the call.
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
