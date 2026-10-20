-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- udp_echo.vhd - UDP Echo Responder
-- VHDL port of rtl/net/udp_echo.v (formally proven equivalent; see sim/parity/).
-- Buffers incoming UDP payload, swaps src/dst MAC + IP + UDP ports, recomputes
-- IP header checksum, sets UDP checksum to 0 (allowed by RFC 768) and replies
-- with a full Ethernet frame.
--
-- Layout of an outbound echo:
--   [0..5]   Dst MAC      (= rx_src_mac)
--   [6..11]  Src MAC      (= our_mac)
--   [12..13] EtherType    = 0x0800
--   [14..33] IPv4 header  (20 bytes, protocol = 17 = UDP)
--   [34..35] UDP src port (= incoming dst port)
--   [36..37] UDP dst port (= incoming src port)
--   [38..39] UDP length   (= 8 + payload length)
--   [40..41] UDP checksum (= 0x0000, optional per RFC 768)
--   [42..]   payload      (echoed back)
--
-- Buffer size limits the largest echoed payload. 1472 = max UDP/IP MTU at 1500
-- Ethernet payload size, but we buffer 1024 here to keep BRAM use small. UDP
-- packets larger than the buffer are simply dropped (RX state machine stops
-- pushing once full; the TX FSM uses captured length to bound transmission).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.emz_util_pkg.all;

entity udp_echo is
    generic (
        BUF_SIZE    : integer := 1024;                                   -- bytes of payload buffer
        LISTEN_PORT : std_logic_vector(15 downto 0) := (others => '0')   -- 0 = echo every UDP payload
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;

        -- Our identity
        our_mac         : in  std_logic_vector(47 downto 0);
        our_ip          : in  std_logic_vector(31 downto 0);

        -- UDP RX (from net_rx, payload only - UDP header already parsed)
        udp_rx_data     : in  std_logic_vector(7 downto 0);
        udp_rx_valid    : in  std_logic;
        udp_rx_last     : in  std_logic;
        udp_rx_err      : in  std_logic;      -- with last: discard (net_rx verdict)
        udp_rx_src_ip   : in  std_logic_vector(31 downto 0);
        udp_rx_src_port : in  std_logic_vector(15 downto 0);
        udp_rx_dst_port : in  std_logic_vector(15 downto 0);
        udp_rx_length   : in  std_logic_vector(15 downto 0);    -- UDP total length (header + payload)

        -- Source MAC captured by net_rx
        rx_src_mac      : in  std_logic_vector(47 downto 0);

        -- TX output - full Ethernet frame
        tx_data         : out std_logic_vector(7 downto 0);
        tx_valid        : out std_logic;
        tx_last         : out std_logic;
        tx_ready        : in  std_logic;
        tx_start        : out std_logic
    );
end entity udp_echo;

architecture rtl of udp_echo is

    -- FSM-side AXIS handshake (gated by the 1-deep register slice below).
    signal src_valid    : std_logic;
    signal src_last     : std_logic;
    signal reply_active : std_logic;   -- TX reply in progress; read by the RX block to drop input

    -- =========================================================================
    -- RX: buffer incoming UDP payload
    -- =========================================================================
    constant ADDR_W : integer := clog2(BUF_SIZE);

    -- BUF_SIZE[ADDR_W:0] (the low ADDR_W+1 bits of the integer parameter)
    constant BUF_SIZE_V : unsigned(ADDR_W downto 0) := resize(to_unsigned(BUF_SIZE, 32), ADDR_W+1);
    constant CNT_0      : unsigned(ADDR_W downto 0) := (others => '0');
    constant PORT_0     : std_logic_vector(15 downto 0) := (others => '0');

    type udp_buf_t is array (integer range 0 to BUF_SIZE-1) of std_logic_vector(7 downto 0);
    signal udp_buf     : udp_buf_t;
    signal payload_len : unsigned(ADDR_W downto 0);
    signal rx_cnt      : unsigned(ADDR_W downto 0);
    signal pkt_ready   : std_logic;
    signal rx_accept   : std_logic;

    signal reply_dst_ip   : std_logic_vector(31 downto 0);
    signal reply_dst_mac  : std_logic_vector(47 downto 0);
    signal reply_dst_port : std_logic_vector(15 downto 0);   -- = original src port
    signal reply_src_port : std_logic_vector(15 downto 0);   -- = original dst port

    -- =========================================================================
    -- TX: build echo reply frame
    -- =========================================================================
    constant TX_IDLE    : std_logic_vector(2 downto 0) := "000";  -- 3'd0
    constant TX_ETH_HDR : std_logic_vector(2 downto 0) := "001";  -- 3'd1
    constant TX_IP_HDR  : std_logic_vector(2 downto 0) := "010";  -- 3'd2
    constant TX_UDP_HDR : std_logic_vector(2 downto 0) := "011";  -- 3'd3
    constant TX_PAYLOAD : std_logic_vector(2 downto 0) := "100";  -- 3'd4

    signal tx_state       : std_logic_vector(2 downto 0);
    signal tx_cnt         : unsigned(5 downto 0);
    signal payload_tx_cnt : unsigned(ADDR_W downto 0);

    -- IP totals: 20 (IP header) + 8 (UDP header) + payload
    signal ip_total_len  : unsigned(15 downto 0);
    signal udp_total_len : unsigned(15 downto 0);
    signal ip_id_cnt     : unsigned(15 downto 0);

    -- IP header checksum (one-pass accumulator, fold at TX)
    signal ip_csum_acc : unsigned(31 downto 0);
    signal ip_fold1    : unsigned(16 downto 0);
    signal ip_fold2    : unsigned(15 downto 0);
    signal ip_checksum : std_logic_vector(15 downto 0);

    -- 1-deep AXIS register-slice signals + combinational mux.
    signal r_data      : std_logic_vector(7 downto 0);
    signal r_valid     : std_logic;
    signal r_last      : std_logic;
    signal tx_data_mux : std_logic_vector(7 downto 0);
    signal src_ready   : std_logic;

begin

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            rx_cnt         <= (others => '0');
            payload_len    <= (others => '0');
            pkt_ready      <= '0';
            rx_accept      <= '0';
            reply_dst_ip   <= (others => '0');
            reply_dst_mac  <= (others => '0');
            reply_dst_port <= (others => '0');
            reply_src_port <= (others => '0');
        elsif rising_edge(clk) then
            pkt_ready <= '0';

            -- While the TX FSM is replying, drop incoming UDP - the single
            -- buffer would otherwise be clobbered mid-transmit. Drains the
            -- input by counting bytes and then advancing on tlast.
            if udp_rx_valid = '1' then
                if rx_cnt = CNT_0 then
                    if LISTEN_PORT = PORT_0 or udp_rx_dst_port = LISTEN_PORT then
                        rx_accept <= '1';
                    else
                        rx_accept <= '0';
                    end if;
                end if;

                if reply_active = '1' or pkt_ready = '1' or
                   (rx_cnt = CNT_0 and
                    LISTEN_PORT /= PORT_0 and
                    udp_rx_dst_port /= LISTEN_PORT) or
                   (rx_cnt /= CNT_0 and rx_accept = '0') then
                    if udp_rx_last = '1' then
                        rx_cnt    <= (others => '0');
                        rx_accept <= '0';
                    end if;
                else
                    if rx_cnt < BUF_SIZE_V then
                        udp_buf(to_integer(rx_cnt(ADDR_W-1 downto 0))) <= udp_rx_data;
                    end if;
                    rx_cnt <= rx_cnt + 1;

                    if udp_rx_last = '1' then
                        payload_len    <= rx_cnt + 1;
                        rx_cnt         <= (others => '0');
                        if udp_rx_err = '0' and (rx_cnt + 1) <= BUF_SIZE_V then
                            pkt_ready      <= '1';
                            reply_dst_ip   <= udp_rx_src_ip;
                            reply_dst_mac  <= rx_src_mac;
                            reply_dst_port <= udp_rx_src_port;
                            reply_src_port <= udp_rx_dst_port;
                        end if;
                        rx_accept <= '0';
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- TX: build echo reply frame
    -- =========================================================================
    -- 16'd28 + {6'd0, payload_len}: the sum is taken modulo 2^16 either way.
    ip_total_len  <= to_unsigned(28, 16) + resize(payload_len, 16);
    udp_total_len <= to_unsigned(8, 16)  + resize(payload_len, 16);

    ip_fold1    <= resize(ip_csum_acc(15 downto 0), 17) + resize(ip_csum_acc(31 downto 16), 17);
    ip_fold2    <= ip_fold1(15 downto 0) + resize(ip_fold1(16 downto 16), 16);
    ip_checksum <= not std_logic_vector(ip_fold2);

    src_ready <= (not r_valid) or tx_ready;

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            tx_state       <= TX_IDLE;
            tx_cnt         <= (others => '0');
            payload_tx_cnt <= (others => '0');
            reply_active   <= '0';
            src_valid      <= '0';
            src_last       <= '0';
            tx_start       <= '0';
            ip_id_cnt      <= to_unsigned(2000, 16);
            ip_csum_acc    <= (others => '0');
        elsif rising_edge(clk) then
            if tx_ready = '1' and r_valid = '1' then   -- tx_valid = r_valid
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
                    if pkt_ready = '1' and reply_active = '0' then
                        tx_state     <= TX_ETH_HDR;
                        tx_cnt       <= (others => '0');
                        reply_active <= '1';
                        tx_start     <= '1';
                        src_valid    <= '1';
                        ip_id_cnt    <= ip_id_cnt + 1;
                        -- Pre-compute IP-header pseudo-sum.
                        -- IP header is fixed 0x4500 / total_len / id / 0x4000 /
                        -- 0x4011 (TTL=64, proto=UDP) / our_ip / dst_ip.
                        ip_csum_acc  <=
                            to_unsigned(16#4500#, 32) +
                            resize(ip_total_len, 32) +
                            resize(ip_id_cnt + 1, 32) +
                            to_unsigned(16#4000#, 32) +
                            to_unsigned(16#4011#, 32) +
                            resize(unsigned(our_ip(31 downto 16)), 32) +
                            resize(unsigned(our_ip(15 downto 0)), 32) +
                            resize(unsigned(reply_dst_ip(31 downto 16)), 32) +
                            resize(unsigned(reply_dst_ip(15 downto 0)), 32);
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
                            tx_state <= TX_UDP_HDR;
                            tx_cnt   <= (others => '0');
                        end if;
                    end if;

                when TX_UDP_HDR =>
                    src_valid <= '1';
                    if src_ready = '1' and src_valid = '1' then
                        tx_cnt <= tx_cnt + 1;
                        if tx_cnt = 7 then
                            -- A 1-byte payload is also the last byte.
                            if payload_len = 1 then
                                src_last <= '1';
                            end if;
                            tx_state       <= TX_PAYLOAD;
                            tx_cnt         <= (others => '0');
                            payload_tx_cnt <= (others => '0');
                        end if;
                    end if;

                when TX_PAYLOAD =>
                    src_valid <= '1';
                    if src_ready = '1' and src_valid = '1' then
                        payload_tx_cnt <= payload_tx_cnt + 1;
                        -- Arm src_last one cycle ahead so it lands with the
                        -- last data byte (registers update next clock).
                        -- The Verilog compares against payload_len - 2 / - 1
                        -- with unsized literals, i.e. at 32 bits (no wrap).
                        if resize(payload_tx_cnt, 32) = resize(payload_len, 32) - 2 then
                            src_last <= '1';
                        end if;
                        if resize(payload_tx_cnt, 32) = resize(payload_len, 32) - 1 then
                            tx_state     <= TX_IDLE;
                            reply_active <= '0';
                            src_valid    <= '0';
                        end if;
                    end if;

                when others => tx_state <= TX_IDLE;
            end case;
        end if;
    end process;

    -- =========================================================================
    -- 1-deep AXIS register slice - same pattern as icmp_echo to keep the
    -- wide tx_data_mux off the eth_mac_tx CRC critical path.
    -- =========================================================================
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

    -- =========================================================================
    -- TX data mux (combinational).
    -- =========================================================================
    process (tx_state, tx_cnt, reply_dst_mac, our_mac, ip_total_len, ip_id_cnt,
             ip_checksum, our_ip, reply_dst_ip, reply_src_port, reply_dst_port,
             udp_total_len, payload_tx_cnt, udp_buf)
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
                    when 2      => tx_data_mux <= std_logic_vector(ip_total_len(15 downto 8));
                    when 3      => tx_data_mux <= std_logic_vector(ip_total_len(7 downto 0));
                    when 4      => tx_data_mux <= std_logic_vector(ip_id_cnt(15 downto 8));
                    when 5      => tx_data_mux <= std_logic_vector(ip_id_cnt(7 downto 0));
                    when 6      => tx_data_mux <= x"40";          -- DF flag
                    when 7      => tx_data_mux <= x"00";
                    when 8      => tx_data_mux <= x"40";          -- TTL = 64
                    when 9      => tx_data_mux <= x"11";          -- Protocol = 17 (UDP)
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
            when TX_UDP_HDR =>
                case to_integer(tx_cnt) is
                    when 0      => tx_data_mux <= reply_src_port(15 downto 8);
                    when 1      => tx_data_mux <= reply_src_port(7 downto 0);
                    when 2      => tx_data_mux <= reply_dst_port(15 downto 8);
                    when 3      => tx_data_mux <= reply_dst_port(7 downto 0);
                    when 4      => tx_data_mux <= std_logic_vector(udp_total_len(15 downto 8));
                    when 5      => tx_data_mux <= std_logic_vector(udp_total_len(7 downto 0));
                    when 6      => tx_data_mux <= x"00";          -- checksum hi (0 = no check)
                    when 7      => tx_data_mux <= x"00";          -- checksum lo
                    when others => tx_data_mux <= x"00";
                end case;
            when TX_PAYLOAD =>
                tx_data_mux <= udp_buf(to_integer(payload_tx_cnt(ADDR_W-1 downto 0)));
            when others =>
                tx_data_mux <= x"00";
        end case;
    end process;

    -- udp_rx_length / udp_rx_dst_port aren't strictly needed once the reply
    -- ports are captured into reply_*. (The Verilog ties them to an `_unused`
    -- lint wire, which has no VHDL counterpart.)

end architecture rtl;
