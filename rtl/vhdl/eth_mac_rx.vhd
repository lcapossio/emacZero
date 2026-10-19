-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- eth_mac_rx.vhd - Ethernet MAC Receive Path
-- Strips preamble/SFD, validates CRC, filters destination MAC, and exposes a
-- byte-wide AXI4-Stream output with internal buffering for downstream stalls.
-- VHDL port of rtl/eth_mac_rx.v (formally proven equivalent; see sim/parity/).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity eth_mac_rx is
    generic (
        MCAST_HASH_FILTER    : integer := 0;
        -- The PHY cannot be backpressured. Keep enough RX buffering for typical
        -- downstream DMA stalls before declaring an overflow error. Errored frames
        -- are delivered with terror; the consumer must discard them.
        AXIS_FIFO_ADDR_WIDTH : integer := 11;     -- 2048 bytes (BRAM-backed sync FIFO)
        -- Frame-size limits in wire bytes after the SFD, FCS included. A frame
        -- with an 802.1Q / 802.1ad tag may be 4 bytes over MAX_FRAME_STD (1522),
        -- as 802.3 allows. jumbo_en raises the limit to MAX_FRAME_JUMBO, tagged
        -- or not, and never lowers it below the standard one.
        MAX_FRAME_STD        : integer := 1518;   -- 802.3 standard
        MAX_FRAME_JUMBO      : integer := 9018;   -- typical jumbo MTU + headers
        -- 1 = build the RX checksum checker (csum_calc.v): with rx_csum_en set, a
        -- frame whose IPv4 header, TCP, UDP, ICMP or ICMPv6 checksum is wrong is
        -- delivered with terror (the consumer must discard it) and pulses
        -- stat_err_csum. Scope is csum_calc.v's. 0 = no checker, rx_csum_en
        -- ignored.
        RX_CSUM_OFFLOAD      : integer := 0
    );
    port (
        clk               : in  std_logic;
        rst_n             : in  std_logic;

        -- GMII RX interface (from RGMII or direct PHY)
        gmii_rxd          : in  std_logic_vector(7 downto 0);
        gmii_rx_dv        : in  std_logic;
        gmii_rx_er        : in  std_logic;

        -- MAC address filter
        our_mac           : in  std_logic_vector(47 downto 0);
        promisc           : in  std_logic;
        passthrough       : in  std_logic;    -- sniffer mode: also bypass MAC filter
                                              -- and never drop on FCS/size errors;
                                              -- m_axis_terror still flagged.

        -- Frame-size policy
        jumbo_en          : in  std_logic;    -- 1 = accept up to MAX_FRAME_JUMBO

        -- Checksum verification (RX_CSUM_OFFLOAD=1 only), sampled at each SFD
        rx_csum_en        : in  std_logic;

        -- Multicast hash table (64 bits). Ignored when MCAST_HASH_FILTER == 0.
        mcast_hash_table  : in  std_logic_vector(63 downto 0);

        -- AXI4-Stream master frame data output. Preamble/SFD/FCS are removed.
        m_axis_tdata      : out std_logic_vector(7 downto 0);
        m_axis_tvalid     : out std_logic;
        m_axis_tready     : in  std_logic;
        m_axis_tlast      : out std_logic;
        m_axis_terror     : out std_logic;
        m_axis_tsof       : out std_logic;

        -- Per-frame classification pulses (single-cycle, end-of-frame)
        stat_done         : out std_logic;                       -- pulses 1 cycle when a frame ends
        stat_len          : out std_logic_vector(13 downto 0);   -- total wire bytes including FCS
        stat_err_fcs      : out std_logic;
        stat_err_align    : out std_logic;   -- rx_er asserted during frame
        stat_err_overflow : out std_logic;   -- FIFO overflow during frame
        stat_err_oversize : out std_logic;   -- length > MAX_FRAME (std/jumbo gated,
                                             -- std +4 for a VLAN-tagged frame)
        stat_err_csum     : out std_logic;   -- IP/L4 checksum wrong, no other error
        stat_is_bcast     : out std_logic;   -- dst-MAC = FF:FF:FF:FF:FF:FF
        stat_is_mcast     : out std_logic;   -- dst-MAC[byte0][LSB]=1 and !bcast

        -- Pulses 1 cycle at end-of-frame for a frame that passed the MAC filter
        -- but was dropped whole because the FIFO had no room for its SOF. Such a
        -- frame produces no AXIS words and no stat_done, so this is its only trace.
        stat_drop         : out std_logic
    );
end entity eth_mac_rx;

architecture rtl of eth_mac_rx is

    constant S_IDLE      : unsigned(2 downto 0) := "000";
    constant S_PREAMBLE  : unsigned(2 downto 0) := "001";
    constant S_DATA      : unsigned(2 downto 0) := "010";
    constant S_DROP      : unsigned(2 downto 0) := "011";
    constant S_CRC_CHECK : unsigned(2 downto 0) := "100";

    constant AXIS_FIFO_DEPTH : integer := 2 ** AXIS_FIFO_ADDR_WIDTH;

    -- Verilog `MCAST_HASH_FILTER && ...`: the integer parameter used as a boolean.
    constant MCAST_EN : boolean := MCAST_HASH_FILTER /= 0;

    constant MAC_BCAST : std_logic_vector(47 downto 0) := (others => '1');

    signal state      : unsigned(2 downto 0);
    signal byte_cnt   : unsigned(13 downto 0);
    signal first_byte : std_logic;

    signal crc_out        : std_logic_vector(31 downto 0);
    signal crc_init       : std_logic;
    signal crc_data_valid : std_logic;
    signal crc_data_in    : std_logic_vector(7 downto 0);

    -- Delay six bytes so the four-byte FCS is stripped and the destination
    -- address decision is known before the first output byte is queued.
    signal delay_pipe0 : std_logic_vector(7 downto 0);
    signal delay_pipe1 : std_logic_vector(7 downto 0);
    signal delay_pipe2 : std_logic_vector(7 downto 0);
    signal delay_pipe3 : std_logic_vector(7 downto 0);
    signal delay_pipe4 : std_logic_vector(7 downto 0);
    signal delay_pipe5 : std_logic_vector(7 downto 0);

    signal dst_mac_captured : std_logic_vector(47 downto 0);
    signal mac_ok           : std_logic;
    signal frame_started    : std_logic;    -- this frame's SOF word made it into the FIFO
    signal rx_er_seen       : std_logic;
    signal rx_overflow_seen : std_logic;
    signal is_bcast_r       : std_logic;
    signal is_mcast_r       : std_logic;
    signal vlan_tag         : std_logic;    -- bytes 12-13 are TPID 0x8100 or 0x88A8
    signal csum_en_r        : std_logic;    -- rx_csum_en latched at this frame's SFD

    signal mac_chk        : std_logic_vector(47 downto 0);
    signal mcast_hash_idx : std_logic_vector(5 downto 0);

    -- Combinational MAC-pass at byte_cnt=5. Gates the byte_cnt=5 SOF push
    -- directly, since mac_ok is its registered copy and lands one cycle later,
    -- after byte 0 has already shifted past delay_pipe1.
    signal mac_pass_now : std_logic;

    -- Output FIFO (BRAM, sync, FWFT). One word per byte, packed so all the
    -- metadata flags ride alongside data into a single BRAM column.
    --   bit 10: sof, bit 9: err, bit 8: last, bits 7:0: data
    signal push_en     : std_logic;
    signal push_data   : std_logic_vector(7 downto 0);
    signal push_last   : std_logic;
    signal push_err    : std_logic;
    signal push_sof    : std_logic;
    signal data_drop   : std_logic;    -- a data byte was dropped for want of FIFO room
    signal push_en_r   : std_logic;
    signal push_data_r : std_logic_vector(7 downto 0);
    signal push_last_r : std_logic;
    signal push_err_r  : std_logic;
    signal push_sof_r  : std_logic;

    signal fifo_full     : std_logic;
    signal fifo_overflow : std_logic;
    signal fifo_rd_data  : std_logic_vector(10 downto 0);
    signal fifo_rd_valid : std_logic;
    signal fifo_count    : std_logic_vector(AXIS_FIFO_ADDR_WIDTH downto 0);
    signal fifo_wr_data  : std_logic_vector(10 downto 0);

    -- Reserve a few slots above the high-water mark so a started frame's closing
    -- TLAST always finds room. A frame is only started (SOF pushed) while
    -- occupancy is below the mark; one that arrives above it is dropped whole
    -- and reported on stat_drop. A started frame that crosses the mark stops
    -- pushing DATA (dropped bytes set the overflow/terror flag) but still gets
    -- its TLAST. That keeps AXIS framing intact under backpressure - a dropped
    -- TLAST would merge this frame into the next.
    -- (Verilog: localparam [AXIS_FIFO_ADDR_WIDTH:0], i.e. truncated to that width.)
    constant FIFO_HWM : unsigned(AXIS_FIFO_ADDR_WIDTH downto 0) :=
        to_unsigned((AXIS_FIFO_DEPTH - 4) mod (2 ** (AXIS_FIFO_ADDR_WIDTH + 1)),
                    AXIS_FIFO_ADDR_WIDTH + 1);
    signal fifo_room : std_logic;

    -- Per-error breakdown: classify the four error sources individually so
    -- eth_stats can update separate counters in addition to the AXIS terror.
    signal err_fcs_now       : std_logic;
    signal err_align_now     : std_logic;
    signal err_overflow_now  : std_logic;
    signal over_std_now      : std_logic;
    signal err_oversize_now  : std_logic;
    signal err_undersize_now : std_logic;
    signal csum_bad_now      : std_logic;
    signal err_csum_now      : std_logic;

begin

    mac_chk        <= dst_mac_captured(39 downto 0) & gmii_rxd;
    mcast_hash_idx <= mac_chk(5 downto 0)   xor mac_chk(11 downto 6)  xor
                      mac_chk(17 downto 12) xor mac_chk(23 downto 18) xor
                      mac_chk(29 downto 24) xor mac_chk(35 downto 30) xor
                      mac_chk(41 downto 36) xor mac_chk(47 downto 42);

    mac_pass_now <= '1' when (mac_chk = our_mac) or
                             (mac_chk = MAC_BCAST) or
                             promisc = '1' or passthrough = '1' or
                             (MCAST_EN and
                              mac_chk(40) = '1' and
                              mac_chk /= MAC_BCAST and
                              mcast_hash_table(to_integer(unsigned(mcast_hash_idx))) = '1')
                    else '0';

    fifo_room <= '1' when unsigned(fifo_count) < FIFO_HWM else '0';

    fifo_wr_data <= push_sof_r & push_err_r & push_last_r & push_data_r;

    u_fifo : entity work.sync_fifo
        generic map (
            DATA_WIDTH => 11,
            ADDR_WIDTH => AXIS_FIFO_ADDR_WIDTH
        )
        port map (
            clk         => clk,
            rst_n       => rst_n,
            wr_data     => fifo_wr_data,
            wr_en       => push_en_r,
            wr_full     => fifo_full,
            rd_data     => fifo_rd_data,
            rd_valid    => fifo_rd_valid,
            rd_en       => m_axis_tready,
            rd_empty    => open,
            count       => fifo_count,
            wr_overflow => fifo_overflow
        );

    m_axis_tdata  <= fifo_rd_data(7 downto 0);
    m_axis_tlast  <= fifo_rd_data(8);
    m_axis_terror <= fifo_rd_data(9);
    m_axis_tsof   <= fifo_rd_data(10);
    m_axis_tvalid <= fifo_rd_valid;

    u_crc : entity work.crc32
        port map (
            clk        => clk,
            rst_n      => rst_n,
            data_in    => crc_data_in,
            data_valid => crc_data_valid,
            crc_init   => crc_init,
            crc_out    => open,
            crc_raw    => crc_out
        );

    err_fcs_now      <= '1' when crc_out /= x"DEBB20E3" else '0';
    err_align_now    <= rx_er_seen;
    err_overflow_now <= rx_overflow_seen;
    over_std_now     <= '1' when (vlan_tag = '1' and byte_cnt > MAX_FRAME_STD + 4) or
                                 (vlan_tag = '0' and byte_cnt > MAX_FRAME_STD)
                        else '0';
    err_oversize_now <= '1' when over_std_now = '1' and
                                 (jumbo_en = '0' or (byte_cnt > MAX_FRAME_JUMBO))
                        else '0';

    -- byte_cnt saturates at 16383, so a limit of 16383 or more could never be
    -- exceeded and oversize frames would pass clean. (The Verilog instantiates
    -- a module that does not exist, named after the error; VHDL asserts.)
    assert not ((MAX_FRAME_JUMBO > 16382) or (MAX_FRAME_STD + 4 > 16382))
        report "EMACZERO_CONFIG_ERROR_eth_mac_rx_frame_limit_must_be_at_most_16382"
        severity failure;

    -- Runt: a valid 802.3 frame is >= 64 wire bytes (60 data/pad + 4 FCS).
    -- byte_cnt counts bytes after the SFD, so < 64 is undersized - a collision
    -- fragment or truncated frame. Deliver it with terror instead of as a clean
    -- frame with a garbage FCS, so the consumer can discard it.
    err_undersize_now <= '1' when byte_cnt < 64 else '0';

    -- IP / L4 checksum verdict, from the GMII bytes of the frame (so it does
    -- not depend on what fit in the FIFO). csum_calc also sees the FCS, so a
    -- header or datagram counts only if it ends at least 4 bytes (the FCS)
    -- before the frame does; its results are final within 3 cycles of its last
    -- byte, so they are final here at S_CRC_CHECK. An IPv4 header is checked
    -- even when the datagram is longer than the frame; such a datagram's L4
    -- checksum is not checked.
    g_csum : if RX_CSUM_OFFLOAD /= 0 generate
        signal c_in_valid                              : std_logic;
        signal c_done, c_ip4, c_l4_ok, c_l4_udp        : std_logic;
        signal c_l3_end, c_hdr_end, c_ip_pos, c_l4_pos : std_logic_vector(13 downto 0);
        signal c_ip_sum, c_l4_sum, c_l4_field          : std_logic_vector(15 downto 0);
        signal hdr_whole, whole, udp_zero              : std_logic;
        signal ip_bad, l4_bad                          : std_logic;
    begin
        c_in_valid <= '1' when state = S_DATA and gmii_rx_dv = '1' else '0';

        u_csum : entity work.csum_calc
            port map (
                clk         => clk,
                rst_n       => rst_n,
                in_valid    => c_in_valid,
                in_idx      => std_logic_vector(byte_cnt),
                in_data     => gmii_rxd,
                zero_fields => '0',
                done        => c_done,
                l3_end      => c_l3_end,
                ip4         => c_ip4,
                ip_sum      => c_ip_sum,
                hdr_end     => c_hdr_end,
                ip_csum_pos => c_ip_pos,
                l4_ok       => c_l4_ok,
                l4_udp      => c_l4_udp,
                l4_sum      => c_l4_sum,
                l4_csum_pos => c_l4_pos,
                l4_field    => c_l4_field
            );

        -- Summed with the received checksum in place, a correct datagram
        -- sums to 0xFFFF. A UDP checksum of 0 means "none" over IPv4 and
        -- is invalid over IPv6 (RFC 8200 8.1), whatever the sum.
        hdr_whole <= '1' when resize(unsigned(c_hdr_end), 15) + 4 <= resize(byte_cnt, 15) else '0';
        whole     <= '1' when resize(unsigned(c_l3_end), 15) + 4 <= resize(byte_cnt, 15) else '0';
        udp_zero  <= '1' when c_l4_udp = '1' and c_l4_field = x"0000" else '0';
        ip_bad    <= '1' when c_ip4 = '1' and hdr_whole = '1' and c_ip_sum /= x"FFFF" else '0';
        l4_bad    <= '1' when c_done = '1' and whole = '1' and c_l4_ok = '1' and
                              ((udp_zero = '1' and c_ip4 = '0') or
                               (udp_zero = '0' and c_l4_sum /= x"FFFF"))
                     else '0';
        csum_bad_now <= csum_en_r and (ip_bad or l4_bad);
    end generate g_csum;

    g_no_csum : if RX_CSUM_OFFLOAD = 0 generate
    begin
        csum_bad_now <= '0';
    end generate g_no_csum;

    -- Counted as a checksum error only when the frame is otherwise sound, so
    -- a frame with a bad FCS (whose checksums are usually wrong too) is not
    -- counted twice.
    err_csum_now <= csum_bad_now and (not err_fcs_now) and (not err_align_now) and
                    (not err_overflow_now) and (not err_oversize_now) and
                    (not err_undersize_now);

    -- Combinational push request from the receive FSM. This is registered
    -- before sync_fifo so MAC filtering does not directly drive the FIFO CE
    -- fanout in the same 100 MHz cycle.
    process (state, gmii_rx_dv, byte_cnt, mac_pass_now, fifo_room, delay_pipe1,
             mac_ok, frame_started, err_fcs_now, err_align_now, err_overflow_now,
             err_oversize_now, err_undersize_now, csum_bad_now)
    begin
        push_en   <= '0';
        push_data <= (others => '0');
        push_last <= '0';
        push_err  <= '0';
        push_sof  <= '0';
        data_drop <= '0';
        case state is
            when S_DATA =>
                if gmii_rx_dv = '1' and byte_cnt = 5 and mac_pass_now = '1' then
                    -- SOF: start the frame only if it can be buffered. If not,
                    -- frame_started stays 0 and the whole frame is cleanly
                    -- dropped (no partial, so the sink's delimiting is unharmed).
                    if fifo_room = '1' then
                        push_en   <= '1';
                        push_data <= delay_pipe1;
                        push_sof  <= '1';
                    end if;
                elsif gmii_rx_dv = '1' and byte_cnt >= 6 and
                      mac_ok = '1' and frame_started = '1' then
                    -- Data byte: push while there is headroom; otherwise drop it
                    -- and flag overflow so the frame is terror'd (its reserved
                    -- SOF/TLAST still bound it correctly).
                    if fifo_room = '1' then
                        push_en   <= '1';
                        push_data <= delay_pipe1;
                    else
                        data_drop <= '1';
                    end if;
                end if;
            when S_CRC_CHECK =>
                -- Always emit the closing word for a started frame - the reserved
                -- headroom guarantees room, so the frame is always terminated.
                if byte_cnt >= 6 and mac_ok = '1' and frame_started = '1' then
                    push_en   <= '1';
                    push_data <= delay_pipe1;
                    push_last <= '1';
                    push_err  <= err_fcs_now or err_align_now or
                                 err_overflow_now or err_oversize_now or
                                 err_undersize_now or csum_bad_now;
                end if;
            when others =>
                null;
        end case;
    end process;

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            state             <= S_IDLE;
            byte_cnt          <= (others => '0');
            first_byte        <= '0';
            crc_init          <= '0';
            crc_data_valid    <= '0';
            crc_data_in       <= (others => '0');
            delay_pipe0       <= (others => '0');
            delay_pipe1       <= (others => '0');
            delay_pipe2       <= (others => '0');
            delay_pipe3       <= (others => '0');
            delay_pipe4       <= (others => '0');
            delay_pipe5       <= (others => '0');
            dst_mac_captured  <= (others => '0');
            mac_ok            <= '0';
            frame_started     <= '0';
            rx_er_seen        <= '0';
            rx_overflow_seen  <= '0';
            is_bcast_r        <= '0';
            is_mcast_r        <= '0';
            vlan_tag          <= '0';
            csum_en_r         <= '0';
            stat_done         <= '0';
            stat_len          <= (others => '0');
            stat_err_fcs      <= '0';
            stat_err_align    <= '0';
            stat_err_overflow <= '0';
            stat_err_oversize <= '0';
            stat_err_csum     <= '0';
            stat_is_bcast     <= '0';
            stat_is_mcast     <= '0';
            stat_drop         <= '0';
            push_en_r         <= '0';
            push_data_r       <= (others => '0');
            push_last_r       <= '0';
            push_err_r        <= '0';
            push_sof_r        <= '0';
        elsif rising_edge(clk) then
            crc_init       <= '0';
            crc_data_valid <= '0';
            stat_done      <= '0';
            stat_drop      <= '0';
            push_en_r      <= push_en;
            push_data_r    <= push_data;
            push_last_r    <= push_last;
            push_err_r     <= push_err;
            push_sof_r     <= push_sof;

            -- The frame is "started" once its SOF word is committed to the FIFO;
            -- gates data/TLAST pushes and stat_done so a frame whose SOF could not
            -- be buffered is dropped whole (no partial, no phantom stat).
            if push_sof = '1' then
                frame_started <= '1';
            end if;

            case state is
                when S_IDLE =>
                    byte_cnt         <= (others => '0');
                    first_byte       <= '0';
                    delay_pipe0      <= (others => '0');
                    delay_pipe1      <= (others => '0');
                    delay_pipe2      <= (others => '0');
                    delay_pipe3      <= (others => '0');
                    delay_pipe4      <= (others => '0');
                    delay_pipe5      <= (others => '0');
                    dst_mac_captured <= (others => '0');
                    mac_ok           <= '0';
                    frame_started    <= '0';
                    rx_er_seen       <= '0';
                    rx_overflow_seen <= '0';
                    is_bcast_r       <= '0';
                    is_mcast_r       <= '0';
                    vlan_tag         <= '0';
                    if gmii_rx_dv = '1' and gmii_rxd = x"55" then
                        state <= S_PREAMBLE;
                    end if;

                when S_PREAMBLE =>
                    -- A carrier/coding error on a preamble or SFD byte is a valid
                    -- 802.3 error indication; latch it so the frame is delivered
                    -- with terror + stat_err_align, not silently clean.
                    if gmii_rx_er = '1' then
                        rx_er_seen <= '1';
                    end if;
                    if gmii_rx_dv = '0' then
                        state <= S_IDLE;
                    elsif gmii_rxd = x"D5" then
                        state      <= S_DATA;
                        first_byte <= '1';
                        crc_init   <= '1';
                        csum_en_r  <= rx_csum_en;
                    elsif gmii_rxd /= x"55" then
                        state <= S_DROP;
                    end if;

                when S_DATA =>
                    if gmii_rx_er = '1' then
                        rx_er_seen <= '1';
                    end if;

                    if gmii_rx_dv = '0' then
                        state <= S_CRC_CHECK;
                    else
                        crc_data_valid <= '1';
                        crc_data_in    <= gmii_rxd;

                        if byte_cnt < 6 then
                            dst_mac_captured <= dst_mac_captured(39 downto 0) & gmii_rxd;
                        end if;

                        if byte_cnt = 5 then
                            mac_ok <= mac_pass_now;

                            -- Bcast / mcast classification on dst-MAC byte 0 LSB.
                            -- mac_chk[40] = first dst-MAC byte's LSB (I/G bit).
                            if mac_chk = MAC_BCAST then
                                is_bcast_r <= '1';
                            else
                                is_bcast_r <= '0';
                            end if;
                            if mac_chk(40) = '1' and mac_chk /= MAC_BCAST then
                                is_mcast_r <= '1';
                            else
                                is_mcast_r <= '0';
                            end if;
                        end if;

                        -- delay_pipe5 still holds byte 12 here.
                        if byte_cnt = 13 then
                            if (delay_pipe5 & gmii_rxd) = x"8100" or
                               (delay_pipe5 & gmii_rxd) = x"88A8" then
                                vlan_tag <= '1';
                            else
                                vlan_tag <= '0';
                            end if;
                        end if;

                        delay_pipe5 <= gmii_rxd;
                        delay_pipe4 <= delay_pipe5;
                        delay_pipe3 <= delay_pipe4;
                        delay_pipe2 <= delay_pipe3;
                        delay_pipe1 <= delay_pipe2;
                        delay_pipe0 <= delay_pipe1;

                        -- Saturate instead of wrapping. byte_cnt gates dst
                        -- capture (<6), the MAC decision (==5) and oversize
                        -- (>MAX_FRAME); a 14-bit wrap at 16384 would re-enter
                        -- byte_cnt==5 mid-frame, re-capturing the dst and firing a
                        -- second SOF. Freezing at 0x3FFF keeps oversize asserted
                        -- (>= jumbo) and cannot re-trigger those decisions.
                        if byte_cnt /= 16#3FFF# then
                            byte_cnt <= byte_cnt + 1;
                        end if;
                        if first_byte = '1' then
                            first_byte <= '0';
                        end if;
                    end if;

                when S_CRC_CHECK =>
                    state <= S_IDLE;
                    -- End-of-frame classification pulse for stats.
                    -- Only emit when MAC filter passed (i.e. frame was actually
                    -- delivered to the AXIS sink), so counts match deliveries.
                    if mac_ok = '1' and frame_started = '1' then
                        stat_done         <= '1';
                        stat_len          <= std_logic_vector(byte_cnt);
                        stat_err_fcs      <= err_fcs_now;
                        stat_err_align    <= err_align_now;
                        stat_err_overflow <= err_overflow_now;
                        stat_err_oversize <= err_oversize_now;
                        stat_err_csum     <= err_csum_now;
                        stat_is_bcast     <= is_bcast_r;
                        stat_is_mcast     <= is_mcast_r;
                    elsif mac_ok = '1' then
                        -- Passed the filter but its SOF found no FIFO room:
                        -- dropped whole. Counted whatever its FCS or length,
                        -- since the frame was never delivered to be judged.
                        stat_drop <= '1';
                    end if;

                when S_DROP =>
                    if gmii_rx_dv = '0' then
                        state <= S_IDLE;
                    end if;

                when others =>
                    state <= S_IDLE;
            end case;

            -- Sticky overflow flag: latched on a data byte dropped for want of
            -- headroom (the normal path now - SOF/TLAST are reserved), or on any
            -- raw FIFO overflow as a backstop.
            if data_drop = '1' or fifo_overflow = '1' then
                rx_overflow_seen <= '1';
            end if;
        end if;
    end process;

end architecture rtl;
