-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- udp_iperf_sink.vhd - Passive iperf2 UDP receiver/stat counter
-- VHDL port of rtl/net/udp_iperf_sink.v (formally proven equivalent; see
-- sim/parity/).
--
-- Consumes UDP payload bytes from net_rx for the selected iperf sink port.
-- Parses the first 12 payload bytes as iperf2's UDP_datagram header:
--   bytes 0..3  signed packet id, big-endian
--   bytes 4..7  tv_sec  (ignored)
--   bytes 8..11 tv_usec (ignored)
--
-- The module intentionally does not try to emit iperf's server report. It is a
-- hardware-side counter that lets the host send ordinary iperf UDP traffic and
-- then query FPGA-observed packet/byte/loss stats through udp_stats_reply.v.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity udp_iperf_sink is
    generic (
        LISTEN_PORT : std_logic_vector(15 downto 0) := x"0000"  -- 16'd0
    );
    port (
        clk                : in  std_logic;
        rst_n              : in  std_logic;

        udp_rx_data        : in  std_logic_vector(7 downto 0);
        udp_rx_valid       : in  std_logic;
        udp_rx_last        : in  std_logic;
        udp_rx_err         : in  std_logic;      -- with last: discard (net_rx verdict)
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
end entity udp_iperf_sink;

architecture rtl of udp_iperf_sink is

    signal payload_cnt     : unsigned(15 downto 0);
    signal seq_shift       : std_logic_vector(31 downto 0);
    signal pkt_seq         : std_logic_vector(31 downto 0);
    signal pkt_payload_len : unsigned(15 downto 0);
    signal pkt_has_header  : std_logic;
    signal have_seq        : std_logic;
    signal rx_accept       : std_logic;

    signal first_payload_byte  : std_logic;
    signal first_accept        : std_logic;
    signal this_accept         : std_logic;
    signal seq_next            : std_logic_vector(31 downto 0);
    signal pkt_has_header_next : std_logic;
    signal pkt_seq_next        : std_logic_vector(31 downto 0);

    -- Statistics outputs the counters read back.
    signal stat_packets_i       : unsigned(31 downto 0);
    signal stat_bytes_i         : unsigned(31 downto 0);
    signal stat_last_seq_i      : unsigned(31 downto 0);
    signal stat_seq_gaps_i      : unsigned(31 downto 0);
    signal stat_out_of_order_i  : unsigned(31 downto 0);
    signal stat_final_packets_i : unsigned(31 downto 0);

begin

    stat_packets       <= std_logic_vector(stat_packets_i);
    stat_bytes         <= std_logic_vector(stat_bytes_i);
    stat_last_seq      <= std_logic_vector(stat_last_seq_i);
    stat_seq_gaps      <= std_logic_vector(stat_seq_gaps_i);
    stat_out_of_order  <= std_logic_vector(stat_out_of_order_i);
    stat_final_packets <= std_logic_vector(stat_final_packets_i);

    first_payload_byte <= '1' when payload_cnt = 0 else '0';
    first_accept <= '1' when (LISTEN_PORT = x"0000") or
                             (udp_rx_dst_port = LISTEN_PORT)
                    else '0';
    this_accept <= first_accept when first_payload_byte = '1' else rx_accept;
    seq_next <=
        seq_shift(23 downto 0) & udp_rx_data when payload_cnt < 4 else seq_shift;
    pkt_has_header_next <= '1' when pkt_has_header = '1' or payload_cnt = 3 else '0';
    pkt_seq_next <=
        seq_next when payload_cnt = 3 else pkt_seq;

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            payload_cnt          <= (others => '0');
            seq_shift            <= (others => '0');
            pkt_seq              <= (others => '0');
            pkt_payload_len      <= (others => '0');
            pkt_has_header       <= '0';
            have_seq             <= '0';
            rx_accept            <= '0';
            stat_packets_i       <= (others => '0');
            stat_bytes_i         <= (others => '0');
            stat_first_seq       <= (others => '0');
            stat_last_seq_i      <= (others => '0');
            stat_seq_gaps_i      <= (others => '0');
            stat_out_of_order_i  <= (others => '0');
            stat_final_packets_i <= (others => '0');
            stat_last_src_ip     <= (others => '0');
            stat_last_src_port   <= (others => '0');
        elsif rising_edge(clk) then
            if clear_stats = '1' then
                payload_cnt          <= (others => '0');
                seq_shift            <= (others => '0');
                pkt_seq              <= (others => '0');
                pkt_payload_len      <= (others => '0');
                pkt_has_header       <= '0';
                have_seq             <= '0';
                rx_accept            <= '0';
                stat_packets_i       <= (others => '0');
                stat_bytes_i         <= (others => '0');
                stat_first_seq       <= (others => '0');
                stat_last_seq_i      <= (others => '0');
                stat_seq_gaps_i      <= (others => '0');
                stat_out_of_order_i  <= (others => '0');
                stat_final_packets_i <= (others => '0');
                stat_last_src_ip     <= (others => '0');
                stat_last_src_port   <= (others => '0');
            elsif udp_rx_valid = '1' then
                if first_payload_byte = '1' then
                    rx_accept <= first_accept;
                    if unsigned(udp_rx_length) >= 8 then
                        pkt_payload_len <= unsigned(udp_rx_length) - 8;
                    else
                        pkt_payload_len <= (others => '0');
                    end if;
                end if;

                if this_accept = '0' then
                    if udp_rx_last = '1' then
                        payload_cnt     <= (others => '0');
                        seq_shift       <= (others => '0');
                        pkt_seq         <= (others => '0');
                        pkt_payload_len <= (others => '0');
                        pkt_has_header  <= '0';
                        rx_accept       <= '0';
                    end if;
                else
                    payload_cnt <= payload_cnt + 1;
                    if payload_cnt < 4 then
                        seq_shift <= seq_next;
                    end if;
                    if payload_cnt = 3 then
                        pkt_seq        <= seq_next;
                        pkt_has_header <= '1';
                    end if;

                    if udp_rx_last = '1' then
                        if pkt_has_header_next = '1' and udp_rx_err = '0' then
                            stat_last_src_ip   <= udp_rx_src_ip;
                            stat_last_src_port <= udp_rx_src_port;
                            if pkt_seq_next(31) = '1' then
                                stat_final_packets_i <= stat_final_packets_i + 1;
                            else
                                stat_packets_i <= stat_packets_i + 1;
                                stat_bytes_i   <= stat_bytes_i + resize(pkt_payload_len, 32);
                                if have_seq = '0' then
                                    have_seq        <= '1';
                                    stat_first_seq  <= pkt_seq_next;
                                    stat_last_seq_i <= unsigned(pkt_seq_next);
                                elsif unsigned(pkt_seq_next) = stat_last_seq_i + 1 then
                                    stat_last_seq_i <= unsigned(pkt_seq_next);
                                elsif unsigned(pkt_seq_next) > stat_last_seq_i + 1 then
                                    stat_seq_gaps_i <= stat_seq_gaps_i +
                                                       (unsigned(pkt_seq_next) - stat_last_seq_i - 1);
                                    stat_last_seq_i <= unsigned(pkt_seq_next);
                                else
                                    stat_out_of_order_i <= stat_out_of_order_i + 1;
                                end if;
                            end if;
                        end if;
                        payload_cnt     <= (others => '0');
                        seq_shift       <= (others => '0');
                        pkt_seq         <= (others => '0');
                        pkt_payload_len <= (others => '0');
                        pkt_has_header  <= '0';
                        rx_accept       <= '0';
                    end if;
                end if;
            end if;
        end if;
    end process;

end architecture rtl;
