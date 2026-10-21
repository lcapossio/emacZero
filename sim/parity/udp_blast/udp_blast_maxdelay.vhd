-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- Parity wrapper: udp_blast with START_DELAY_CYCLES = -1 (= 32'hFFFFFFFF in
-- the Verilog `parameter [31:0]`) and USEC_TICK_CYCLES = 0. VHDL side of
-- udp_blast_maxdelay.{v,vhd}; see the .v for why.
library ieee;
use ieee.std_logic_1164.all;

entity udp_blast_maxdelay is
    port (
        clk               : in  std_logic;
        rst_n             : in  std_logic;
        our_mac           : in  std_logic_vector(47 downto 0);
        our_ip            : in  std_logic_vector(31 downto 0);
        dst_mac           : in  std_logic_vector(47 downto 0);
        dst_ip            : in  std_logic_vector(31 downto 0);
        dst_port          : in  std_logic_vector(15 downto 0);
        src_port          : in  std_logic_vector(15 downto 0);
        payload_size      : in  std_logic_vector(13 downto 0);
        enable            : in  std_logic;
        inter_frame_delay : in  std_logic_vector(23 downto 0);
        pkts_sent         : out std_logic_vector(31 downto 0);
        pkt_done_pulse    : out std_logic;
        tx_data           : out std_logic_vector(7 downto 0);
        tx_valid          : out std_logic;
        tx_last           : out std_logic;
        tx_ready          : in  std_logic;
        tx_start          : out std_logic
    );
end entity udp_blast_maxdelay;

architecture rtl of udp_blast_maxdelay is
begin
    u_dut : entity work.udp_blast
        generic map (
            START_DELAY_CYCLES => -1,
            USEC_TICK_CYCLES   => 0
        )
        port map (
            clk               => clk,
            rst_n             => rst_n,
            our_mac           => our_mac,
            our_ip            => our_ip,
            dst_mac           => dst_mac,
            dst_ip            => dst_ip,
            dst_port          => dst_port,
            src_port          => src_port,
            payload_size      => payload_size,
            enable            => enable,
            inter_frame_delay => inter_frame_delay,
            pkts_sent         => pkts_sent,
            pkt_done_pulse    => pkt_done_pulse,
            tx_data           => tx_data,
            tx_valid          => tx_valid,
            tx_last           => tx_last,
            tx_ready          => tx_ready,
            tx_start          => tx_start
        );
end architecture rtl;
