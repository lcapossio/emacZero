-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- eth_pause_rx.vhd - 802.3x PAUSE frame recognition on the PHY receive stream
-- VHDL port of rtl/eth_pause_rx.v (formally proven equivalent; see sim/parity/).
--
-- Runs in the PHY receive clock domain, on the bytes as they arrive from the
-- PHY (preamble and SFD included), ahead of the RX store-and-forward FIFO. A
-- PAUSE frame therefore takes effect as soon as it has been received, not
-- after the frames buffered ahead of it have been replayed: 802.3 Annex 31B
-- gives a MAC 512 bit times (1024 at 1 Gb/s) from the end of a PAUSE frame to
-- stop starting data frames.
--
-- A frame is a PAUSE frame when dst = 01:80:C2:00:00:01, EtherType = 0x8808
-- and opcode = 0x0001. It counts, and takes effect when it ends, only if it
-- is a valid frame: good FCS, no rx_er after the SFD, and at least 64 bytes.
-- Then pause_tgl flips when it ends. eth_pause crosses that into its own clock
-- domain: it synchronizes pause_tgl and reads pause_quanta once the flip has
-- arrived. pause_quanta takes a matched frame's pause_time as soon as those
-- bytes arrive (bytes 16-17 after the SFD), so it is settled at least 46 byte
-- times before the flip (the rest of the frame, FCS included) without a
-- timing constraint on the crossing, and it next changes at the next matched
-- frame's pause_time bytes, at least 24 byte times after the flip (preamble,
-- SFD and 16 bytes, with any IFG), far longer than the synchronizer takes.
--
-- Byte input:
--   RX_NIBBLE = 0  rx_d is a byte on every rx_clk cycle with rx_dv and rx_ce
--                  (GMII: rx_ce tied 1; RGMII 10/100: one byte every two
--                  cycles). rx_er is sampled with the byte.
--   RX_NIBBLE = 1  rx_d(3 downto 0) is an MII nibble on every cycle with rx_dv,
--                  low nibble first; rx_ce is ignored. A byte's rx_er is the OR
--                  of its two nibbles'.
-- A frame is the rx_dv envelope; it ends on the first cycle with rx_dv low.
--
-- rst_n is asynchronous; it is synchronized to rx_clk here.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity eth_pause_rx is
    generic (
        RX_NIBBLE : integer := 0
    );
    port (
        rx_clk       : in  std_logic;
        rst_n        : in  std_logic;

        rx_d         : in  std_logic_vector(7 downto 0);
        rx_dv        : in  std_logic;
        rx_er        : in  std_logic;
        rx_ce        : in  std_logic;

        pause_tgl    : out std_logic;                       -- flips once per valid PAUSE frame
        pause_quanta : out std_logic_vector(15 downto 0)    -- pause_time of the last matched frame (see above)
    );
end entity eth_pause_rx;

architecture rtl of eth_pause_rx is

    -- Vivado attribute (same name and value as the Verilog).
    attribute ASYNC_REG : string;

    -- =========================================================================
    -- rx_clk reset synchronizer
    -- =========================================================================
    signal rst_n_s1, rst_n_s2 : std_logic;
    attribute ASYNC_REG of rst_n_s1 : signal is "TRUE";
    attribute ASYNC_REG of rst_n_s2 : signal is "TRUE";

    -- =========================================================================
    -- Byte stage
    -- =========================================================================
    signal b_d     : std_logic_vector(7 downto 0);
    signal b_stb   : std_logic;
    signal b_er    : std_logic;
    signal b_end   : std_logic;
    signal dv_d1   : std_logic;
    signal nib_sel : std_logic;      -- RX_NIBBLE: the low nibble of a byte is held
    signal nib_low : std_logic_vector(3 downto 0);
    signal nib_er  : std_logic;

    -- =========================================================================
    -- Parser FSM
    -- =========================================================================
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

    signal rx_state  : std_logic_vector(3 downto 0);
    signal rx_idx    : unsigned(2 downto 0);   -- 0..5 within DST/SRC fields
    signal rx_len    : unsigned(6 downto 0);   -- bytes after the SFD, saturating at 64
    signal rx_bad    : std_logic;              -- rx_er seen after the SFD

    signal pause_tgl_i    : std_logic;
    signal pause_quanta_i : std_logic_vector(15 downto 0);

    -- CRC over the bytes after the SFD. A frame whose FCS is good leaves the
    -- register at the CRC-32 residue, as in eth_mac_rx.
    signal rx_sfd    : std_logic;
    signal rx_body   : std_logic;
    signal rx_crc    : std_logic_vector(31 downto 0);
    signal rx_fcs_ok : std_logic;

    -- 802.3x reserved multicast address for MAC Control frames.
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

begin

    process (rx_clk, rst_n)
    begin
        if rst_n = '0' then
            rst_n_s1 <= '0';
            rst_n_s2 <= '0';
        elsif rising_edge(rx_clk) then
            rst_n_s1 <= '1';
            rst_n_s2 <= rst_n_s1;
        end if;
    end process;

    -- =========================================================================
    -- Byte stage: one registered byte strobe per received byte, and a frame-
    -- end strobe on the cycle after rx_dv falls, so it always follows the
    -- frame's last byte strobe.
    -- =========================================================================
    process (rx_clk, rst_n_s2)
    begin
        if rst_n_s2 = '0' then
            b_d     <= (others => '0');
            b_stb   <= '0';
            b_er    <= '0';
            b_end   <= '0';
            dv_d1   <= '0';
            nib_sel <= '0';
            nib_low <= (others => '0');
            nib_er  <= '0';
        elsif rising_edge(rx_clk) then
            dv_d1 <= rx_dv;
            b_end <= dv_d1 and not rx_dv;
            b_stb <= '0';
            -- Nibble pairing (used only when RX_NIBBLE /= 0).
            if rx_dv = '1' then
                nib_sel <= not nib_sel;
                if nib_sel = '0' then
                    nib_low <= rx_d(3 downto 0);
                    nib_er  <= rx_er;
                end if;
            else
                nib_sel <= '0';
            end if;
            if RX_NIBBLE /= 0 then
                if rx_dv = '1' and nib_sel = '1' then
                    b_d   <= rx_d(3 downto 0) & nib_low;
                    b_er  <= nib_er or rx_er;
                    b_stb <= '1';
                end if;
            elsif rx_dv = '1' and rx_ce = '1' then
                b_d   <= rx_d;
                b_er  <= rx_er;
                b_stb <= '1';
            end if;
        end if;
    end process;

    -- =========================================================================
    -- Parser FSM. Bytes after the SFD run through a CRC-32 and a length count
    -- so a PAUSE frame is acted on only once its FCS has checked out, as 802.3
    -- requires of a MAC Control frame.
    -- =========================================================================
    rx_sfd  <= '1' when b_stb = '1' and rx_state = RX_PRE and b_d = x"D5" else '0';
    rx_body <= '1' when b_stb = '1' and rx_state /= RX_IDLE and rx_state /= RX_PRE and
                        rx_state /= RX_DRAIN else '0';
    rx_fcs_ok <= '1' when rx_crc = x"DEBB20E3" else '0';

    u_rx_crc : entity work.crc32
        port map (
            clk        => rx_clk,
            rst_n      => rst_n_s2,
            data_in    => b_d,
            data_valid => rx_body,
            crc_init   => rx_sfd,
            crc_out    => open,
            crc_raw    => rx_crc
        );

    process (rx_clk, rst_n_s2)
    begin
        if rst_n_s2 = '0' then
            rx_state       <= RX_IDLE;
            rx_idx         <= (others => '0');
            rx_len         <= (others => '0');
            rx_bad         <= '0';
            pause_tgl_i    <= '0';
            pause_quanta_i <= (others => '0');
        elsif rising_edge(rx_clk) then
            if rx_body = '1' then
                if rx_len /= 64 then
                    rx_len <= rx_len + 1;
                end if;
                if b_er = '1' then
                    rx_bad <= '1';
                end if;
            end if;

            if b_stb = '1' then
                case rx_state is
                    when RX_IDLE =>
                        if b_d = x"55" then rx_state <= RX_PRE; else rx_state <= RX_DRAIN; end if;

                    when RX_PRE =>
                        rx_idx <= (others => '0');
                        rx_len <= (others => '0');
                        rx_bad <= '0';
                        if b_d = x"D5" then
                            rx_state <= RX_DST;
                        elsif b_d /= x"55" then
                            rx_state <= RX_DRAIN;
                        end if;

                    when RX_DST =>
                        if not dst_byte_match(rx_idx, b_d) then
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
                        if b_d = x"88" then rx_state <= RX_TYPE_LO; else rx_state <= RX_DRAIN; end if;
                    when RX_TYPE_LO =>
                        if b_d = x"08" then rx_state <= RX_OP_HI; else rx_state <= RX_DRAIN; end if;
                    when RX_OP_HI =>
                        if b_d = x"00" then rx_state <= RX_OP_LO; else rx_state <= RX_DRAIN; end if;
                    when RX_OP_LO =>
                        if b_d = x"01" then rx_state <= RX_QUANTA_HI; else rx_state <= RX_DRAIN; end if;

                    when RX_QUANTA_HI =>
                        pause_quanta_i(15 downto 8) <= b_d;
                        rx_state <= RX_QUANTA_LO;
                    when RX_QUANTA_LO =>
                        pause_quanta_i(7 downto 0) <= b_d;
                        rx_state <= RX_LATCH;

                    when RX_LATCH | RX_DRAIN =>
                        null;  -- wait for end of frame
                    when others =>
                        rx_state <= RX_IDLE;
                end case;
            end if;

            if b_end = '1' then
                -- End of frame. Commit a matched PAUSE frame only if it was a
                -- valid frame.
                if rx_state = RX_LATCH and rx_fcs_ok = '1' and rx_bad = '0' and rx_len = 64 then
                    pause_tgl_i <= not pause_tgl_i;
                end if;
                rx_state <= RX_IDLE;
                rx_idx   <= (others => '0');
            end if;
        end if;
    end process;

    pause_tgl    <= pause_tgl_i;
    pause_quanta <= pause_quanta_i;

end architecture rtl;
