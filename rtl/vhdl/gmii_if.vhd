-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- gmii_if.vhd - GMII PHY interface (vendor-agnostic), 1000 Mbps
-- Registers the internal 8-bit GMII bus onto the GMII pins and forwards the
-- transmit clock to the PHY.
-- VHDL port of rtl/gmii_if.v (formally proven equivalent; see sim/parity/).
-- =============================================================================
-- Naming. IEEE 802.3 Clause 35 calls the MAC-sourced transmit clock GTX_CLK,
-- and PHY datasheets label the pin that way. This port is nevertheless named
-- `gmii_txc` (`phy_gmii_txc` at the top level): "gtx" collides with the Xilinx
-- GTX serial transceivers, so a wildcard constraint aimed at those - e.g.
-- `[get_ports *gtx*]` - would otherwise sweep up this Ethernet pin. `txc` also
-- matches the existing `rgmii_txc` in this repo. Comments below keep saying
-- GTX_CLK where they refer to the standard's signal, for traceability against
-- PHY documentation.
-- =============================================================================
-- GMII is a 1000 Mbps-only interface: 8 bits per clock at 125 MHz. A tri-speed
-- PHY that exposes GMII reverts to 4-bit MII at 10/100, where the PHY - not the
-- MAC - sources TX_CLK. That pin-sharing mode is a different interface and is
-- NOT implemented here; instantiate PHY_INTERFACE="MII" for 10/100 operation.
-- Accordingly this module has no cfg_speed input and always runs at 125 MHz.
--
-- Clocks:
--   clk_125    - 125 MHz, 0 deg. TX data is launched on this edge, and GTX_CLK
--                is forwarded from it INVERTED (see below).
--   gmii_rx_clk- 125 MHz RX clock sourced by the PHY.
--
-- GTX_CLK phase. IEEE 802.3 Clause 35.5.2 requires 2.5 ns setup / 0.5 ns hold
-- AT THE SIGNAL SOURCE - i.e. at this MAC's own output pins, which is what this
-- module controls - against an 8 ns data window. Those relax to 2.0 ns / 0 ns
-- at the receiver (the PHY pins); the 500 ps difference is the board
-- length-matching budget. The forwarded clock's RISING edge must therefore sit
-- near the centre of the data window, not near its start:
--
--   clk_125    __|""""|____|""""|____   data launches on each rising edge
--   TXD        XXXX<   byte N    >XXXX
--   GTX_CLK    ""|____|""""|____|""""   PHY samples on GTX_CLK rising
--                       ^ 4 ns into the data window
--
-- Driving the DDR cell from clk_125 with d1=0/d2=1 puts GTX_CLK's rising edge
-- at clk_125's FALLING edge - 4 ns after the data transition - leaving ~4 ns
-- each of setup and hold before board and clock-to-out skew. A dedicated 180
-- deg clock is equivalent.
--
-- Do NOT forward clk_125_90 here: that is the RGMII convention (where the
-- ~2 ns offset satisfies RGMII's own internal-delay requirement), and 2 ns is
-- below the 2.5 ns setup GMII requires at the source, before any skew is
-- subtracted. Likewise do not forward clk_125 with d1=1/d2=0: that is
-- edge-aligned and leaves no deliberate phase margin in either direction.
--
-- GTX_CLK duty cycle: Clause 35 allows 35%-75%. The inverted DDR waveform is
-- 50% by construction, so it is compliant with margin.
--
-- I/O packing: the TX output and RX input registers below are written as plain
-- single-stage flops so the tool can pack them into the IOB. Constrain with
-- `set_property IOB TRUE` in the XDC; no attribute is applied here so the RTL
-- stays vendor-neutral.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity gmii_if is
    port (
        clk_125        : in  std_logic;
        rst_n          : in  std_logic;

        -- --- GMII pins (to/from PHY) ---
        gmii_txd       : out std_logic_vector(7 downto 0);
        gmii_tx_en     : out std_logic;
        gmii_tx_er     : out std_logic;
        gmii_txc       : out std_logic;     -- IEEE 802.3 Clause 35 GTX_CLK
        gmii_rx_clk    : in  std_logic;
        gmii_rxd       : in  std_logic_vector(7 downto 0);
        gmii_rx_dv     : in  std_logic;
        gmii_rx_er     : in  std_logic;

        -- --- Internal GMII, media-clock domain (to/from gmii_cdc) ---
        gmii_txd_int   : in  std_logic_vector(7 downto 0);
        gmii_tx_en_int : in  std_logic;
        gmii_tx_er_int : in  std_logic;
        gmii_rxd_int   : out std_logic_vector(7 downto 0);
        gmii_rx_dv_int : out std_logic;
        gmii_rx_er_int : out std_logic
    );
end entity gmii_if;

architecture rtl of gmii_if is

    signal tx_rst_n_s1, tx_rst_n_s2 : std_logic;
    signal rx_rst_n_s1, rx_rst_n_s2 : std_logic;

    attribute ASYNC_REG : string;
    attribute ASYNC_REG of tx_rst_n_s1 : signal is "TRUE";
    attribute ASYNC_REG of tx_rst_n_s2 : signal is "TRUE";
    attribute ASYNC_REG of rx_rst_n_s1 : signal is "TRUE";
    attribute ASYNC_REG of rx_rst_n_s2 : signal is "TRUE";

begin

    -- =========================================================================
    -- TX path: clk_125 -> pins
    -- =========================================================================
    -- rst_n is generated in the system-clock domain and is asynchronous to
    -- clk_125. Async assert, 2-FF sync deassert, so the TX output registers
    -- cannot release inconsistently and emit a spurious TX_EN/TX_ER pulse.
    process (clk_125, rst_n)
    begin
        if rst_n = '0' then
            tx_rst_n_s2 <= '0';
            tx_rst_n_s1 <= '0';
        elsif rising_edge(clk_125) then
            tx_rst_n_s2 <= tx_rst_n_s1;
            tx_rst_n_s1 <= '1';
        end if;
    end process;

    -- gmii_cdc already presents its media-side output registered on clk_125,
    -- so this is a single IOB-bound retiming stage, not a resynchronizer.
    process (clk_125, tx_rst_n_s2)
    begin
        if tx_rst_n_s2 = '0' then
            gmii_txd   <= (others => '0');
            gmii_tx_en <= '0';
            gmii_tx_er <= '0';
        elsif rising_edge(clk_125) then
            gmii_txd   <= gmii_txd_int;
            gmii_tx_en <= gmii_tx_en_int;
            gmii_tx_er <= gmii_tx_er_int;
        end if;
    end process;

    -- GTX_CLK (`gmii_txc`) forwarding. Driving the clock out of a DDR cell
    -- (rather than routing a clock to a pin directly) keeps it on the clock
    -- network to the IOB. d1=0/d2=1 inverts the waveform so the rising edge
    -- lands mid-window; see the phase discussion in the header.
    u_txc : entity work.ddr_output
        port map (
            clk => clk_125,
            d1  => '0',
            d2  => '1',
            q   => gmii_txc
        );

    -- =========================================================================
    -- RX path: pins -> gmii_rx_clk
    -- =========================================================================
    -- rst_n is asynchronous to gmii_rx_clk (a PHY-sourced clock). Async assert,
    -- 2-FF sync deassert, matching the rgmii_if / gmii_cdc reset style.
    process (gmii_rx_clk, rst_n)
    begin
        if rst_n = '0' then
            rx_rst_n_s2 <= '0';
            rx_rst_n_s1 <= '0';
        elsif rising_edge(gmii_rx_clk) then
            rx_rst_n_s2 <= rx_rst_n_s1;
            rx_rst_n_s1 <= '1';
        end if;
    end process;

    process (gmii_rx_clk, rx_rst_n_s2)
    begin
        if rx_rst_n_s2 = '0' then
            gmii_rxd_int   <= (others => '0');
            gmii_rx_dv_int <= '0';
            gmii_rx_er_int <= '0';
        elsif rising_edge(gmii_rx_clk) then
            gmii_rxd_int   <= gmii_rxd;
            gmii_rx_dv_int <= gmii_rx_dv;
            gmii_rx_er_int <= gmii_rx_er;
        end if;
    end process;

end architecture rtl;
