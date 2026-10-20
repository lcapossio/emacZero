-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- udp_iperf_sink_p5001.vhd - Parity-only wrapper: udp_iperf_sink with
-- LISTEN_PORT = x"1389" (16'd5001), the value arty_a7_top and zcu106_eth_demo
-- use. VHDL twin of udp_iperf_sink_p5001.v; same ports, same instance.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity udp_iperf_sink_p5001 is
    port (
        clk                : in  std_logic;
        rst_n              : in  std_logic;
        udp_rx_data        : in  std_logic_vector(7 downto 0);
        udp_rx_valid       : in  std_logic;
        udp_rx_last        : in  std_logic;
        udp_rx_err         : in  std_logic;
        udp_rx_src_ip      : in  std_logic_vector(31 downto 0);
        udp_rx_src_port    : in  std_logic_vector(15 downto 0);
        udp_rx_dst_port    : in  std_logic_vector(15 downto 0);
        udp_rx_length      : in  std_logic_vector(15 downto 0);
        clear_stats        : in  std_logic;
        stat_packets       : out std_logic_vector(31 downto 0);
        stat_bytes         : out std_logic_vector(31 downto 0);
        stat_first_seq     : out std_logic_vector(31 downto 0);
        stat_last_seq      : out std_logic_vector(31 downto 0);
        stat_seq_gaps      : out std_logic_vector(31 downto 0);
        stat_out_of_order  : out std_logic_vector(31 downto 0);
        stat_final_packets : out std_logic_vector(31 downto 0);
        stat_last_src_ip   : out std_logic_vector(31 downto 0);
        stat_last_src_port : out std_logic_vector(15 downto 0)
    );
end entity udp_iperf_sink_p5001;

architecture wrap of udp_iperf_sink_p5001 is
begin
    u_dut : entity work.udp_iperf_sink
        generic map (LISTEN_PORT => x"1389")
        port map (
            clk                => clk,
            rst_n              => rst_n,
            udp_rx_data        => udp_rx_data,
            udp_rx_valid       => udp_rx_valid,
            udp_rx_last        => udp_rx_last,
            udp_rx_err         => udp_rx_err,
            udp_rx_src_ip      => udp_rx_src_ip,
            udp_rx_src_port    => udp_rx_src_port,
            udp_rx_dst_port    => udp_rx_dst_port,
            udp_rx_length      => udp_rx_length,
            clear_stats        => clear_stats,
            stat_packets       => stat_packets,
            stat_bytes         => stat_bytes,
            stat_first_seq     => stat_first_seq,
            stat_last_seq      => stat_last_seq,
            stat_seq_gaps      => stat_seq_gaps,
            stat_out_of_order  => stat_out_of_order,
            stat_final_packets => stat_final_packets,
            stat_last_src_ip   => stat_last_src_ip,
            stat_last_src_port => stat_last_src_port
        );
end architecture wrap;
