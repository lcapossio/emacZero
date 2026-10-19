-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- rgmii_if.vhd - RGMII PHY interface (vendor-agnostic), 10/100/1G capable
-- Converts between internal 8-bit GMII and 4-bit DDR RGMII.
-- VHDL port of rtl/rgmii_if.v (formally proven equivalent; see sim/parity/).
-- =============================================================================
-- Speed encoding (cfg_speed[1:0]):
--   2'b00 = 1G (full DDR: rising = TXD[3:0], falling = TXD[7:4])
--   2'b01 = 100M (TXC = 25 MHz, same nibble on both edges)
--   2'b10 = 10M  (TXC = 2.5 MHz, same nibble on both edges)
--   2'b11 = reserved (treated as 1G)
--
-- At 10/100 a byte takes two TXC/RXC cycles, low nibble first:
--   TX: gmii_txd must hold each byte for exactly 10 (100M) or 100 (10M)
--       clk_125 cycles with gmii_tx_en high for the whole frame, as gmii_cdc's
--       pacer does. The first TXC cycle of each byte sends TXD[3:0], the
--       second TXD[7:4].
--   RX: two RXC cycles are paired into one byte. gmii_rx_dv stays high for
--       the whole frame and gmii_rx_ce strobes once per assembled byte, so a
--       consumer takes a byte only when gmii_rx_dv && gmii_rx_ce. At 1G
--       gmii_rx_ce is always 1.
--
-- Clocks:
--   clk_125    - 125 MHz, 0 deg. Clocks TXD and TX_CTL at every speed.
--   clk_125_90 - 125 MHz, 90 deg, from the same source as clk_125. Clocks TXC
--                when 1G is built (RGMII_SPEEDS "ALL" or "1G_ONLY"); unused
--                for "10_100", where TXC runs on clk_125.
--   The 10/100 TXC is a pattern sent through the TXC cell, so no 25 MHz or
--   2.5 MHz clock is needed.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity rgmii_if is
    generic (
        -- Which speeds to synthesize. Logic for unused speeds is tied off so
        -- synthesis prunes it. Every value uses the same six TX and five RX DDR
        -- cells.
        --   "ALL"     = 10/100/1G (default)
        --   "1G_ONLY" = 1G only (no 10/100 phase counter)
        --   "10_100"  = 10/100 only (TXC on clk_125; clk_125_90 unused)
        RGMII_SPEEDS : string := "ALL"
    );
    port (
        clk_125      : in  std_logic;
        clk_125_90   : in  std_logic;
        rst_n        : in  std_logic;

        cfg_speed    : in  std_logic_vector(1 downto 0);   -- 00=1G, 01=100M, 10=10M

        -- --- RGMII pins ---
        rgmii_txd    : out std_logic_vector(3 downto 0);
        rgmii_tx_ctl : out std_logic;
        rgmii_txc    : out std_logic;
        rgmii_rxd    : in  std_logic_vector(3 downto 0);
        rgmii_rx_ctl : in  std_logic;
        rgmii_rxc    : in  std_logic;

        -- --- Internal GMII (8-bit, single-edge) ---
        gmii_txd     : in  std_logic_vector(7 downto 0);
        gmii_tx_en   : in  std_logic;
        gmii_tx_er   : in  std_logic;
        gmii_rxd     : out std_logic_vector(7 downto 0);
        gmii_rx_dv   : out std_logic;     -- frame envelope
        gmii_rx_er   : out std_logic;
        gmii_rx_ce   : out std_logic      -- byte strobe (1 at 1G)
    );
end entity rgmii_if;

architecture rtl of rgmii_if is

    -- =========================================================================
    -- Speed decode (with parameter-based pruning)
    -- =========================================================================
    constant SUPPORT_1G  : boolean := (RGMII_SPEEDS = "ALL") or (RGMII_SPEEDS = "1G_ONLY");
    constant SUPPORT_100 : boolean := (RGMII_SPEEDS = "ALL") or (RGMII_SPEEDS = "10_100");
    constant SUPPORT_10  : boolean := (RGMII_SPEEDS = "ALL") or (RGMII_SPEEDS = "10_100");

    -- TX and RX each take a synchronized copy of cfg_speed in their own clock
    -- domains (below).

    constant SUPPORT_SLOW : boolean := SUPPORT_100 or SUPPORT_10;

    function to_sl(b : boolean) return std_logic is
    begin
        if b then
            return '1';
        else
            return '0';
        end if;
    end function to_sl;

    -- TX path
    signal clk_txc : std_logic;

    signal spd_s1, spd_s2 : std_logic_vector(1 downto 0);
    signal spd_s3         : std_logic_vector(1 downto 0);
    signal spd_run        : unsigned(1 downto 0);   -- further cycles spd_s3 == spd_s2, saturating at 3
    signal spd_ok         : std_logic;

    signal tx_rst_n_s1, tx_rst_n_s2 : std_logic;

    signal tx_spd    : std_logic_vector(1 downto 0);
    signal tx_live   : std_logic;
    signal is_1g_tx  : std_logic;
    signal is_100_tx : std_logic;

    signal last_ph  : unsigned(5 downto 0);   -- N - 1
    signal txc_rise : unsigned(6 downto 0);   -- first high slot
    signal txc_fall : unsigned(6 downto 0);   -- first low slot after it

    signal tx_ph   : unsigned(5 downto 0);
    signal tx_s1   : unsigned(6 downto 0);    -- slot sent by d1
    signal tx_s2   : unsigned(6 downto 0);    -- slot sent by d2
    signal tx_wrap : std_logic;

    signal txc_d1, txc_d2 : std_logic;

    signal spd_d     : std_logic_vector(1 downto 0);
    signal is_1g_d   : std_logic;
    signal is_100_d  : std_logic;
    signal last_ph_d : unsigned(5 downto 0);  -- N - 1
    signal tx_n      : unsigned(6 downto 0);  -- N

    signal tx_nib, txd_slow         : std_logic_vector(3 downto 0);
    signal tx_hi, tx_en_q, tx_er_q  : std_logic;
    signal txctl_slow1, txctl_slow2 : std_logic;

    signal txd_d1, txd_d2     : std_logic_vector(3 downto 0);
    signal txctl_d1, txctl_d2 : std_logic;

    -- RX path
    signal rxd_rising     : std_logic_vector(3 downto 0);
    signal rxd_falling    : std_logic_vector(3 downto 0);
    signal rx_ctl_rising  : std_logic;
    signal rx_ctl_falling : std_logic;

    signal rx_rst_n_s1, rx_rst_n_s2 : std_logic;
    signal spd_rx_s1, spd_rx_s2     : std_logic_vector(1 downto 0);
    signal rx_is_1g                 : std_logic;

    signal nibble_lo     : std_logic_vector(3 downto 0);
    signal have_lo       : std_logic;
    signal rxd_lo_pair   : std_logic_vector(7 downto 0);
    signal rx_dv_lo_pair : std_logic;
    signal rx_er_lo_pair : std_logic;
    signal rx_frame_lo   : std_logic;

    attribute ASYNC_REG : string;
    attribute ASYNC_REG of spd_s1      : signal is "TRUE";
    attribute ASYNC_REG of spd_s2      : signal is "TRUE";
    attribute ASYNC_REG of tx_rst_n_s1 : signal is "TRUE";
    attribute ASYNC_REG of tx_rst_n_s2 : signal is "TRUE";
    attribute ASYNC_REG of rx_rst_n_s1 : signal is "TRUE";
    attribute ASYNC_REG of rx_rst_n_s2 : signal is "TRUE";
    attribute ASYNC_REG of spd_rx_s1   : signal is "TRUE";
    attribute ASYNC_REG of spd_rx_s2   : signal is "TRUE";

begin

    -- =========================================================================
    -- TX path
    -- =========================================================================
    -- One DDR cell per pin. An ODDR (7-series) or ODDRE1 (UltraScale+) has to
    -- drive its pad with nothing in between, so the speed select is in front
    -- of each cell's d1/d2, never behind its q. TXD and TX_CTL are clocked by
    -- clk_125 at every speed, TXC by clk_txc (clk_125_90 when 1G is built,
    -- clk_125 otherwise). A cell samples d1 and d2 on the same rising edge and
    -- drives d1 in the high half of the next cycle and d2 in the low half.
    --
    -- 1G: TXD[3:0] in the high half, TXD[7:4] in the low half; TX_CTL carries
    -- TX_EN, then TX_EN ^ TX_ER. TXC is 1/0 on the 90-degree clock, so its
    -- edges fall mid-way through each half.
    --
    -- 10/100: one TXC period is N clk_125 cycles (N = 5 at 100M, 50 at 10M),
    -- or 2N half-cycle slots. TXD and TX_CTL carry the rising-edge value in
    -- slots 0..N-1 and the falling-edge value in slots N..2N-1. TXC is high in
    -- slots N/2 .. N/2+N-1 (N/2 rounded down), so its rising edge falls inside
    -- the first group and its falling edge inside the second, each at least
    -- 8 ns from a data change at 100M (10 ns with the 90-degree clock). The
    -- nibble is the same in both groups; TX_CTL carries TX_EN, then
    -- TX_EN ^ TX_ER.
    clk_txc <= clk_125_90 when SUPPORT_1G else clk_125;

    -- cfg_speed comes from the system clock domain and is synchronized into
    -- clk_txc. A new speed is taken into tx_spd only where a TXC period ends
    -- (TXC is low there), and the counter restarts with it, so a speed change
    -- never cuts a TXC pulse short: every high and low time is that of the
    -- old or the new speed. The clk_125 side takes its own copy of tx_spd,
    -- one cycle later, so the data switches on the same boundary. The speed
    -- is only changed while the link is down.
    --
    -- The two bits are synchronized separately, so a sample taken as
    -- cfg_speed changes can mix old and new bits (01 -> 10 read as 00 or 11,
    -- i.e. 1G). A speed is taken only once spd_s2 has read the same value
    -- for 5 cycles running. With metastability settling within a cycle (the
    -- assumption behind any 2-flop synchronizer, met with the MTBF of
    -- ASYNC_REG flops), only a sample taken on a change can be mixed, so a
    -- mixed value would need cfg_speed to change on 5 consecutive clk_txc
    -- cycles; a CSR written by software does not.
    process (clk_txc, rst_n)
    begin
        if rst_n = '0' then
            spd_s3  <= "00";
            spd_s2  <= "00";
            spd_s1  <= "00";
            spd_run <= "00";
        elsif rising_edge(clk_txc) then
            spd_s3 <= spd_s2;
            spd_s2 <= spd_s1;
            spd_s1 <= cfg_speed;
            if spd_s3 /= spd_s2 then
                spd_run <= "00";
            elsif spd_run /= 3 then
                spd_run <= spd_run + 1;
            end if;
        end if;
    end process;
    spd_ok <= to_sl((spd_s3 = spd_s2) and (spd_run = 3));

    -- TX reset, synchronized to clk_txc. tx_live rises once the first speed
    -- has been taken; until then the counter and TXC are held at zero.
    process (clk_txc, rst_n)
    begin
        if rst_n = '0' then
            tx_rst_n_s2 <= '0';
            tx_rst_n_s1 <= '0';
        elsif rising_edge(clk_txc) then
            tx_rst_n_s2 <= tx_rst_n_s1;
            tx_rst_n_s1 <= '1';
        end if;
    end process;

    is_1g_tx  <= to_sl(SUPPORT_1G  and ((tx_spd = "00") or (tx_spd = "11")));
    is_100_tx <= to_sl(SUPPORT_100 and (tx_spd = "01"));

    -- Phase counter, clk_txc domain: tx_ph = 0..N-1 picks slots 2*tx_ph and
    -- 2*tx_ph+1. The clk_125 logic below reads it; with the 90-degree clock
    -- that path has 6 ns. At 1G the counter runs with N = 50, which only
    -- paces the speed changes.
    last_ph  <= to_unsigned(4, 6) when is_100_tx = '1' else to_unsigned(49, 6);   -- N - 1
    txc_rise <= to_unsigned(2, 7) when is_100_tx = '1' else to_unsigned(25, 7);   -- first high slot
    txc_fall <= to_unsigned(7, 7) when is_100_tx = '1' else to_unsigned(75, 7);   -- first low slot after it

    tx_s1 <= tx_ph & '0';                              -- slot sent by d1
    tx_s2 <= tx_ph & '1';                              -- slot sent by d2
    -- Last slot pair of a period. Without 10/100 any cycle is a boundary.
    tx_wrap <= to_sl((not SUPPORT_SLOW) or (tx_ph >= last_ph));

    process (clk_txc, tx_rst_n_s2)
    begin
        if tx_rst_n_s2 = '0' then
            tx_spd  <= "00";
            tx_live <= '0';
            tx_ph   <= (others => '0');
        elsif rising_edge(clk_txc) then
            if tx_live = '0' then
                if spd_ok = '1' then
                    tx_spd  <= spd_s2;
                    tx_live <= '1';
                end if;
                tx_ph <= (others => '0');
            elsif tx_wrap = '1' then
                if spd_ok = '1' then
                    tx_spd <= spd_s2;
                end if;
                tx_ph <= (others => '0');
            else
                tx_ph <= tx_ph + 1;
            end if;
        end if;
    end process;

    -- TXC pattern, registered on clk_txc so the TXC cell is fed by a flop on
    -- its own clock.
    process (clk_txc, tx_rst_n_s2)
    begin
        if tx_rst_n_s2 = '0' then
            txc_d1 <= '0';
            txc_d2 <= '0';
        elsif rising_edge(clk_txc) then
            if tx_live = '0' then
                txc_d1 <= '0';
                txc_d2 <= '0';
            elsif is_1g_tx = '1' then
                txc_d1 <= '1';
                txc_d2 <= '0';
            elsif SUPPORT_SLOW then
                txc_d1 <= to_sl((tx_s1 >= txc_rise) and (tx_s1 < txc_fall));
                txc_d2 <= to_sl((tx_s2 >= txc_rise) and (tx_s2 < txc_fall));
            else
                txc_d1 <= '0';
                txc_d2 <= '0';
            end if;
        end if;
    end process;

    -- clk_125 copy of tx_spd, so the selects in front of the TXD / TX_CTL
    -- cells are timed within clk_125, not from clk_125_90. It lags tx_spd by
    -- one cycle, in which tx_ph is 0 after a change. Between 100M and 10M
    -- that changes nothing: both send TX_EN in slots 0/1 and neither loads
    -- at tx_ph 0. Between 1G and 10/100 the TXD / TX_CTL cells take one more
    -- cycle from the old source, while the line is idle.
    process (clk_125)
    begin
        if rising_edge(clk_125) then
            spd_d <= tx_spd;
        end if;
    end process;
    is_1g_d   <= to_sl(SUPPORT_1G  and ((spd_d = "00") or (spd_d = "11")));
    is_100_d  <= to_sl(SUPPORT_100 and (spd_d = "01"));
    last_ph_d <= to_unsigned(4, 6) when is_100_d = '1' else to_unsigned(49, 6);   -- N - 1
    tx_n      <= to_unsigned(5, 7) when is_100_d = '1' else to_unsigned(50, 7);   -- N

    -- 10/100 data, clk_125 domain. A new nibble, TX_EN and TX_ER are taken
    -- once per TXC period, on the cycle that registers its last slot pair, so
    -- the slot registers use them for the whole next period. tx_hi selects
    -- the high nibble in the second period of each byte. It needs no reset:
    -- it clears on the first period with gmii_tx_en low, and gmii_tx_en is
    -- low whenever the MAC is idle.
    process (clk_125)
    begin
        if rising_edge(clk_125) then
            txd_slow <= tx_nib;
            if tx_s1 < tx_n then
                txctl_slow1 <= tx_en_q;
            else
                txctl_slow1 <= tx_en_q xor tx_er_q;
            end if;
            if tx_s2 < tx_n then
                txctl_slow2 <= tx_en_q;
            else
                txctl_slow2 <= tx_en_q xor tx_er_q;
            end if;
            if tx_ph = last_ph_d then
                tx_hi <= gmii_tx_en and (not tx_hi);
                if tx_hi = '1' then
                    tx_nib <= gmii_txd(7 downto 4);
                else
                    tx_nib <= gmii_txd(3 downto 0);
                end if;
                tx_en_q <= gmii_tx_en;
                tx_er_q <= gmii_tx_er;
            end if;
        end if;
    end process;

    -- Speed select in front of the cells. At 1G the cells take gmii_txd,
    -- gmii_tx_en and gmii_tx_er directly.
    txd_d1   <= gmii_txd(3 downto 0)       when is_1g_d = '1'
                else txd_slow              when SUPPORT_SLOW
                else "0000";
    txd_d2   <= gmii_txd(7 downto 4)       when is_1g_d = '1'
                else txd_slow              when SUPPORT_SLOW
                else "0000";
    txctl_d1 <= gmii_tx_en                 when is_1g_d = '1'
                else txctl_slow1           when SUPPORT_SLOW
                else '0';
    txctl_d2 <= (gmii_tx_en xor gmii_tx_er) when is_1g_d = '1'
                else txctl_slow2           when SUPPORT_SLOW
                else '0';

    gen_txd : for i_tx in 0 to 3 generate
        u_txd : entity work.ddr_output
            port map (
                clk => clk_125,
                d1  => txd_d1(i_tx),
                d2  => txd_d2(i_tx),
                q   => rgmii_txd(i_tx)
            );
    end generate gen_txd;

    u_tx_ctl : entity work.ddr_output
        port map (clk => clk_125, d1 => txctl_d1, d2 => txctl_d2,
                  q => rgmii_tx_ctl);
    u_txc    : entity work.ddr_output
        port map (clk => clk_txc, d1 => txc_d1,   d2 => txc_d2,
                  q => rgmii_txc);

    -- =========================================================================
    -- RX path
    -- =========================================================================
    gen_rx_data : for i_rx in 0 to 3 generate
        u_rxd : entity work.ddr_input
            port map (
                clk => rgmii_rxc,
                d   => rgmii_rxd(i_rx),
                q1  => rxd_rising(i_rx),
                q2  => rxd_falling(i_rx)
            );
    end generate gen_rx_data;

    u_rx_ctl : entity work.ddr_input
        port map (
            clk => rgmii_rxc,
            d   => rgmii_rx_ctl,
            q1  => rx_ctl_rising,
            q2  => rx_ctl_falling
        );

    -- =========================================================================
    -- 10/100 nibble pairing (only used when !rx_is_1g)
    -- =========================================================================
    -- Synchronize the system reset into the RGMII RX clock domain. rst_n is
    -- asynchronous to rgmii_rxc (a PHY-sourced clock); using it directly risks
    -- metastable reset release of the pairing state. Async assert, 2-FF sync
    -- deassert, matching the gmii_cdc / mii_if reset-synchronizer style.
    process (rgmii_rxc, rst_n)
    begin
        if rst_n = '0' then
            rx_rst_n_s2 <= '0';
            rx_rst_n_s1 <= '0';
        elsif rising_edge(rgmii_rxc) then
            rx_rst_n_s2 <= rx_rst_n_s1;
            rx_rst_n_s1 <= '1';
        end if;
    end process;

    -- cfg_speed synchronized into rgmii_rxc, which drives the pairing below
    -- and the output select, and is the clock gmii_cdc takes the outputs on.
    -- RX follows a speed change only while RXC runs; the speed is only
    -- changed while the link is down, and a frame cannot arrive before RXC
    -- has run for many cycles.
    process (rgmii_rxc, rst_n)
    begin
        if rst_n = '0' then
            spd_rx_s2 <= "00";
            spd_rx_s1 <= "00";
        elsif rising_edge(rgmii_rxc) then
            spd_rx_s2 <= spd_rx_s1;
            spd_rx_s1 <= cfg_speed;
        end if;
    end process;
    rx_is_1g <= to_sl(SUPPORT_1G and ((spd_rx_s2 = "00") or (spd_rx_s2 = "11")));

    -- rx_dv_lo_pair strobes once per assembled byte; rx_frame_lo is RX_DV
    -- delayed one cycle, so it rises before the first strobe and falls after
    -- the last one, giving the consumer an unbroken frame envelope.
    process (rgmii_rxc, rx_rst_n_s2)
    begin
        if rx_rst_n_s2 = '0' then
            nibble_lo     <= (others => '0');
            have_lo       <= '0';
            rxd_lo_pair   <= (others => '0');
            rx_dv_lo_pair <= '0';
            rx_er_lo_pair <= '0';
            rx_frame_lo   <= '0';
        elsif rising_edge(rgmii_rxc) then
            if rx_is_1g = '0' then
                rx_dv_lo_pair <= '0';
                rx_frame_lo   <= rx_ctl_rising;
                if rx_ctl_rising = '1' then
                    if have_lo = '0' then
                        nibble_lo <= rxd_rising;
                        have_lo   <= '1';
                    else
                        rxd_lo_pair   <= rxd_rising & nibble_lo;
                        rx_dv_lo_pair <= '1';
                        rx_er_lo_pair <= rx_ctl_rising xor rx_ctl_falling;
                        have_lo       <= '0';
                    end if;
                else
                    have_lo <= '0';
                end if;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- Output: at 1G use direct DDR pair; at 10/100 use the paired latch.
    -- The 1G path matches the original byte-for-byte.
    -- =========================================================================
    gmii_rxd   <= (rxd_falling & rxd_rising)          when rx_is_1g = '1' else rxd_lo_pair;
    gmii_rx_dv <= rx_ctl_rising                       when rx_is_1g = '1' else rx_frame_lo;
    gmii_rx_er <= (rx_ctl_rising xor rx_ctl_falling)  when rx_is_1g = '1' else rx_er_lo_pair;
    gmii_rx_ce <= '1'                                 when rx_is_1g = '1' else rx_dv_lo_pair;

end architecture rtl;
