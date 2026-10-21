-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- icmp_echo.vhd - ICMP Echo (Ping) Responder
-- VHDL port of rtl/net/icmp_echo.v (formally proven equivalent; see sim/parity/).
-- Buffers incoming echo request, swaps addresses, replies with correct
-- IP header checksum and incremental ICMP checksum adjustment.
--
-- One request is buffered at a time. A request is answered only if it fits
-- the buffer (MAX_LEN bytes of ICMP) and arrives while the responder is idle;
-- anything else is dropped without touching the buffer, so a reply is never
-- sent truncated, padded with stale bytes, or overwritten while it goes out.
-- =============================================================================
-- ICMP echo request: Type(1)=0x08 | Code(1)=0x00 | Csum(2) | Id(2) | Seq(2) | Data(N)
-- ICMP echo reply:   Type(1)=0x00 | Code(1)=0x00 | Csum(2) | Id(2) | Seq(2) | Data(N)
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.emz_util_pkg.all;

entity icmp_echo is
    generic (
        -- Largest ICMP message answered, header included. 1480 is a full
        -- 1500-byte IPv4 packet; longer (jumbo) requests get no reply.
        MAX_LEN : integer := 1480
    );
    port (
        clk            : in  std_logic;
        rst_n          : in  std_logic;

        -- Our identity
        our_mac        : in  std_logic_vector(47 downto 0);
        our_ip         : in  std_logic_vector(31 downto 0);

        -- ICMP RX (from net_rx - ICMP payload after IP header)
        icmp_rx_data   : in  std_logic_vector(7 downto 0);
        icmp_rx_valid  : in  std_logic;
        icmp_rx_last   : in  std_logic;
        icmp_rx_err    : in  std_logic;     -- with last: discard (net_rx verdict)
        icmp_rx_src_ip : in  std_logic_vector(31 downto 0);

        -- Source MAC (captured by net_rx before IP parsing)
        rx_src_mac     : in  std_logic_vector(47 downto 0);

        -- TX output - full Ethernet frame (dst+src+type+IP+ICMP)
        tx_data        : out std_logic_vector(7 downto 0);
        tx_valid       : out std_logic;
        tx_last        : out std_logic;
        tx_ready       : in  std_logic;
        tx_start       : out std_logic
    );
end entity icmp_echo;

architecture rtl of icmp_echo is

    -- FSM-side AXIS handshake (internal). The external tx_data / tx_valid /
    -- tx_last go through a 1-deep register slice below - this breaks the
    -- long combinational path tx_data_mux -> eth_mac_tx.crc_saved that was
    -- the design's worst sys_clk path.
    signal src_valid : std_logic;
    signal src_last  : std_logic;

    -- =========================================================================
    -- Buffer incoming ICMP packet (max MAX_LEN bytes)
    -- =========================================================================
    constant LEN_W   : integer := clog2(MAX_LEN + 1);
    -- Sized like the Verilog [LEN_W-1:0] localparams (truncated to LEN_W bits).
    constant LEN_MAX : unsigned(LEN_W-1 downto 0) := resize(to_unsigned(MAX_LEN, 32), LEN_W);
    constant LEN_1   : unsigned(LEN_W-1 downto 0) := resize(to_unsigned(1, 32), LEN_W);
    constant LEN_2   : unsigned(LEN_W-1 downto 0) := resize(to_unsigned(2, 32), LEN_W);
    constant LEN_3   : unsigned(LEN_W-1 downto 0) := resize(to_unsigned(3, 32), LEN_W);
    constant LEN_8   : unsigned(LEN_W-1 downto 0) := resize(to_unsigned(8, 32), LEN_W);
    constant LEN_0   : unsigned(LEN_W-1 downto 0) := (others => '0');

    type icmp_buf_t is array (integer range 0 to MAX_LEN-1) of std_logic_vector(7 downto 0);
    signal icmp_buf     : icmp_buf_t;
    signal icmp_len     : unsigned(LEN_W-1 downto 0);  -- length of the buffered request
    signal rx_cnt       : unsigned(LEN_W-1 downto 0);  -- bytes stored of the packet arriving
    signal rx_ovf       : std_logic;                   -- it has more than MAX_LEN bytes
    signal rx_in_pkt    : std_logic;                   -- a packet is arriving (first byte seen)
    signal rx_drop      : std_logic;                   -- it arrived busy: ignore it to its end
    signal is_echo_req  : std_logic;
    signal pkt_ready    : std_logic;
    signal reply_active : std_logic;                   -- driven by the TX FSM below

    -- Busy from the request being handed over until its reply is sent. A
    -- packet whose first byte arrives while busy is dropped whole.
    signal rx_busy    : std_logic;
    signal rx_sop     : std_logic;
    signal rx_skip    : std_logic;
    signal rx_store   : std_logic;
    -- The byte that would be number MAX_LEN+1 makes the packet too long.
    signal rx_ovf_now : std_logic;

    -- Captured source info for reply
    signal reply_dst_ip  : std_logic_vector(31 downto 0);
    signal reply_dst_mac : std_logic_vector(47 downto 0);

    signal orig_csum : std_logic_vector(15 downto 0);

    -- =========================================================================
    -- TX: generate echo reply
    -- =========================================================================
    constant TX_IDLE    : std_logic_vector(2 downto 0) := "000";  -- 3'd0
    constant TX_ETH_HDR : std_logic_vector(2 downto 0) := "001";  -- 3'd1
    constant TX_IP_HDR  : std_logic_vector(2 downto 0) := "010";  -- 3'd2
    constant TX_ICMP    : std_logic_vector(2 downto 0) := "011";  -- 3'd3

    signal tx_state    : std_logic_vector(2 downto 0);
    signal tx_cnt      : unsigned(5 downto 0);
    signal icmp_tx_cnt : unsigned(LEN_W-1 downto 0);

    -- IP header fields
    signal ip_total_len : unsigned(15 downto 0);
    signal ip_id_cnt    : unsigned(15 downto 0);

    -- IP header checksum
    signal ip_csum_acc : unsigned(31 downto 0);
    signal ip_fold1    : unsigned(16 downto 0);
    signal ip_fold2    : unsigned(15 downto 0);
    signal ip_checksum : std_logic_vector(15 downto 0);

    -- ICMP checksum: incremental update (type 0x08 -> 0x00 = add 0x0800)
    signal new_csum_raw : unsigned(16 downto 0);
    signal new_csum     : unsigned(15 downto 0);

    -- AXIS register-slice signals (1-deep). src_ready is the slice "can accept"
    -- handshake; the slice registers and the combinational tx_data_mux are
    -- driven further below.
    signal r_data      : std_logic_vector(7 downto 0);
    signal r_valid     : std_logic;
    signal r_last      : std_logic;
    signal tx_data_mux : std_logic_vector(7 downto 0);
    signal src_ready   : std_logic;

begin

    rx_busy    <= pkt_ready or reply_active;
    rx_sop     <= icmp_rx_valid and not rx_in_pkt;
    rx_skip    <= rx_busy when rx_sop = '1' else rx_drop;
    rx_store   <= '1' when icmp_rx_valid = '1' and rx_skip = '0' and rx_cnt /= LEN_MAX else '0';
    rx_ovf_now <= '1' when rx_ovf = '1' or
                           (icmp_rx_valid = '1' and rx_skip = '0' and rx_cnt = LEN_MAX) else '0';

    -- =========================================================================
    -- RX: buffer incoming ICMP data
    -- =========================================================================
    -- The buffer has no reset and one read port (the TX byte), so it maps to
    -- distributed RAM. The checksum bytes are also kept in orig_csum, so
    -- nothing else reads the buffer: two more fixed-index reads would build
    -- it from flip-flops.
    process (clk)
    begin
        if rising_edge(clk) then
            if rx_store = '1' then
                icmp_buf(to_integer(rx_cnt)) <= icmp_rx_data;
                if rx_cnt = LEN_2 then orig_csum(15 downto 8) <= icmp_rx_data; end if;
                if rx_cnt = LEN_3 then orig_csum(7 downto 0)  <= icmp_rx_data; end if;
            end if;
        end if;
    end process;

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            rx_cnt        <= (others => '0');
            rx_ovf        <= '0';
            rx_in_pkt     <= '0';
            rx_drop       <= '0';
            icmp_len      <= (others => '0');
            is_echo_req   <= '0';
            pkt_ready     <= '0';
            reply_dst_ip  <= (others => '0');
            reply_dst_mac <= (others => '0');
        elsif rising_edge(clk) then
            pkt_ready <= '0';

            if icmp_rx_valid = '1' then
                if rx_sop = '1' then
                    rx_drop <= rx_busy;
                end if;
                rx_in_pkt <= not icmp_rx_last;

                if rx_store = '1' then
                    rx_cnt <= rx_cnt + LEN_1;
                    -- Check ICMP type (byte 0) and code (byte 1)
                    if rx_cnt = LEN_0 then
                        if icmp_rx_data = x"08" then is_echo_req <= '1'; else is_echo_req <= '0'; end if;
                    end if;
                    if rx_cnt = LEN_1 then
                        if is_echo_req = '1' and icmp_rx_data = x"00" then
                            is_echo_req <= '1';
                        else
                            is_echo_req <= '0';
                        end if;
                    end if;
                end if;
                if rx_ovf_now = '1' then
                    rx_ovf <= '1';
                end if;

                if icmp_rx_last = '1' then
                    rx_cnt <= (others => '0');
                    rx_ovf <= '0';
                    -- icmp_len changes only with an accepted request, so it
                    -- holds still while that request's reply goes out.
                    if rx_skip = '0' and rx_ovf_now = '0' and is_echo_req = '1' and
                       icmp_rx_err = '0' and (rx_cnt + LEN_1) >= LEN_8 then
                        icmp_len      <= rx_cnt + LEN_1;
                        pkt_ready     <= '1';
                        reply_dst_ip  <= icmp_rx_src_ip;
                        reply_dst_mac <= rx_src_mac;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- TX: generate echo reply
    -- =========================================================================
    -- Frame layout:
    --   [0:5]   Dst MAC
    --   [6:11]  Src MAC (ours)
    --   [12:13] Ethertype 0x0800 (IPv4)
    --   [14:33] IP header (20 bytes)
    --   [34+]   ICMP payload (type=0x00, checksum adjusted)

    ip_total_len <= to_unsigned(20, 16) + resize(icmp_len, 16);

    ip_fold1    <= resize(ip_csum_acc(15 downto 0), 17) + resize(ip_csum_acc(31 downto 16), 17);
    ip_fold2    <= ip_fold1(15 downto 0) + resize(ip_fold1(16 downto 16), 16);
    ip_checksum <= not std_logic_vector(ip_fold2);

    new_csum_raw <= ('0' & unsigned(orig_csum)) + to_unsigned(16#0800#, 17);
    new_csum     <= new_csum_raw(15 downto 0) + resize(new_csum_raw(16 downto 16), 16);

    src_ready <= (not r_valid) or tx_ready;

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            tx_state     <= TX_IDLE;
            tx_cnt       <= (others => '0');
            icmp_tx_cnt  <= (others => '0');
            reply_active <= '0';
            src_valid    <= '0';
            src_last     <= '0';
            tx_start     <= '0';
            ip_id_cnt    <= to_unsigned(1000, 16);
            ip_csum_acc  <= (others => '0');
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
                        src_valid    <= '1';  -- assert immediately so byte 0 lands
                        ip_id_cnt    <= ip_id_cnt + 1;
                        ip_csum_acc  <=
                            to_unsigned(16#4500#, 32) +
                            resize(ip_total_len, 32) +
                            resize(ip_id_cnt + 1, 32) +
                            to_unsigned(16#4000#, 32) +
                            to_unsigned(16#4001#, 32) +
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
                            tx_state    <= TX_ICMP;
                            tx_cnt      <= (others => '0');
                            icmp_tx_cnt <= (others => '0');
                        end if;
                    end if;

                when TX_ICMP =>
                    src_valid <= '1';
                    if src_ready = '1' and src_valid = '1' then
                        icmp_tx_cnt <= icmp_tx_cnt + LEN_1;
                        -- Arm src_last one cycle ahead so it lands with the
                        -- last data byte (registers update next clock).
                        if icmp_tx_cnt = icmp_len - LEN_2 then
                            src_last <= '1';
                        end if;
                        if icmp_tx_cnt = icmp_len - LEN_1 then
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
    -- AXIS register slice (1-deep). Breaks the long combinational path from
    -- tx_data_mux into eth_mac_tx's CRC pipeline. The FSM produces src_*;
    -- tx_* are registered outputs driven by r_*.
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
             ip_checksum, our_ip, reply_dst_ip, icmp_tx_cnt, new_csum, icmp_buf)
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
                    when 0      => tx_data_mux <= x"45";          -- Version=4, IHL=5
                    when 1      => tx_data_mux <= x"00";          -- DSCP/ECN
                    when 2      => tx_data_mux <= std_logic_vector(ip_total_len(15 downto 8));
                    when 3      => tx_data_mux <= std_logic_vector(ip_total_len(7 downto 0));
                    when 4      => tx_data_mux <= std_logic_vector(ip_id_cnt(15 downto 8));
                    when 5      => tx_data_mux <= std_logic_vector(ip_id_cnt(7 downto 0));
                    when 6      => tx_data_mux <= x"40";          -- Don't Fragment
                    when 7      => tx_data_mux <= x"00";
                    when 8      => tx_data_mux <= x"40";          -- TTL=64
                    when 9      => tx_data_mux <= x"01";          -- Protocol=ICMP
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
            when TX_ICMP =>
                if icmp_tx_cnt = LEN_0 or icmp_tx_cnt = LEN_1 then
                    tx_data_mux <= x"00";                         -- Type = Echo Reply, Code = 0
                elsif icmp_tx_cnt = LEN_2 then
                    tx_data_mux <= std_logic_vector(new_csum(15 downto 8));  -- Adjusted checksum
                elsif icmp_tx_cnt = LEN_3 then
                    tx_data_mux <= std_logic_vector(new_csum(7 downto 0));
                else
                    tx_data_mux <= icmp_buf(to_integer(icmp_tx_cnt));
                end if;
            when others => tx_data_mux <= x"00";
        end case;
    end process;

end architecture rtl;
