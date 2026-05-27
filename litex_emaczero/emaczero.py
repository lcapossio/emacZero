# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
"""
LiteX wrapper for emacZero (`eth_mac_sys`).

Exposes the MAC as a LiteX `LiteXModule` with:

  * AXI-Lite slave (`s_axi`) for the CSR block — 8-bit address, 32-bit data.
    Bridge it onto the SoC bus with `axi.AXILite2Wishbone` (or use
    `SoC.bus.add_slave(name, mac.s_axi, region=...)` if your SoC carries
    AXI-Lite natively).
  * AXI-Stream master `m_axis` (RX, FPGA -> host) and slave `s_axis`
    (TX, host -> FPGA), 8 bits wide, byte-rate.
  * MII *or* RGMII PHY pads.
  * MDIO tristate signals (`mdio_o` / `mdio_oe` / `mdio_i`).
  * `irq` line for the SoC interrupt controller.

The wrapper does not add an external AXI-Stream store-forward block. The
standalone MAC already contains the MII-side frame buffering it needs; add
upstream store-forward buffering in your parent SoC only if your AXI-Stream TX
producer can underrun after starting a frame.

Typical use (MII, Arty A7-style, 100 MHz `sys` clock domain)::

    from litex.gen import LiteXModule
    from litex.soc.interconnect import axi
    from litex_emaczero import EmacZero, add_sources

    add_sources(platform)

    eth_pads = platform.request("eth")
    self.submodules.mac = mac = EmacZero(platform, eth_pads,
                                         phy_interface="MII")
    self.bus.add_slave("emaczero",
        axi.AXILite2Wishbone(mac.s_axi).wishbone,
        SoCRegion(origin=0x60000000, size=0x100, mode="rw"))
    self.add_interrupt("emaczero")

For a gigabit RGMII target, instantiate with ``phy_interface="RGMII"`` and
also drive ``clk_125`` / ``clk_125_90`` / ``clk_25`` / ``clk_2_5`` from the
platform's clock generator.
"""

from pathlib import Path

from migen import ClockSignal, Instance, ResetSignal, Signal, TSTriple

from litex.gen import LiteXModule
from litex.soc.interconnect import axi, stream

# -----------------------------------------------------------------------------
# Source list
# -----------------------------------------------------------------------------

# Files relative to the repository root. `add_sources()` resolves them against
# REPO_ROOT (this file lives at <repo>/litex_emaczero/emaczero.py).
REPO_ROOT = Path(__file__).resolve().parent.parent

CORE_SOURCES = [
    "rtl/crc32.v",
    "rtl/async_fifo.v",
    "rtl/sync_fifo.v",
    "rtl/mii_if.v",
    "rtl/eth_mac_rx.v",
    "rtl/eth_mac_tx.v",
    "rtl/eth_mac.v",
    "rtl/mdio_master.v",
    "rtl/eth_stats.v",
    "rtl/eth_pause.v",
    "rtl/axilite_regs.v",
    "rtl/ddr_output.v",
    "rtl/ddr_input.v",
    "rtl/rgmii_if.v",
    "rtl/gmii_cdc.v",
    "rtl/net/tx_csum_off.v",
    "rtl/eth_mac_sys.v",
]

# `axilite_regs.v` does ``include "version.vh"``; the rtl/ dir is the include
# search path (single source of truth, cf. rtl/version.vh).
INCLUDE_DIRS = ["rtl"]


def add_sources(platform):
    """Register every Verilog source emacZero needs with the LiteX platform.

    Idempotent — safe to call once per LiteX SoC. The repo root is detected
    relative to this file, so users only need to ``pip install -e .`` (or set
    ``PYTHONPATH``) and import; no per-project file paths required.
    """
    for relpath in CORE_SOURCES:
        platform.add_source(str(REPO_ROOT / relpath))
    add_include_path = getattr(platform, "add_verilog_include_path", None)
    if add_include_path is not None:
        for incdir in INCLUDE_DIRS:
            add_include_path(str(REPO_ROOT / incdir))


# -----------------------------------------------------------------------------
# Wrapper
# -----------------------------------------------------------------------------

class EmacZero(LiteXModule):
    """Instantiates ``eth_mac_sys`` and exposes LiteX-friendly interfaces.

    Parameters
    ----------
    platform : LiteX platform
        Used by ``add_sources`` to register the Verilog files. Pass it through
        even if you call ``add_sources`` separately.
    pads : Record-like
        PHY pad bundle. Required signals depend on ``phy_interface``:

        * MII   : ``tx_data[3:0]``, ``tx_en``, ``tx_clk``, ``rx_data[3:0]``,
                  ``rx_dv``, ``rx_er``, ``rx_clk``, ``crs``, ``col``,
                  ``mdc``, ``mdio`` (TSTriple-compatible attribute *or* a
                  raw bidir; see below).
        * RGMII : ``tx_data[3:0]``, ``tx_ctl``, ``txc``, ``rx_data[3:0]``,
                  ``rx_ctl``, ``rxc``, ``mdc``, ``mdio``.

        ``pads.mdio`` may be a LiteX TSTriple (preferred) or a single bidir
        pin; in the latter case, instantiate a TSTriple yourself and connect
        ``self.mdio_t`` to it.
    phy_interface : str
        ``"MII"`` (10/100) or ``"RGMII"`` (10/100/1G).
    mcast_hash_filter : int
        Pass-through to the same parameter on ``eth_mac_sys`` (0 disables the
        64-bit multicast hash table; 1 enables it).
    max_frame : int
        Pass-through to ``MAX_FRAME``. Default 9018 covers jumbo.
    """

    def __init__(self, platform, pads,
                 phy_interface="MII",
                 mcast_hash_filter=0,
                 max_frame=9018):
        if phy_interface not in ("MII", "RGMII"):
            raise ValueError(f"phy_interface must be 'MII' or 'RGMII', got {phy_interface!r}")

        add_sources(platform)

        # ---- AXI-Lite CSR slave (8-bit address, 32-bit data) ----
        self.s_axi = axi.AXILiteInterface(data_width=32, address_width=8)

        # ---- AXI-Stream interfaces (byte-rate) ----
        # Naming follows LiteX/AXI conventions:
        #   sink    -> data going INTO the MAC's TX path (SoC -> wire)
        #   source  -> data coming OUT of the MAC's RX path (wire -> SoC)
        self.sink   = stream.Endpoint([("data", 8)])
        self.source = stream.Endpoint([("data", 8), ("error", 1)])

        # IRQ + MDIO TS so the user can wire either kind of pad.
        self.irq    = Signal()
        self.mdio_t = TSTriple()

        # Optional gigabit clocks (only needed when phy_interface == "RGMII").
        # Default to 0 so MII users don't have to wire anything.
        self.clk_125    = Signal()
        self.clk_125_90 = Signal()
        self.clk_25     = Signal()
        self.clk_2_5    = Signal()

        # ---- Verilog instance ----
        params = dict(
            p_PHY_INTERFACE     = phy_interface,
            p_MCAST_HASH_FILTER = mcast_hash_filter,
            p_MAX_FRAME         = max_frame,

            i_clk   = ClockSignal("sys"),
            i_rst_n = ~ResetSignal("sys"),

            # AXI-Lite CSR
            i_s_axi_awaddr  = self.s_axi.aw.addr,
            i_s_axi_awvalid = self.s_axi.aw.valid,
            o_s_axi_awready = self.s_axi.aw.ready,
            i_s_axi_wdata   = self.s_axi.w.data,
            i_s_axi_wstrb   = self.s_axi.w.strb,
            i_s_axi_wvalid  = self.s_axi.w.valid,
            o_s_axi_wready  = self.s_axi.w.ready,
            o_s_axi_bresp   = self.s_axi.b.resp,
            o_s_axi_bvalid  = self.s_axi.b.valid,
            i_s_axi_bready  = self.s_axi.b.ready,
            i_s_axi_araddr  = self.s_axi.ar.addr,
            i_s_axi_arvalid = self.s_axi.ar.valid,
            o_s_axi_arready = self.s_axi.ar.ready,
            o_s_axi_rdata   = self.s_axi.r.data,
            o_s_axi_rresp   = self.s_axi.r.resp,
            o_s_axi_rvalid  = self.s_axi.r.valid,
            i_s_axi_rready  = self.s_axi.r.ready,

            # TX AXI-Stream  (SoC -> MAC)
            i_s_axis_tdata  = self.sink.data,
            i_s_axis_tvalid = self.sink.valid,
            o_s_axis_tready = self.sink.ready,
            i_s_axis_tlast  = self.sink.last,

            # RX AXI-Stream  (MAC -> SoC)
            o_m_axis_tdata  = self.source.data,
            o_m_axis_tvalid = self.source.valid,
            i_m_axis_tready = self.source.ready,
            o_m_axis_tlast  = self.source.last,
            o_m_axis_terror = self.source.error,
            o_m_axis_tsof   = self.source.first,

            # MDIO tristate
            o_mdc    = pads.mdc,
            o_mdio_o = self.mdio_t.o,
            o_mdio_oe= self.mdio_t.oe,
            i_mdio_i = self.mdio_t.i,

            # Interrupt
            o_irq    = self.irq,
        )

        # PHY pads — wire only the active interface, tie the other to zero.
        if phy_interface == "MII":
            params.update(
                o_mii_txd    = pads.tx_data,
                o_mii_tx_en  = pads.tx_en,
                i_mii_tx_clk = pads.tx_clk,
                i_mii_rxd    = pads.rx_data,
                i_mii_rx_dv  = pads.rx_dv,
                i_mii_rx_er  = pads.rx_er,
                i_mii_rx_clk = pads.rx_clk,
                i_mii_col    = getattr(pads, "col", Signal()),
                i_mii_crs    = getattr(pads, "crs", Signal()),

                i_clk_125    = self.clk_125,
                i_clk_125_90 = self.clk_125_90,
                i_clk_25     = self.clk_25,
                i_clk_2_5    = self.clk_2_5,
                o_rgmii_txd    = Signal(4),
                o_rgmii_tx_ctl = Signal(),
                o_rgmii_txc    = Signal(),
                i_rgmii_rxd    = 0,
                i_rgmii_rx_ctl = 0,
                i_rgmii_rxc    = 0,
            )
        else:  # RGMII
            params.update(
                o_rgmii_txd    = pads.tx_data,
                o_rgmii_tx_ctl = pads.tx_ctl,
                o_rgmii_txc    = pads.txc,
                i_rgmii_rxd    = pads.rx_data,
                i_rgmii_rx_ctl = pads.rx_ctl,
                i_rgmii_rxc    = pads.rxc,
                i_clk_125      = self.clk_125,
                i_clk_125_90   = self.clk_125_90,
                i_clk_25       = self.clk_25,
                i_clk_2_5      = self.clk_2_5,

                o_mii_txd    = Signal(4),
                o_mii_tx_en  = Signal(),
                i_mii_tx_clk = 0,
                i_mii_rxd    = 0,
                i_mii_rx_dv  = 0,
                i_mii_rx_er  = 0,
                i_mii_rx_clk = 0,
                i_mii_col    = 0,
                i_mii_crs    = 0,
            )

        self.specials += Instance("eth_mac_sys", **params)

        # If the platform exposes mdio as a raw bidir wire (not a TSTriple),
        # the user can connect it via:
        #   self.specials += self.mdio_t.get_tristate(pads.mdio)
        # We don't auto-instantiate it here because some platforms expect the
        # TSTriple to be created at the top level.
