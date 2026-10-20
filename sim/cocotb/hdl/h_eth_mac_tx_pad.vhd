-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- h_eth_mac_tx_pad.vhd - cocotb harness: the DUT pair of tb_eth_mac_tx_pad.v
--
-- eth_mac_tx (GMII framer) and mii_tx_saf (MII framer) side by side on one
-- AXIS source, wired as the bench wires them: sel_gmii picks the framer that
-- sees s_tvalid and whose tready comes back as s_tready. Port names follow
-- the bench's net names. Generics pass through (defaults = the RTL defaults
-- the bench uses); they exist so the parity proof can run small.
-- Same entity in h_eth_mac_tx_pad.v. VHDL-93.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity h_eth_mac_tx_pad is
    generic (
        MAC_MAX_FRAME       : integer := 9018;
        SAF_MAX_FRAME       : integer := 1518;
        SAF_FIFO_ADDR_WIDTH : integer := 12
    );
    port (
        clk        : in  std_logic;
        mclk       : in  std_logic;
        rst_n      : in  std_logic;

        s_tdata    : in  std_logic_vector(7 downto 0);
        s_tvalid   : in  std_logic;
        s_tlast    : in  std_logic;
        sel_gmii   : in  std_logic;   -- 1 = eth_mac_tx, 0 = mii_tx_saf
        s_tready   : out std_logic;

        gmii_txd   : out std_logic_vector(7 downto 0);
        gmii_tx_en : out std_logic;
        gmii_tx_er : out std_logic;

        mii_txd    : out std_logic_vector(3 downto 0);
        mii_tx_en  : out std_logic
    );
end entity h_eth_mac_tx_pad;

architecture rtl of h_eth_mac_tx_pad is
    signal rdy_g, rdy_m     : std_logic;
    signal tvalid_g         : std_logic;
    signal tvalid_m         : std_logic;
begin

    s_tready <= rdy_g when sel_gmii = '1' else rdy_m;
    tvalid_g <= s_tvalid and sel_gmii;
    tvalid_m <= s_tvalid and not sel_gmii;

    u_gmii : entity work.eth_mac_tx
        generic map (MAX_FRAME => MAC_MAX_FRAME)
        port map (
            clk           => clk,
            rst_n         => rst_n,
            tx_start_ok   => '1',
            gmii_txd      => gmii_txd,
            gmii_tx_en    => gmii_tx_en,
            gmii_tx_er    => gmii_tx_er,
            s_axis_tdata  => s_tdata,
            s_axis_tvalid => tvalid_g,
            s_axis_tready => rdy_g,
            s_axis_tlast  => s_tlast,
            s_axis_tkeep  => "1",
            tx_active     => open,
            dbg_state     => open,
            dbg_stall_cnt => open
        );

    u_mii : entity work.mii_tx_saf
        generic map (
            MAX_FRAME       => SAF_MAX_FRAME,
            FIFO_ADDR_WIDTH => SAF_FIFO_ADDR_WIDTH
        )
        port map (
            clk           => clk,
            rst_n         => rst_n,
            s_axis_tdata  => s_tdata,
            s_axis_tvalid => tvalid_m,
            s_axis_tready => rdy_m,
            s_axis_tlast  => s_tlast,
            tx_start_ok   => '1',
            mii_tx_clk    => mclk,
            mii_txd       => mii_txd,
            mii_tx_en     => mii_tx_en,
            tx_busy       => open,
            tx_fifo_level => open,
            tx_active     => open,
            tx_byte_stb   => open,
            tx_frame_done => open,
            dbg_saf       => open
        );

end architecture rtl;
