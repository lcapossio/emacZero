-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- h_rgmii_if_100m.vhd - cocotb harness: two rgmii_if, TX pins looped to RX
-- through the board delay, RX clocked by the forwarded TXC
--
-- The DUT pair of tb_rgmii_if_100m.v and tb_rgmii_if_speed_switch.v, which
-- wire it identically (speed_switch ties u_tx's gmii_tx_er low; its test
-- drives tx_gmii_tx_er 0). Both instances share cfg_speed. The nets are
-- those of the benches:
--   txd_s / ctl_s / txc_s       the pins after a 10 ps inertial delay, which
--                               drops the zero-time glitches of the
--                               behavioural DDR model (the PHY's view)
--   rgmii_rxd / _rx_ctl / _rxc  those, 3 ns later (board delay, same on clock
--                               and data), into u_rx; rgmii_rxc is u_rx's RXC
-- The delays are the benches' own continuous assignments (inertial, as a
-- Verilog assign #d). Every net the test reads is a port; the _i nets carry
-- them inside (a VHDL-93 out port cannot be read back). Same entity in
-- h_rgmii_if_100m.v. VHDL-93.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity h_rgmii_if_100m is
    port (
        clk_125       : in  std_logic;
        clk_125_90    : in  std_logic;
        rst_n         : in  std_logic;
        cfg_speed     : in  std_logic_vector(1 downto 0);

        -- u_tx GMII inputs
        tx_gmii_txd   : in  std_logic_vector(7 downto 0);
        tx_gmii_tx_en : in  std_logic;
        tx_gmii_tx_er : in  std_logic;

        -- u_tx RGMII pins
        rgmii_txd     : out std_logic_vector(3 downto 0);
        rgmii_tx_ctl  : out std_logic;
        rgmii_txc     : out std_logic;

        -- The pins after 10 ps
        txd_s         : out std_logic_vector(3 downto 0);
        ctl_s         : out std_logic;
        txc_s         : out std_logic;

        -- u_rx RGMII inputs (3 ns further)
        rgmii_rxd     : out std_logic_vector(3 downto 0);
        rgmii_rx_ctl  : out std_logic;
        rgmii_rxc     : out std_logic;

        -- u_rx GMII outputs
        rx_gmii_rxd   : out std_logic_vector(7 downto 0);
        rx_gmii_rx_dv : out std_logic;
        rx_gmii_rx_er : out std_logic;
        rx_gmii_rx_ce : out std_logic
    );
end entity h_rgmii_if_100m;

architecture rtl of h_rgmii_if_100m is
    signal rgmii_txd_i    : std_logic_vector(3 downto 0);
    signal rgmii_tx_ctl_i : std_logic;
    signal rgmii_txc_i    : std_logic;
    signal txd_s_i        : std_logic_vector(3 downto 0);
    signal ctl_s_i        : std_logic;
    signal txc_s_i        : std_logic;
    signal rgmii_rxd_i    : std_logic_vector(3 downto 0);
    signal rgmii_rx_ctl_i : std_logic;
    signal rgmii_rxc_i    : std_logic;
begin

    txd_s_i <= rgmii_txd_i    after 10 ps;
    ctl_s_i <= rgmii_tx_ctl_i after 10 ps;
    txc_s_i <= rgmii_txc_i    after 10 ps;

    rgmii_rxd_i    <= txd_s_i after 3 ns;
    rgmii_rx_ctl_i <= ctl_s_i after 3 ns;
    rgmii_rxc_i    <= txc_s_i after 3 ns;

    rgmii_txd    <= rgmii_txd_i;
    rgmii_tx_ctl <= rgmii_tx_ctl_i;
    rgmii_txc    <= rgmii_txc_i;
    txd_s        <= txd_s_i;
    ctl_s        <= ctl_s_i;
    txc_s        <= txc_s_i;
    rgmii_rxd    <= rgmii_rxd_i;
    rgmii_rx_ctl <= rgmii_rx_ctl_i;
    rgmii_rxc    <= rgmii_rxc_i;

    u_tx : entity work.rgmii_if
        port map (
            clk_125      => clk_125,
            clk_125_90   => clk_125_90,
            rst_n        => rst_n,
            cfg_speed    => cfg_speed,
            rgmii_txd    => rgmii_txd_i,
            rgmii_tx_ctl => rgmii_tx_ctl_i,
            rgmii_txc    => rgmii_txc_i,
            rgmii_rxd    => "0000",
            rgmii_rx_ctl => '0',
            rgmii_rxc    => '0',
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
            cfg_speed    => cfg_speed,
            rgmii_txd    => open,
            rgmii_tx_ctl => open,
            rgmii_txc    => open,
            rgmii_rxd    => rgmii_rxd_i,
            rgmii_rx_ctl => rgmii_rx_ctl_i,
            rgmii_rxc    => rgmii_rxc_i,
            gmii_txd     => "00000000",
            gmii_tx_en   => '0',
            gmii_tx_er   => '0',
            gmii_rxd     => rx_gmii_rxd,
            gmii_rx_dv   => rx_gmii_rx_dv,
            gmii_rx_er   => rx_gmii_rx_er,
            gmii_rx_ce   => rx_gmii_rx_ce
        );

end architecture rtl;
