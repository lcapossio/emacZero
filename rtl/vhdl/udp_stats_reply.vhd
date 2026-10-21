-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- udp_stats_reply.vhd - Fixed binary UDP stats responder
-- VHDL port of rtl/net/udp_stats_reply.v (formally proven equivalent; see sim/parity/).
--
-- Query payload:
--   "G" -> reply with current stats
--   "C" -> clear stats and reply with the pre-clear snapshot
--
-- Reply payload is 44 bytes:
--   0..3   "IPS0"
--   4..7   packets
--   8..11  bytes
--   12..15 first_seq
--   16..19 last_seq
--   20..23 seq_gaps
--   24..27 out_of_order
--   28..31 final_packets
--   32..35 last_src_ip
--   36..37 last_src_port
--   38..39 flags/reserved
--   40..43 magic "DONE"
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity udp_stats_reply is
    port (
        clk                : in  std_logic;
        rst_n              : in  std_logic;

        our_mac            : in  std_logic_vector(47 downto 0);
        our_ip             : in  std_logic_vector(31 downto 0);
        stats_port         : in  std_logic_vector(15 downto 0);

        udp_rx_data        : in  std_logic_vector(7 downto 0);
        udp_rx_valid       : in  std_logic;
        udp_rx_last        : in  std_logic;
        udp_rx_err         : in  std_logic;      -- with last: discard (net_rx verdict)
        udp_rx_src_ip      : in  std_logic_vector(31 downto 0);
        udp_rx_src_port    : in  std_logic_vector(15 downto 0);
        udp_rx_dst_port    : in  std_logic_vector(15 downto 0);
        rx_src_mac         : in  std_logic_vector(47 downto 0);

        stat_packets       : in  std_logic_vector(31 downto 0);
        stat_bytes         : in  std_logic_vector(31 downto 0);
        stat_first_seq     : in  std_logic_vector(31 downto 0);
        stat_last_seq      : in  std_logic_vector(31 downto 0);
        stat_seq_gaps      : in  std_logic_vector(31 downto 0);
        stat_out_of_order  : in  std_logic_vector(31 downto 0);
        stat_final_packets : in  std_logic_vector(31 downto 0);
        stat_last_src_ip   : in  std_logic_vector(31 downto 0);
        stat_last_src_port : in  std_logic_vector(15 downto 0);

        clear_stats        : out std_logic;

        tx_data            : out std_logic_vector(7 downto 0);
        tx_valid           : out std_logic;
        tx_last            : out std_logic;
        tx_ready           : in  std_logic;
        tx_start           : out std_logic
    );
end entity udp_stats_reply;

architecture rtl of udp_stats_reply is

    constant PAYLOAD_LEN   : unsigned(15 downto 0) := to_unsigned(44, 16);
    constant IP_TOTAL_LEN  : unsigned(15 downto 0) := to_unsigned(28, 16) + PAYLOAD_LEN;
    constant UDP_TOTAL_LEN : unsigned(15 downto 0) := to_unsigned(8, 16) + PAYLOAD_LEN;

    signal pkt_ready      : std_logic;
    signal reply_active   : std_logic;
    signal query_is_clear : std_logic;
    signal reply_dst_ip   : std_logic_vector(31 downto 0);
    signal reply_dst_mac  : std_logic_vector(47 downto 0);
    signal reply_dst_port : std_logic_vector(15 downto 0);

    signal lat_packets       : std_logic_vector(31 downto 0);
    signal lat_bytes         : std_logic_vector(31 downto 0);
    signal lat_first_seq     : std_logic_vector(31 downto 0);
    signal lat_last_seq      : std_logic_vector(31 downto 0);
    signal lat_seq_gaps      : std_logic_vector(31 downto 0);
    signal lat_out_of_order  : std_logic_vector(31 downto 0);
    signal lat_final_packets : std_logic_vector(31 downto 0);
    signal lat_last_src_ip   : std_logic_vector(31 downto 0);
    signal lat_last_src_port : std_logic_vector(15 downto 0);

    constant RX_IDLE    : std_logic_vector(1 downto 0) := "00";  -- 2'd0
    constant RX_DRAIN   : std_logic_vector(1 downto 0) := "01";  -- 2'd1
    constant RX_CAPTURE : std_logic_vector(1 downto 0) := "10";  -- 2'd2

    signal rx_state         : std_logic_vector(1 downto 0);
    signal reply_take       : std_logic;
    signal query_clear_next : std_logic;
    signal do_latch_query   : std_logic;

    constant TX_IDLE    : std_logic_vector(1 downto 0) := "00";  -- 2'd0
    constant TX_ETH_HDR : std_logic_vector(1 downto 0) := "01";  -- 2'd1
    constant TX_IP_HDR  : std_logic_vector(1 downto 0) := "10";  -- 2'd2
    constant TX_UDP     : std_logic_vector(1 downto 0) := "11";  -- 2'd3

    signal tx_state  : std_logic_vector(1 downto 0);
    signal tx_cnt    : unsigned(5 downto 0);
    signal src_valid : std_logic;
    signal src_last  : std_logic;
    signal ip_id_cnt : unsigned(15 downto 0);

    signal ip_csum_acc : unsigned(31 downto 0);
    signal ip_fold1    : unsigned(16 downto 0);
    signal ip_fold2    : unsigned(15 downto 0);
    signal ip_checksum : std_logic_vector(15 downto 0);

    -- 1-deep AXIS register-slice signals + combinational mux, declared ahead of
    -- the TX FSM that references src_ready and tx_data_mux (logic is below).
    signal r_data      : std_logic_vector(7 downto 0);
    signal r_valid     : std_logic;
    signal r_last      : std_logic;
    signal tx_data_mux : std_logic_vector(7 downto 0);
    signal src_ready   : std_logic;

begin

    query_clear_next <= '1' when (rx_state = RX_IDLE and udp_rx_data = x"43") or
                                 (rx_state /= RX_IDLE and query_is_clear = '1')
                        else '0';
    do_latch_query <= '1' when udp_rx_valid = '1' and udp_rx_err = '0' and
                               ((rx_state = RX_IDLE and udp_rx_dst_port = stats_port and udp_rx_last = '1') or
                                (rx_state = RX_CAPTURE and udp_rx_last = '1'))
                      else '0';

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            pkt_ready         <= '0';
            query_is_clear    <= '0';
            reply_dst_ip      <= (others => '0');
            reply_dst_mac     <= (others => '0');
            reply_dst_port    <= (others => '0');
            rx_state          <= RX_IDLE;
            clear_stats       <= '0';
            lat_packets       <= (others => '0');
            lat_bytes         <= (others => '0');
            lat_first_seq     <= (others => '0');
            lat_last_seq      <= (others => '0');
            lat_seq_gaps      <= (others => '0');
            lat_out_of_order  <= (others => '0');
            lat_final_packets <= (others => '0');
            lat_last_src_ip   <= (others => '0');
            lat_last_src_port <= (others => '0');
        elsif rising_edge(clk) then
            clear_stats <= '0';
            if reply_take = '1' then
                pkt_ready <= '0';
            elsif udp_rx_valid = '1' and reply_active = '0' and pkt_ready = '0' then
                if do_latch_query = '1' then
                    pkt_ready         <= '1';
                    reply_dst_ip      <= udp_rx_src_ip;
                    reply_dst_mac     <= rx_src_mac;
                    reply_dst_port    <= udp_rx_src_port;
                    lat_packets       <= stat_packets;
                    lat_bytes         <= stat_bytes;
                    lat_first_seq     <= stat_first_seq;
                    lat_last_seq      <= stat_last_seq;
                    lat_seq_gaps      <= stat_seq_gaps;
                    lat_out_of_order  <= stat_out_of_order;
                    lat_final_packets <= stat_final_packets;
                    lat_last_src_ip   <= stat_last_src_ip;
                    lat_last_src_port <= stat_last_src_port;
                    clear_stats       <= query_clear_next;
                    query_is_clear    <= '0';
                    rx_state          <= RX_IDLE;
                else
                    case rx_state is
                        when RX_IDLE =>
                            if udp_rx_dst_port = stats_port then
                                if udp_rx_data = x"43" then  -- "C"
                                    query_is_clear <= '1';
                                else
                                    query_is_clear <= '0';
                                end if;
                                rx_state <= RX_CAPTURE;
                            else
                                if udp_rx_last = '1' then
                                    rx_state <= RX_IDLE;
                                else
                                    rx_state <= RX_DRAIN;
                                end if;
                            end if;

                        when RX_CAPTURE =>
                            -- Payload bytes after byte 0 are ignored; the final
                            -- byte is handled by do_latch_query above.
                            null;

                        when RX_DRAIN =>
                            if udp_rx_last = '1' then
                                rx_state <= RX_IDLE;
                            end if;

                        when others =>
                            rx_state <= RX_IDLE;
                    end case;
                end if;
            elsif udp_rx_valid = '1' and udp_rx_last = '1' then
                -- Drop arrivals that complete while a reply is active/pending.
                rx_state       <= RX_IDLE;
                query_is_clear <= '0';
            end if;
            -- A discarded datagram (net_rx error) ends here too.
            if udp_rx_valid = '1' and udp_rx_last = '1' and udp_rx_err = '1' then
                rx_state       <= RX_IDLE;
                query_is_clear <= '0';
            end if;
        end if;
    end process;

    ip_fold1    <= resize(ip_csum_acc(15 downto 0), 17) + resize(ip_csum_acc(31 downto 16), 17);
    ip_fold2    <= ip_fold1(15 downto 0) + resize(ip_fold1(16 downto 16), 16);
    ip_checksum <= not std_logic_vector(ip_fold2);
    reply_take  <= '1' when tx_state = TX_IDLE and pkt_ready = '1' and reply_active = '0' else '0';

    src_ready <= (not r_valid) or tx_ready;

    process (clk, rst_n)
        -- {16'd0, ip_id_cnt + 16'd1}: the 16-bit sum wraps inside the
        -- concatenation before it is zero-extended.
        variable v_id16 : unsigned(15 downto 0);
    begin
        if rst_n = '0' then
            tx_state     <= TX_IDLE;
            tx_cnt       <= (others => '0');
            reply_active <= '0';
            src_valid    <= '0';
            src_last     <= '0';
            tx_start     <= '0';
            ip_id_cnt    <= to_unsigned(5000, 16);
            ip_csum_acc  <= (others => '0');
        elsif rising_edge(clk) then
            -- tx_valid is r_valid (read here instead of the out port).
            if tx_ready = '1' and r_valid = '1' then
                tx_start <= '0';
            end if;
            -- Hold tlast until the output slice captures it: the slice samples
            -- src_* only while src_ready is high, so an unconditional clear drops
            -- tlast when the sink stalls on that beat and merges two frames.
            if src_ready = '1' then
                src_last <= '0';
            end if;

            case tx_state is
                when TX_IDLE =>
                    src_valid <= '0';
                    if reply_take = '1' then
                        tx_state     <= TX_ETH_HDR;
                        tx_cnt       <= (others => '0');
                        reply_active <= '1';
                        src_valid    <= '1';
                        tx_start     <= '1';
                        ip_id_cnt    <= ip_id_cnt + 1;
                        v_id16       := ip_id_cnt + 1;
                        ip_csum_acc  <= to_unsigned(16#4500#, 32)
                                      + resize(IP_TOTAL_LEN, 32)
                                      + resize(v_id16, 32)
                                      + to_unsigned(16#4000#, 32)
                                      + to_unsigned(16#4011#, 32)
                                      + resize(unsigned(our_ip(31 downto 16)), 32)
                                      + resize(unsigned(our_ip(15 downto 0)), 32)
                                      + resize(unsigned(reply_dst_ip(31 downto 16)), 32)
                                      + resize(unsigned(reply_dst_ip(15 downto 0)), 32);
                    end if;

                when TX_ETH_HDR =>
                    src_valid <= '1';
                    if src_ready = '1' and src_valid = '1' then
                        tx_cnt <= tx_cnt + 1;
                        if tx_cnt = 13 then
                            tx_state <= TX_IP_HDR;
                            tx_cnt   <= (others => '0');
                        end if;
                    end if;

                when TX_IP_HDR =>
                    src_valid <= '1';
                    if src_ready = '1' and src_valid = '1' then
                        tx_cnt <= tx_cnt + 1;
                        if tx_cnt = 19 then
                            tx_state <= TX_UDP;
                            tx_cnt   <= (others => '0');
                        end if;
                    end if;

                when TX_UDP =>
                    src_valid <= '1';
                    if src_ready = '1' and src_valid = '1' then
                        tx_cnt <= tx_cnt + 1;
                        if tx_cnt = 50 then
                            src_last <= '1';
                        end if;
                        if tx_cnt = 51 then
                            tx_state     <= TX_IDLE;
                            reply_active <= '0';
                            src_valid    <= '0';
                        end if;
                    end if;

                when others =>
                    tx_state <= TX_IDLE;
            end case;
        end if;
    end process;

    -- r_data/r_valid/r_last and src_ready are declared above (ahead of the FSM).
    tx_data  <= r_data;
    tx_valid <= r_valid;
    tx_last  <= r_last;

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            r_data  <= (others => '0');
            r_valid <= '0';
            r_last  <= '0';
        elsif rising_edge(clk) then
            if src_ready = '1' then
                r_data  <= tx_data_mux;
                r_valid <= src_valid;
                r_last  <= src_last;
            end if;
        end if;
    end process;

    -- tx_data_mux is declared above.
    process (tx_state, tx_cnt, reply_dst_mac, our_mac, ip_id_cnt, ip_checksum,
             our_ip, reply_dst_ip, stats_port, reply_dst_port, lat_packets,
             lat_bytes, lat_first_seq, lat_last_seq, lat_seq_gaps,
             lat_out_of_order, lat_final_packets, lat_last_src_ip,
             lat_last_src_port)
    begin
        tx_data_mux <= x"00";
        case tx_state is
            when TX_ETH_HDR =>
                case to_integer(tx_cnt) is
                    when 0      => tx_data_mux <= reply_dst_mac(47 downto 40);
                    when 1      => tx_data_mux <= reply_dst_mac(39 downto 32);
                    when 2      => tx_data_mux <= reply_dst_mac(31 downto 24);
                    when 3      => tx_data_mux <= reply_dst_mac(23 downto 16);
                    when 4      => tx_data_mux <= reply_dst_mac(15 downto 8);
                    when 5      => tx_data_mux <= reply_dst_mac(7 downto 0);
                    when 6      => tx_data_mux <= our_mac(47 downto 40);
                    when 7      => tx_data_mux <= our_mac(39 downto 32);
                    when 8      => tx_data_mux <= our_mac(31 downto 24);
                    when 9      => tx_data_mux <= our_mac(23 downto 16);
                    when 10     => tx_data_mux <= our_mac(15 downto 8);
                    when 11     => tx_data_mux <= our_mac(7 downto 0);
                    when 12     => tx_data_mux <= x"08";
                    when 13     => tx_data_mux <= x"00";
                    when others => tx_data_mux <= x"00";
                end case;

            when TX_IP_HDR =>
                case to_integer(tx_cnt) is
                    when 0      => tx_data_mux <= x"45";
                    when 1      => tx_data_mux <= x"00";
                    when 2      => tx_data_mux <= std_logic_vector(IP_TOTAL_LEN(15 downto 8));
                    when 3      => tx_data_mux <= std_logic_vector(IP_TOTAL_LEN(7 downto 0));
                    when 4      => tx_data_mux <= std_logic_vector(ip_id_cnt(15 downto 8));
                    when 5      => tx_data_mux <= std_logic_vector(ip_id_cnt(7 downto 0));
                    when 6      => tx_data_mux <= x"40";
                    when 7      => tx_data_mux <= x"00";
                    when 8      => tx_data_mux <= x"40";
                    when 9      => tx_data_mux <= x"11";
                    when 10     => tx_data_mux <= ip_checksum(15 downto 8);
                    when 11     => tx_data_mux <= ip_checksum(7 downto 0);
                    when 12     => tx_data_mux <= our_ip(31 downto 24);
                    when 13     => tx_data_mux <= our_ip(23 downto 16);
                    when 14     => tx_data_mux <= our_ip(15 downto 8);
                    when 15     => tx_data_mux <= our_ip(7 downto 0);
                    when 16     => tx_data_mux <= reply_dst_ip(31 downto 24);
                    when 17     => tx_data_mux <= reply_dst_ip(23 downto 16);
                    when 18     => tx_data_mux <= reply_dst_ip(15 downto 8);
                    when 19     => tx_data_mux <= reply_dst_ip(7 downto 0);
                    when others => tx_data_mux <= x"00";
                end case;

            when TX_UDP =>
                case to_integer(tx_cnt) is
                    when 0      => tx_data_mux <= stats_port(15 downto 8);
                    when 1      => tx_data_mux <= stats_port(7 downto 0);
                    when 2      => tx_data_mux <= reply_dst_port(15 downto 8);
                    when 3      => tx_data_mux <= reply_dst_port(7 downto 0);
                    when 4      => tx_data_mux <= std_logic_vector(UDP_TOTAL_LEN(15 downto 8));
                    when 5      => tx_data_mux <= std_logic_vector(UDP_TOTAL_LEN(7 downto 0));
                    when 6      => tx_data_mux <= x"00";
                    when 7      => tx_data_mux <= x"00";
                    when 8      => tx_data_mux <= x"49"; -- I
                    when 9      => tx_data_mux <= x"50"; -- P
                    when 10     => tx_data_mux <= x"53"; -- S
                    when 11     => tx_data_mux <= x"30"; -- 0
                    when 12     => tx_data_mux <= lat_packets(31 downto 24);
                    when 13     => tx_data_mux <= lat_packets(23 downto 16);
                    when 14     => tx_data_mux <= lat_packets(15 downto 8);
                    when 15     => tx_data_mux <= lat_packets(7 downto 0);
                    when 16     => tx_data_mux <= lat_bytes(31 downto 24);
                    when 17     => tx_data_mux <= lat_bytes(23 downto 16);
                    when 18     => tx_data_mux <= lat_bytes(15 downto 8);
                    when 19     => tx_data_mux <= lat_bytes(7 downto 0);
                    when 20     => tx_data_mux <= lat_first_seq(31 downto 24);
                    when 21     => tx_data_mux <= lat_first_seq(23 downto 16);
                    when 22     => tx_data_mux <= lat_first_seq(15 downto 8);
                    when 23     => tx_data_mux <= lat_first_seq(7 downto 0);
                    when 24     => tx_data_mux <= lat_last_seq(31 downto 24);
                    when 25     => tx_data_mux <= lat_last_seq(23 downto 16);
                    when 26     => tx_data_mux <= lat_last_seq(15 downto 8);
                    when 27     => tx_data_mux <= lat_last_seq(7 downto 0);
                    when 28     => tx_data_mux <= lat_seq_gaps(31 downto 24);
                    when 29     => tx_data_mux <= lat_seq_gaps(23 downto 16);
                    when 30     => tx_data_mux <= lat_seq_gaps(15 downto 8);
                    when 31     => tx_data_mux <= lat_seq_gaps(7 downto 0);
                    when 32     => tx_data_mux <= lat_out_of_order(31 downto 24);
                    when 33     => tx_data_mux <= lat_out_of_order(23 downto 16);
                    when 34     => tx_data_mux <= lat_out_of_order(15 downto 8);
                    when 35     => tx_data_mux <= lat_out_of_order(7 downto 0);
                    when 36     => tx_data_mux <= lat_final_packets(31 downto 24);
                    when 37     => tx_data_mux <= lat_final_packets(23 downto 16);
                    when 38     => tx_data_mux <= lat_final_packets(15 downto 8);
                    when 39     => tx_data_mux <= lat_final_packets(7 downto 0);
                    when 40     => tx_data_mux <= lat_last_src_ip(31 downto 24);
                    when 41     => tx_data_mux <= lat_last_src_ip(23 downto 16);
                    when 42     => tx_data_mux <= lat_last_src_ip(15 downto 8);
                    when 43     => tx_data_mux <= lat_last_src_ip(7 downto 0);
                    when 44     => tx_data_mux <= lat_last_src_port(15 downto 8);
                    when 45     => tx_data_mux <= lat_last_src_port(7 downto 0);
                    when 46     => tx_data_mux <= x"00";
                    when 47     => tx_data_mux <= x"00";
                    when 48     => tx_data_mux <= x"44"; -- D
                    when 49     => tx_data_mux <= x"4f"; -- O
                    when 50     => tx_data_mux <= x"4e"; -- N
                    when 51     => tx_data_mux <= x"45"; -- E
                    when others => tx_data_mux <= x"00";
                end case;

            when others =>
                tx_data_mux <= x"00";
        end case;
    end process;

end architecture rtl;
