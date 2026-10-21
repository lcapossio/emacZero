-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- eth_pause.vhd - 802.3x PAUSE flow control
-- VHDL port of rtl/eth_pause.v (formally proven equivalent; see sim/parity/).
--
-- Two cooperating units:
--
--   * RX parser: snoops the GMII RX byte stream, preamble and SFD included,
--                looking for PAUSE frames (dst=01:80:C2:00:00:01,
--                EtherType=0x8808, opcode=0x0001). A matched frame counts and
--                takes effect when it ends, and only if it is a valid frame:
--                good FCS, no rx_er after the SFD, and at least 64 bytes. It
--                then loads its 16-bit quanta into pause_remaining, which
--                decrements at one tick per "pause quantum" of the current
--                line rate. While pause_remaining != 0, tx_paused is asserted
--                to gate eth_mac_tx from starting a new frame. A quanta of 0
--                cancels the pause immediately.
--
--   * TX generator: when cfg_pause_tx_send pulses, enqueues a single 60-byte
--                   MAC-Control PAUSE frame on its own AXIS-byte master. The
--                   wrapper is responsible for priority-muxing this source
--                   into eth_mac_tx ahead of normal user traffic.
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

        -- ---- Snoop GMII RX (preamble and SFD included, as from the PHY) ----
        gmii_rxd            : in  std_logic_vector(7 downto 0);
        gmii_rx_dv          : in  std_logic;
        gmii_rx_er          : in  std_logic;

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
    -- RX parser FSM
    -- ============================================================
    constant RX_IDLE      : std_logic_vector(3 downto 0) := "0000";  -- 4'd0
    constant RX_DST       : std_logic_vector(3 downto 0) := "0001";  -- 4'd1
    constant RX_SRC       : std_logic_vector(3 downto 0) := "0010";  -- 4'd2
    constant RX_TYPE_HI   : std_logic_vector(3 downto 0) := "0011";  -- 4'd3
    constant RX_TYPE_LO   : std_logic_vector(3 downto 0) := "0100";  -- 4'd4
    constant RX_OP_HI     : std_logic_vector(3 downto 0) := "0101";  -- 4'd5
    constant RX_OP_LO     : std_logic_vector(3 downto 0) := "0110";  -- 4'd6
    constant RX_QUANTA_HI : std_logic_vector(3 downto 0) := "0111";  -- 4'd7
    constant RX_QUANTA_LO : std_logic_vector(3 downto 0) := "1000";  -- 4'd8
    constant RX_LATCH     : std_logic_vector(3 downto 0) := "1001";  -- 4'd9
    constant RX_DRAIN     : std_logic_vector(3 downto 0) := "1010";  -- 4'd10
    constant RX_PRE       : std_logic_vector(3 downto 0) := "1011";  -- 4'd11

    signal rx_state        : std_logic_vector(3 downto 0);
    signal rx_idx          : unsigned(2 downto 0);   -- 0..5 within DST/SRC fields
    signal rx_quanta       : std_logic_vector(15 downto 0);
    signal pause_remaining : unsigned(15 downto 0);
    signal rx_len          : unsigned(6 downto 0);   -- bytes after the SFD, saturating at 64
    signal rx_bad          : std_logic;              -- rx_er seen after the SFD

    -- CRC over the bytes after the SFD. A frame whose FCS is good leaves the
    -- register at the CRC-32 residue, as in eth_mac_rx.
    signal rx_sfd    : std_logic;
    signal rx_body   : std_logic;
    signal rx_crc    : std_logic_vector(31 downto 0);
    signal rx_fcs_ok : std_logic;
    signal pause_rx_cnt_i  : unsigned(31 downto 0);

    -- Constant: 802.3x reserved multicast address for MAC Control frames.
    -- Wire-byte order: 01 80 C2 00 00 01.
    function dst_byte_match(idx : unsigned(2 downto 0); b : std_logic_vector(7 downto 0))
        return boolean is
    begin
        case to_integer(idx) is
            when 0      => return b = x"01";
            when 1      => return b = x"80";
            when 2      => return b = x"C2";
            when 3      => return b = x"00";
            when 4      => return b = x"00";
            when 5      => return b = x"01";
            when others => return false;
        end case;
    end function dst_byte_match;

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

    tick_div <= TICK_DIV_1G_U   when cfg_speed = "00" else
                TICK_DIV_100M_U when cfg_speed = "01" else
                TICK_DIV_10M_U;

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            tick_cnt   <= (others => '0');
            pause_tick <= '0';
        elsif rising_edge(clk) then
            if tick_cnt >= tick_div - 1 then
                tick_cnt   <= (others => '0');
                pause_tick <= '1';
            else
                tick_cnt   <= tick_cnt + 1;
                pause_tick <= '0';
            end if;
        end if;
    end process;

    -- ============================================================
    -- RX parser FSM
    -- The snooped bus is the PHY byte stream: one or more 0x55 preamble bytes,
    -- the 0xD5 SFD, then the frame, as eth_mac_rx sees it. Bytes after the SFD
    -- run through a CRC-32 and a length count so a PAUSE frame is acted on
    -- only once its FCS has checked out, as 802.3 requires of a MAC Control
    -- frame.
    -- ============================================================
    rx_sfd  <= '1' when gmii_rx_dv = '1' and rx_state = RX_PRE and gmii_rxd = x"D5" else '0';
    rx_body <= '1' when gmii_rx_dv = '1' and rx_state /= RX_IDLE and rx_state /= RX_PRE and
                        rx_state /= RX_DRAIN else '0';
    rx_fcs_ok <= '1' when rx_crc = x"DEBB20E3" else '0';

    u_rx_crc : entity work.crc32
        port map (
            clk        => clk,
            rst_n      => rst_n,
            data_in    => gmii_rxd,
            data_valid => rx_body,
            crc_init   => rx_sfd,
            crc_out    => open,
            crc_raw    => rx_crc
        );

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            rx_state        <= RX_IDLE;
            rx_idx          <= (others => '0');
            rx_quanta       <= (others => '0');
            rx_len          <= (others => '0');
            rx_bad          <= '0';
            pause_remaining <= (others => '0');
            pause_rx_cnt_i  <= (others => '0');
        elsif rising_edge(clk) then
            -- Pause counter decrements on each tick (clamped at 0).
            if pause_tick = '1' and pause_remaining /= 0 then
                pause_remaining <= pause_remaining - 1;
            end if;

            if rx_body = '1' then
                if rx_len /= 64 then
                    rx_len <= rx_len + 1;
                end if;
                if gmii_rx_er = '1' then
                    rx_bad <= '1';
                end if;
            end if;

            if gmii_rx_dv = '1' then
                case rx_state is
                    when RX_IDLE =>
                        if gmii_rxd = x"55" then rx_state <= RX_PRE; else rx_state <= RX_DRAIN; end if;

                    when RX_PRE =>
                        rx_idx <= (others => '0');
                        rx_len <= (others => '0');
                        rx_bad <= '0';
                        if gmii_rxd = x"D5" then
                            rx_state <= RX_DST;
                        elsif gmii_rxd /= x"55" then
                            rx_state <= RX_DRAIN;
                        end if;

                    when RX_DST =>
                        if not dst_byte_match(rx_idx, gmii_rxd) then
                            rx_state <= RX_DRAIN;
                        elsif rx_idx = 5 then
                            rx_state <= RX_SRC;
                            rx_idx   <= (others => '0');
                        else
                            rx_idx <= rx_idx + 1;
                        end if;

                    when RX_SRC =>
                        -- Skip 6 source-MAC bytes
                        if rx_idx = 5 then
                            rx_state <= RX_TYPE_HI;
                            rx_idx   <= (others => '0');
                        else
                            rx_idx <= rx_idx + 1;
                        end if;

                    when RX_TYPE_HI =>
                        if gmii_rxd = x"88" then rx_state <= RX_TYPE_LO; else rx_state <= RX_DRAIN; end if;
                    when RX_TYPE_LO =>
                        if gmii_rxd = x"08" then rx_state <= RX_OP_HI; else rx_state <= RX_DRAIN; end if;
                    when RX_OP_HI =>
                        if gmii_rxd = x"00" then rx_state <= RX_OP_LO; else rx_state <= RX_DRAIN; end if;
                    when RX_OP_LO =>
                        if gmii_rxd = x"01" then rx_state <= RX_QUANTA_HI; else rx_state <= RX_DRAIN; end if;

                    when RX_QUANTA_HI =>
                        rx_quanta(15 downto 8) <= gmii_rxd;
                        rx_state <= RX_QUANTA_LO;
                    when RX_QUANTA_LO =>
                        rx_quanta(7 downto 0) <= gmii_rxd;
                        rx_state <= RX_LATCH;

                    when RX_LATCH | RX_DRAIN =>
                        null;  -- wait for end of frame
                    when others =>
                        rx_state <= RX_IDLE;
                end case;
            elsif rx_state /= RX_IDLE then
                -- gmii_rx_dv low: end of frame. Commit a matched PAUSE frame
                -- only if it was a valid frame.
                if rx_state = RX_LATCH and rx_fcs_ok = '1' and rx_bad = '0' and rx_len = 64 then
                    if pause_rx_cnt_i = x"FFFFFFFF" then
                        pause_rx_cnt_i <= pause_rx_cnt_i;
                    else
                        pause_rx_cnt_i <= pause_rx_cnt_i + 1;
                    end if;
                    if cfg_pause_rx_en = '1' then
                        pause_remaining <= unsigned(rx_quanta);
                    end if;
                end if;
                rx_state <= RX_IDLE;
                rx_idx   <= (others => '0');
            end if;

            if stat_clr = '1' then
                pause_rx_cnt_i <= (others => '0');
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
