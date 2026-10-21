-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- Parity wrapper: udp_echo with LISTEN_PORT set from an integer generic
-- (default 9999, the port both boards use), because translateHDL param sets
-- cannot set a [15:0] vector parameter / std_logic_vector generic directly.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity udp_echo_listen is
    generic (
        BUF_SIZE : integer := 1024;
        LPORT    : integer := 9999
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
        our_mac         : in  std_logic_vector(47 downto 0);
        our_ip          : in  std_logic_vector(31 downto 0);
        udp_rx_data     : in  std_logic_vector(7 downto 0);
        udp_rx_valid    : in  std_logic;
        udp_rx_last     : in  std_logic;
        udp_rx_err      : in  std_logic;
        udp_rx_src_ip   : in  std_logic_vector(31 downto 0);
        udp_rx_src_port : in  std_logic_vector(15 downto 0);
        udp_rx_dst_port : in  std_logic_vector(15 downto 0);
        udp_rx_length   : in  std_logic_vector(15 downto 0);
        rx_src_mac      : in  std_logic_vector(47 downto 0);
        tx_data         : out std_logic_vector(7 downto 0);
        tx_valid        : out std_logic;
        tx_last         : out std_logic;
        tx_ready        : in  std_logic;
        tx_start        : out std_logic
    );
end entity udp_echo_listen;

architecture rtl of udp_echo_listen is
begin
    u_echo : entity work.udp_echo
        generic map (BUF_SIZE => BUF_SIZE, LISTEN_PORT => std_logic_vector(to_unsigned(LPORT, 16)))
        port map (
            clk => clk, rst_n => rst_n, our_mac => our_mac, our_ip => our_ip,
            udp_rx_data => udp_rx_data, udp_rx_valid => udp_rx_valid,
            udp_rx_last => udp_rx_last, udp_rx_err => udp_rx_err,
            udp_rx_src_ip => udp_rx_src_ip, udp_rx_src_port => udp_rx_src_port,
            udp_rx_dst_port => udp_rx_dst_port, udp_rx_length => udp_rx_length,
            rx_src_mac => rx_src_mac, tx_data => tx_data, tx_valid => tx_valid,
            tx_last => tx_last, tx_ready => tx_ready, tx_start => tx_start
        );
end architecture rtl;
