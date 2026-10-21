-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- sfp_lb_tester.vhd - Traffic generator/checker for the ZCU106 SFP loopback
-- VHDL port of fpga/zcu106/rtl/sfp_lb_tester.v (formally proven equivalent;
-- see sim/parity/).
--
-- Plays a host on the far end of the link: its own eth_mac_sys (GMII mode, MAC
-- 02:00:00:00:00:02, IP 192.168.137.1) sends requests to the emacZero demo
-- (zcu106_eth_demo: 02:00:00:00:00:01, 192.168.137.200) and checks each reply:
--
--   ARP request  who-has 192.168.137.200       -> ARP reply
--   ICMP echo    id 0xBEEF, seq n, 18..1472 B  -> echo reply, same payload
--   UDP to 9999  18..1472 B payload            -> echo, ports swapped
--
-- Payloads start at 18 bytes, the smallest that needs no Ethernet padding;
-- short mode covers the padded sizes below that.
--
-- The three kinds rotate, one transaction in flight at a time, with payload
-- lengths stepping through their range and a sequence-seeded byte pattern.
-- Each reply is checked byte by byte against the expected frame (fields the
-- responder may choose, such as IP ID/TTL and the checksums, are not
-- compared), plus its length, terror, the IPv4 header checksum and the ICMP
-- checksum. No reply within ~1 ms counts as a timeout.
--
-- Negative mode (ctrl[2]) adds a fourth kind to the rotation: a frame the
-- demo must not answer, cycling through eight variants (based on a 32-byte
-- ping unless noted):
--   0 wrong destination MAC (02:00:00:00:00:11)
--   1 wrong destination IP (192.168.137.201)
--   2 ARP request for 192.168.137.201
--   3 UDP to port 9998
--   4 bad IPv4 header checksum
--   5 bad ICMP checksum
--   6 bad FCS (one data bit flipped on GMII after the MAC)
--   7 GMII tx_er in the middle of the frame
-- Silence for 200 us counts as ok_neg; a frame in that window counts as
-- neg_replies (not bad) and sets neg_fail[variant].
--
-- Short mode (ctrl[3]) uses ICMP payloads of 0..17 bytes and UDP payloads of
-- 1..18 bytes (all but 18 need Ethernet padding) and checks for replies of
-- the request's own length. A 0-byte UDP datagram is not sent: net_rx hands
-- datagrams on byte by byte, so an empty one never reaches udp_echo.
--
-- ctrl (any clock domain; synchronized here): [0] run  [1] clear counters
--   [2] negative frames  [3] short payloads
-- status (clk domain; stop traffic before reading for a coherent view):
--   [31:0]    tx_count     requests sent
--   [63:32]   ok_arp       correct ARP replies
--   [95:64]   ok_icmp      correct ICMP echo replies
--   [127:96]  ok_udp       correct UDP echoes
--   [159:128] bad          wrong replies (see first_* for the first one)
--   [191:160] timeouts     requests with no reply
--   [207:192] max_rtt      longest request-end to reply-end time, cycles
--   [211:208] first_reason 1 byte  2 length  3 terror  4 IP csum
--                          5 ICMP csum  6 timeout  7 unexpected frame
--   [213:212] first_kind   0 ARP  1 ICMP  2 UDP
--   [229:214] first_idx    byte offset of the first mismatch (reason 1)
--   [237:230] first_got    received byte   (reason 1)
--   [245:238] first_exp    expected byte   (reason 1)
--   [261:246] first_seq    sequence number of the first bad transaction
--   [262]     init_done    [263] run (synced)
--   [295:264] ok_neg       negative frames correctly ignored
--   [303:296] neg_fail     negative variants that got a reply
--   [351:304] rx_bytes     bytes in correct replies (Ethernet frame, no FCS)
--   [383:352] neg_replies  replies to negative frames
-- VHDL-93
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sfp_lb_tester is
    port (
        clk        : in  std_logic;                       -- 125 MHz
        rst_n      : in  std_logic;
        ctrl       : in  std_logic_vector(3 downto 0);
        link_ok    : in  std_logic;                       -- both 1000BASE-X links up

        -- GMII to the PCS/PMA (clk domain)
        gmii_txd   : out std_logic_vector(7 downto 0);
        gmii_tx_en : out std_logic;
        gmii_tx_er : out std_logic;
        gmii_rxd   : in  std_logic_vector(7 downto 0);
        gmii_rx_dv : in  std_logic;
        gmii_rx_er : in  std_logic;

        status     : out std_logic_vector(383 downto 0);
        ok_pulse   : out std_logic;                       -- one cycle per correct reply
        bad_pulse  : out std_logic                        -- one cycle per bad reply or timeout
    );
end entity sfp_lb_tester;

architecture rtl of sfp_lb_tester is

    subtype slv8  is std_logic_vector(7 downto 0);
    subtype u16   is unsigned(15 downto 0);
    subtype u32   is unsigned(31 downto 0);

    constant TM       : std_logic_vector(47 downto 0) := x"020000000002";   -- tester MAC
    constant DM       : std_logic_vector(47 downto 0) := x"020000000001";   -- demo MAC
    constant TI       : std_logic_vector(31 downto 0) := x"C0A88901";       -- 192.168.137.1
    constant DI       : std_logic_vector(31 downto 0) := x"C0A889C8";       -- 192.168.137.200
    constant UDP_PORT : std_logic_vector(15 downto 0) := x"270F";           -- 9999
    constant ICMP_ID  : std_logic_vector(15 downto 0) := x"BEEF";
    constant K_ARP    : std_logic_vector(1 downto 0)  := "00";
    constant K_ICMP   : std_logic_vector(1 downto 0)  := "01";
    constant K_UDP    : std_logic_vector(1 downto 0)  := "10";
    constant K_NEG    : std_logic_vector(1 downto 0)  := "11";
    constant TIMEOUT  : unsigned(16 downto 0) := "1" & x"FFFF";          -- ~1.05 ms
    constant NEG_WIN  : unsigned(16 downto 0) := to_unsigned(25000, 17); -- 200 us

    -- =========================================================================
    -- Helpers
    -- =========================================================================
    function fold(s : u32) return u16 is   -- one's-complement fold of a 32-bit sum
        variable t : u32;
    begin
        t := (x"0000" & s(15 downto 0)) + (x"0000" & s(31 downto 16));
        t := (x"0000" & t(15 downto 0)) + (x"0000" & t(31 downto 16));
        return t(15 downto 0);
    end function fold;

    function pat(i : u16; s : u16) return slv8 is   -- payload byte i of transaction s
    begin
        return std_logic_vector(i(7 downto 0) xor (s(7 downto 0) + i(15 downto 8)));
    end function pat;

    -- =========================================================================
    -- Control synchronizers (static levels, so bitwise synchronizers are fine)
    -- =========================================================================
    signal ctrl_s0, ctrl_s1 : std_logic_vector(3 downto 0);
    attribute ASYNC_REG : string;
    attribute ASYNC_REG of ctrl_s0 : signal is "TRUE";
    attribute ASYNC_REG of ctrl_s1 : signal is "TRUE";
    signal run, clr, neg_en, short : std_logic;

    -- =========================================================================
    -- Tester MAC
    -- =========================================================================
    signal aw_valid, w_valid, init_done : std_logic;
    signal aw_ready, w_ready, b_valid   : std_logic;

    signal tx_tdata             : std_logic_vector(7 downto 0);
    signal tx_tvalid, tx_tlast  : std_logic;
    signal tx_tready            : std_logic;
    signal rx_tdata             : std_logic_vector(7 downto 0);
    signal rx_tvalid, rx_tlast, rx_terror : std_logic;
    signal mac_txd              : std_logic_vector(7 downto 0);
    signal mac_tx_en, mac_tx_er : std_logic;

    -- =========================================================================
    -- Transaction state
    -- =========================================================================
    constant S_IDLE : std_logic_vector(2 downto 0) := "000";
    constant S_PREP : std_logic_vector(2 downto 0) := "001";
    constant S_SUM  : std_logic_vector(2 downto 0) := "010";
    constant S_SEND : std_logic_vector(2 downto 0) := "011";
    constant S_WAIT : std_logic_vector(2 downto 0) := "100";
    constant S_GAP  : std_logic_vector(2 downto 0) := "101";
    signal state     : std_logic_vector(2 downto 0);
    signal kind      : std_logic_vector(1 downto 0);
    signal seq       : u16;
    signal plen      : u16;                    -- payload length (ICMP data / UDP data)
    signal flen      : u16;                    -- request frame length
    signal ip_len    : u16;
    signal ip_csum, icmp_csum : std_logic_vector(15 downto 0);
    signal sum_acc   : u32;
    signal idx       : u16;
    signal icmp_step : u16;
    signal udp_step  : u16;
    signal timer     : unsigned(16 downto 0);
    signal rtt       : u16;
    signal gap_cnt   : unsigned(3 downto 0);

    -- Frame template and deviations for this transaction (set in S_PREP):
    -- the request is built as kind fk, and negative variants change one thing
    signal fk         : std_logic_vector(1 downto 0);
    signal q_dm       : std_logic_vector(47 downto 0);
    signal q_di       : std_logic_vector(31 downto 0);
    signal q_dport    : std_logic_vector(15 downto 0);
    signal q_bad_ipcs, q_bad_iccs, q_fcs, q_txer : std_logic;
    signal neg_var    : unsigned(2 downto 0);
    signal short_step : unsigned(4 downto 0);  -- 0..17

    -- GMII fault injection after the MAC: at frame byte 42 (GMII byte 50,
    -- after preamble and SFD), flip bit 4 (bad FCS) or assert tx_er
    signal gbyte  : unsigned(11 downto 0);
    signal inject : std_logic;

    signal udp_sport : std_logic_vector(15 downto 0);
    signal udp_len_w : u16;                    -- UDP header + data
    signal proto     : std_logic_vector(7 downto 0);

    -- Request byte at idx
    signal tx_byte   : std_logic_vector(7 downto 0);

    -- =========================================================================
    -- RX checker
    -- =========================================================================
    signal ridx       : u16;
    signal r_mis      : std_logic;             -- a compared byte differed
    signal r_mis_idx  : u16;
    signal r_mis_got, r_mis_exp : std_logic_vector(7 downto 0);
    signal r_ipsum, r_icsum : u32;
    signal exp_len    : u16;

    -- Expected reply byte at ridx, and whether it is compared
    signal exp_byte   : std_logic_vector(7 downto 0);
    signal exp_chk    : std_logic;

    -- One's-complement running sums over the IPv4 header and the ICMP message
    signal rx_word    : u16;
    signal in_iphdr   : std_logic;
    signal in_icmp    : std_logic;

    -- =========================================================================
    -- Counters and the first failure
    -- =========================================================================
    signal tx_count, ok_arp, ok_icmp, ok_udp, bad, timeouts : u32;
    signal ok_neg, neg_replies : u32;
    signal neg_fail     : std_logic_vector(7 downto 0);
    signal rx_bytes     : unsigned(47 downto 0);
    signal max_rtt      : u16;
    signal have_first   : std_logic;
    signal first_reason : std_logic_vector(3 downto 0);
    signal first_kind   : std_logic_vector(1 downto 0);
    signal first_idx, first_seq : u16;
    signal first_got, first_exp : std_logic_vector(7 downto 0);

    -- Evaluate a finished reply (valid on the cycle with rx_tlast)
    signal last_mis     : std_logic;
    signal any_mis      : std_logic;
    signal len_now      : u16;
    signal ipsum_now    : u32;
    signal icsum_now    : u32;
    signal reply_reason : std_logic_vector(3 downto 0);

begin

    -- =========================================================================
    -- Control synchronizers
    -- =========================================================================
    process (clk)
    begin
        if rising_edge(clk) then
            ctrl_s0 <= ctrl;
            ctrl_s1 <= ctrl_s0;
        end if;
    end process;
    run    <= ctrl_s1(0);
    clr    <= ctrl_s1(1);
    neg_en <= ctrl_s1(2);
    short  <= ctrl_s1(3);

    -- =========================================================================
    -- Tester MAC. After reset one AXI-Lite write sets MAC_LO so the MAC
    -- address becomes 02:00:00:00:00:02 (MAC_HI keeps its 0x0200 default).
    -- =========================================================================
    u_mac : entity work.eth_mac_sys
        generic map (
            PHY_INTERFACE => "GMII",
            CLK_FREQ_HZ   => 125_000_000
        )
        port map (
            clk             => clk,
            rst_n           => rst_n,
            s_axi_awaddr    => x"0C",          -- MAC_LO
            s_axi_awvalid   => aw_valid,
            s_axi_awready   => aw_ready,
            s_axi_wdata     => TM(31 downto 0),
            s_axi_wstrb     => x"F",
            s_axi_wvalid    => w_valid,
            s_axi_wready    => w_ready,
            s_axi_bresp     => open,
            s_axi_bvalid    => b_valid,
            s_axi_bready    => '1',
            s_axi_araddr    => x"00",
            s_axi_arvalid   => '0',
            s_axi_arready   => open,
            s_axi_rdata     => open,
            s_axi_rresp     => open,
            s_axi_rvalid    => open,
            s_axi_rready    => '1',
            s_axis_tdata    => tx_tdata,
            s_axis_tvalid   => tx_tvalid,
            s_axis_tready   => tx_tready,
            s_axis_tlast    => tx_tlast,
            m_axis_tdata    => rx_tdata,
            m_axis_tvalid   => rx_tvalid,
            m_axis_tready   => '1',
            m_axis_tlast    => rx_tlast,
            m_axis_terror   => rx_terror,
            m_axis_tsof     => open,
            mii_txd         => open,
            mii_tx_en       => open,
            mii_tx_clk      => '0',
            mii_rxd         => "0000",
            mii_rx_dv       => '0',
            mii_rx_er       => '0',
            mii_rx_clk      => '0',
            mii_col         => '0',
            mii_crs         => '0',
            clk_125         => clk,
            clk_125_90      => '0',
            clk_25          => '0',
            clk_2_5         => '0',
            rgmii_txd       => open,
            rgmii_tx_ctl    => open,
            rgmii_txc       => open,
            rgmii_rxd       => "0000",
            rgmii_rx_ctl    => '0',
            rgmii_rxc       => '0',
            phy_gmii_txd    => mac_txd,
            phy_gmii_tx_en  => mac_tx_en,
            phy_gmii_tx_er  => mac_tx_er,
            phy_gmii_txc    => open,
            phy_gmii_rx_clk => clk,
            phy_gmii_rxd    => gmii_rxd,
            phy_gmii_rx_dv  => gmii_rx_dv,
            phy_gmii_rx_er  => gmii_rx_er,
            mdc             => open,
            mdio_i          => '1',
            mdio_o          => open,
            mdio_oe         => open,
            cfg_ip_addr     => open,
            irq             => open
        );

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            aw_valid  <= '1';
            w_valid   <= '1';
            init_done <= '0';
        elsif rising_edge(clk) then
            if aw_valid = '1' and aw_ready = '1' then aw_valid <= '0'; end if;
            if w_valid = '1' and w_ready = '1' then w_valid <= '0'; end if;
            if b_valid = '1' then init_done <= '1'; end if;
        end if;
    end process;

    -- =========================================================================
    -- GMII fault injection
    -- =========================================================================
    process (clk, rst_n)
    begin
        if rst_n = '0' then
            gbyte <= (others => '0');
        elsif rising_edge(clk) then
            if mac_tx_en = '0' then
                gbyte <= (others => '0');
            elsif gbyte /= x"FFF" then
                gbyte <= gbyte + 1;
            end if;
        end if;
    end process;
    inject     <= '1' when mac_tx_en = '1' and gbyte = 50 and kind = K_NEG else '0';
    gmii_txd   <= mac_txd xor x"10" when (inject = '1' and q_fcs = '1') else
                  mac_txd;
    gmii_tx_en <= mac_tx_en;
    gmii_tx_er <= mac_tx_er or (inject and q_txer);

    udp_sport <= x"C000" or ("0000" & std_logic_vector(seq(11 downto 0)));
    udp_len_w <= ip_len - 20;
    proto     <= x"11" when fk = K_UDP else x"01";

    -- Request byte at idx
    process (fk, idx, seq, q_dm, q_di, q_dport, ip_len, ip_csum, icmp_csum,
             proto, udp_sport, udp_len_w)
        variable v : std_logic_vector(7 downto 0);
    begin
        v := x"00";
        if fk = K_ARP then
            case to_integer(idx) is
                when 0 | 1 | 2 | 3 | 4 | 5 => v := x"FF";
                when 6  => v := TM(47 downto 40);  when 7  => v := TM(39 downto 32);
                when 8  => v := TM(31 downto 24);  when 9  => v := TM(23 downto 16);
                when 10 => v := TM(15 downto 8);   when 11 => v := TM(7 downto 0);
                when 12 => v := x"08";             when 13 => v := x"06";
                when 14 => v := x"00";             when 15 => v := x"01";
                when 16 => v := x"08";             when 17 => v := x"00";
                when 18 => v := x"06";             when 19 => v := x"04";
                when 20 => v := x"00";             when 21 => v := x"01";
                when 22 => v := TM(47 downto 40);  when 23 => v := TM(39 downto 32);
                when 24 => v := TM(31 downto 24);  when 25 => v := TM(23 downto 16);
                when 26 => v := TM(15 downto 8);   when 27 => v := TM(7 downto 0);
                when 28 => v := TI(31 downto 24);  when 29 => v := TI(23 downto 16);
                when 30 => v := TI(15 downto 8);   when 31 => v := TI(7 downto 0);
                when 38 => v := q_di(31 downto 24);  when 39 => v := q_di(23 downto 16);
                when 40 => v := q_di(15 downto 8);   when 41 => v := q_di(7 downto 0);
                when others => v := x"00";         -- target MAC (32..37) = 0
            end case;
        elsif idx >= 42 then
            v := pat(idx - 42, seq);
        else
            case to_integer(idx) is
                when 0  => v := q_dm(47 downto 40);  when 1  => v := q_dm(39 downto 32);
                when 2  => v := q_dm(31 downto 24);  when 3  => v := q_dm(23 downto 16);
                when 4  => v := q_dm(15 downto 8);   when 5  => v := q_dm(7 downto 0);
                when 6  => v := TM(47 downto 40);  when 7  => v := TM(39 downto 32);
                when 8  => v := TM(31 downto 24);  when 9  => v := TM(23 downto 16);
                when 10 => v := TM(15 downto 8);   when 11 => v := TM(7 downto 0);
                when 12 => v := x"08";             when 13 => v := x"00";
                when 14 => v := x"45";             when 15 => v := x"00";
                when 16 => v := std_logic_vector(ip_len(15 downto 8));
                when 17 => v := std_logic_vector(ip_len(7 downto 0));
                when 18 => v := std_logic_vector(seq(15 downto 8));
                when 19 => v := std_logic_vector(seq(7 downto 0));
                when 20 => v := x"00";             when 21 => v := x"00";
                when 22 => v := x"40";             when 23 => v := proto;
                when 24 => v := ip_csum(15 downto 8);
                when 25 => v := ip_csum(7 downto 0);
                when 26 => v := TI(31 downto 24);  when 27 => v := TI(23 downto 16);
                when 28 => v := TI(15 downto 8);   when 29 => v := TI(7 downto 0);
                when 30 => v := q_di(31 downto 24);  when 31 => v := q_di(23 downto 16);
                when 32 => v := q_di(15 downto 8);   when 33 => v := q_di(7 downto 0);
                when others =>
                    if fk = K_ICMP then
                        case to_integer(idx) is
                            when 34 => v := x"08";
                            when 35 => v := x"00";
                            when 36 => v := icmp_csum(15 downto 8);
                            when 37 => v := icmp_csum(7 downto 0);
                            when 38 => v := ICMP_ID(15 downto 8);
                            when 39 => v := ICMP_ID(7 downto 0);
                            when 40 => v := std_logic_vector(seq(15 downto 8));
                            when others => v := std_logic_vector(seq(7 downto 0));  -- 41
                        end case;
                    else
                        case to_integer(idx) is
                            when 34 => v := udp_sport(15 downto 8);
                            when 35 => v := udp_sport(7 downto 0);
                            when 36 => v := q_dport(15 downto 8);
                            when 37 => v := q_dport(7 downto 0);
                            when 38 => v := std_logic_vector(udp_len_w(15 downto 8));
                            when 39 => v := std_logic_vector(udp_len_w(7 downto 0));
                            when others => v := x"00";        -- csum 0
                        end case;
                    end if;
            end case;
        end if;
        tx_byte <= v;
    end process;

    -- =========================================================================
    -- RX checker
    -- =========================================================================
    exp_len <= to_unsigned(60, 16) when flen < 60 else flen;

    -- Expected reply byte at ridx, and whether it is compared
    process (ridx, flen, kind, seq, ip_len, proto, udp_sport, udp_len_w)
        variable b : std_logic_vector(7 downto 0);
        variable c : std_logic;
    begin
        b := x"00";
        c := '1';
        if ridx >= flen then
            c := '0';                                  -- padding
        elsif ridx < 12 then
            case to_integer(ridx) is
                when 0  => b := TM(47 downto 40);  when 1  => b := TM(39 downto 32);
                when 2  => b := TM(31 downto 24);  when 3  => b := TM(23 downto 16);
                when 4  => b := TM(15 downto 8);   when 5  => b := TM(7 downto 0);
                when 6  => b := DM(47 downto 40);  when 7  => b := DM(39 downto 32);
                when 8  => b := DM(31 downto 24);  when 9  => b := DM(23 downto 16);
                when 10 => b := DM(15 downto 8);   when others => b := DM(7 downto 0);
            end case;
        elsif kind = K_ARP then
            case to_integer(ridx) is
                when 12 => b := x"08";             when 13 => b := x"06";
                when 14 => b := x"00";             when 15 => b := x"01";
                when 16 => b := x"08";             when 17 => b := x"00";
                when 18 => b := x"06";             when 19 => b := x"04";
                when 20 => b := x"00";             when 21 => b := x"02";
                when 22 => b := DM(47 downto 40);  when 23 => b := DM(39 downto 32);
                when 24 => b := DM(31 downto 24);  when 25 => b := DM(23 downto 16);
                when 26 => b := DM(15 downto 8);   when 27 => b := DM(7 downto 0);
                when 28 => b := DI(31 downto 24);  when 29 => b := DI(23 downto 16);
                when 30 => b := DI(15 downto 8);   when 31 => b := DI(7 downto 0);
                when 32 => b := TM(47 downto 40);  when 33 => b := TM(39 downto 32);
                when 34 => b := TM(31 downto 24);  when 35 => b := TM(23 downto 16);
                when 36 => b := TM(15 downto 8);   when 37 => b := TM(7 downto 0);
                when 38 => b := TI(31 downto 24);  when 39 => b := TI(23 downto 16);
                when 40 => b := TI(15 downto 8);   when others => b := TI(7 downto 0);
            end case;
        elsif ridx >= 42 then
            b := pat(ridx - 42, seq);
        else
            case to_integer(ridx) is
                when 12 => b := x"08";             when 13 => b := x"00";
                when 14 => b := x"45";
                when 16 => b := std_logic_vector(ip_len(15 downto 8));
                when 17 => b := std_logic_vector(ip_len(7 downto 0));
                when 23 => b := proto;
                when 26 => b := DI(31 downto 24);  when 27 => b := DI(23 downto 16);
                when 28 => b := DI(15 downto 8);   when 29 => b := DI(7 downto 0);
                when 30 => b := TI(31 downto 24);  when 31 => b := TI(23 downto 16);
                when 32 => b := TI(15 downto 8);   when 33 => b := TI(7 downto 0);
                -- TOS, ID, flags/fragment, TTL and the IP checksum are the
                -- responder's choice; the checksum is verified by summing.
                when 15 | 18 | 19 | 20 | 21 | 22 | 24 | 25 => c := '0';
                when others =>
                    if kind = K_ICMP then
                        case to_integer(ridx) is
                            when 34 => b := x"00";         -- echo reply
                            when 35 => b := x"00";
                            when 38 => b := ICMP_ID(15 downto 8);
                            when 39 => b := ICMP_ID(7 downto 0);
                            when 40 => b := std_logic_vector(seq(15 downto 8));
                            when 41 => b := std_logic_vector(seq(7 downto 0));
                            when others => c := '0';       -- 36, 37 csum
                        end case;
                    else
                        case to_integer(ridx) is
                            when 34 => b := UDP_PORT(15 downto 8);
                            when 35 => b := UDP_PORT(7 downto 0);
                            when 36 => b := udp_sport(15 downto 8);
                            when 37 => b := udp_sport(7 downto 0);
                            when 38 => b := std_logic_vector(udp_len_w(15 downto 8));
                            when 39 => b := std_logic_vector(udp_len_w(7 downto 0));
                            when others => c := '0';       -- 40, 41 csum
                        end case;
                    end if;
            end case;
        end if;
        exp_byte <= b;
        exp_chk  <= c;
    end process;

    -- One's-complement running sums over the IPv4 header and the ICMP message
    rx_word  <= unsigned(x"00" & rx_tdata) when ridx(0) = '1' else
                unsigned(rx_tdata & x"00");
    in_iphdr <= '1' when (ridx >= 14) and (ridx < 34) else '0';
    in_icmp  <= '1' when (ridx >= 34) and (ridx < flen) else '0';

    -- =========================================================================
    -- Counters and the first failure
    -- =========================================================================

    -- Evaluate a finished reply (valid on the cycle with rx_tlast)
    last_mis  <= '1' when exp_chk = '1' and rx_tdata /= exp_byte else '0';
    any_mis   <= r_mis or last_mis;
    len_now   <= ridx + 1;
    ipsum_now <= r_ipsum;                     -- header ends at byte 33
    icsum_now <= r_icsum + resize(rx_word, 32) when in_icmp = '1' else r_icsum;

    process (state, kind, rx_terror, any_mis, len_now, exp_len, ipsum_now, icsum_now)
    begin
        if state /= S_WAIT or kind = K_NEG then
            reply_reason <= "0111";
        elsif rx_terror = '1' then
            reply_reason <= "0011";
        elsif any_mis = '1' then
            reply_reason <= "0001";
        elsif len_now /= exp_len then
            reply_reason <= "0010";
        elsif kind /= K_ARP and fold(ipsum_now) /= x"FFFF" then
            reply_reason <= "0100";
        elsif kind = K_ICMP and fold(icsum_now) /= x"FFFF" then
            reply_reason <= "0101";
        else
            reply_reason <= "0000";
        end if;
    end process;

    -- =========================================================================
    -- Main FSM
    -- =========================================================================
    process (clk, rst_n)
    begin
        if rst_n = '0' then
            state      <= S_IDLE;
            kind       <= K_ARP;
            seq        <= (others => '0');
            plen       <= (others => '0');
            flen       <= to_unsigned(42, 16);
            ip_len     <= (others => '0');
            ip_csum    <= (others => '0');
            icmp_csum  <= (others => '0');
            sum_acc    <= (others => '0');
            idx        <= (others => '0');
            icmp_step  <= to_unsigned(18, 16);
            udp_step   <= to_unsigned(18, 16);
            timer      <= (others => '0');
            rtt        <= (others => '0');
            gap_cnt    <= (others => '0');
            fk         <= K_ARP;
            q_dm       <= DM;
            q_di       <= DI;
            q_dport    <= UDP_PORT;
            q_bad_ipcs <= '0';
            q_bad_iccs <= '0';
            q_fcs      <= '0';
            q_txer     <= '0';
            neg_var    <= (others => '0');
            short_step <= (others => '0');
            tx_tdata   <= (others => '0');
            tx_tvalid  <= '0';
            tx_tlast   <= '0';
            ridx       <= (others => '0');
            r_mis      <= '0';
            r_mis_idx  <= (others => '0');
            r_mis_got  <= (others => '0');
            r_mis_exp  <= (others => '0');
            r_ipsum    <= (others => '0');
            r_icsum    <= (others => '0');
            tx_count   <= (others => '0');
            ok_arp     <= (others => '0');
            ok_icmp    <= (others => '0');
            ok_udp     <= (others => '0');
            bad        <= (others => '0');
            timeouts   <= (others => '0');
            ok_neg     <= (others => '0');
            neg_replies <= (others => '0');
            neg_fail   <= (others => '0');
            rx_bytes   <= (others => '0');
            max_rtt    <= (others => '0');
            have_first <= '0';
            first_reason <= (others => '0');
            first_kind <= (others => '0');
            first_idx  <= (others => '0');
            first_seq  <= (others => '0');
            first_got  <= (others => '0');
            first_exp  <= (others => '0');
            ok_pulse   <= '0';
            bad_pulse  <= '0';
        elsif rising_edge(clk) then
            ok_pulse  <= '0';
            bad_pulse <= '0';

            -- ---------------- request side ----------------
            case state is
            when S_IDLE =>
                if run = '1' and link_ok = '1' and init_done = '1' then
                    state <= S_PREP;
                end if;
            when S_PREP =>
                -- ICMP and UDP data 18..1472 B (full 1500-byte IP MTU); short mode
                -- sweeps ICMP 0..17 B up and UDP 18..1 B down
                fk         <= kind;
                q_dm       <= DM;
                q_di       <= DI;
                q_dport    <= UDP_PORT;
                q_bad_ipcs <= '0';
                q_bad_iccs <= '0';
                q_fcs      <= '0';
                q_txer     <= '0';
                case kind is
                    when K_ARP =>
                        plen <= (others => '0');
                    when K_ICMP =>
                        if short = '1' then
                            plen <= resize(short_step, 16);
                        else
                            plen <= icmp_step;
                        end if;
                    when K_UDP =>
                        if short = '1' then
                            plen <= resize(to_unsigned(18, 5) - short_step, 16);
                        else
                            plen <= udp_step;
                        end if;
                    when others =>      -- K_NEG: variant neg_var
                        if neg_var = 2 then
                            fk <= K_ARP;
                        elsif neg_var = 3 then
                            fk <= K_UDP;
                        else
                            fk <= K_ICMP;
                        end if;
                        if neg_var = 2 then
                            plen <= (others => '0');
                        else
                            plen <= to_unsigned(32, 16);
                        end if;
                        case to_integer(neg_var) is
                            when 0 => q_dm       <= DM xor x"000000000010";
                            when 1 => q_di       <= DI xor x"00000001";
                            when 2 => q_di       <= DI xor x"00000001";
                            when 3 => q_dport    <= std_logic_vector(unsigned(UDP_PORT) - 1);
                            when 4 => q_bad_ipcs <= '1';
                            when 5 => q_bad_iccs <= '1';
                            when 6 => q_fcs      <= '1';
                            when others => q_txer <= '1';
                        end case;
                end case;
                sum_acc <= (others => '0');
                idx     <= (others => '0');
                state   <= S_SUM;
            when S_SUM =>
                -- ip_len/flen from plen; ICMP data sum, one byte per cycle
                ip_len <= 28 + plen;
                if fk = K_ARP then
                    flen <= to_unsigned(42, 16);
                else
                    flen <= 42 + plen;
                end if;
                if fk = K_ICMP and idx < plen then
                    if idx(0) = '1' then
                        sum_acc <= sum_acc + unsigned(x"000000" & pat(idx, seq));
                    else
                        sum_acc <= sum_acc + unsigned(x"0000" & pat(idx, seq) & x"00");
                    end if;
                    idx     <= idx + 1;
                else
                    ip_csum   <= std_logic_vector(
                                     (not fold(x"00004500" + (x"0000" & (28 + plen))
                                               + (x"0000" & seq) + x"00000000"
                                               + unsigned(x"0000" & x"40" & proto)
                                               + unsigned(x"0000" & TI(31 downto 16))
                                               + unsigned(x"0000" & TI(15 downto 0))
                                               + unsigned(x"0000" & q_di(31 downto 16))
                                               + unsigned(x"0000" & q_di(15 downto 0))))
                                     xor (to_unsigned(0, 15) & q_bad_ipcs));
                    icmp_csum <= std_logic_vector(
                                     (not fold(sum_acc + x"00000800"
                                               + unsigned(x"0000" & ICMP_ID)
                                               + (x"0000" & seq)))
                                     xor (to_unsigned(0, 15) & q_bad_iccs));
                    idx       <= (others => '0');
                    state     <= S_SEND;
                end if;
            when S_SEND =>
                if tx_tvalid = '0' or tx_tready = '1' then
                    if tx_tvalid = '1' and tx_tlast = '1' then
                        tx_tvalid <= '0';
                        tx_tlast  <= '0';
                        tx_count  <= tx_count + 1;
                        timer     <= (others => '0');
                        rtt       <= (others => '0');
                        ridx      <= (others => '0');
                        r_mis     <= '0';
                        r_ipsum   <= (others => '0');
                        r_icsum   <= (others => '0');
                        state     <= S_WAIT;
                    else
                        tx_tdata  <= tx_byte;
                        tx_tvalid <= '1';
                        if idx = flen - 1 then
                            tx_tlast <= '1';
                        else
                            tx_tlast <= '0';
                        end if;
                        idx       <= idx + 1;
                    end if;
                end if;
            when S_WAIT =>
                timer <= timer + 1;
                if rtt /= x"FFFF" then rtt <= rtt + 1; end if;
                if kind = K_NEG then
                    if timer = NEG_WIN then     -- silence: correct
                        ok_neg   <= ok_neg + 1;
                        ok_pulse <= '1';
                        gap_cnt  <= (others => '0');
                        state    <= S_GAP;
                    end if;
                elsif timer = TIMEOUT then
                    timeouts  <= timeouts + 1;
                    bad_pulse <= '1';
                    if have_first = '0' then
                        have_first   <= '1';
                        first_reason <= "0110";
                        first_kind   <= kind;
                        first_seq    <= seq;
                        first_idx    <= (others => '0');
                        first_got    <= (others => '0');
                        first_exp    <= (others => '0');
                    end if;
                    gap_cnt <= (others => '0');
                    state   <= S_GAP;
                end if;
            when S_GAP =>
                gap_cnt <= gap_cnt + 1;
                if gap_cnt = 15 then
                    seq  <= seq + 1;
                    if kind = K_UDP then
                        if neg_en = '1' then
                            kind <= K_NEG;
                        else
                            kind <= K_ARP;
                        end if;
                    elsif kind = K_NEG then
                        kind <= K_ARP;
                    else
                        kind <= std_logic_vector(unsigned(kind) + 1);
                    end if;
                    if kind = K_NEG then
                        neg_var <= neg_var + 1;
                    end if;
                    if kind = K_UDP then
                        if short_step = 17 then
                            short_step <= (others => '0');
                        else
                            short_step <= short_step + 1;
                        end if;
                    end if;
                    -- +37 in a cycle of 1455 (18..1472): coprime, so in
                    -- time every payload length is sent, crossing the
                    -- icmp_echo boundaries that once failed (249, 504 B)
                    if kind = K_ICMP then
                        if icmp_step >= 1436 then
                            icmp_step <= icmp_step - 1418;
                        else
                            icmp_step <= icmp_step + 37;
                        end if;
                    end if;
                    if kind = K_UDP then
                        if udp_step > 1375 then
                            udp_step <= udp_step - 1358;
                        else
                            udp_step <= udp_step + 97;
                        end if;
                    end if;
                    state <= S_IDLE;
                end if;
            when others =>
                state <= S_IDLE;
            end case;

            -- ---------------- reply side ----------------
            if rx_tvalid = '1' then
                if rx_tlast = '0' then
                    ridx <= ridx + 1;
                    if last_mis = '1' and r_mis = '0' then
                        r_mis     <= '1';
                        r_mis_idx <= ridx;
                        r_mis_got <= rx_tdata;
                        r_mis_exp <= exp_byte;
                    end if;
                    if in_iphdr = '1' then r_ipsum <= r_ipsum + resize(rx_word, 32); end if;
                    if in_icmp = '1'  then r_icsum <= r_icsum + resize(rx_word, 32); end if;
                else
                    ridx    <= (others => '0');
                    r_mis   <= '0';
                    r_ipsum <= (others => '0');
                    r_icsum <= (others => '0');
                    if reply_reason = "0000" then
                        ok_pulse <= '1';
                        case kind is
                            when K_ARP  => ok_arp  <= ok_arp  + 1;
                            when K_ICMP => ok_icmp <= ok_icmp + 1;
                            when others => ok_udp  <= ok_udp  + 1;
                        end case;
                        if rtt > max_rtt then max_rtt <= rtt; end if;
                        rx_bytes <= rx_bytes + resize(len_now, 48);
                    elsif state = S_WAIT and kind = K_NEG then
                        neg_replies <= neg_replies + 1;
                        neg_fail(to_integer(neg_var)) <= '1';
                        bad_pulse   <= '1';
                    else
                        -- note_bad(reply_reason): the Verilog task, inlined
                        -- (its only call site)
                        bad       <= bad + 1;
                        bad_pulse <= '1';
                        if have_first = '0' then
                            have_first   <= '1';
                            first_reason <= reply_reason;
                            first_kind   <= kind;
                            first_seq    <= seq;
                            if reply_reason = "0001" then
                                if r_mis = '1' then
                                    first_idx <= r_mis_idx;
                                else
                                    first_idx <= ridx;
                                end if;
                            else
                                first_idx <= (others => '0');
                            end if;
                            if r_mis = '1' then
                                first_got <= r_mis_got;
                                first_exp <= r_mis_exp;
                            else
                                first_got <= rx_tdata;
                                first_exp <= exp_byte;
                            end if;
                        end if;
                    end if;
                    if state = S_WAIT then
                        gap_cnt <= (others => '0');
                        state   <= S_GAP;
                    end if;
                end if;
            end if;

            if clr = '1' then
                tx_count   <= (others => '0');
                ok_arp     <= (others => '0');
                ok_icmp    <= (others => '0');
                ok_udp     <= (others => '0');
                bad        <= (others => '0');
                timeouts   <= (others => '0');
                ok_neg     <= (others => '0');
                neg_replies <= (others => '0');
                neg_fail   <= (others => '0');
                rx_bytes   <= (others => '0');
                max_rtt    <= (others => '0');
                have_first <= '0';
            end if;
        end if;
    end process;

    status <= std_logic_vector(neg_replies) & std_logic_vector(rx_bytes) & neg_fail &
              std_logic_vector(ok_neg) & run & init_done &
              std_logic_vector(first_seq) & first_exp & first_got &
              std_logic_vector(first_idx) & first_kind &
              first_reason & std_logic_vector(max_rtt) &
              std_logic_vector(timeouts) & std_logic_vector(bad) &
              std_logic_vector(ok_udp) & std_logic_vector(ok_icmp) &
              std_logic_vector(ok_arp) & std_logic_vector(tx_count);

end architecture rtl;
