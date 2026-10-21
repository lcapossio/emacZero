-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- h_eth_mac_rx_loop.vhd - cocotb harness: eth_mac_tx feeding eth_mac_rx
--
-- The DUT pair of tb_eth_mac_rx_mcast.v, tb_eth_mac_rx_backpressure.v,
-- tb_eth_mac_rx_byte0.v and tb_eth_mac_sys_jumbo.v. Those benches loop the TX
-- GMII outputs back into the RX GMII inputs through a negedge register
-- (lb_*); the test drives that register from Python, so here gmii_tx* are
-- outputs and lb_* are inputs. The RX configuration inputs that the benches
-- tie to different constants are ports; the test drives them.
-- Port names follow the benches' net names. Same entity in
-- h_eth_mac_rx_loop.v. VHDL-93.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity h_eth_mac_rx_loop is
    generic (
        TX_MAX_FRAME         : integer := 9018;
        MCAST_HASH_FILTER    : integer := 0;
        AXIS_FIFO_ADDR_WIDTH : integer := 11
    );
    port (
        clk               : in  std_logic;
        rst_n             : in  std_logic;

        -- TX AXI4-Stream input
        tx_tdata          : in  std_logic_vector(7 downto 0);
        tx_tvalid         : in  std_logic;
        tx_tready         : out std_logic;
        tx_tlast          : in  std_logic;

        -- TX GMII output (to the test's loopback register)
        gmii_txd          : out std_logic_vector(7 downto 0);
        gmii_tx_en        : out std_logic;
        gmii_tx_er        : out std_logic;

        -- RX GMII input (the loopback register's outputs)
        lb_rxd            : in  std_logic_vector(7 downto 0);
        lb_rx_dv          : in  std_logic;
        lb_rx_er          : in  std_logic;

        -- RX configuration
        our_mac           : in  std_logic_vector(47 downto 0);
        promisc           : in  std_logic;
        passthrough       : in  std_logic;
        jumbo_en          : in  std_logic;
        rx_csum_en        : in  std_logic;
        mcast_hash_table  : in  std_logic_vector(63 downto 0);

        -- RX AXI4-Stream output
        rx_tdata          : out std_logic_vector(7 downto 0);
        rx_tvalid         : out std_logic;
        rx_tready         : in  std_logic;
        rx_tlast          : out std_logic;
        rx_terror         : out std_logic;
        rx_tsof           : out std_logic;

        -- RX stat pulses
        stat_done         : out std_logic;
        stat_len          : out std_logic_vector(13 downto 0);
        stat_err_fcs      : out std_logic;
        stat_err_align    : out std_logic;
        stat_err_overflow : out std_logic;
        stat_err_oversize : out std_logic;
        stat_err_csum     : out std_logic;
        stat_is_bcast     : out std_logic;
        stat_is_mcast     : out std_logic;
        stat_drop         : out std_logic
    );
end entity h_eth_mac_rx_loop;

architecture rtl of h_eth_mac_rx_loop is
begin

    u_tx : entity work.eth_mac_tx
        generic map (
            MAX_FRAME => TX_MAX_FRAME
        )
        port map (
            clk           => clk,
            rst_n         => rst_n,
            tx_start_ok   => '1',
            gmii_txd      => gmii_txd,
            gmii_tx_en    => gmii_tx_en,
            gmii_tx_er    => gmii_tx_er,
            s_axis_tdata  => tx_tdata,
            s_axis_tvalid => tx_tvalid,
            s_axis_tready => tx_tready,
            s_axis_tkeep  => "1",
            s_axis_tlast  => tx_tlast,
            tx_active     => open,
            dbg_state     => open,
            dbg_stall_cnt => open
        );

    u_rx : entity work.eth_mac_rx
        generic map (
            MCAST_HASH_FILTER    => MCAST_HASH_FILTER,
            AXIS_FIFO_ADDR_WIDTH => AXIS_FIFO_ADDR_WIDTH
        )
        port map (
            clk               => clk,
            rst_n             => rst_n,
            gmii_rxd          => lb_rxd,
            gmii_rx_dv        => lb_rx_dv,
            gmii_rx_er        => lb_rx_er,
            our_mac           => our_mac,
            promisc           => promisc,
            passthrough       => passthrough,
            jumbo_en          => jumbo_en,
            rx_csum_en        => rx_csum_en,
            mcast_hash_table  => mcast_hash_table,
            m_axis_tdata      => rx_tdata,
            m_axis_tvalid     => rx_tvalid,
            m_axis_tready     => rx_tready,
            m_axis_tlast      => rx_tlast,
            m_axis_terror     => rx_terror,
            m_axis_tsof       => rx_tsof,
            stat_done         => stat_done,
            stat_len          => stat_len,
            stat_err_fcs      => stat_err_fcs,
            stat_err_align    => stat_err_align,
            stat_err_overflow => stat_err_overflow,
            stat_err_oversize => stat_err_oversize,
            stat_err_csum     => stat_err_csum,
            stat_is_bcast     => stat_is_bcast,
            stat_is_mcast     => stat_is_mcast,
            stat_drop         => stat_drop
        );

end architecture rtl;
