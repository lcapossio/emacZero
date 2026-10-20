-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- udp_blast_trigger.vhd - Parse a UDP control packet into a bounded blast request
-- VHDL port of rtl/net/udp_blast_trigger.v (formally proven equivalent; see
-- sim/parity/).
--
-- Trigger payload format:
--   bytes 0..2: extra inter-frame delay in 100 MHz cycles
--   bytes 3..6: packet count
--   bytes 7..8: destination UDP port override
--   bytes 9..10: UDP payload size override (bytes, iperf2 header included)
--
-- Short packets are accepted:
--   0..2 bytes -> defaults
--   3 bytes    -> delay only
--   7 bytes    -> delay + count
--   9 bytes    -> delay + count + dst-port override
--   11+ bytes  -> delay + count + dst-port + payload size
-- payload_size is DEFAULT_PAYLOAD unless the trigger carries a nonzero size;
-- the instantiating design range-checks it against what its generator takes.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity udp_blast_trigger is
    generic (
        TRIGGER_PORT    : std_logic_vector(15 downto 0) := x"270D";      -- 16'd9997
        IGNORE_SRC_PORT : std_logic_vector(15 downto 0) := x"1389";      -- 16'd5001
        DEFAULT_COUNT   : std_logic_vector(31 downto 0) := x"000F4240";  -- 32'd1000000
        DEFAULT_PAYLOAD : std_logic_vector(15 downto 0) := x"05C0"       -- 16'd1472
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;

        udp_rx_data     : in  std_logic_vector(7 downto 0);
        udp_rx_valid    : in  std_logic;
        udp_rx_last     : in  std_logic;
        udp_rx_err      : in  std_logic;      -- with last: discard (net_rx verdict)
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
end entity udp_blast_trigger;

architecture rtl of udp_blast_trigger is

    signal active    : std_logic;
    signal accept    : std_logic;
    signal byte_cnt  : unsigned(3 downto 0);
    signal delay_acc : std_logic_vector(23 downto 0);
    signal count_acc : std_logic_vector(31 downto 0);
    signal port_acc  : std_logic_vector(15 downto 0);
    signal size_acc  : std_logic_vector(15 downto 0);

    signal is_first      : std_logic;
    signal first_accept  : std_logic;
    signal this_accept   : std_logic;
    signal take_byte     : std_logic;
    signal byte_cnt_next : unsigned(3 downto 0);
    signal delay_next    : std_logic_vector(23 downto 0);
    signal count_next    : std_logic_vector(31 downto 0);
    signal port_next     : std_logic_vector(15 downto 0);
    signal size_next     : std_logic_vector(15 downto 0);

begin

    is_first <= not active;
    first_accept <=
        '1' when (udp_rx_dst_port = TRIGGER_PORT) and
                 (udp_rx_src_port /= IGNORE_SRC_PORT) and
                 busy = '0'
        else '0';

    this_accept <= first_accept when is_first = '1' else accept;
    take_byte   <= '1' when udp_rx_valid = '1' and this_accept = '1' and byte_cnt < 11 else '0';

    byte_cnt_next <= byte_cnt + 1 when take_byte = '1' else byte_cnt;
    delay_next <=
        delay_acc(15 downto 0) & udp_rx_data when take_byte = '1' and byte_cnt < 3 else delay_acc;
    count_next <=
        count_acc(23 downto 0) & udp_rx_data when take_byte = '1' and byte_cnt >= 3 and byte_cnt < 7 else
        count_acc;
    port_next <=
        port_acc(7 downto 0) & udp_rx_data when take_byte = '1' and byte_cnt >= 7 and byte_cnt < 9 else
        port_acc;
    size_next <=
        size_acc(7 downto 0) & udp_rx_data when take_byte = '1' and byte_cnt >= 9 else size_acc;

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            active       <= '0';
            accept       <= '0';
            byte_cnt     <= (others => '0');
            delay_acc    <= (others => '0');
            count_acc    <= (others => '0');
            port_acc     <= (others => '0');
            size_acc     <= (others => '0');
            start        <= '0';
            dst_mac      <= (others => '0');
            dst_ip       <= (others => '0');
            dst_port     <= (others => '0');
            src_port     <= (others => '0');
            ifg_delay    <= (others => '0');
            packet_count <= (others => '0');
            payload_size <= DEFAULT_PAYLOAD;
        elsif rising_edge(clk) then
            start <= '0';

            if udp_rx_valid = '1' then
                if active = '0' then
                    active    <= '1';
                    accept    <= first_accept;
                    byte_cnt  <= (others => '0');
                    delay_acc <= (others => '0');
                    count_acc <= (others => '0');
                    port_acc  <= (others => '0');
                    size_acc  <= (others => '0');
                end if;

                if this_accept = '1' then
                    byte_cnt  <= byte_cnt_next;
                    delay_acc <= delay_next;
                    count_acc <= count_next;
                    port_acc  <= port_next;
                    size_acc  <= size_next;
                end if;

                if udp_rx_last = '1' then
                    if this_accept = '1' and udp_rx_err = '0' then
                        start   <= '1';
                        dst_mac <= udp_rx_src_mac;
                        dst_ip  <= udp_rx_src_ip;
                        if byte_cnt_next >= 9 and port_next /= x"0000" then
                            dst_port <= port_next;
                        else
                            dst_port <= udp_rx_src_port;
                        end if;
                        src_port <= udp_rx_dst_port;
                        if byte_cnt_next >= 3 then
                            ifg_delay <= delay_next;
                        else
                            ifg_delay <= (others => '0');
                        end if;
                        if byte_cnt_next >= 7 and count_next /= x"00000000" then
                            packet_count <= count_next;
                        else
                            packet_count <= DEFAULT_COUNT;
                        end if;
                        if byte_cnt_next >= 11 and size_next /= x"0000" then
                            payload_size <= size_next;
                        else
                            payload_size <= DEFAULT_PAYLOAD;
                        end if;
                    end if;
                    active   <= '0';
                    accept   <= '0';
                    byte_cnt <= (others => '0');
                end if;
            end if;
        end if;
    end process;

end architecture rtl;
