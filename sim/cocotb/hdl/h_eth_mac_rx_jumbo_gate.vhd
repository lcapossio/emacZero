-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- h_eth_mac_rx_jumbo_gate.vhd - cocotb harness for tb_eth_mac_rx_jumbo_gate.v
--
-- One eth_mac_tx and two eth_mac_rx wired as in the bench: u_rx with the
-- default limits, u_rx2 with MAX_FRAME_JUMBO = 1518, both fed by the same
-- loopback register (lb_*), which the test drives from Python on the falling
-- edge; gmii_tx* are outputs for that. RX tie-offs are the bench's constants.
-- Port names follow the bench's net names. Same entity in
-- h_eth_mac_rx_jumbo_gate.v. VHDL-93.
-- AXIS_FIFO_ADDR_WIDTH is passed to both RXs (bench: the default, 11); it is
-- a generic only so the equivalence proof can shrink the FIFO.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity h_eth_mac_rx_jumbo_gate is
    generic (
        AXIS_FIFO_ADDR_WIDTH : integer := 11
    );
    port (
        clk        : in  std_logic;
        rst_n      : in  std_logic;

        -- TX AXI4-Stream input
        tx_tdata   : in  std_logic_vector(7 downto 0);
        tx_tvalid  : in  std_logic;
        tx_tready  : out std_logic;
        tx_tlast   : in  std_logic;

        -- TX GMII output (to the test's loopback register)
        gmii_txd   : out std_logic_vector(7 downto 0);
        gmii_tx_en : out std_logic;
        gmii_tx_er : out std_logic;

        -- RX GMII input (the loopback register's outputs), shared by both RXs
        lb_rxd     : in  std_logic_vector(7 downto 0);
        lb_rx_dv   : in  std_logic;
        lb_rx_er   : in  std_logic;

        jumbo_en   : in  std_logic;

        -- u_rx (MAX_FRAME_JUMBO = 9018)
        rx_tdata   : out std_logic_vector(7 downto 0);
        rx_tvalid  : out std_logic;
        rx_tlast   : out std_logic;
        rx_terror  : out std_logic;
        rx_tsof    : out std_logic;
        stat_done1 : out std_logic;
        stat_ovs1  : out std_logic;

        -- u_rx2 (MAX_FRAME_JUMBO = 1518)
        rx2_tvalid : out std_logic;
        rx2_tlast  : out std_logic;
        rx2_terror : out std_logic;
        stat_done2 : out std_logic;
        stat_ovs2  : out std_logic
    );
end entity h_eth_mac_rx_jumbo_gate;

architecture rtl of h_eth_mac_rx_jumbo_gate is
begin

    u_tx : entity work.eth_mac_tx
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
            AXIS_FIFO_ADDR_WIDTH => AXIS_FIFO_ADDR_WIDTH
        )
        port map (
            clk               => clk,
            rst_n             => rst_n,
            gmii_rxd          => lb_rxd,
            gmii_rx_dv        => lb_rx_dv,
            gmii_rx_er        => lb_rx_er,
            our_mac           => x"FFFFFFFFFFFF",
            promisc           => '0',
            passthrough       => '0',
            jumbo_en          => jumbo_en,
            rx_csum_en        => '0',
            mcast_hash_table  => (others => '0'),
            m_axis_tdata      => rx_tdata,
            m_axis_tvalid     => rx_tvalid,
            m_axis_tready     => '1',
            m_axis_tlast      => rx_tlast,
            m_axis_terror     => rx_terror,
            m_axis_tsof       => rx_tsof,
            stat_done         => stat_done1,
            stat_len          => open,
            stat_err_fcs      => open,
            stat_err_align    => open,
            stat_err_overflow => open,
            stat_err_oversize => stat_ovs1,
            stat_err_csum     => open,
            stat_is_bcast     => open,
            stat_is_mcast     => open,
            stat_drop         => open
        );

    u_rx2 : entity work.eth_mac_rx
        generic map (
            AXIS_FIFO_ADDR_WIDTH => AXIS_FIFO_ADDR_WIDTH,
            MAX_FRAME_JUMBO      => 1518
        )
        port map (
            clk               => clk,
            rst_n             => rst_n,
            gmii_rxd          => lb_rxd,
            gmii_rx_dv        => lb_rx_dv,
            gmii_rx_er        => lb_rx_er,
            our_mac           => x"FFFFFFFFFFFF",
            promisc           => '0',
            passthrough       => '0',
            jumbo_en          => jumbo_en,
            rx_csum_en        => '0',
            mcast_hash_table  => (others => '0'),
            m_axis_tdata      => open,
            m_axis_tvalid     => rx2_tvalid,
            m_axis_tready     => '1',
            m_axis_tlast      => rx2_tlast,
            m_axis_terror     => rx2_terror,
            m_axis_tsof       => open,
            stat_done         => stat_done2,
            stat_len          => open,
            stat_err_fcs      => open,
            stat_err_align    => open,
            stat_err_overflow => open,
            stat_err_oversize => stat_ovs2,
            stat_err_csum     => open,
            stat_is_bcast     => open,
            stat_is_mcast     => open,
            stat_drop         => open
        );

end architecture rtl;
