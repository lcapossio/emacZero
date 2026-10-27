-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- gmii_cdc.vhd - GMII Clock Domain Crossing Bridge (for RGMII/Gigabit)
-- Store-and-forward CDC between system clock and media clock domains.
-- No nibble conversion - both sides are 8-bit GMII.
-- VHDL port of rtl/gmii_cdc.v (formally proven equivalent; see sim/parity/).
--
-- TX carries two streams, each through its own FIFO: data frames
-- (gmii_txd_in) and MAC Control frames (gmii_ctl_txd_in, e.g. PAUSE). The
-- media side picks the next frame to send: a control frame first, else a data
-- frame unless tx_hold is set. A data frame chosen but still in its start gap
-- gives way when a control frame arrives or tx_hold rises, so tx_hold stops
-- data frames at the media side, not just as they enter the FIFO. A frame
-- that has started is always sent whole.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.emz_util_pkg.all;

entity gmii_cdc is
    generic (
        -- Largest frame the RX path must deliver intact (DA..FCS bytes). The RX CDC
        -- FIFO is store-and-forward - the sys side waits for a frame's EOF marker -
        -- so it must hold MAX_FRAME + 8 preamble/SFD words + the EOF word + the
        -- slots held back for that EOF. 4096-word floor keeps standard-MTU builds
        -- at their previous depth for small-frame bursts.
        MAX_FRAME          : integer := 9018;
        RX_FIFO_ADDR_WIDTH : integer := 0;   -- 0 = max(clog2(MAX_FRAME + 10), 12), as the Verilog default
        -- Storage for both CDC FIFOs (async_fifo RAM_STYLE). "BLOCK" maps them to
        -- block RAM; "DISTRIBUTED" to LUTRAM, which at the 16K-word jumbo depths
        -- costs ~7K LUTs and does not close timing at 100/125 MHz on Artix-7.
        FIFO_RAM_STYLE     : string  := "BLOCK"
    );
    port (
        sys_clk        : in  std_logic;
        sys_rst_n      : in  std_logic;
        media_clk      : in  std_logic;   -- 125 MHz TX/media clock
        media_rx_clk   : in  std_logic;   -- RGMII RX clock or media_clk for GMII loopback

        -- Speed selection (sys_clk domain; sampled into media_clk via 2-FF sync)
        cfg_speed      : in  std_logic_vector(1 downto 0);   -- 00=1G, 01=100M, 10=10M

        -- ---- GMII from MAC (sys_clk domain) ----
        gmii_txd_in    : in  std_logic_vector(7 downto 0);
        gmii_tx_en_in  : in  std_logic;
        gmii_tx_er_in  : in  std_logic;

        -- ---- GMII control frames from MAC (sys_clk domain) ----
        -- Frames of at most 72 bytes (preamble to FCS); start one only while
        -- tx_ctl_busy is low. Tie gmii_ctl_tx_en_in low when unused.
        gmii_ctl_txd_in   : in  std_logic_vector(7 downto 0);
        gmii_ctl_tx_en_in : in  std_logic;
        gmii_ctl_tx_er_in : in  std_logic;

        -- 1 = start no new data frame on the media side (sys_clk domain, e.g. a
        -- received PAUSE). Control frames are not held.
        tx_hold        : in  std_logic;

        -- ---- GMII to MAC (sys_clk domain) ----
        gmii_rxd_out   : out std_logic_vector(7 downto 0);
        gmii_rx_dv_out : out std_logic;
        gmii_rx_er_out : out std_logic;

        -- ---- GMII to media interface (media_clk domain) ----
        gmii_txd_out   : out std_logic_vector(7 downto 0);
        gmii_tx_en_out : out std_logic;
        gmii_tx_er_out : out std_logic;

        -- ---- GMII from media interface (media_clk domain) ----
        gmii_rxd_in    : in  std_logic_vector(7 downto 0);
        gmii_rx_dv_in  : in  std_logic;   -- frame envelope
        gmii_rx_er_in  : in  std_logic;
        gmii_rx_ce_in  : in  std_logic;   -- byte strobe; tie 1 when every dv cycle is a byte

        -- ---- Status ----
        tx_busy        : out std_logic;
        tx_ctl_busy    : out std_logic;   -- control FIFO cannot take a whole frame
        tx_fifo_level  : out std_logic_vector(11 downto 0)
    );
end entity gmii_cdc;

architecture rtl of gmii_cdc is
    -- RX_FIFO_ADDR_WIDTH resolved (its Verilog default depends on MAX_FRAME,
    -- which a VHDL-93 generic default cannot; see emz_util_pkg.auto_or).
    constant RX_FIFO_AW : integer := auto_or(RX_FIFO_ADDR_WIDTH, max_int(clog2(MAX_FRAME + 10), 12));

    attribute ASYNC_REG : string;

    -- =========================================================================
    -- Reset synchronizers
    -- =========================================================================
    signal media_rst_n_s1, media_rst_n_s2       : std_logic;
    signal media_rx_rst_n_s1, media_rx_rst_n_s2 : std_logic;
    attribute ASYNC_REG of media_rst_n_s1    : signal is "TRUE";
    attribute ASYNC_REG of media_rst_n_s2    : signal is "TRUE";
    attribute ASYNC_REG of media_rx_rst_n_s1 : signal is "TRUE";
    attribute ASYNC_REG of media_rx_rst_n_s2 : signal is "TRUE";

    -- =========================================================================
    -- RX path: media_clk GMII -> async FIFO -> sys_clk GMII
    -- =========================================================================
    -- FIFO data: [9] = EOF marker, [8] = error, [7:0] = data.
    -- On an EOF word, [8] set means the frame was truncated by RX FIFO overflow.
    constant RX_FIFO_DEPTH : unsigned(RX_FIFO_AW downto 0) :=
        shift_left(to_unsigned(1, RX_FIFO_AW + 1), RX_FIFO_AW);
    signal rx_wr_data  : std_logic_vector(9 downto 0);
    signal rx_wr_en    : std_logic;
    signal rx_wr_full  : std_logic;
    signal rx_wr_count : std_logic_vector(RX_FIFO_AW downto 0);
    signal rx_dv_d1    : std_logic;
    signal rx_drop     : std_logic;   -- media_rx: current frame lost bytes to overflow

    -- Overflow policy. Data words are only written while slots are held back
    -- for the frame's EOF word, so it always fits: a dropped EOF would leave
    -- the sys side reading two frames as one (the frame toggle still fires).
    -- Once a data word is refused, the rest of that frame is dropped too - no
    -- holes - and its EOF carries the truncation flag. rx_wr_count lags reads,
    -- never writes, so it only ever over-reports occupancy (safe direction).
    --
    -- rx_data_room is registered to keep the pointer arithmetic out of the
    -- FIFO write-enable path (unregistered it failed 125 MHz timing). The
    -- registered value misses at most the one write accepted since it was
    -- sampled, so the threshold is DEPTH-2: sampled <= DEPTH-3 means at most
    -- DEPTH-1 words after this write, leaving the EOF its slot.
    signal rx_wr_is_eof   : std_logic;
    signal rx_data_room   : std_logic;
    signal rx_wr_accept   : std_logic;
    signal rx_data_refuse : std_logic;
    signal rx_fifo_din    : std_logic_vector(9 downto 0);

    -- Frame toggle for CDC handoff
    signal rx_frame_toggle : std_logic;

    -- RX async FIFO
    signal rx_rd_data  : std_logic_vector(9 downto 0);
    signal rx_rd_empty : std_logic;
    signal rx_rd_en    : std_logic;

    -- Frame availability tracking (sys_clk domain)
    signal rx_toggle_s1, rx_toggle_s2, rx_toggle_s3 : std_logic;
    attribute ASYNC_REG of rx_toggle_s1 : signal is "TRUE";
    attribute ASYNC_REG of rx_toggle_s2 : signal is "TRUE";
    attribute ASYNC_REG of rx_toggle_s3 : signal is "TRUE";
    signal rx_avail_delay : std_logic_vector(7 downto 0);
    -- Width = RX FIFO addr width + 1 (RX_CNT_W). A 4-bit counter aliased once 16
    -- frames buffered: under sustained line rate the 125 MHz media_rx side fills
    -- faster than the (slower) sys side drains, so small frames pile up well past
    -- 16 long before the RX FIFO fills - the counter wrapped, rx_frame_ready
    -- read false, and the readout stalled. At ADDR_WIDTH+1 bits the FIFO fills
    -- first, so it cannot alias.
    constant RX_CNT_W : integer := RX_FIFO_AW + 1;
    signal rx_frames_pending   : unsigned(RX_CNT_W-1 downto 0);
    signal rx_frame_done_pulse : std_logic;
    signal rx_reading          : std_logic;
    -- One-byte hold: each data word waits here until the next word is seen, so
    -- an overflow-truncated frame can flag its own last byte with rx_er rather
    -- than growing an extra error byte (which inflated RX byte and size stats).
    signal rx_pend_data  : std_logic_vector(7 downto 0);
    signal rx_pend_er    : std_logic;
    signal rx_pend_valid : std_logic;

    signal rx_frame_avail   : std_logic;
    signal rx_frame_avail_d : std_logic;
    -- rx_frames_pending lags a retired frame by one cycle (done pulse in
    -- flight), and at an EOF still counts the frame being retired. Readiness
    -- must exclude both, or the reader starts a frame whose EOF has not been
    -- written yet - cut-through, which underflows at 10/100 and breaks framing.
    signal rx_done_inflight : unsigned(RX_CNT_W-1 downto 0);
    signal rx_frame_ready   : std_logic;
    signal rx_next_ready    : std_logic;

    -- =========================================================================
    -- TX path
    -- =========================================================================
    signal tx_en_d1    : std_logic;
    signal tx_data_d1  : std_logic_vector(7 downto 0);
    signal tx_er_d1    : std_logic;
    signal tx_valid_d1 : std_logic;
    signal tx_en_fall  : std_logic;

    signal tx_wr_data   : std_logic_vector(9 downto 0);
    signal tx_wr_en     : std_logic;
    signal tx_wr_full   : std_logic;
    signal tx_wr_accept : std_logic;
    signal tx_eof_wr    : std_logic;

    signal txd_rd_data  : std_logic_vector(9 downto 0);   -- data FIFO head
    signal txd_rd_empty : std_logic;
    signal txd_rd_en    : std_logic;
    signal tx_rd_en     : std_logic;                      -- pop the selected FIFO (tx_sel_ctl)

    -- FIFO occupancy (sys_clk / write domain), taken directly from the async
    -- FIFO's exact write-side data count (wr_ptr - synced rd_ptr).
    signal tx_fifo_count : std_logic_vector(14 downto 0);

    -- A frame takes MAX_FRAME (at least the 9018-byte jumbo frame) plus 12
    -- preamble / SFD / FCS words in the FIFO, and one more may still be in the
    -- tx_*_d1 stage when tx_busy is sampled. With tx_hold the media side can
    -- stop reading, so a frame started at TX_START_LIMIT must still fit.
    constant TX_FIFO_DEPTH      : unsigned(14 downto 0) := to_unsigned(16383, 15);
    constant TX_MAX_FRAME_BYTES : unsigned(14 downto 0) :=
        to_unsigned(max_int(MAX_FRAME, 9018) mod 32768, 15);
    constant TX_START_LIMIT     : unsigned(14 downto 0) :=
        TX_FIFO_DEPTH - TX_MAX_FRAME_BYTES - to_unsigned(13, 15);

    -- Committed-frame counter (sys_clk): increments when a frame's EOF byte is
    -- accepted, i.e. a whole frame is now buffered. Gray-coded for the CDC to the
    -- media domain, where it gates the start of transmission.
    -- Counter width = FIFO addr width + 1. A narrower counter (was 4 bits)
    -- aliases to a false "equal" once 2**width whole frames back up in the FIFO
    -- (16 for 4 bits) - small frames reach that long before the 16K-byte FIFO
    -- fills - deasserting tx_frame_pending_media and wedging the paced media
    -- side. At ADDR_WIDTH+1 bits the byte FIFO fills first, so it cannot alias.
    constant FRAME_CNT_W : integer := 15;   -- 14 (ADDR_WIDTH) + 1
    signal tx_frame_wr_count_bin  : unsigned(FRAME_CNT_W-1 downto 0);
    signal tx_frame_wr_count_gray : unsigned(FRAME_CNT_W-1 downto 0);
    signal tx_frame_wr_count_next : unsigned(FRAME_CNT_W-1 downto 0);

    function gray_to_bin(gray : unsigned(FRAME_CNT_W-1 downto 0))
        return unsigned is
        variable b : unsigned(FRAME_CNT_W-1 downto 0);
    begin
        b(FRAME_CNT_W-1) := gray(FRAME_CNT_W-1);
        for i in FRAME_CNT_W-2 downto 0 loop
            b(i) := b(i+1) xor gray(i);
        end loop;
        return b;
    end function gray_to_bin;

    -- TX control path
    signal ctl_en_d1     : std_logic;
    signal ctl_data_d1   : std_logic_vector(7 downto 0);
    signal ctl_er_d1     : std_logic;
    signal ctl_en_fall   : std_logic;
    signal ctl_wr_data   : std_logic_vector(9 downto 0);
    signal ctl_wr_full   : std_logic;
    signal ctl_wr_accept : std_logic;
    signal ctl_eof_wr    : std_logic;
    signal ctl_rd_data   : std_logic_vector(9 downto 0);
    signal ctl_rd_empty  : std_logic;
    signal ctl_rd_en     : std_logic;
    signal ctl_fifo_count : std_logic_vector(7 downto 0);

    constant CTL_CNT_W : integer := 8;   -- 7 (ADDR_WIDTH) + 1
    signal ctl_frame_wr_count_bin  : unsigned(CTL_CNT_W-1 downto 0);
    signal ctl_frame_wr_count_gray : unsigned(CTL_CNT_W-1 downto 0);
    signal ctl_frame_wr_count_next : unsigned(CTL_CNT_W-1 downto 0);

    function ctl_gray_to_bin(gray : unsigned(CTL_CNT_W-1 downto 0))
        return unsigned is
        variable b : unsigned(CTL_CNT_W-1 downto 0);
    begin
        b(CTL_CNT_W-1) := gray(CTL_CNT_W-1);
        for i in CTL_CNT_W-2 downto 0 loop
            b(i) := b(i+1) xor gray(i);
        end loop;
        return b;
    end function ctl_gray_to_bin;

    -- Speed selection synchronizer (sys_clk -> media_clk)
    signal cfg_speed_s1, cfg_speed_s2 : std_logic_vector(1 downto 0);
    attribute ASYNC_REG of cfg_speed_s1 : signal is "TRUE";
    attribute ASYNC_REG of cfg_speed_s2 : signal is "TRUE";
    signal is_1g    : std_logic;
    signal is_100   : std_logic;
    signal is_10    : std_logic;
    signal pace_max : unsigned(9 downto 0);
    signal tx_gap   : unsigned(10 downto 0);

    -- Committed-frame counter CDC into the media domain.
    signal tx_frame_wr_count_s1 : unsigned(FRAME_CNT_W-1 downto 0);
    signal tx_frame_wr_count_s2 : unsigned(FRAME_CNT_W-1 downto 0);
    signal tx_frame_wr_count_s3 : unsigned(FRAME_CNT_W-1 downto 0);
    attribute ASYNC_REG of tx_frame_wr_count_s1 : signal is "TRUE";
    attribute ASYNC_REG of tx_frame_wr_count_s2 : signal is "TRUE";
    attribute ASYNC_REG of tx_frame_wr_count_s3 : signal is "TRUE";
    signal tx_frame_rd_count_bin   : unsigned(FRAME_CNT_W-1 downto 0);
    signal tx_frame_wr_count_media : unsigned(FRAME_CNT_W-1 downto 0);
    signal tx_frame_pending_media  : std_logic;

    -- The same for the control FIFO.
    signal ctl_frame_wr_count_s1 : unsigned(CTL_CNT_W-1 downto 0);
    signal ctl_frame_wr_count_s2 : unsigned(CTL_CNT_W-1 downto 0);
    signal ctl_frame_wr_count_s3 : unsigned(CTL_CNT_W-1 downto 0);
    attribute ASYNC_REG of ctl_frame_wr_count_s1 : signal is "TRUE";
    attribute ASYNC_REG of ctl_frame_wr_count_s2 : signal is "TRUE";
    attribute ASYNC_REG of ctl_frame_wr_count_s3 : signal is "TRUE";
    signal ctl_frame_rd_count_bin   : unsigned(CTL_CNT_W-1 downto 0);
    signal ctl_frame_wr_count_media : unsigned(CTL_CNT_W-1 downto 0);
    signal ctl_frame_pending_media  : std_logic;

    -- tx_hold into the media domain.
    signal tx_hold_s1, tx_hold_s2 : std_logic;
    attribute ASYNC_REG of tx_hold_s1 : signal is "TRUE";
    attribute ASYNC_REG of tx_hold_s2 : signal is "TRUE";

    -- The selected FIFO.
    signal tx_sel_ctl  : std_logic;
    signal tx_rd_data  : std_logic_vector(9 downto 0);
    signal tx_rd_empty : std_logic;

    -- TX readout state machine (media_clk domain)
    signal tx_frame_loaded : std_logic;
    signal tx_frame_end    : std_logic;
    signal tx_start_delay  : unsigned(10 downto 0);
    signal pace_cnt        : unsigned(9 downto 0);
    signal pace_tick       : std_logic;
    signal pace_advance    : std_logic;

begin

    -- MAX_FRAME + 13 words must fit in the 16K-word TX FIFO (TX_START_LIMIT):
    -- MAX_FRAME at most 16370. (The Verilog instantiates a module that does
    -- not exist, named after the error; VHDL asserts.)
    assert not (MAX_FRAME > 16370)
        report "EMACZERO_CONFIG_ERROR_gmii_cdc_MAX_FRAME_must_be_at_most_16370"
        severity failure;

    -- =========================================================================
    -- Reset synchronizers
    -- =========================================================================
    process (media_clk, sys_rst_n)
    begin
        if sys_rst_n = '0' then
            media_rst_n_s2 <= '0';
            media_rst_n_s1 <= '0';
        elsif rising_edge(media_clk) then
            media_rst_n_s2 <= media_rst_n_s1;
            media_rst_n_s1 <= '1';
        end if;
    end process;

    process (media_rx_clk, sys_rst_n)
    begin
        if sys_rst_n = '0' then
            media_rx_rst_n_s2 <= '0';
            media_rx_rst_n_s1 <= '0';
        elsif rising_edge(media_rx_clk) then
            media_rx_rst_n_s2 <= media_rx_rst_n_s1;
            media_rx_rst_n_s1 <= '1';
        end if;
    end process;

    -- =========================================================================
    -- RX path: media_clk GMII -> async FIFO -> sys_clk GMII
    -- =========================================================================
    rx_wr_is_eof <= rx_wr_data(9);

    process (media_rx_clk, media_rx_rst_n_s2)
    begin
        if media_rx_rst_n_s2 = '0' then
            rx_data_room <= '1';
        elsif rising_edge(media_rx_clk) then
            if unsigned(rx_wr_count) < RX_FIFO_DEPTH - 2 then
                rx_data_room <= '1';
            else
                rx_data_room <= '0';
            end if;
        end if;
    end process;

    rx_wr_accept   <= rx_wr_en and (not rx_wr_full)                     when rx_wr_is_eof = '1' else
                      rx_wr_en and rx_data_room and (not rx_drop);
    rx_data_refuse <= rx_wr_en and (not rx_wr_is_eof) and (not rx_wr_accept);
    rx_fifo_din    <= '1' & (rx_drop or rx_data_refuse) & x"00" when rx_wr_is_eof = '1' else
                      rx_wr_data;

    process (media_rx_clk, media_rx_rst_n_s2)
    begin
        if media_rx_rst_n_s2 = '0' then
            rx_wr_data <= (others => '0');
            rx_wr_en   <= '0';
            rx_dv_d1   <= '0';
            rx_drop    <= '0';
        elsif rising_edge(media_rx_clk) then
            rx_wr_en <= '0';
            rx_dv_d1 <= gmii_rx_dv_in;

            if rx_wr_en = '1' and rx_wr_is_eof = '1' then
                rx_drop <= '0';
            elsif rx_data_refuse = '1' then
                rx_drop <= '1';
            end if;

            -- A frame is the gmii_rx_dv_in envelope; within it only cycles
            -- with gmii_rx_ce_in carry a byte (rgmii_if at 10/100 assembles
            -- one byte every two RXC cycles).
            if gmii_rx_dv_in = '1' then
                if gmii_rx_ce_in = '1' then
                    rx_wr_data <= '0' & gmii_rx_er_in & gmii_rxd_in;
                    rx_wr_en   <= '1';
                end if;
            elsif rx_dv_d1 = '1' then
                -- Write EOF marker
                rx_wr_data <= '1' & '0' & x"00";
                rx_wr_en   <= '1';
            end if;
        end if;
    end process;

    -- Frame toggle for CDC handoff
    process (media_rx_clk, media_rx_rst_n_s2)
    begin
        if media_rx_rst_n_s2 = '0' then
            rx_frame_toggle <= '0';
        elsif rising_edge(media_rx_clk) then
            if rx_wr_accept = '1' and rx_wr_is_eof = '1' then
                rx_frame_toggle <= not rx_frame_toggle;
            end if;
        end if;
    end process;

    -- RX async FIFO
    u_rx_fifo : entity work.async_fifo
        generic map (
            DATA_WIDTH => 10,
            ADDR_WIDTH => RX_FIFO_AW,
            RAM_STYLE  => FIFO_RAM_STYLE
        )
        port map (
            wr_clk        => media_rx_clk,
            wr_rst_n      => media_rx_rst_n_s2,
            wr_data       => rx_fifo_din,
            wr_en         => rx_wr_accept,
            wr_full       => rx_wr_full,
            rd_clk        => sys_clk,
            rd_rst_n      => sys_rst_n,
            rd_data       => rx_rd_data,
            rd_en         => rx_rd_en,
            rd_empty      => rx_rd_empty,
            wr_data_count => rx_wr_count
        );

    -- Frame availability tracking (sys_clk domain)
    rx_frame_avail   <= '1' when rx_toggle_s2 /= rx_toggle_s3 else '0';
    rx_frame_avail_d <= rx_avail_delay(7);
    rx_done_inflight <= (0 => rx_frame_done_pulse, others => '0');
    rx_frame_ready   <= '1' when rx_frames_pending > rx_done_inflight else '0';
    rx_next_ready    <= '1' when rx_frames_pending > rx_done_inflight + 1 else '0';

    process (sys_clk, sys_rst_n)
        variable sel : std_logic_vector(1 downto 0);
    begin
        if sys_rst_n = '0' then
            rx_toggle_s1      <= '0';
            rx_toggle_s2      <= '0';
            rx_toggle_s3      <= '0';
            rx_avail_delay    <= (others => '0');
            rx_frames_pending <= (others => '0');
        elsif rising_edge(sys_clk) then
            rx_toggle_s1   <= rx_frame_toggle;
            rx_toggle_s2   <= rx_toggle_s1;
            rx_toggle_s3   <= rx_toggle_s2;
            rx_avail_delay <= rx_avail_delay(6 downto 0) & rx_frame_avail;

            sel := rx_frame_avail_d & rx_frame_done_pulse;
            case sel is
                when "10" =>
                    rx_frames_pending <= rx_frames_pending + 1;
                when "01" =>
                    if rx_frames_pending /= 0 then
                        rx_frames_pending <= rx_frames_pending - 1;
                    end if;
                when others =>
                    null;
            end case;
        end if;
    end process;

    -- RX readout state machine (sys_clk domain)
    process (sys_clk, sys_rst_n)
    begin
        if sys_rst_n = '0' then
            gmii_rxd_out        <= (others => '0');
            gmii_rx_dv_out      <= '0';
            gmii_rx_er_out      <= '0';
            rx_rd_en            <= '0';
            rx_reading          <= '0';
            rx_frame_done_pulse <= '0';
            rx_pend_data        <= (others => '0');
            rx_pend_er          <= '0';
            rx_pend_valid       <= '0';
        elsif rising_edge(sys_clk) then
            rx_rd_en            <= '0';
            gmii_rx_dv_out      <= '0';
            gmii_rx_er_out      <= '0';
            rx_frame_done_pulse <= '0';

            if rx_reading = '1' then
                if rx_rd_empty = '0' then
                    if rx_rd_data(9) = '1' then
                        -- EOF marker: end this frame (consumed, not output).
                        -- Release the held last byte; if the frame was truncated
                        -- by overflow (EOF err bit) it carries rx_er, so the MAC
                        -- terrors the frame without an extra byte. A frame
                        -- dropped whole has no held byte and emits nothing.
                        rx_frame_done_pulse <= '1';
                        if rx_pend_valid = '1' then
                            gmii_rxd_out   <= rx_pend_data;
                            gmii_rx_dv_out <= '1';
                            gmii_rx_er_out <= rx_pend_er or rx_rd_data(8);
                        end if;
                        rx_pend_valid <= '0';
                        if rx_next_ready = '1' then
                            -- Next frame is already whole in the FIFO: keep the
                            -- read stream going. Its first word goes into the
                            -- hold next cycle, which is the dv-low gap.
                            rx_rd_en <= '1';
                        else
                            -- Nothing complete behind this frame: go idle WITHOUT
                            -- a speculative pop. That pop used to eat the next
                            -- word - a preamble byte of a partly written frame,
                            -- or the EOF of a frame dropped whole by overflow,
                            -- which then left rx_frames_pending stuck.
                            rx_reading <= '0';
                        end if;
                    else
                        if rx_pend_valid = '1' then
                            gmii_rxd_out   <= rx_pend_data;
                            gmii_rx_dv_out <= '1';
                            gmii_rx_er_out <= rx_pend_er;
                        end if;
                        rx_pend_data  <= rx_rd_data(7 downto 0);
                        rx_pend_er    <= rx_rd_data(8);
                        rx_pend_valid <= '1';
                        rx_rd_en      <= '1';
                    end if;
                elsif rx_frame_ready = '0' then
                    rx_reading <= '0';
                end if;
            elsif rx_frame_ready = '1' and rx_rd_empty = '0' then
                -- Start a buffered frame. rd_en runs one cycle ahead of the
                -- reader: this pop lands on the edge where the reading path
                -- first sees the word, so each word is consumed exactly once.
                rx_reading <= '1';
                rx_rd_en   <= '1';
            end if;
        end if;
    end process;

    -- =========================================================================
    -- TX path: sys_clk GMII -> packet FIFO (data + EOF sideband) -> media_clk GMII
    -- Store-and-forward: the media side does not start a frame until that frame's
    -- EOF byte has been committed to the FIFO, tracked by a gray-coded committed-
    -- frame counter. This mirrors the RX path's EOF-marker packet FIFO (and the
    -- MII adapter's scheme), replacing the separate length FIFO the earlier
    -- revision used to signal frame boundaries.
    -- =========================================================================
    -- One-cycle delay so the EOF sideband bit can be attached to the frame's
    -- last byte: tx_en_fall pulses the cycle after gmii_tx_en_in drops, which is
    -- exactly when tx_data_d1 still holds that last byte.
    process (sys_clk, sys_rst_n)
    begin
        if sys_rst_n = '0' then
            tx_en_d1    <= '0';
            tx_data_d1  <= (others => '0');
            tx_er_d1    <= '0';
            tx_valid_d1 <= '0';
        elsif rising_edge(sys_clk) then
            tx_en_d1    <= gmii_tx_en_in;
            tx_data_d1  <= gmii_txd_in;
            tx_er_d1    <= gmii_tx_er_in;   -- rides with its byte through the FIFO
            tx_valid_d1 <= gmii_tx_en_in;
        end if;
    end process;
    tx_en_fall <= tx_en_d1 and (not gmii_tx_en_in);

    -- FIFO word: [9] = error (per byte), [8] = EOF (set on the frame's last byte),
    -- [7:0] = data. The error bit carries gmii_tx_er_in across the CDC so the
    -- media side can re-drive gmii_tx_er_out, mirroring the RX rx_er path.
    tx_wr_data   <= tx_er_d1 & tx_en_fall & tx_data_d1;
    tx_wr_en     <= tx_valid_d1;
    tx_wr_accept <= tx_wr_en and (not tx_wr_full);
    tx_eof_wr    <= tx_wr_accept and tx_wr_data(8);

    tx_frame_wr_count_next <= tx_frame_wr_count_bin + 1;
    process (sys_clk, sys_rst_n)
    begin
        if sys_rst_n = '0' then
            tx_frame_wr_count_bin  <= (others => '0');
            tx_frame_wr_count_gray <= (others => '0');
        elsif rising_edge(sys_clk) then
            if tx_eof_wr = '1' then
                tx_frame_wr_count_bin  <= tx_frame_wr_count_next;
                tx_frame_wr_count_gray <= tx_frame_wr_count_next xor
                                          shift_right(tx_frame_wr_count_next, 1);
            end if;
        end if;
    end process;

    -- Saturate external level to 12 bits - most consumers only care about
    -- coarse fill state.
    tx_fifo_level <= x"FFF" when unsigned(tx_fifo_count) > 4095 else
                     tx_fifo_count(11 downto 0);
    tx_busy       <= '1' when unsigned(tx_fifo_count) > TX_START_LIMIT else '0';

    -- TX data + EOF packet FIFO: sys_clk -> media_clk (16K words for jumbo)
    u_tx_fifo : entity work.async_fifo
        generic map (
            DATA_WIDTH => 10,
            ADDR_WIDTH => 14,
            RAM_STYLE  => FIFO_RAM_STYLE
        )
        port map (
            wr_clk        => sys_clk,
            wr_rst_n      => sys_rst_n,
            wr_data       => tx_wr_data,
            wr_en         => tx_wr_accept,
            wr_full       => tx_wr_full,
            rd_clk        => media_clk,
            rd_rst_n      => media_rst_n_s2,
            rd_data       => txd_rd_data,
            rd_en         => txd_rd_en,
            rd_empty      => txd_rd_empty,
            wr_data_count => tx_fifo_count
        );

    -- =========================================================================
    -- TX control path: sys_clk GMII -> control packet FIFO -> media_clk, the
    -- same word format and committed-frame counter as the data path. 128
    -- words hold one 72-byte control frame plus the tail of the one before.
    -- =========================================================================
    process (sys_clk, sys_rst_n)
    begin
        if sys_rst_n = '0' then
            ctl_en_d1   <= '0';
            ctl_data_d1 <= (others => '0');
            ctl_er_d1   <= '0';
        elsif rising_edge(sys_clk) then
            ctl_en_d1   <= gmii_ctl_tx_en_in;
            ctl_data_d1 <= gmii_ctl_txd_in;
            ctl_er_d1   <= gmii_ctl_tx_er_in;
        end if;
    end process;
    ctl_en_fall <= ctl_en_d1 and (not gmii_ctl_tx_en_in);

    ctl_wr_data   <= ctl_er_d1 & ctl_en_fall & ctl_data_d1;
    ctl_wr_accept <= ctl_en_d1 and (not ctl_wr_full);
    ctl_eof_wr    <= ctl_wr_accept and ctl_wr_data(8);

    -- A 72-byte frame started with at most 55 words queued (and one more in
    -- ctl_*_d1) fits the 128 words.
    tx_ctl_busy <= '1' when unsigned(ctl_fifo_count) > 55 else '0';

    ctl_frame_wr_count_next <= ctl_frame_wr_count_bin + 1;
    process (sys_clk, sys_rst_n)
    begin
        if sys_rst_n = '0' then
            ctl_frame_wr_count_bin  <= (others => '0');
            ctl_frame_wr_count_gray <= (others => '0');
        elsif rising_edge(sys_clk) then
            if ctl_eof_wr = '1' then
                ctl_frame_wr_count_bin  <= ctl_frame_wr_count_next;
                ctl_frame_wr_count_gray <= ctl_frame_wr_count_next xor
                                           shift_right(ctl_frame_wr_count_next, 1);
            end if;
        end if;
    end process;

    u_ctl_fifo : entity work.async_fifo
        generic map (
            DATA_WIDTH => 10,
            ADDR_WIDTH => 7,
            RAM_STYLE  => "DISTRIBUTED"
        )
        port map (
            wr_clk        => sys_clk,
            wr_rst_n      => sys_rst_n,
            wr_data       => ctl_wr_data,
            wr_en         => ctl_wr_accept,
            wr_full       => ctl_wr_full,
            rd_clk        => media_clk,
            rd_rst_n      => media_rst_n_s2,
            rd_data       => ctl_rd_data,
            rd_en         => ctl_rd_en,
            rd_empty      => ctl_rd_empty,
            wr_data_count => ctl_fifo_count
        );

    -- =========================================================================
    -- Speed selection synchronizer (sys_clk -> media_clk)
    -- =========================================================================
    process (media_clk, media_rst_n_s2)
    begin
        if media_rst_n_s2 = '0' then
            cfg_speed_s1 <= "00";
            cfg_speed_s2 <= "00";
        elsif rising_edge(media_clk) then
            cfg_speed_s1 <= cfg_speed;
            cfg_speed_s2 <= cfg_speed_s1;
        end if;
    end process;
    is_1g  <= '1' when cfg_speed_s2 = "00" or cfg_speed_s2 = "11" else '0';
    is_100 <= '1' when cfg_speed_s2 = "01" else '0';
    is_10  <= '1' when cfg_speed_s2 = "10" else '0';

    -- Pacing: at 125 MHz media_clk, emit 1 byte per
    --   1G   = 8 ns  =  1 cycle  (pace_max = 0)
    --   100M = 80 ns = 10 cycles (pace_max = 9)
    --   10M  = 800ns = 100 cycles(pace_max = 99)
    pace_max <= to_unsigned(0, 10)  when is_1g = '1' else
                to_unsigned(9, 10)  when is_100 = '1' else
                to_unsigned(99, 10);

    -- Start delay before each frame, in media cycles. The TX FIFO is
    -- store-and-forward, so the next frame can be waiting as soon as one ends
    -- and the MAC framer's own IFG never reaches the wire: the gap is enforced
    -- here at every speed. TX_EN is low for tx_gap + 2 cycles (one to close
    -- out the frame, one to load the next), so 1G uses 10 for exactly 12 byte
    -- times (the 96-bit-time IFG); 100M/10M get 122/1202 cycles, just over 12
    -- byte times. Anything much shorter is invisible to the PHY at 2.5/25 MHz
    -- and merges back-to-back frames on the wire.
    tx_gap <= to_unsigned(10, 11)   when is_1g = '1' else
              to_unsigned(120, 11)  when is_100 = '1' else
              to_unsigned(1200, 11);

    -- Committed-frame counter CDC into the media domain. tx_frame_pending_media
    -- asserts once at least one whole frame has been committed to the FIFO but
    -- not yet drained - the store-and-forward start gate.
    process (media_clk, media_rst_n_s2)
    begin
        if media_rst_n_s2 = '0' then
            tx_frame_wr_count_s1 <= (others => '0');
            tx_frame_wr_count_s2 <= (others => '0');
            tx_frame_wr_count_s3 <= (others => '0');
        elsif rising_edge(media_clk) then
            tx_frame_wr_count_s1 <= tx_frame_wr_count_gray;
            tx_frame_wr_count_s2 <= tx_frame_wr_count_s1;
            tx_frame_wr_count_s3 <= tx_frame_wr_count_s2;
        end if;
    end process;
    tx_frame_wr_count_media <= gray_to_bin(tx_frame_wr_count_s3);
    tx_frame_pending_media  <= '1' when tx_frame_wr_count_media /= tx_frame_rd_count_bin else '0';

    -- The same for the control FIFO.
    process (media_clk, media_rst_n_s2)
    begin
        if media_rst_n_s2 = '0' then
            ctl_frame_wr_count_s1 <= (others => '0');
            ctl_frame_wr_count_s2 <= (others => '0');
            ctl_frame_wr_count_s3 <= (others => '0');
        elsif rising_edge(media_clk) then
            ctl_frame_wr_count_s1 <= ctl_frame_wr_count_gray;
            ctl_frame_wr_count_s2 <= ctl_frame_wr_count_s1;
            ctl_frame_wr_count_s3 <= ctl_frame_wr_count_s2;
        end if;
    end process;
    ctl_frame_wr_count_media <= ctl_gray_to_bin(ctl_frame_wr_count_s3);
    ctl_frame_pending_media  <= '1' when ctl_frame_wr_count_media /= ctl_frame_rd_count_bin else '0';

    -- tx_hold into the media domain.
    process (media_clk, media_rst_n_s2)
    begin
        if media_rst_n_s2 = '0' then
            tx_hold_s1 <= '0';
            tx_hold_s2 <= '0';
        elsif rising_edge(media_clk) then
            tx_hold_s1 <= tx_hold;
            tx_hold_s2 <= tx_hold_s1;
        end if;
    end process;

    -- The selected FIFO: tx_sel_ctl is set when a frame is loaded and held
    -- until the next one is, so the close-out pop (applied the cycle after the
    -- frame ends) still reaches the FIFO the frame came from.
    tx_rd_data  <= ctl_rd_data  when tx_sel_ctl = '1' else txd_rd_data;
    tx_rd_empty <= ctl_rd_empty when tx_sel_ctl = '1' else txd_rd_empty;
    txd_rd_en   <= tx_rd_en and (not tx_sel_ctl);
    ctl_rd_en   <= tx_rd_en and tx_sel_ctl;

    -- =========================================================================
    -- TX readout state machine (media_clk domain)
    -- =========================================================================
    -- Read scheme (pacing unchanged from the length-FIFO revision):
    --   - A 1-cycle prefetch (start_delay==1) pulses rd_en so byte 0 is at the
    --     FWFT FIFO output for the first pace_tick while rd_en advances to byte 1,
    --     keeping the read pointer exactly one byte ahead of each paced emit.
    --     This avoids the NBA race that caused byte duplication / skips.
    --   - The frame ends when the emitted byte carries the EOF sideband bit,
    --     rather than when a preloaded byte counter reaches zero.
    pace_tick    <= '1' when pace_cnt = 0 else '0';
    pace_advance <= '1' when pace_max = 0 or pace_cnt = 1 else '0';

    -- Synchronous reset on media_rst_n_s2 here, as in the Verilog (the other
    -- media_clk registers reset asynchronously on it).
    process (media_clk)
    begin
        if rising_edge(media_clk) then
            if media_rst_n_s2 = '0' then
                gmii_txd_out          <= (others => '0');
                gmii_tx_en_out        <= '0';
                gmii_tx_er_out        <= '0';
                tx_rd_en              <= '0';
                tx_frame_loaded       <= '0';
                tx_frame_end          <= '0';
                tx_start_delay        <= (others => '0');
                tx_frame_rd_count_bin <= (others => '0');
                ctl_frame_rd_count_bin <= (others => '0');
                tx_sel_ctl            <= '0';
                pace_cnt              <= (others => '0');
            else
                tx_rd_en <= '0';

                if pace_cnt = 0 then
                    pace_cnt <= pace_max;
                else
                    pace_cnt <= pace_cnt - 1;
                end if;

                if tx_frame_loaded = '0' then
                    gmii_tx_en_out <= '0';
                    -- Pick the next frame: a control frame first, else a data
                    -- frame unless held.
                    if ctl_frame_pending_media = '1' or
                       (tx_frame_pending_media = '1' and tx_hold_s2 = '0') then
                        tx_sel_ctl      <= ctl_frame_pending_media;
                        tx_start_delay  <= tx_gap;
                        tx_frame_loaded <= '1';
                        pace_cnt        <= pace_max;
                    end if;
                else
                    if tx_start_delay > 1 and tx_sel_ctl = '0' and
                       (tx_hold_s2 = '1' or ctl_frame_pending_media = '1') then
                        -- A data frame still in its start gap, before the prefetch
                        -- below has touched the FIFO, gives way to a control frame
                        -- or a hold. The next cycle picks again and the gap
                        -- restarts, so it only grows.
                        tx_frame_loaded <= '0';
                    elsif tx_start_delay /= 0 then
                        tx_start_delay <= tx_start_delay - 1;
                        gmii_tx_en_out <= '0';
                        -- Prefetch: pulse rd_en one cycle before start_delay==0 so
                        -- byte 0 is at the FIFO output for the first pace_tick. Also
                        -- align pace_cnt so pace_tick fires at start_delay==0.
                        if tx_start_delay = 1 and tx_rd_empty = '0' then
                            tx_rd_en <= '1';
                            pace_cnt <= (others => '0');
                        end if;
                    elsif tx_frame_end = '1' then
                        -- The EOF byte was emitted at the last pace_tick. Hold it (and
                        -- gmii_tx_en_out) for its full pace interval - close out only
                        -- at the NEXT pace_tick, so the final byte occupies `period`
                        -- media cycles like every other byte instead of just one (a
                        -- 1-cycle last byte can be mis-sampled by a paced downstream).
                        -- At 1G pace_tick is always asserted, so this closes out the
                        -- next cycle exactly as before.
                        if pace_tick = '1' then
                            -- Advance past the EOF word: its per-byte advance is
                            -- suppressed above (don't prefetch past EOF), so without
                            -- this the read pointer would be left on the EOF byte and
                            -- the next paced frame would emit that stale byte, see EOF,
                            -- and end immediately - a phantom frame that orphans the
                            -- real frame. Paced modes only: at 1G the every-cycle
                            -- prefetch already realigns the pointer.
                            if is_1g = '0' then
                                tx_rd_en <= '1';
                            end if;
                            gmii_tx_en_out        <= '0';
                            tx_frame_loaded       <= '0';
                            tx_frame_end          <= '0';
                            if tx_sel_ctl = '1' then
                                ctl_frame_rd_count_bin <= ctl_frame_rd_count_bin + 1;
                            else
                                tx_frame_rd_count_bin  <= tx_frame_rd_count_bin + 1;
                            end if;
                        end if;
                    elsif tx_rd_empty = '0' then
                        if pace_tick = '1' then
                            gmii_txd_out   <= tx_rd_data(7 downto 0);
                            gmii_tx_en_out <= '1';
                            gmii_tx_er_out <= tx_rd_data(9);   -- per-byte error passthrough
                            if tx_rd_data(8) = '1' then
                                tx_frame_end <= '1';   -- last byte of the frame
                            end if;
                        end if;
                        -- Pulse rd_en the cycle before the NEXT pace_tick so the FIFO
                        -- advance is visible exactly at that capture edge. Don't
                        -- prefetch past the last (EOF) byte.
                        if pace_advance = '1' and tx_rd_data(8) = '0' then
                            tx_rd_en <= '1';
                        end if;
                        -- Hold gmii_tx_en_out high between paced beats so the RGMII
                        -- PHY sees a continuous frame.
                    end if;
                end if;
            end if;
        end if;
    end process;

end architecture rtl;
