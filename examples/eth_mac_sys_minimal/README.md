# Minimal eth_mac_sys instantiation

Thinnest possible wrapper around `eth_mac_sys` with every host-side port
brought out at the top. Use it as a copy-paste template when integrating
the MAC into your own SoC.

## What's in scope

- AXI4-Lite CSR (drive from your CPU bus)
- AXI4-Stream TX/RX (8-bit byte streams)
- MII or RGMII PHY pads
- MDIO with separate `mdio_o`/`mdio_oe`/`mdio_i` (host shell does the
  tristate buffer to the package pin)
- Single-bit `irq` line

## What's NOT here (compared to the Arty demo)

No clock generation, no PHY reset sequencing, no UART, no test sequencer,
no ARP responder, no ICMP echo. That's deliberate — this template is the
MAC alone, ready to be wired into your existing infrastructure.

There is also no external AXI-Stream store-forward wrapper here. The MII PHY
path inside `eth_mac_sys` already uses frame-aware CDC buffering. Add a parent
`axis_store_forward`-style block only if your upstream DMA or packet producer
can begin a TX frame and then underrun before `tlast`.

`MII_DEBUG` is an `eth_mac_sys` parameter and defaults to `0`. Leave it off
for normal builds; set it only when you deliberately want the lower-level MII
debug capture/counters preserved for bring-up.

## File list to compile

Use one of:

- FuseSoC core: `bard0:eth:emaczero:0.1.0`, target `default`
- Flat filelist: [rtl/eth_mac_sys.f](../../rtl/eth_mac_sys.f) + this file

```
iverilog -g2001 -f rtl/eth_mac_sys.f \
         examples/eth_mac_sys_minimal/eth_mac_sys_minimal.v \
         <your_tb.v>
```

## Software side

CSRs are documented in [sw/README.md](../../sw/README.md). The driver in
`sw/emaczero/` matches the exact register layout this wrapper exposes.

## Picking MII vs RGMII

```verilog
eth_mac_sys_minimal #(.PHY_INTERFACE("MII"))  u_mac (...);
// or
eth_mac_sys_minimal #(.PHY_INTERFACE("RGMII")) u_mac (...);
```

Tie off the unused interface's input ports (`mii_*` or `rgmii_*` plus
`clk_125`, `clk_125_90`, `clk_25`, `clk_2_5`) when you instantiate. The
unused output ports can be left floating.
