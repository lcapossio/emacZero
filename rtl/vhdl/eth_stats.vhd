-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- eth_stats.vhd - Ethernet MAC statistics counters
-- 32-bit saturating counters for TX/RX frame, byte, and error counts plus the
-- detailed RX breakdown (size buckets, error type, bcast/mcast).
-- All inputs and outputs are in the system clock domain.
-- VHDL port of rtl/eth_stats.v (formally proven equivalent; see sim/parity/).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity eth_stats is
    generic (
        -- Counter width. 32 bits suits line-rate byte/frame/size-bucket counters:
        -- a narrower counter would saturate in well under a second at line rate.
        -- Lower only for resource-constrained builds that do not need the full
        -- range; the eth_mac_sys CSR readback wiring assumes 32-bit and must be
        -- narrowed to match if this is reduced.
        STAT_CNT_W : integer := 32
    );
    port (
        clk                   : in  std_logic;
        rst_n                 : in  std_logic;

        -- ---- GMII observation (sys_clk domain) ----
        gmii_tx_en            : in  std_logic;    -- high while TX byte on wire
        gmii_rx_dv            : in  std_logic;    -- high while RX byte on wire

        -- ---- Frame completion pulses (single-cycle, sys_clk domain) ----
        tx_frame_done         : in  std_logic;    -- falling edge of gmii_tx_en
        rx_frame_good         : in  std_logic;    -- TLAST handshake (tvalid && tready) && !terror
        rx_frame_bad          : in  std_logic;    -- TLAST handshake (tvalid && tready) && terror

        -- ---- RX classification bus (single-cycle, end-of-frame) ----
        rx_stat_done          : in  std_logic;    -- pulses when a delivered frame ends
        rx_stat_len           : in  std_logic_vector(13 downto 0);  -- total wire bytes (incl FCS)
        rx_stat_err_fcs       : in  std_logic;
        rx_stat_err_align     : in  std_logic;
        rx_stat_err_overflow  : in  std_logic;
        rx_stat_err_oversize  : in  std_logic;
        rx_stat_err_csum      : in  std_logic;
        rx_stat_is_bcast      : in  std_logic;
        rx_stat_is_mcast      : in  std_logic;
        rx_stat_drop          : in  std_logic;    -- pulses when a frame is dropped whole

        -- ---- Counter outputs ----
        tx_frame_cnt          : out std_logic_vector(STAT_CNT_W-1 downto 0);
        tx_byte_cnt           : out std_logic_vector(STAT_CNT_W-1 downto 0);
        rx_frame_cnt          : out std_logic_vector(STAT_CNT_W-1 downto 0);
        rx_byte_cnt           : out std_logic_vector(STAT_CNT_W-1 downto 0);
        rx_crc_err_cnt        : out std_logic_vector(STAT_CNT_W-1 downto 0);  -- legacy alias = rx_err_fcs_cnt

        -- RX error breakdown
        rx_err_align_cnt      : out std_logic_vector(STAT_CNT_W-1 downto 0);
        rx_err_overflow_cnt   : out std_logic_vector(STAT_CNT_W-1 downto 0);
        rx_err_oversize_cnt   : out std_logic_vector(STAT_CNT_W-1 downto 0);
        rx_err_csum_cnt       : out std_logic_vector(STAT_CNT_W-1 downto 0);  -- wrong IP / L4 checksum

        -- RX bcast/mcast
        rx_bcast_cnt          : out std_logic_vector(STAT_CNT_W-1 downto 0);
        rx_mcast_cnt          : out std_logic_vector(STAT_CNT_W-1 downto 0);

        -- RX size buckets (by total wire bytes incl. FCS)
        rx_size_64_cnt        : out std_logic_vector(STAT_CNT_W-1 downto 0);  -- ==64
        rx_size_65_127_cnt    : out std_logic_vector(STAT_CNT_W-1 downto 0);
        rx_size_128_255_cnt   : out std_logic_vector(STAT_CNT_W-1 downto 0);
        rx_size_256_511_cnt   : out std_logic_vector(STAT_CNT_W-1 downto 0);
        rx_size_512_1023_cnt  : out std_logic_vector(STAT_CNT_W-1 downto 0);
        rx_size_1024_1518_cnt : out std_logic_vector(STAT_CNT_W-1 downto 0);
        rx_size_jumbo_cnt     : out std_logic_vector(STAT_CNT_W-1 downto 0);  -- >1518

        -- RX frames dropped whole (no FIFO room at SOF; never delivered)
        rx_drop_cnt           : out std_logic_vector(STAT_CNT_W-1 downto 0);

        -- ---- Clear (active-high pulse) ----
        clr_tx                : in  std_logic;
        clr_rx                : in  std_logic
    );
end entity eth_stats;

architecture rtl of eth_stats is

    subtype cnt_t is unsigned(STAT_CNT_W-1 downto 0);
    constant CNT_ZERO : cnt_t := (others => '0');

    -- Saturating increment: returns current value + 1, or holds at all-ones.
    -- The all-ones detect (&cnt) replaces a full-width equality comparator and
    -- is width-agnostic, so it tracks STAT_CNT_W automatically.
    -- (Verilog: `define SAT_INC(cnt) ((&(cnt)) ? (cnt) : (cnt) + 1'b1))
    function sat_inc(cnt : unsigned) return unsigned is
    begin
        if cnt = (cnt'range => '1') then
            return cnt;
        else
            return cnt + 1;
        end if;
    end function sat_inc;

    signal tx_frame_cnt_i          : cnt_t;
    signal tx_byte_cnt_i           : cnt_t;
    signal rx_frame_cnt_i          : cnt_t;
    signal rx_byte_cnt_i           : cnt_t;
    signal rx_crc_err_cnt_i        : cnt_t;
    signal rx_err_align_cnt_i      : cnt_t;
    signal rx_err_overflow_cnt_i   : cnt_t;
    signal rx_err_oversize_cnt_i   : cnt_t;
    signal rx_err_csum_cnt_i       : cnt_t;
    signal rx_bcast_cnt_i          : cnt_t;
    signal rx_mcast_cnt_i          : cnt_t;
    signal rx_size_64_cnt_i        : cnt_t;
    signal rx_size_65_127_cnt_i    : cnt_t;
    signal rx_size_128_255_cnt_i   : cnt_t;
    signal rx_size_256_511_cnt_i   : cnt_t;
    signal rx_size_512_1023_cnt_i  : cnt_t;
    signal rx_size_1024_1518_cnt_i : cnt_t;
    signal rx_size_jumbo_cnt_i     : cnt_t;
    signal rx_drop_cnt_i           : cnt_t;

    signal bucket_64        : std_logic;
    signal bucket_65_127    : std_logic;
    signal bucket_128_255   : std_logic;
    signal bucket_256_511   : std_logic;
    signal bucket_512_1023  : std_logic;
    signal bucket_1024_1518 : std_logic;
    signal bucket_jumbo     : std_logic;

begin

    -- =====================================================================
    -- TX counters
    -- =====================================================================
    process (clk, rst_n)
    begin
        if rst_n = '0' then
            tx_frame_cnt_i <= CNT_ZERO;
            tx_byte_cnt_i  <= CNT_ZERO;
        elsif rising_edge(clk) then
            if clr_tx = '1' then
                tx_frame_cnt_i <= CNT_ZERO;
                tx_byte_cnt_i  <= CNT_ZERO;
            else
                if tx_frame_done = '1' then
                    tx_frame_cnt_i <= sat_inc(tx_frame_cnt_i);
                end if;

                if gmii_tx_en = '1' then
                    tx_byte_cnt_i <= sat_inc(tx_byte_cnt_i);
                end if;
            end if;
        end if;
    end process;

    -- =====================================================================
    -- RX counters - basic
    -- =====================================================================
    process (clk, rst_n)
    begin
        if rst_n = '0' then
            rx_frame_cnt_i   <= CNT_ZERO;
            rx_byte_cnt_i    <= CNT_ZERO;
            rx_crc_err_cnt_i <= CNT_ZERO;
        elsif rising_edge(clk) then
            if clr_rx = '1' then
                rx_frame_cnt_i   <= CNT_ZERO;
                rx_byte_cnt_i    <= CNT_ZERO;
                rx_crc_err_cnt_i <= CNT_ZERO;
            else
                if (rx_frame_good or rx_frame_bad) = '1' then
                    rx_frame_cnt_i <= sat_inc(rx_frame_cnt_i);
                end if;

                if gmii_rx_dv = '1' then
                    rx_byte_cnt_i <= sat_inc(rx_byte_cnt_i);
                end if;

                if rx_frame_bad = '1' then
                    rx_crc_err_cnt_i <= sat_inc(rx_crc_err_cnt_i);
                end if;
            end if;
        end if;
    end process;

    -- =====================================================================
    -- RX counters - error breakdown + bcast/mcast + size buckets
    -- Driven from end-of-frame classification pulse.
    -- =====================================================================
    bucket_64        <= '1' when unsigned(rx_stat_len) = 64 else '0';
    bucket_65_127    <= '1' when unsigned(rx_stat_len) > 64   and unsigned(rx_stat_len) <= 127  else '0';
    bucket_128_255   <= '1' when unsigned(rx_stat_len) > 127  and unsigned(rx_stat_len) <= 255  else '0';
    bucket_256_511   <= '1' when unsigned(rx_stat_len) > 255  and unsigned(rx_stat_len) <= 511  else '0';
    bucket_512_1023  <= '1' when unsigned(rx_stat_len) > 511  and unsigned(rx_stat_len) <= 1023 else '0';
    bucket_1024_1518 <= '1' when unsigned(rx_stat_len) > 1023 and unsigned(rx_stat_len) <= 1518 else '0';
    bucket_jumbo     <= '1' when unsigned(rx_stat_len) > 1518 else '0';

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            rx_err_align_cnt_i      <= CNT_ZERO;
            rx_err_overflow_cnt_i   <= CNT_ZERO;
            rx_err_oversize_cnt_i   <= CNT_ZERO;
            rx_err_csum_cnt_i       <= CNT_ZERO;
            rx_bcast_cnt_i          <= CNT_ZERO;
            rx_mcast_cnt_i          <= CNT_ZERO;
            rx_size_64_cnt_i        <= CNT_ZERO;
            rx_size_65_127_cnt_i    <= CNT_ZERO;
            rx_size_128_255_cnt_i   <= CNT_ZERO;
            rx_size_256_511_cnt_i   <= CNT_ZERO;
            rx_size_512_1023_cnt_i  <= CNT_ZERO;
            rx_size_1024_1518_cnt_i <= CNT_ZERO;
            rx_size_jumbo_cnt_i     <= CNT_ZERO;
        elsif rising_edge(clk) then
            if clr_rx = '1' then
                rx_err_align_cnt_i      <= CNT_ZERO;
                rx_err_overflow_cnt_i   <= CNT_ZERO;
                rx_err_oversize_cnt_i   <= CNT_ZERO;
                rx_err_csum_cnt_i       <= CNT_ZERO;
                rx_bcast_cnt_i          <= CNT_ZERO;
                rx_mcast_cnt_i          <= CNT_ZERO;
                rx_size_64_cnt_i        <= CNT_ZERO;
                rx_size_65_127_cnt_i    <= CNT_ZERO;
                rx_size_128_255_cnt_i   <= CNT_ZERO;
                rx_size_256_511_cnt_i   <= CNT_ZERO;
                rx_size_512_1023_cnt_i  <= CNT_ZERO;
                rx_size_1024_1518_cnt_i <= CNT_ZERO;
                rx_size_jumbo_cnt_i     <= CNT_ZERO;
            elsif rx_stat_done = '1' then
                if rx_stat_err_align = '1'    then rx_err_align_cnt_i    <= sat_inc(rx_err_align_cnt_i);    end if;
                if rx_stat_err_overflow = '1' then rx_err_overflow_cnt_i <= sat_inc(rx_err_overflow_cnt_i); end if;
                if rx_stat_err_oversize = '1' then rx_err_oversize_cnt_i <= sat_inc(rx_err_oversize_cnt_i); end if;
                if rx_stat_err_csum = '1'     then rx_err_csum_cnt_i     <= sat_inc(rx_err_csum_cnt_i);     end if;
                if rx_stat_is_bcast = '1'     then rx_bcast_cnt_i        <= sat_inc(rx_bcast_cnt_i);        end if;
                if rx_stat_is_mcast = '1'     then rx_mcast_cnt_i        <= sat_inc(rx_mcast_cnt_i);        end if;

                if bucket_64 = '1'        then rx_size_64_cnt_i        <= sat_inc(rx_size_64_cnt_i);        end if;
                if bucket_65_127 = '1'    then rx_size_65_127_cnt_i    <= sat_inc(rx_size_65_127_cnt_i);    end if;
                if bucket_128_255 = '1'   then rx_size_128_255_cnt_i   <= sat_inc(rx_size_128_255_cnt_i);   end if;
                if bucket_256_511 = '1'   then rx_size_256_511_cnt_i   <= sat_inc(rx_size_256_511_cnt_i);   end if;
                if bucket_512_1023 = '1'  then rx_size_512_1023_cnt_i  <= sat_inc(rx_size_512_1023_cnt_i);  end if;
                if bucket_1024_1518 = '1' then rx_size_1024_1518_cnt_i <= sat_inc(rx_size_1024_1518_cnt_i); end if;
                if bucket_jumbo = '1'     then rx_size_jumbo_cnt_i     <= sat_inc(rx_size_jumbo_cnt_i);     end if;
            end if;
        end if;
    end process;

    -- =====================================================================
    -- RX whole-frame drops. Separate from the stat_done-driven breakdown:
    -- a dropped frame never produces stat_done, so it is in none of the
    -- counters above.
    -- =====================================================================
    process (clk, rst_n)
    begin
        if rst_n = '0' then
            rx_drop_cnt_i <= CNT_ZERO;
        elsif rising_edge(clk) then
            if clr_rx = '1' then
                rx_drop_cnt_i <= CNT_ZERO;
            elsif rx_stat_drop = '1' then
                rx_drop_cnt_i <= sat_inc(rx_drop_cnt_i);
            end if;
        end if;
    end process;

    tx_frame_cnt          <= std_logic_vector(tx_frame_cnt_i);
    tx_byte_cnt           <= std_logic_vector(tx_byte_cnt_i);
    rx_frame_cnt          <= std_logic_vector(rx_frame_cnt_i);
    rx_byte_cnt           <= std_logic_vector(rx_byte_cnt_i);
    rx_crc_err_cnt        <= std_logic_vector(rx_crc_err_cnt_i);
    rx_err_align_cnt      <= std_logic_vector(rx_err_align_cnt_i);
    rx_err_overflow_cnt   <= std_logic_vector(rx_err_overflow_cnt_i);
    rx_err_oversize_cnt   <= std_logic_vector(rx_err_oversize_cnt_i);
    rx_err_csum_cnt       <= std_logic_vector(rx_err_csum_cnt_i);
    rx_bcast_cnt          <= std_logic_vector(rx_bcast_cnt_i);
    rx_mcast_cnt          <= std_logic_vector(rx_mcast_cnt_i);
    rx_size_64_cnt        <= std_logic_vector(rx_size_64_cnt_i);
    rx_size_65_127_cnt    <= std_logic_vector(rx_size_65_127_cnt_i);
    rx_size_128_255_cnt   <= std_logic_vector(rx_size_128_255_cnt_i);
    rx_size_256_511_cnt   <= std_logic_vector(rx_size_256_511_cnt_i);
    rx_size_512_1023_cnt  <= std_logic_vector(rx_size_512_1023_cnt_i);
    rx_size_1024_1518_cnt <= std_logic_vector(rx_size_1024_1518_cnt_i);
    rx_size_jumbo_cnt     <= std_logic_vector(rx_size_jumbo_cnt_i);
    rx_drop_cnt           <= std_logic_vector(rx_drop_cnt_i);

end architecture rtl;
