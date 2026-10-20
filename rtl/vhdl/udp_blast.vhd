-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- udp_blast.vhd - Line-rate UDP traffic generator
-- VHDL port of rtl/net/udp_blast.v (formally proven equivalent; see sim/parity/).
--
-- While `enable` is high, continuously emits well-formed UDP/IPv4/Ethernet
-- frames to {dst_mac, dst_ip, dst_port} from {our_mac, our_ip, src_port}.
-- Frames are sent back-to-back; eth_mac_tx adds preamble/SFD/FCS/IFG. The
-- generator is the AXIS master; eth_mac_tx accepts one byte per cycle so
-- throughput is wire-rate (8128 fps with 1518-byte frames at 100 Mbps).
--
-- Each datagram carries the 12-byte iperf2 UDP_datagram header
-- (id + tv_sec + tv_usec) so an iperf2 -u -s server on the receiver can
-- parse and count packets natively. The default timestamp tick assumes the
-- Arty 100 MHz system clock: 100 cycles per microsecond.
--
-- IP header checksum is computed once at start (all fields except total_len
-- are constant; total_len is constant within a blast, so the IP csum is
-- constant too). UDP checksum = 0 (skipped per RFC 768).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity udp_blast is
    generic (
        -- Verilog `parameter [31:0]`: the 32-bit two's-complement pattern of
        -- the integer is used, so values >= 2**31 are given as negative
        -- integers (VHDL-93 integers stop at 2**31 - 1).
        START_DELAY_CYCLES : integer := 0;
        -- Verilog `parameter [6:0]`: only the low 7 bits are used.
        USEC_TICK_CYCLES   : integer := 100
    );
    port (
        clk               : in  std_logic;
        rst_n             : in  std_logic;

        -- Identity
        our_mac           : in  std_logic_vector(47 downto 0);
        our_ip            : in  std_logic_vector(31 downto 0);

        -- Target (typically captured from a host trigger packet)
        dst_mac           : in  std_logic_vector(47 downto 0);
        dst_ip            : in  std_logic_vector(31 downto 0);
        dst_port          : in  std_logic_vector(15 downto 0);
        src_port          : in  std_logic_vector(15 downto 0);

        -- Configuration
        payload_size      : in  std_logic_vector(13 downto 0);  -- total UDP payload bytes (incl. 12B iperf2 hdr)
        enable            : in  std_logic;                      -- 1 = blast continuously while held high
        inter_frame_delay : in  std_logic_vector(23 downto 0);  -- sys_clk cycles to wait between frames (0 = back-to-back)

        -- Status
        pkts_sent         : out std_logic_vector(31 downto 0);
        pkt_done_pulse    : out std_logic;                      -- 1-cycle pulse after each TX frame

        -- AXIS TX (master). Uses 1-deep skid the same way as udp_echo / icmp_echo
        -- so the wide tx_data_mux stays off the eth_mac_tx CRC critical path.
        tx_data           : out std_logic_vector(7 downto 0);
        tx_valid          : out std_logic;
        tx_last           : out std_logic;
        tx_ready          : in  std_logic;
        tx_start          : out std_logic
    );
end entity udp_blast;

architecture rtl of udp_blast is

    constant START_DELAY_CYCLES_U : unsigned(31 downto 0) := unsigned(to_signed(START_DELAY_CYCLES, 32));
    constant USEC_TICK_CYCLES_U   : unsigned(6 downto 0)  := to_unsigned(USEC_TICK_CYCLES mod 128, 7);

    -- FSM-side AXIS handshake
    signal src_valid : std_logic;
    signal src_last  : std_logic;

    -- ============================================================
    -- Frame layout
    --   [0..5]    dst MAC
    --   [6..11]   src MAC (= our_mac)
    --   [12..13]  ethertype 0x0800
    --   [14..33]  IPv4 header (20 bytes, proto=UDP)
    --   [34..41]  UDP header (8 bytes, csum=0)
    --   [42..53]  iperf2 header (id + tv_sec + tv_usec)
    --   [54..]    filler bytes
    -- ============================================================
    constant TX_IDLE      : std_logic_vector(3 downto 0) := "0000";  -- 4'd0
    constant TX_ETH_HDR   : std_logic_vector(3 downto 0) := "0001";  -- 4'd1
    constant TX_IP_HDR    : std_logic_vector(3 downto 0) := "0010";  -- 4'd2
    constant TX_UDP_HDR   : std_logic_vector(3 downto 0) := "0011";  -- 4'd3
    constant TX_IPERF_HDR : std_logic_vector(3 downto 0) := "0100";  -- 4'd4
    constant TX_PAYLOAD   : std_logic_vector(3 downto 0) := "0101";  -- 4'd5

    signal tx_state        : std_logic_vector(3 downto 0);
    signal hdr_cnt         : unsigned(5 downto 0);
    signal body_cnt        : unsigned(13 downto 0);
    signal payload_lat     : unsigned(13 downto 0);   -- latched at frame start
    signal gap_cnt         : unsigned(23 downto 0);   -- counts down inter_frame_delay between frames
    signal start_delay_cnt : unsigned(31 downto 0);   -- optional delay before the first frame of a burst
    signal enable_d        : std_logic;

    -- Pre-computed frame fields. ip_total_len = 20 (IP) + 8 (UDP) + payload_size.
    signal ip_total_len  : unsigned(15 downto 0);
    signal udp_total_len : unsigned(15 downto 0);

    -- IP id increments each frame so the receiver can correlate
    signal ip_id_cnt : unsigned(15 downto 0);
    signal ip_id_lat : unsigned(15 downto 0);

    -- IP header checksum: latched at packet start so the long 9-term carry
    -- chain doesn't sit on the tx_data_mux -> r_data path. The fold is two
    -- small adders done combinationally on the registered accumulator.
    signal ip_csum_acc : unsigned(31 downto 0);
    signal ip_fold1    : unsigned(16 downto 0);
    signal ip_fold2    : unsigned(15 downto 0);
    signal ip_checksum : std_logic_vector(15 downto 0);

    -- iperf2 sequence number (32-bit, wraps)
    signal seq_cnt       : unsigned(31 downto 0);
    signal usec_tick_cnt : unsigned(6 downto 0);
    signal ts_sec_cnt    : unsigned(31 downto 0);
    signal ts_usec_cnt   : unsigned(31 downto 0);
    signal ts_sec_lat    : unsigned(31 downto 0);
    signal ts_usec_lat   : unsigned(31 downto 0);

    -- pkts_sent is read back (pkts_sent + 1); VHDL-93 cannot read an out port.
    signal pkts_sent_i : unsigned(31 downto 0);

    -- 1-deep AXIS register-slice signals + combinational mux, declared ahead of
    -- the TX FSM that references src_ready and tx_data_mux (logic is below).
    signal r_data      : std_logic_vector(7 downto 0);
    signal r_valid     : std_logic;
    signal r_last      : std_logic;
    signal tx_data_mux : std_logic_vector(7 downto 0);
    signal src_ready   : std_logic;

begin

    ip_total_len  <= to_unsigned(28, 16) + resize(payload_lat, 16);
    udp_total_len <= to_unsigned(8, 16)  + resize(payload_lat, 16);

    ip_fold1    <= resize(ip_csum_acc(15 downto 0), 17) + resize(ip_csum_acc(31 downto 16), 17);
    ip_fold2    <= ip_fold1(15 downto 0) + resize(ip_fold1(16 downto 16), 16);
    ip_checksum <= not std_logic_vector(ip_fold2);

    src_ready <= (not r_valid) or tx_ready;

    pkts_sent <= std_logic_vector(pkts_sent_i);

    process (clk, rst_n)
        -- {16'd0, 16'd28 + {2'd0, payload_size}}: the 16-bit sum wraps inside
        -- the concatenation before it is zero-extended.
        variable v_len16 : unsigned(15 downto 0);
    begin
        if rst_n = '0' then
            tx_state        <= TX_IDLE;
            hdr_cnt         <= (others => '0');
            body_cnt        <= (others => '0');
            payload_lat     <= (others => '0');
            gap_cnt         <= (others => '0');
            start_delay_cnt <= (others => '0');
            enable_d        <= '0';
            ip_id_cnt       <= to_unsigned(1, 16);
            ip_id_lat       <= to_unsigned(1, 16);
            seq_cnt         <= (others => '0');
            usec_tick_cnt   <= (others => '0');
            ts_sec_cnt      <= (others => '0');
            ts_usec_cnt     <= (others => '0');
            ts_sec_lat      <= (others => '0');
            ts_usec_lat     <= (others => '0');
            pkts_sent_i     <= (others => '0');
            pkt_done_pulse  <= '0';
            ip_csum_acc     <= (others => '0');
            src_valid       <= '0';
            src_last        <= '0';
            tx_start        <= '0';
        elsif rising_edge(clk) then
            if usec_tick_cnt = USEC_TICK_CYCLES_U - 1 then
                usec_tick_cnt <= (others => '0');
                if ts_usec_cnt = to_unsigned(999999, 32) then
                    ts_usec_cnt <= (others => '0');
                    ts_sec_cnt  <= ts_sec_cnt + 1;
                else
                    ts_usec_cnt <= ts_usec_cnt + 1;
                end if;
            else
                usec_tick_cnt <= usec_tick_cnt + 1;
            end if;
            enable_d <= enable;
            pkt_done_pulse <= '0';
            -- tx_valid is r_valid (read here instead of the out port).
            if tx_ready = '1' and r_valid = '1' then
                tx_start <= '0';
            end if;
            -- src_last must survive until the output slice actually captures it.
            -- The slice samples src_* only while src_ready is high, so clearing
            -- tlast unconditionally lets it evaporate whenever the sink stalls on
            -- exactly that beat. The frame then merges with the next one, the MAC's
            -- oversize guard truncates the pair, and one frame goes out for every
            -- two generated - the rate-dependent every-other-packet TX loss.
            if src_ready = '1' then
                src_last <= '0';
            end if;

            if enable = '0' then
                start_delay_cnt <= (others => '0');
            elsif enable_d = '0' then
                start_delay_cnt <= START_DELAY_CYCLES_U;
                seq_cnt         <= (others => '0');
                pkts_sent_i     <= (others => '0');
            end if;

            case tx_state is
                when TX_IDLE =>
                    src_valid <= '0';
                    if gap_cnt /= 0 then
                        gap_cnt <= gap_cnt - 1;
                    elsif enable = '1' and enable_d = '0' and START_DELAY_CYCLES_U /= 0 then
                        -- Latch the new-burst delay above; start after it expires.
                        null;
                    elsif start_delay_cnt /= 0 then
                        start_delay_cnt <= start_delay_cnt - 1;
                    elsif enable = '1' then
                        tx_state    <= TX_ETH_HDR;
                        hdr_cnt     <= (others => '0');
                        payload_lat <= unsigned(payload_size);
                        ip_id_lat   <= ip_id_cnt;
                        ip_id_cnt   <= ip_id_cnt + 1;
                        ts_sec_lat  <= ts_sec_cnt;
                        ts_usec_lat <= ts_usec_cnt;
                        -- Register the long sum once per frame.
                        v_len16 := to_unsigned(28, 16) + resize(unsigned(payload_size), 16);
                        ip_csum_acc <= to_unsigned(16#4500#, 32)
                                     + resize(v_len16, 32)
                                     + resize(ip_id_cnt, 32)
                                     + to_unsigned(16#4000#, 32)
                                     + to_unsigned(16#4011#, 32)
                                     + resize(unsigned(our_ip(31 downto 16)), 32)
                                     + resize(unsigned(our_ip(15 downto 0)), 32)
                                     + resize(unsigned(dst_ip(31 downto 16)), 32)
                                     + resize(unsigned(dst_ip(15 downto 0)), 32);
                        tx_start    <= '1';
                        src_valid   <= '1';
                    end if;

                when TX_ETH_HDR =>
                    src_valid <= '1';
                    if src_ready = '1' and src_valid = '1' then
                        hdr_cnt <= hdr_cnt + 1;
                        if hdr_cnt = 13 then
                            tx_state <= TX_IP_HDR;
                            hdr_cnt  <= (others => '0');
                        end if;
                    end if;

                when TX_IP_HDR =>
                    src_valid <= '1';
                    if src_ready = '1' and src_valid = '1' then
                        hdr_cnt <= hdr_cnt + 1;
                        if hdr_cnt = 19 then
                            tx_state <= TX_UDP_HDR;
                            hdr_cnt  <= (others => '0');
                        end if;
                    end if;

                when TX_UDP_HDR =>
                    src_valid <= '1';
                    if src_ready = '1' and src_valid = '1' then
                        hdr_cnt <= hdr_cnt + 1;
                        if hdr_cnt = 7 then
                            tx_state <= TX_IPERF_HDR;
                            hdr_cnt  <= (others => '0');
                        end if;
                    end if;

                when TX_IPERF_HDR =>
                    src_valid <= '1';
                    if src_ready = '1' and src_valid = '1' then
                        hdr_cnt <= hdr_cnt + 1;
                        if hdr_cnt = 11 then
                            tx_state <= TX_PAYLOAD;
                            body_cnt <= to_unsigned(12, 14);  -- 12 bytes already counted as iperf hdr
                        end if;
                    end if;

                when TX_PAYLOAD =>
                    src_valid <= '1';
                    if src_ready = '1' and src_valid = '1' then
                        body_cnt <= body_cnt + 1;
                        -- Arm src_last one cycle ahead so it lands with the
                        -- last data byte (registers update next clock).
                        if body_cnt = payload_lat - 2 then
                            src_last <= '1';
                        end if;
                        if body_cnt = payload_lat - 1 then
                            -- Frame done. Always return through TX_IDLE for one
                            -- cycle so src_valid drops; otherwise the 1-deep
                            -- skid would latch the last payload byte as byte 0
                            -- of the next frame (verified at wire level: byte
                            -- 0 = last_payload_byte, dst-MAC shifted by 1).
                            pkts_sent_i    <= pkts_sent_i + 1;
                            seq_cnt        <= seq_cnt + 1;
                            pkt_done_pulse <= '1';
                            tx_state       <= TX_IDLE;
                            gap_cnt        <= unsigned(inter_frame_delay);
                            src_valid      <= '0';
                        end if;
                    end if;

                when others =>
                    tx_state <= TX_IDLE;
            end case;
        end if;
    end process;

    -- ============================================================
    -- 1-deep AXIS register slice. r_data/r_valid/r_last and src_ready are
    -- declared above (ahead of the FSM that references them).
    -- ============================================================
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

    -- ============================================================
    -- Combinational byte mux. tx_data_mux is declared above.
    -- ============================================================
    process (tx_state, hdr_cnt, body_cnt, dst_mac, our_mac, ip_total_len,
             ip_id_lat, ip_checksum, our_ip, dst_ip, src_port, dst_port,
             udp_total_len, seq_cnt, ts_sec_lat, ts_usec_lat)
    begin
        tx_data_mux <= x"00";
        case tx_state is
            when TX_ETH_HDR =>
                case to_integer(hdr_cnt) is
                    when 0      => tx_data_mux <= dst_mac(47 downto 40);
                    when 1      => tx_data_mux <= dst_mac(39 downto 32);
                    when 2      => tx_data_mux <= dst_mac(31 downto 24);
                    when 3      => tx_data_mux <= dst_mac(23 downto 16);
                    when 4      => tx_data_mux <= dst_mac(15 downto 8);
                    when 5      => tx_data_mux <= dst_mac(7 downto 0);
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
                case to_integer(hdr_cnt) is
                    when 0      => tx_data_mux <= x"45";
                    when 1      => tx_data_mux <= x"00";
                    when 2      => tx_data_mux <= std_logic_vector(ip_total_len(15 downto 8));
                    when 3      => tx_data_mux <= std_logic_vector(ip_total_len(7 downto 0));
                    when 4      => tx_data_mux <= std_logic_vector(ip_id_lat(15 downto 8));
                    when 5      => tx_data_mux <= std_logic_vector(ip_id_lat(7 downto 0));
                    when 6      => tx_data_mux <= x"40";
                    when 7      => tx_data_mux <= x"00";
                    when 8      => tx_data_mux <= x"40";             -- TTL = 64
                    when 9      => tx_data_mux <= x"11";             -- protocol = UDP
                    when 10     => tx_data_mux <= ip_checksum(15 downto 8);
                    when 11     => tx_data_mux <= ip_checksum(7 downto 0);
                    when 12     => tx_data_mux <= our_ip(31 downto 24);
                    when 13     => tx_data_mux <= our_ip(23 downto 16);
                    when 14     => tx_data_mux <= our_ip(15 downto 8);
                    when 15     => tx_data_mux <= our_ip(7 downto 0);
                    when 16     => tx_data_mux <= dst_ip(31 downto 24);
                    when 17     => tx_data_mux <= dst_ip(23 downto 16);
                    when 18     => tx_data_mux <= dst_ip(15 downto 8);
                    when 19     => tx_data_mux <= dst_ip(7 downto 0);
                    when others => tx_data_mux <= x"00";
                end case;

            when TX_UDP_HDR =>
                case to_integer(hdr_cnt) is
                    when 0      => tx_data_mux <= src_port(15 downto 8);
                    when 1      => tx_data_mux <= src_port(7 downto 0);
                    when 2      => tx_data_mux <= dst_port(15 downto 8);
                    when 3      => tx_data_mux <= dst_port(7 downto 0);
                    when 4      => tx_data_mux <= std_logic_vector(udp_total_len(15 downto 8));
                    when 5      => tx_data_mux <= std_logic_vector(udp_total_len(7 downto 0));
                    when 6      => tx_data_mux <= x"00";     -- UDP csum = 0 (skipped)
                    when 7      => tx_data_mux <= x"00";
                    when others => tx_data_mux <= x"00";
                end case;

            when TX_IPERF_HDR =>
                case to_integer(hdr_cnt) is
                    -- iperf2 UDP_datagram: { int32 id (BE); uint32 tv_sec (BE);
                    --                        uint32 tv_usec (BE) }
                    when 0      => tx_data_mux <= std_logic_vector(seq_cnt(31 downto 24));
                    when 1      => tx_data_mux <= std_logic_vector(seq_cnt(23 downto 16));
                    when 2      => tx_data_mux <= std_logic_vector(seq_cnt(15 downto 8));
                    when 3      => tx_data_mux <= std_logic_vector(seq_cnt(7 downto 0));
                    when 4      => tx_data_mux <= std_logic_vector(ts_sec_lat(31 downto 24));
                    when 5      => tx_data_mux <= std_logic_vector(ts_sec_lat(23 downto 16));
                    when 6      => tx_data_mux <= std_logic_vector(ts_sec_lat(15 downto 8));
                    when 7      => tx_data_mux <= std_logic_vector(ts_sec_lat(7 downto 0));
                    when 8      => tx_data_mux <= std_logic_vector(ts_usec_lat(31 downto 24));
                    when 9      => tx_data_mux <= std_logic_vector(ts_usec_lat(23 downto 16));
                    when 10     => tx_data_mux <= std_logic_vector(ts_usec_lat(15 downto 8));
                    when 11     => tx_data_mux <= std_logic_vector(ts_usec_lat(7 downto 0));
                    when others => tx_data_mux <= x"00";
                end case;

            -- Filler payload: simple ramp so iperf2 packet captures look sane.
            when TX_PAYLOAD =>
                tx_data_mux <= std_logic_vector(body_cnt(7 downto 0));

            when others =>
                tx_data_mux <= x"00";
        end case;
    end process;

end architecture rtl;
