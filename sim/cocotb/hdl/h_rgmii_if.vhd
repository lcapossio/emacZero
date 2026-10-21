-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- h_rgmii_if.vhd - cocotb harness: two rgmii_if at 1G, TX pins looped to RX
--
-- The DUT pair of tb_rgmii_if.v. u_tx sends at 1G; its RGMII pins drive
-- u_rx's RGMII inputs directly (no board delay), and u_rx takes them on
-- clk_125_90 as its RXC. u_tx's own RX side is tied off with RXC = clk_125,
-- as in the bench. The test drives the clocks, reset and u_tx's GMII inputs.
-- The pins are ports so the test can read them; the _i nets carry them to
-- u_rx (a VHDL-93 out port cannot be read back). Port names follow the
-- bench's net names. Same entity in h_rgmii_if.v. VHDL-93.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity h_rgmii_if is
    port (
        clk_125       : in  std_logic;
        clk_125_90    : in  std_logic;
        rst_n         : in  std_logic;

        -- u_tx GMII inputs
        tx_gmii_txd   : in  std_logic_vector(7 downto 0);
        tx_gmii_tx_en : in  std_logic;
        tx_gmii_tx_er : in  std_logic;

        -- RGMII pins, u_tx -> u_rx
        rgmii_txd     : out std_logic_vector(3 downto 0);
        rgmii_tx_ctl  : out std_logic;
        rgmii_txc     : out std_logic;

        -- u_rx GMII outputs
        rx_gmii_rxd   : out std_logic_vector(7 downto 0);
        rx_gmii_rx_dv : out std_logic;
        rx_gmii_rx_er : out std_logic
    );
end entity h_rgmii_if;

architecture rtl of h_rgmii_if is
    signal rgmii_txd_i    : std_logic_vector(3 downto 0);
    signal rgmii_tx_ctl_i : std_logic;
    signal rgmii_txc_i    : std_logic;
begin

    rgmii_txd    <= rgmii_txd_i;
    rgmii_tx_ctl <= rgmii_tx_ctl_i;
    rgmii_txc    <= rgmii_txc_i;

    u_tx : entity work.rgmii_if
        port map (
            clk_125      => clk_125,
            clk_125_90   => clk_125_90,
            rst_n        => rst_n,
            cfg_speed    => "00",
            rgmii_txd    => rgmii_txd_i,
            rgmii_tx_ctl => rgmii_tx_ctl_i,
            rgmii_txc    => rgmii_txc_i,
            rgmii_rxd    => "0000",
            rgmii_rx_ctl => '0',
            rgmii_rxc    => clk_125,
            gmii_txd     => tx_gmii_txd,
            gmii_tx_en   => tx_gmii_tx_en,
            gmii_tx_er   => tx_gmii_tx_er,
            gmii_rxd     => open,
            gmii_rx_dv   => open,
            gmii_rx_er   => open,
            gmii_rx_ce   => open
        );

    u_rx : entity work.rgmii_if
        port map (
            clk_125      => clk_125,
            clk_125_90   => clk_125_90,
            rst_n        => rst_n,
            cfg_speed    => "00",
            rgmii_txd    => open,
            rgmii_tx_ctl => open,
            rgmii_txc    => open,
            rgmii_rxd    => rgmii_txd_i,
            rgmii_rx_ctl => rgmii_tx_ctl_i,
            rgmii_rxc    => clk_125_90,
            gmii_txd     => "00000000",
            gmii_tx_en   => '0',
            gmii_tx_er   => '0',
            gmii_rxd     => rx_gmii_rxd,
            gmii_rx_dv   => rx_gmii_rx_dv,
            gmii_rx_er   => rx_gmii_rx_er,
            gmii_rx_ce   => open
        );

end architecture rtl;
