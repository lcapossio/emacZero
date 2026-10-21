-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- udp_blast_trigger_alt.vhd - Parity-only wrapper: udp_blast_trigger with every
-- generic away from its default (TRIGGER_PORT x"1234", IGNORE_SRC_PORT x"5678",
-- DEFAULT_COUNT 7, DEFAULT_PAYLOAD 99). VHDL twin of udp_blast_trigger_alt.v;
-- same ports, same instance.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity udp_blast_trigger_alt is
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        udp_rx_data     : in  std_logic_vector(7 downto 0);
        udp_rx_valid    : in  std_logic;
        udp_rx_last     : in  std_logic;
        udp_rx_err      : in  std_logic;
        udp_rx_src_mac  : in  std_logic_vector(47 downto 0);
        udp_rx_src_ip   : in  std_logic_vector(31 downto 0);
        udp_rx_src_port : in  std_logic_vector(15 downto 0);
        udp_rx_dst_port : in  std_logic_vector(15 downto 0);
        busy            : in  std_logic;
        start           : out std_logic;
        dst_mac         : out std_logic_vector(47 downto 0);
        dst_ip          : out std_logic_vector(31 downto 0);
        dst_port        : out std_logic_vector(15 downto 0);
        src_port        : out std_logic_vector(15 downto 0);
        ifg_delay       : out std_logic_vector(23 downto 0);
        packet_count    : out std_logic_vector(31 downto 0);
        payload_size    : out std_logic_vector(15 downto 0)
    );
end entity udp_blast_trigger_alt;

architecture wrap of udp_blast_trigger_alt is
begin
    u_dut : entity work.udp_blast_trigger
        generic map (
            TRIGGER_PORT    => x"1234",
            IGNORE_SRC_PORT => x"5678",
            DEFAULT_COUNT   => x"00000007",  -- 32'd7
            DEFAULT_PAYLOAD => x"0063"       -- 16'd99
        )
        port map (
            clk             => clk,
            rst_n           => rst_n,
            udp_rx_data     => udp_rx_data,
            udp_rx_valid    => udp_rx_valid,
            udp_rx_last     => udp_rx_last,
            udp_rx_err      => udp_rx_err,
            udp_rx_src_mac  => udp_rx_src_mac,
            udp_rx_src_ip   => udp_rx_src_ip,
            udp_rx_src_port => udp_rx_src_port,
            udp_rx_dst_port => udp_rx_dst_port,
            busy            => busy,
            start           => start,
            dst_mac         => dst_mac,
            dst_ip          => dst_ip,
            dst_port        => dst_port,
            src_port        => src_port,
            ifg_delay       => ifg_delay,
            packet_count    => packet_count,
            payload_size    => payload_size
        );
end architecture wrap;
