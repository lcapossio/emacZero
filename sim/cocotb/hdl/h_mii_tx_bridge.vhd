-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- h_mii_tx_bridge.vhd - cocotb harness: eth_mac_tx feeding mii_if's TX path
--
-- The DUT pair of tb_mii_tx_bridge.v (MII_DEBUG=0) and
-- tb_mii_tx_burst_backpressure.v (MII_DEBUG=1), wired as both benches wire
-- it: eth_mac_tx's GMII output drives mii_if's GMII TX input, mii_if's
-- tx_busy holds off frame starts (tx_start_ok = not tx_busy), the MII RX
-- inputs are tied idle and both MII clocks are mii_clk. The GMII nets,
-- tx_busy, tx_fifo_level and the two TX debug strobes the backpressure bench
-- counts are outputs. Port names follow the benches' net names. Same entity
-- in h_mii_tx_bridge.v. VHDL-93 (outputs read back through *_i signals).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity h_mii_tx_bridge is
    generic (
        MII_DEBUG : integer := 0
    );
    port (
        clk              : in  std_logic;
        mii_clk          : in  std_logic;
        rst_n            : in  std_logic;

        tx_data          : in  std_logic_vector(7 downto 0);
        tx_valid         : in  std_logic;
        tx_last          : in  std_logic;
        tx_ready         : out std_logic;

        gmii_txd         : out std_logic_vector(7 downto 0);
        gmii_tx_en       : out std_logic;
        gmii_tx_er       : out std_logic;

        mii_txd          : out std_logic_vector(3 downto 0);
        mii_tx_en        : out std_logic;

        tx_busy          : out std_logic;
        tx_fifo_level    : out std_logic_vector(12 downto 0);
        dbg_tx_len_wr_en : out std_logic;
        dbg_tx_wr_full   : out std_logic
    );
end entity h_mii_tx_bridge;

architecture rtl of h_mii_tx_bridge is
    signal gmii_txd_i   : std_logic_vector(7 downto 0);
    signal gmii_tx_en_i : std_logic;
    signal gmii_tx_er_i : std_logic;
    signal tx_busy_i    : std_logic;
    signal tx_start_ok  : std_logic;
begin

    gmii_txd    <= gmii_txd_i;
    gmii_tx_en  <= gmii_tx_en_i;
    gmii_tx_er  <= gmii_tx_er_i;
    tx_busy     <= tx_busy_i;
    tx_start_ok <= not tx_busy_i;

    u_mii : entity work.mii_if
        generic map (MII_DEBUG => MII_DEBUG)
        port map (
            clk                   => clk,
            rst_n                 => rst_n,
            mii_rxd               => "0000",
            mii_rx_dv             => '0',
            mii_rx_er             => '0',
            mii_rx_clk            => mii_clk,
            mii_col               => '0',
            mii_crs               => '0',
            mii_txd               => mii_txd,
            mii_tx_en             => mii_tx_en,
            mii_tx_clk            => mii_clk,
            gmii_txd              => gmii_txd_i,
            gmii_tx_en            => gmii_tx_en_i,
            gmii_tx_er            => gmii_tx_er_i,
            gmii_rxd              => open,
            gmii_rx_dv            => open,
            gmii_rx_er            => open,
            mii_tx_clk_out        => open,
            tx_busy               => tx_busy_i,
            tx_fifo_level         => tx_fifo_level,
            dbg_tx_fifo_empty     => open,
            dbg_rx_prog_empty     => open,
            dbg_rx_rd_empty       => open,
            dbg_rx_reading        => open,
            dbg_rx_frames_pending => open,
            dbg_tx_len_wr_en      => dbg_tx_len_wr_en,
            dbg_tx_wr_full        => dbg_tx_wr_full
        );

    u_mac_tx : entity work.eth_mac_tx
        port map (
            clk           => clk,
            rst_n         => rst_n,
            tx_start_ok   => tx_start_ok,
            gmii_txd      => gmii_txd_i,
            gmii_tx_en    => gmii_tx_en_i,
            gmii_tx_er    => gmii_tx_er_i,
            s_axis_tdata  => tx_data,
            s_axis_tvalid => tx_valid,
            s_axis_tready => tx_ready,
            s_axis_tlast  => tx_last,
            s_axis_tkeep  => "1",
            tx_active     => open,
            dbg_state     => open,
            dbg_stall_cnt => open
        );

end architecture rtl;
