-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- h_rgmii_if_variants.vhd - cocotb harness: rgmii_if with each RGMII_SPEEDS
--
-- The three instances of tb_rgmii_if_variants.v, all driven by the same GMII
-- inputs (tx_d / tx_en / tx_er):
--   u_1g_only  RGMII_SPEEDS_1G_ONLY ("1G_ONLY"), cfg_speed 00 (1G)
--   u_10_100   RGMII_SPEEDS_10_100  ("10_100"),  cfg_speed 01 (100M),
--              clk_125_90 tied low (unused for 10_100)
--   u_all      RGMII_SPEEDS_ALL     ("ALL"),     cfg_speed 00 (1G)
-- The RX sides are tied off as in the bench. txc_1g_s / txc_100_s are the two
-- TXCs after the bench's 10 ps inertial delay, which drops the zero-time
-- glitches of the behavioural DDR model. Every net the test reads is a port;
-- the _i nets carry the TXCs to the delays (a VHDL-93 out port cannot be read
-- back). Same entity in h_rgmii_if_variants.v. VHDL-93.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity h_rgmii_if_variants is
    generic (
        RGMII_SPEEDS_1G_ONLY : string := "1G_ONLY";
        RGMII_SPEEDS_10_100  : string := "10_100";
        RGMII_SPEEDS_ALL     : string := "ALL"
    );
    port (
        clk_125       : in  std_logic;
        clk_125_90    : in  std_logic;
        rst_n         : in  std_logic;

        tx_d          : in  std_logic_vector(7 downto 0);
        tx_en         : in  std_logic;
        tx_er         : in  std_logic;

        txd_1g_only   : out std_logic_vector(3 downto 0);
        txctl_1g_only : out std_logic;
        txc_1g_only   : out std_logic;
        txd_10_100    : out std_logic_vector(3 downto 0);
        txctl_10_100  : out std_logic;
        txc_10_100    : out std_logic;
        txd_all       : out std_logic_vector(3 downto 0);
        txctl_all     : out std_logic;

        txc_1g_s      : out std_logic;
        txc_100_s     : out std_logic
    );
end entity h_rgmii_if_variants;

architecture rtl of h_rgmii_if_variants is
    signal txc_1g_only_i : std_logic;
    signal txc_10_100_i  : std_logic;
begin

    txc_1g_only <= txc_1g_only_i;
    txc_10_100  <= txc_10_100_i;

    txc_1g_s  <= txc_1g_only_i after 10 ps;
    txc_100_s <= txc_10_100_i  after 10 ps;

    u_1g_only : entity work.rgmii_if
        generic map (
            RGMII_SPEEDS => RGMII_SPEEDS_1G_ONLY
        )
        port map (
            clk_125      => clk_125,
            clk_125_90   => clk_125_90,
            rst_n        => rst_n,
            cfg_speed    => "00",
            rgmii_txd    => txd_1g_only,
            rgmii_tx_ctl => txctl_1g_only,
            rgmii_txc    => txc_1g_only_i,
            rgmii_rxd    => "0000",
            rgmii_rx_ctl => '0',
            rgmii_rxc    => '0',
            gmii_txd     => tx_d,
            gmii_tx_en   => tx_en,
            gmii_tx_er   => tx_er,
            gmii_rxd     => open,
            gmii_rx_dv   => open,
            gmii_rx_er   => open,
            gmii_rx_ce   => open
        );

    u_10_100 : entity work.rgmii_if
        generic map (
            RGMII_SPEEDS => RGMII_SPEEDS_10_100
        )
        port map (
            clk_125      => clk_125,
            clk_125_90   => '0',
            rst_n        => rst_n,
            cfg_speed    => "01",
            rgmii_txd    => txd_10_100,
            rgmii_tx_ctl => txctl_10_100,
            rgmii_txc    => txc_10_100_i,
            rgmii_rxd    => "0000",
            rgmii_rx_ctl => '0',
            rgmii_rxc    => '0',
            gmii_txd     => tx_d,
            gmii_tx_en   => tx_en,
            gmii_tx_er   => tx_er,
            gmii_rxd     => open,
            gmii_rx_dv   => open,
            gmii_rx_er   => open,
            gmii_rx_ce   => open
        );

    u_all : entity work.rgmii_if
        generic map (
            RGMII_SPEEDS => RGMII_SPEEDS_ALL
        )
        port map (
            clk_125      => clk_125,
            clk_125_90   => clk_125_90,
            rst_n        => rst_n,
            cfg_speed    => "00",
            rgmii_txd    => txd_all,
            rgmii_tx_ctl => txctl_all,
            rgmii_txc    => open,
            rgmii_rxd    => "0000",
            rgmii_rx_ctl => '0',
            rgmii_rxc    => '0',
            gmii_txd     => tx_d,
            gmii_tx_en   => tx_en,
            gmii_tx_er   => tx_er,
            gmii_rxd     => open,
            gmii_rx_dv   => open,
            gmii_rx_er   => open,
            gmii_rx_ce   => open
        );

end architecture rtl;
