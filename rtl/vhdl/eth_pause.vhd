-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- eth_pause.vhd - 802.3x PAUSE flow control
-- VHDL port of rtl/eth_pause.v (formally proven equivalent; see sim/parity/).
--
-- Two cooperating units:
--
--   * RX: eth_pause_rx (instantiated next to the PHY interface, in the PHY
--                receive clock domain, ahead of the RX FIFO) recognizes PAUSE
--                frames (dst=01:80:C2:00:00:01, EtherType=0x8808,
--                opcode=0x0001) and flips rx_pause_tgl for each valid one:
--                good FCS, no rx_er after the SFD, and at least 64 bytes. Here
--                each flip counts, and its 16-bit quanta is loaded into
--                pause_remaining, which decrements at one tick per "pause
--                quantum" of the current line rate. While pause_remaining != 0,
--                tx_paused is asserted to hold data frames that have not yet
--                started on the medium. A quanta of 0 cancels the pause
--                immediately.
--
--   * TX generator: when cfg_pause_tx_send pulses, enqueues a single 60-byte
--                   MAC-Control PAUSE frame on its own AXIS-byte master. The
--                   wrapper sends it on a control path that is not held by
--                   tx_paused and goes out ahead of queued user frames.
--
-- Pause-quantum tick period, in clk cycles (defaults are for clk = 100 MHz;
-- eth_mac_sys derives them from its CLK_FREQ_HZ):
--     1G   : 512 bit-times = 512 ns       =   52 clk cycles (rounded up)
--     100M :                = 5.12 us     =  512 cycles
--     10M  :                = 51.2 us     = 5120 cycles
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity eth_pause is
    generic (
        -- Verilog `parameter [15:0]`: only the low 16 bits are used.
        TICK_DIV_1G   : integer := 52;
        TICK_DIV_100M : integer := 512;
        TICK_DIV_10M  : integer := 5120
    );
    port (
        clk                 : in  std_logic;
        rst_n               : in  std_logic;

        -- ---- Configuration / control ----
        our_mac             : in  std_logic_vector(47 downto 0);
        cfg_speed           : in  std_logic_vector(1 downto 0);   -- 00=1G, 01=100M, 10=10M
        cfg_pause_rx_en     : in  std_logic;                      -- honor incoming PAUSE
        cfg_pause_tx_send   : in  std_logic;                      -- 1-cycle pulse: emit a PAUSE frame
        cfg_pause_tx_quanta : in  std_logic_vector(15 downto 0);  -- quanta value to send

        -- ---- From eth_pause_rx, in the PHY receive clock domain (asynchronous) ----
        rx_pause_tgl        : in  std_logic;                      -- flips once per valid PAUSE frame
        rx_pause_quanta     : in  std_logic_vector(15 downto 0);  -- its pause_time; stable between flips

        -- ---- TX gate to eth_mac_tx ----
        tx_paused           : out std_logic;                      -- 1 = block new frame starts

        -- ---- AXIS-byte master output (PAUSE frame source) ----
        pause_tdata         : out std_logic_vector(7 downto 0);
        pause_tvalid        : out std_logic;
        pause_tready        : in  std_logic;
        pause_tlast         : out std_logic;

        -- ---- Status counters (32-bit saturating) ----
        stat_clr            : in  std_logic;                      -- 1-cycle pulse: clear both counters
        pause_rx_cnt        : out std_logic_vector(31 downto 0);
        pause_tx_cnt        : out std_logic_vector(31 downto 0)
    );
end entity eth_pause;

architecture rtl of eth_pause is

    -- Vivado attribute (same name and value as the Verilog).
    attribute ASYNC_REG : string;

    -- ============================================================
    -- RX PAUSE events from eth_pause_rx
    -- ============================================================
    signal prx_tgl_s1, prx_tgl_s2 : std_logic;
    attribute ASYNC_REG of prx_tgl_s1 : signal is "TRUE";
    attribute ASYNC_REG of prx_tgl_s2 : signal is "TRUE";
    signal prx_tgl_s3 : std_logic;
    signal prx_evt    : std_logic;
    signal pause_load : std_logic;

    -- ============================================================
    -- Pause-quantum tick prescaler (speed-dependent)
    -- ============================================================
    constant TICK_DIV_1G_U   : unsigned(15 downto 0) := to_unsigned(TICK_DIV_1G   mod 65536, 16);
    constant TICK_DIV_100M_U : unsigned(15 downto 0) := to_unsigned(TICK_DIV_100M mod 65536, 16);
    constant TICK_DIV_10M_U  : unsigned(15 downto 0) := to_unsigned(TICK_DIV_10M  mod 65536, 16);

    signal tick_cnt   : unsigned(15 downto 0);
    signal tick_div   : unsigned(15 downto 0);
    signal pause_tick : std_logic;

    -- ============================================================
    -- Pause timer and PAUSE_RX counter
    -- ============================================================
    signal pause_remaining : unsigned(15 downto 0);
    signal pause_rx_cnt_i  : unsigned(31 downto 0);

    -- (our_mac is consumed by the TX generator below; tag the snoop input as
    --  used so lint stays clean even when the parser only verifies the dst.)
    -- Verilog name `_unused_our_mac`; a VHDL identifier cannot start with '_'.
    signal unused_our_mac : std_logic;

    -- ============================================================
    -- TX generator
    -- ============================================================
    signal tx_idx        : unsigned(5 downto 0);   -- 0..59
    signal tx_quanta_lat : std_logic_vector(15 downto 0);
    signal tx_src_lat    : std_logic_vector(47 downto 0);

    constant TX_IDLE : std_logic_vector(1 downto 0) := "00";  -- 2'd0
    constant TX_RUN  : std_logic_vector(1 downto 0) := "01";  -- 2'd1
    constant TX_DONE : std_logic_vector(1 downto 0) := "10";  -- 2'd2

    signal tx_state       : std_logic_vector(1 downto 0);
    signal pause_tx_cnt_i : unsigned(31 downto 0);

begin

    -- ============================================================
    -- RX PAUSE events from eth_pause_rx
    -- ============================================================
    -- Toggle synchronizer into clk. rx_pause_quanta settles at least 46 byte
    -- times before its toggle and holds for at least 24 byte times after it
    -- (see eth_pause_rx), so it is sampled directly on the cycle the toggle
    -- edge is seen here.
    process (clk, rst_n)
    begin
        if rst_n = '0' then
            prx_tgl_s1 <= '0';
            prx_tgl_s2 <= '0';
            prx_tgl_s3 <= '0';
        elsif rising_edge(clk) then
            prx_tgl_s1 <= rx_pause_tgl;
            prx_tgl_s2 <= prx_tgl_s1;
            prx_tgl_s3 <= prx_tgl_s2;
        end if;
    end process;

    prx_evt    <= prx_tgl_s2 xor prx_tgl_s3;
    pause_load <= prx_evt and cfg_pause_rx_en;

    -- ============================================================
    -- Pause-quantum tick prescaler (speed-dependent). It restarts when a
    -- PAUSE frame loads the timer, so N quanta always last N full quanta.
    -- ============================================================
    tick_div <= TICK_DIV_1G_U   when cfg_speed = "00" else
                TICK_DIV_100M_U when cfg_speed = "01" else
                TICK_DIV_10M_U;

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            tick_cnt   <= (others => '0');
            pause_tick <= '0';
        elsif rising_edge(clk) then
            if pause_load = '1' then
                tick_cnt   <= (others => '0');
                pause_tick <= '0';
            elsif tick_cnt >= tick_div - 1 then
                tick_cnt   <= (others => '0');
                pause_tick <= '1';
            else
                tick_cnt   <= tick_cnt + 1;
                pause_tick <= '0';
            end if;
        end if;
    end process;

    -- ============================================================
    -- Pause timer and PAUSE_RX counter
    -- ============================================================
    process (clk, rst_n)
    begin
        if rst_n = '0' then
            pause_remaining <= (others => '0');
            pause_rx_cnt_i  <= (others => '0');
        elsif rising_edge(clk) then
            if pause_load = '1' then
                pause_remaining <= unsigned(rx_pause_quanta);
            elsif pause_tick = '1' and pause_remaining /= 0 then
                pause_remaining <= pause_remaining - 1;
            end if;

            if stat_clr = '1' then
                pause_rx_cnt_i <= (others => '0');
            elsif prx_evt = '1' and pause_rx_cnt_i /= x"FFFFFFFF" then
                pause_rx_cnt_i <= pause_rx_cnt_i + 1;
            end if;
        end if;
    end process;

    tx_paused <= '1' when pause_remaining /= 0 else '0';

    unused_our_mac <= '1' when unsigned(our_mac) /= 0 else '0';

    -- ============================================================
    -- TX generator: emits a 60-byte 802.3x PAUSE frame on AXIS.
    -- Frame layout (no preamble/SFD/FCS - those are added by eth_mac_tx):
    --   [0..5]   dst MAC      = 01:80:C2:00:00:01
    --   [6..11]  src MAC      = our_mac (byte 0 = our_mac[47:40])
    --   [12]     ethertype hi = 0x88
    --   [13]     ethertype lo = 0x08
    --   [14]     opcode hi    = 0x00
    --   [15]     opcode lo    = 0x01
    --   [16]     quanta hi    = cfg_pause_tx_quanta[15:8]
    --   [17]     quanta lo    = cfg_pause_tx_quanta[7:0]
    --   [18..59] pad bytes    = 0x00 (ensures min frame size before FCS)
    -- ============================================================
    process (tx_idx, tx_src_lat, tx_quanta_lat)
    begin
        -- Default: drive the byte for the current tx_idx
        case to_integer(tx_idx) is
            when 0      => pause_tdata <= x"01";
            when 1      => pause_tdata <= x"80";
            when 2      => pause_tdata <= x"C2";
            when 3      => pause_tdata <= x"00";
            when 4      => pause_tdata <= x"00";
            when 5      => pause_tdata <= x"01";
            when 6      => pause_tdata <= tx_src_lat(47 downto 40);
            when 7      => pause_tdata <= tx_src_lat(39 downto 32);
            when 8      => pause_tdata <= tx_src_lat(31 downto 24);
            when 9      => pause_tdata <= tx_src_lat(23 downto 16);
            when 10     => pause_tdata <= tx_src_lat(15 downto 8);
            when 11     => pause_tdata <= tx_src_lat(7 downto 0);
            when 12     => pause_tdata <= x"88";
            when 13     => pause_tdata <= x"08";
            when 14     => pause_tdata <= x"00";
            when 15     => pause_tdata <= x"01";
            when 16     => pause_tdata <= tx_quanta_lat(15 downto 8);
            when 17     => pause_tdata <= tx_quanta_lat(7 downto 0);
            when others => pause_tdata <= x"00";
        end case;
    end process;

    -- tvalid and tlast follow the state and index directly, like tdata, so
    -- the 60th byte carries tlast whether or not tready stalls before it.
    pause_tvalid <= '1' when tx_state = TX_RUN else '0';
    pause_tlast  <= '1' when tx_state = TX_RUN and tx_idx = 59 else '0';

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            tx_state       <= TX_IDLE;
            tx_idx         <= (others => '0');
            tx_quanta_lat  <= (others => '0');
            tx_src_lat     <= (others => '0');
            pause_tx_cnt_i <= (others => '0');
        elsif rising_edge(clk) then
            case tx_state is
                when TX_IDLE =>
                    if cfg_pause_tx_send = '1' then
                        tx_quanta_lat <= cfg_pause_tx_quanta;
                        tx_src_lat    <= our_mac;
                        tx_idx        <= (others => '0');
                        tx_state      <= TX_RUN;
                    end if;

                when TX_RUN =>
                    if pause_tready = '1' then
                        if tx_idx = 59 then
                            tx_state <= TX_DONE;
                        else
                            tx_idx <= tx_idx + 1;
                        end if;
                    end if;

                when TX_DONE =>
                    if pause_tx_cnt_i = x"FFFFFFFF" then
                        pause_tx_cnt_i <= pause_tx_cnt_i;
                    else
                        pause_tx_cnt_i <= pause_tx_cnt_i + 1;
                    end if;
                    tx_state <= TX_IDLE;

                when others =>
                    tx_state <= TX_IDLE;
            end case;

            if stat_clr = '1' then
                pause_tx_cnt_i <= (others => '0');
            end if;
        end if;
    end process;

    pause_rx_cnt <= std_logic_vector(pause_rx_cnt_i);
    pause_tx_cnt <= std_logic_vector(pause_tx_cnt_i);

end architecture rtl;
