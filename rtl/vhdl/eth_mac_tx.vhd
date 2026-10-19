-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- eth_mac_tx.vhd - Ethernet MAC Transmit Path
-- Adds preamble/SFD, pads to 64 bytes minimum, appends CRC
-- VHDL port of rtl/eth_mac_tx.v (formally proven equivalent; see sim/parity/).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity eth_mac_tx is
    generic (
        MAX_FRAME : integer := 9018     -- jumbo MTU + headers; standard Ethernet
                                        -- is 1518; raise for jumbo frame use
    );
    port (
        clk           : in  std_logic;
        rst_n         : in  std_logic;
        -- Sampled only in S_IDLE so downstream pressure can delay a new frame
        -- without ever stalling an in-flight Ethernet transmission.
        tx_start_ok   : in  std_logic;

        -- GMII TX interface (to RGMII or direct PHY)
        gmii_txd      : out std_logic_vector(7 downto 0);
        gmii_tx_en    : out std_logic;
        gmii_tx_er    : out std_logic;

        -- Frame data input (complete Ethernet frame: dst+src+type+payload)
        -- Caller provides raw frame content; this module adds preamble/SFD and CRC
        s_axis_tdata  : in  std_logic_vector(7 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;
        s_axis_tlast  : in  std_logic;
        s_axis_tkeep  : in  std_logic_vector(0 downto 0);

        -- Status
        tx_active     : out std_logic;
        -- Debug
        dbg_state     : out std_logic_vector(3 downto 0);
        dbg_stall_cnt : out std_logic_vector(3 downto 0)
    );
end entity eth_mac_tx;

architecture rtl of eth_mac_tx is

    constant S_IDLE     : unsigned(3 downto 0) := "0000";
    constant S_PREAMBLE : unsigned(3 downto 0) := "0001";
    constant S_SFD      : unsigned(3 downto 0) := "0010";
    constant S_DATA     : unsigned(3 downto 0) := "0011";
    constant S_PAD      : unsigned(3 downto 0) := "0100";
    constant S_CRC      : unsigned(3 downto 0) := "0101";
    constant S_IFG      : unsigned(3 downto 0) := "0110";

    constant PREAMBLE_LEN : integer := 7;
    constant MIN_FRAME    : integer := 60;
    constant IFG_BYTES    : integer := 12;

    signal state     : unsigned(3 downto 0);
    signal count     : unsigned(3 downto 0);
    signal data_cnt  : unsigned(13 downto 0);
    signal stall_cnt : unsigned(3 downto 0);

    signal crc_saved  : std_logic_vector(31 downto 0);
    signal crc_accum  : std_logic_vector(31 downto 0);
    signal first_data : std_logic_vector(7 downto 0);
    signal first_last : std_logic;
    signal have_first : std_logic;

    signal s_axis_tready_i : std_logic;

    function crc_step_byte(crc_in : std_logic_vector(31 downto 0);
                           data   : std_logic_vector(7 downto 0))
        return std_logic_vector is
        variable c : std_logic_vector(31 downto 0);
    begin
        c := crc_in xor (x"000000" & data);
        for i in 0 to 7 loop
            if c(0) = '1' then
                c := ('0' & c(31 downto 1)) xor x"EDB88320";
            else
                c := '0' & c(31 downto 1);
            end if;
        end loop;
        return c;
    end function crc_step_byte;

    -- CRC is tracked combinationally via crc_step_byte/crc_accum below so the
    -- final FCS (crc_saved) can be precomputed one cycle ahead of the last data
    -- byte; no separate crc32 instance is needed on the TX path.

    signal frame_ended : std_logic;

begin

    dbg_state     <= std_logic_vector(state);
    dbg_stall_cnt <= std_logic_vector(stall_cnt);
    s_axis_tready <= s_axis_tready_i;

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            state           <= S_IDLE;
            count           <= (others => '0');
            data_cnt        <= (others => '0');
            gmii_txd        <= (others => '0');
            gmii_tx_en      <= '0';
            gmii_tx_er      <= '0';
            s_axis_tready_i <= '0';
            tx_active       <= '0';
            crc_saved       <= (others => '0');
            crc_accum       <= (others => '1');
            frame_ended     <= '0';
            stall_cnt       <= (others => '0');
            first_data      <= (others => '0');
            first_last      <= '0';
            have_first      <= '0';
        elsif rising_edge(clk) then
            s_axis_tready_i <= '0';
            gmii_tx_er      <= '0';

            case state is
                when S_IDLE =>
                    gmii_tx_en  <= '0';
                    tx_active   <= '0';
                    frame_ended <= '0';
                    stall_cnt   <= (others => '0');
                    have_first  <= '0';
                    -- Verilog: (tx_start_ok !== 1'b0)
                    if tx_start_ok /= '0' then
                        s_axis_tready_i <= '1';
                    else
                        s_axis_tready_i <= '0';
                    end if;
                    if s_axis_tvalid = '1' and s_axis_tready_i = '1' and tx_start_ok /= '0' then
                        first_data      <= s_axis_tdata;
                        first_last      <= s_axis_tlast;
                        have_first      <= '1';
                        s_axis_tready_i <= '0';
                        state           <= S_PREAMBLE;
                        count           <= (others => '0');
                        crc_accum       <= (others => '1');
                        tx_active       <= '1';
                    end if;

                when S_PREAMBLE =>
                    gmii_tx_en <= '1';
                    gmii_txd   <= x"55";
                    stall_cnt  <= (others => '0');
                    count      <= count + 1;
                    if count = PREAMBLE_LEN - 1 then
                        state <= S_SFD;
                    end if;

                when S_SFD =>
                    gmii_txd  <= x"D5";
                    data_cnt  <= (others => '0');
                    stall_cnt <= (others => '0');
                    state     <= S_DATA;

                when S_DATA =>
                    if frame_ended = '1' then
                        stall_cnt <= (others => '0');
                        if data_cnt < MIN_FRAME - 1 then
                            state     <= S_PAD;
                            gmii_txd  <= x"00";
                            crc_accum <= crc_step_byte(crc_accum, x"00");
                            data_cnt  <= data_cnt + 1;
                        elsif data_cnt = MIN_FRAME - 1 then
                            -- One pad byte completes the frame: S_PAD would
                            -- always send a second one, so go straight to CRC.
                            gmii_txd  <= x"00";
                            crc_saved <= not crc_step_byte(crc_accum, x"00");
                            data_cnt  <= data_cnt + 1;
                            state     <= S_CRC;
                            count     <= (others => '0');
                        else
                            -- crc_saved was precomputed when the final data byte
                            -- was accepted, so it already includes that byte.
                            state    <= S_CRC;
                            count    <= to_unsigned(1, 4);
                            gmii_txd <= crc_saved(7 downto 0);
                        end if;
                    elsif have_first = '1' then
                        stall_cnt  <= (others => '0');
                        gmii_txd   <= first_data;
                        crc_accum  <= crc_step_byte(crc_accum, first_data);
                        data_cnt   <= data_cnt + 1;
                        have_first <= '0';
                        if first_last = '1' then
                            crc_saved   <= not crc_step_byte(crc_accum, first_data);
                            frame_ended <= '1';
                        elsif data_cnt >= MAX_FRAME - 1 then
                            gmii_tx_er <= '1';
                            state      <= S_IFG;
                            count      <= (others => '0');
                        else
                            s_axis_tready_i <= '1';
                        end if;
                    elsif s_axis_tvalid = '1' then
                        stall_cnt <= (others => '0');
                        gmii_txd  <= s_axis_tdata;
                        crc_accum <= crc_step_byte(crc_accum, s_axis_tdata);
                        data_cnt  <= data_cnt + 1;
                        if s_axis_tlast = '1' then
                            crc_saved       <= not crc_step_byte(crc_accum, s_axis_tdata);
                            frame_ended     <= '1';
                            s_axis_tready_i <= '0';
                        elsif data_cnt >= MAX_FRAME - 1 then
                            gmii_tx_er      <= '1';
                            state           <= S_IFG;
                            count           <= (others => '0');
                            s_axis_tready_i <= '0';
                        else
                            s_axis_tready_i <= '1';
                        end if;
                    else
                        gmii_txd   <= x"00";
                        gmii_tx_er <= '1';
                        stall_cnt  <= stall_cnt + 1;
                        if stall_cnt >= 7 then
                            state <= S_IFG;
                            count <= (others => '0');
                        end if;
                    end if;

                when S_PAD =>
                    stall_cnt <= (others => '0');
                    gmii_txd  <= x"00";
                    crc_accum <= crc_step_byte(crc_accum, x"00");
                    data_cnt  <= data_cnt + 1;
                    if data_cnt >= MIN_FRAME - 1 then
                        crc_saved <= not crc_step_byte(crc_accum, x"00");
                        state     <= S_CRC;
                        count     <= (others => '0');
                    end if;

                when S_CRC =>
                    stall_cnt <= (others => '0');
                    count     <= count + 1;
                    case to_integer(count) is
                        when 0 => gmii_txd <= crc_saved(7 downto 0);
                        when 1 => gmii_txd <= crc_saved(15 downto 8);
                        when 2 => gmii_txd <= crc_saved(23 downto 16);
                        when 3 =>
                            gmii_txd <= crc_saved(31 downto 24);
                            state    <= S_IFG;
                            count    <= (others => '0');
                        when others => null;
                    end case;

                -- TX_EN stays low through S_IDLE too, for at least two more
                -- cycles (s_axis_tready is registered, so the next frame's
                -- handshake comes a cycle after it rises). Counting those
                -- here makes the gap exactly IFG_BYTES between back-to-back
                -- frames. Counting them on top gave IFG_BYTES + 2, which held
                -- 1G to 99.87% of line rate at 1518-byte frames and 97.6% at
                -- 64-byte frames.
                when S_IFG =>
                    gmii_tx_en <= '0';
                    gmii_txd   <= (others => '0');
                    stall_cnt  <= (others => '0');
                    count      <= count + 1;
                    if count >= IFG_BYTES - 3 then
                        state <= S_IDLE;
                    end if;

                when others =>
                    state <= S_IDLE;
            end case;
        end if;
    end process;

end architecture rtl;
