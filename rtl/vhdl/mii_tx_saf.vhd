-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- mii_tx_saf.vhd - Store-and-forward MII transmit path (single FIFO)
-- AXIS frame in (sys clk) -> ONE async frame FIFO {tlast,data} -> media-side
-- framer (preamble/SFD/CRC/pad/FCS/IFG) with 4-bit MII nibble output.
--
-- The framer does not start a frame until that whole frame has been committed
-- to the FIFO (tracked by a gray-coded committed-frame counter), so it can
-- never underrun. Consequently the AXIS input MAY bubble (deassert tvalid
-- mid-frame) with no wire underrun and no transmit error - the framer replaces
-- the cut-through eth_mac_tx on the MII path.
--
-- Overflow policy: backpressure (tready = !full) for well-formed frames; size
-- the FIFO >= MAX_FRAME so a valid frame always fits. A runaway frame whose
-- no-tlast run reaches MAX_FRAME is force-terminated (synthetic EOF) and its
-- tail dropped, so uncommitted data can never fill the FIFO and deadlock the
-- framer (see the oversized-frame guard on the write side).
-- VHDL port of rtl/mii_tx_saf.v (formally proven equivalent; see sim/parity/).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mii_tx_saf is
    generic (
        MAX_FRAME       : integer := 1518;   -- max raw AXIS payload (dst+src+type+data)
        FIFO_ADDR_WIDTH : integer := 12      -- 4096 bytes; must be >= MAX_FRAME
    );
    port (
        clk           : in  std_logic;       -- sys clock (AXIS write side)
        rst_n         : in  std_logic;

        -- ---- AXIS frame input (raw frame: dst+src+type+payload; no preamble/FCS)
        s_axis_tdata  : in  std_logic_vector(7 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;
        s_axis_tlast  : in  std_logic;

        -- Gate frame START (sys clk). Low pauses starting new frames (e.g. on an
        -- inbound 802.3x PAUSE); an in-flight frame always completes. Tie high if
        -- unused.
        tx_start_ok   : in  std_logic;

        -- ---- MII output (media clock) ----
        mii_tx_clk    : in  std_logic;
        mii_txd       : out std_logic_vector(3 downto 0);
        mii_tx_en     : out std_logic;

        -- ---- Status (sys clk) ----
        tx_busy       : out std_logic;                      -- < one frame of FIFO space left
        tx_fifo_level : out std_logic_vector(12 downto 0);  -- FIFO occupancy (write-side count)

        -- ---- TX observability for stats/IRQ (sys clk) ----
        tx_active     : out std_logic;       -- high while a frame is on the wire
        tx_byte_stb   : out std_logic;       -- 1-cycle pulse per byte put on the wire
        tx_frame_done : out std_logic;       -- 1-cycle pulse when a frame finishes

        -- ---- Debug (sys clk): read-side framer state synchronized into the write
        --      domain so a CSR/ELA on sys clk sees stable values. Layout:
        --      [5:0] committed frames  [11:6] drained frames (synced)
        --      [12] rd_empty (synced)  [15:13] framer state (synced)
        dbg_saf       : out std_logic_vector(15 downto 0)
    );
end entity mii_tx_saf;

architecture rtl of mii_tx_saf is

    constant PREAMBLE_LEN : integer := 7;
    constant MIN_FRAME    : integer := 60;   -- data+pad bytes before the 4-byte FCS
    constant IFG_BYTES    : integer := 12;

    -- Committed-frame counter width. The framer only starts a frame while
    -- frame_pending (frame_wr != frame_rd) is set, so this counter must never
    -- wrap to a false "equal" before the FIFO backpressures. A 1-byte frame is
    -- one FIFO entry, so up to FIFO_DEPTH (=2**FIFO_ADDR_WIDTH) frames can be
    -- buffered at once; one extra bit guarantees the difference never aliases.
    constant FRAME_CNT_W : integer := FIFO_ADDR_WIDTH + 1;

    attribute ASYNC_REG : string;
    attribute IOB       : string;

    -- =========================================================================
    -- mii_tx_clk reset synchronizer
    -- =========================================================================
    signal tx_rst_n_s1 : std_logic;
    signal tx_rst_n_s2 : std_logic;
    attribute ASYNC_REG of tx_rst_n_s1 : signal is "TRUE";
    attribute ASYNC_REG of tx_rst_n_s2 : signal is "TRUE";

    -- =========================================================================
    -- AXIS write side (sys clk): {tlast, data} straight into the frame FIFO.
    -- tlast is already aligned to the last byte, so no delay stage is needed.
    --
    -- Oversized-frame guard. The framer only starts a frame once it is COMMITTED
    -- (a tlast byte written, tracked by frame_wr_bin). A contiguous run of bytes
    -- with no tlast that reaches the FIFO depth - an oversized frame, or several
    -- frames merged by a dropped tlast upstream - would otherwise fill the FIFO
    -- with uncommitted data: frame_pending never rises, the framer never starts,
    -- wr_full sticks, and the WHOLE TX path deadlocks permanently. To stay robust
    -- we cap the in-flight (uncommitted) run at MAX_FRAME: on the MAX_FRAME-th
    -- byte with no real tlast we force a synthetic EOF (commit a truncated frame)
    -- and then drop the rest of the runaway frame until its real tlast. Because
    -- MAX_FRAME < FIFO depth, that forced commit always finds room, so
    -- uncommitted data can never fill the FIFO and the framer can always make
    -- progress. Well-formed frames (<= MAX_FRAME ending in a real tlast) hit the
    -- real tlast first and are never truncated.
    -- =========================================================================
    -- max bytes written per frame (Verilog: MAX_FRAME[13:0])
    constant OVERSIZE_LIMIT : unsigned(13 downto 0) := to_unsigned(MAX_FRAME mod 2 ** 14, 14);

    signal wr_full       : std_logic;
    signal dropping      : std_logic;               -- discarding the tail of an oversized frame
    signal frame_bytes   : unsigned(13 downto 0);   -- bytes written in the current frame so far
    signal reached_limit : std_logic;
    signal eff_last      : std_logic;
    signal forced_cut    : std_logic;

    signal wr_accept     : std_logic;
    signal eof_wr        : std_logic;               -- frame committed
    signal wr_data       : std_logic_vector(8 downto 0);
    signal fifo_count    : std_logic_vector(FIFO_ADDR_WIDTH downto 0);

    -- Committed-frame counter (sys clk): +1 when a frame's (real or forced) last
    -- byte is accepted, i.e. a whole frame is now buffered. Gray-coded for the
    -- media CDC.
    signal frame_wr_bin  : unsigned(FRAME_CNT_W-1 downto 0);
    signal frame_wr_gray : std_logic_vector(FRAME_CNT_W-1 downto 0);
    signal frame_wr_next : unsigned(FRAME_CNT_W-1 downto 0);

    -- "< one frame of space left" busy hint (matches the old tx_start_ok gate).
    constant FIFO_DEPTH : unsigned(FIFO_ADDR_WIDTH downto 0) :=
        to_unsigned(2 ** FIFO_ADDR_WIDTH, FIFO_ADDR_WIDTH + 1);

    -- Verilog: FIFO_DEPTH - MAX_FRAME[FIFO_ADDR_WIDTH:0], at FIFO_ADDR_WIDTH+1 bits.
    signal busy_thresh : unsigned(FIFO_ADDR_WIDTH downto 0);

    -- tx_fifo_level is a fixed 13-bit telemetry field, but fifo_count is
    -- FIFO_ADDR_WIDTH+1 bits and straddles that width: MAX_FRAME=1518 gives 12
    -- bits, the 9018 default gives 15. Padding 13 zeros on top keeps both
    -- part-selects in range for any FIFO_ADDR_WIDTH and avoids an implicit
    -- width conversion. Saturate rather than truncate, as gmii_cdc does: a
    -- truncated occupancy of 8192 would be reported as 0.
    signal fifo_count_pad : unsigned(FIFO_ADDR_WIDTH+13 downto 0);

    signal rd_data  : std_logic_vector(8 downto 0);
    signal rd_empty : std_logic;
    signal rd_en    : std_logic;

    function gray_to_bin(gray : std_logic_vector) return std_logic_vector is
        variable r : std_logic_vector(gray'length-1 downto 0);
        variable g : std_logic_vector(gray'length-1 downto 0);
    begin
        g := gray;
        r(gray'length-1) := g(gray'length-1);
        for i in gray'length-2 downto 0 loop
            r(i) := r(i+1) xor g(i);
        end loop;
        return r;
    end function gray_to_bin;

    -- Committed-frame counter CDC into the media domain.
    signal frame_wr_s1  : std_logic_vector(FRAME_CNT_W-1 downto 0);
    signal frame_wr_s2  : std_logic_vector(FRAME_CNT_W-1 downto 0);
    signal frame_wr_s3  : std_logic_vector(FRAME_CNT_W-1 downto 0);
    signal start_ok_s1  : std_logic;
    signal start_ok_s2  : std_logic;
    attribute ASYNC_REG of frame_wr_s1 : signal is "TRUE";
    attribute ASYNC_REG of frame_wr_s2 : signal is "TRUE";
    attribute ASYNC_REG of frame_wr_s3 : signal is "TRUE";
    attribute ASYNC_REG of start_ok_s1 : signal is "TRUE";
    attribute ASYNC_REG of start_ok_s2 : signal is "TRUE";
    signal frame_rd_bin   : unsigned(FRAME_CNT_W-1 downto 0);
    signal frame_wr_media : unsigned(FRAME_CNT_W-1 downto 0);
    signal frame_pending  : std_logic;

    -- =========================================================================
    -- CRC-32 (Ethernet FCS), one byte per step - same polynomial as eth_mac_tx.
    -- =========================================================================
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

    -- =========================================================================
    -- Framer FSM (mii_tx_clk). Each byte is emitted low-nibble then high-nibble
    -- (nib = 0, 1). Byte advance / next-state decisions happen at nib==1.
    -- =========================================================================
    constant S_IDLE : unsigned(2 downto 0) := "000";
    constant S_PRE  : unsigned(2 downto 0) := "001";
    constant S_SFD  : unsigned(2 downto 0) := "010";
    constant S_DATA : unsigned(2 downto 0) := "011";
    constant S_PAD  : unsigned(2 downto 0) := "100";
    constant S_FCS  : unsigned(2 downto 0) := "101";
    constant S_IFG  : unsigned(2 downto 0) := "110";

    signal st        : unsigned(2 downto 0);
    signal nib       : std_logic;                       -- 0 = low nibble cycle, 1 = high nibble cycle
    signal cur       : std_logic_vector(7 downto 0);    -- byte currently being nibbled out
    signal cnt       : unsigned(3 downto 0);            -- preamble / FCS / IFG byte counter
    signal dcnt      : unsigned(13 downto 0);           -- data + pad byte count
    signal crc       : std_logic_vector(31 downto 0);
    signal crc_saved : std_logic_vector(31 downto 0);
    signal cur_last  : std_logic;                       -- tlast of the data byte currently in 'cur'

    signal mii_txd_int   : std_logic_vector(3 downto 0);
    signal mii_tx_en_int : std_logic;

    -- wire the next FCS word combinationally for readability
    signal crc_final : std_logic_vector(31 downto 0);   -- for last data/pad byte
    signal crc_pad0  : std_logic_vector(31 downto 0);   -- for last pad byte

    -- Per-byte "on the wire" strobe + frame-done, toggled in media domain and
    -- synchronized to sys clk below.
    signal tx_byte_tgl     : std_logic;
    signal tx_done_tgl     : std_logic;
    signal tx_active_media : std_logic;

    -- Dedicated IOB output registers (fanout=1, drive pad only).
    signal mii_txd_iob   : std_logic_vector(3 downto 0);
    signal mii_tx_en_iob : std_logic;
    attribute IOB of mii_txd_iob   : signal is "TRUE";
    attribute IOB of mii_tx_en_iob : signal is "TRUE";

    -- =========================================================================
    -- TX observability CDC (media -> sys). At MII byte rate (<= 12.5 MB/s) a
    -- toggle-per-event resolves cleanly against the 100 MHz sys clk.
    -- =========================================================================
    signal tx_byte_s1   : std_logic;
    signal tx_byte_s2   : std_logic;
    signal tx_byte_s3   : std_logic;
    signal tx_done_s1   : std_logic;
    signal tx_done_s2   : std_logic;
    signal tx_done_s3   : std_logic;
    signal tx_active_s1 : std_logic;
    signal tx_active_s2 : std_logic;
    attribute ASYNC_REG of tx_byte_s1   : signal is "TRUE";
    attribute ASYNC_REG of tx_byte_s2   : signal is "TRUE";
    attribute ASYNC_REG of tx_byte_s3   : signal is "TRUE";
    attribute ASYNC_REG of tx_done_s1   : signal is "TRUE";
    attribute ASYNC_REG of tx_done_s2   : signal is "TRUE";
    attribute ASYNC_REG of tx_done_s3   : signal is "TRUE";
    attribute ASYNC_REG of tx_active_s1 : signal is "TRUE";
    attribute ASYNC_REG of tx_active_s2 : signal is "TRUE";

    -- =========================================================================
    -- Debug: synchronize the read-side (mii_tx_clk) framer signals into the
    -- write (sys) domain. Plain 2-FF sync - values are only read while the
    -- framer is quiescent/stuck, so multi-bit skew is not a concern here.
    -- =========================================================================
    signal frame_rd_ws1 : std_logic_vector(FRAME_CNT_W-1 downto 0);
    signal frame_rd_ws2 : std_logic_vector(FRAME_CNT_W-1 downto 0);
    signal rd_empty_ws1 : std_logic;
    signal rd_empty_ws2 : std_logic;
    signal st_ws1       : std_logic_vector(2 downto 0);
    signal st_ws2       : std_logic_vector(2 downto 0);
    attribute ASYNC_REG of frame_rd_ws1 : signal is "TRUE";
    attribute ASYNC_REG of frame_rd_ws2 : signal is "TRUE";
    attribute ASYNC_REG of rd_empty_ws1 : signal is "TRUE";
    attribute ASYNC_REG of rd_empty_ws2 : signal is "TRUE";
    attribute ASYNC_REG of st_ws1       : signal is "TRUE";
    attribute ASYNC_REG of st_ws2       : signal is "TRUE";

begin

    -- Elaboration guard: the oversize cap and the busy_thresh below both rely on
    -- MAX_FRAME < FIFO_DEPTH. If misconfigured (e.g. FIFO_ADDR_WIDTH too small),
    -- the forced-EOF commit could never find room - reintroducing the permanent
    -- TX wedge - and busy_thresh would underflow. Fail synthesis/sim loudly.
    assert MAX_FRAME < 2 ** FIFO_ADDR_WIDTH
        report "FATAL: mii_tx_saf requires MAX_FRAME (" & integer'image(MAX_FRAME) &
               ") < FIFO_DEPTH (" & integer'image(2 ** FIFO_ADDR_WIDTH) & ")"
        severity failure;

    -- =========================================================================
    -- mii_tx_clk reset synchronizer
    -- =========================================================================
    process (mii_tx_clk, rst_n)
    begin
        if rst_n = '0' then
            tx_rst_n_s2 <= '0';
            tx_rst_n_s1 <= '0';
        elsif rising_edge(mii_tx_clk) then
            tx_rst_n_s2 <= tx_rst_n_s1;
            tx_rst_n_s1 <= '1';
        end if;
    end process;

    -- =========================================================================
    -- AXIS write side
    -- =========================================================================
    reached_limit <= '1' when frame_bytes = OVERSIZE_LIMIT - 1 else '0';
    eff_last      <= s_axis_tlast or reached_limit;
    forced_cut    <= reached_limit and (not s_axis_tlast);

    wr_accept <= s_axis_tvalid and (not wr_full) and (not dropping);
    eof_wr    <= wr_accept and eff_last;
    wr_data   <= eff_last & s_axis_tdata;

    -- While dropping a runaway frame's tail, absorb source bytes fast (ready high,
    -- no writes) until its real tlast; otherwise ready = !full (backpressure).
    s_axis_tready <= '1' when dropping = '1' else not wr_full;

    -- In-flight byte count + runaway-tail drop state.
    process (clk, rst_n)
    begin
        if rst_n = '0' then
            dropping    <= '0';
            frame_bytes <= (others => '0');
        elsif rising_edge(clk) then
            if dropping = '1' then
                if s_axis_tvalid = '1' and s_axis_tlast = '1' then   -- real end of the dropped frame
                    dropping <= '0';
                end if;
            elsif wr_accept = '1' then
                if eff_last = '1' then
                    frame_bytes <= (others => '0');
                    if forced_cut = '1' then
                        dropping <= '1';    -- truncated: drop the runaway tail
                    end if;
                else
                    frame_bytes <= frame_bytes + 1;
                end if;
            end if;
        end if;
    end process;

    frame_wr_next <= frame_wr_bin + 1;

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            frame_wr_bin  <= (others => '0');
            frame_wr_gray <= (others => '0');
        elsif rising_edge(clk) then
            if eof_wr = '1' then
                frame_wr_bin  <= frame_wr_next;
                frame_wr_gray <= std_logic_vector(frame_wr_next xor shift_right(frame_wr_next, 1));
            end if;
        end if;
    end process;

    busy_thresh <= FIFO_DEPTH - to_unsigned(MAX_FRAME mod 2 ** (FIFO_ADDR_WIDTH + 1),
                                            FIFO_ADDR_WIDTH + 1);
    tx_busy     <= '1' when unsigned(fifo_count) > busy_thresh else '0';

    fifo_count_pad <= resize(unsigned(fifo_count), FIFO_ADDR_WIDTH + 14);
    tx_fifo_level  <= (others => '1') when fifo_count_pad(FIFO_ADDR_WIDTH+13 downto 13) /= 0
                      else std_logic_vector(fifo_count_pad(12 downto 0));

    u_fifo : entity work.async_fifo
        generic map (DATA_WIDTH => 9, ADDR_WIDTH => FIFO_ADDR_WIDTH)
        port map (
            wr_clk        => clk,
            wr_rst_n      => rst_n,
            wr_data       => wr_data,
            wr_en         => wr_accept,
            wr_full       => wr_full,
            rd_clk        => mii_tx_clk,
            rd_rst_n      => tx_rst_n_s2,
            rd_data       => rd_data,
            rd_en         => rd_en,
            rd_empty      => rd_empty,
            wr_data_count => fifo_count
        );

    -- Committed-frame counter CDC into the media domain.
    process (mii_tx_clk, tx_rst_n_s2)
    begin
        if tx_rst_n_s2 = '0' then
            frame_wr_s1 <= (others => '0');
            frame_wr_s2 <= (others => '0');
            frame_wr_s3 <= (others => '0');
            start_ok_s1 <= '0';
            start_ok_s2 <= '0';
        elsif rising_edge(mii_tx_clk) then
            frame_wr_s1 <= frame_wr_gray;
            frame_wr_s2 <= frame_wr_s1;
            frame_wr_s3 <= frame_wr_s2;
            start_ok_s1 <= tx_start_ok;
            start_ok_s2 <= start_ok_s1;
        end if;
    end process;
    frame_wr_media <= unsigned(gray_to_bin(frame_wr_s3));
    frame_pending  <= '1' when frame_wr_media /= frame_rd_bin else '0';

    crc_final <= not crc_step_byte(crc, cur);
    crc_pad0  <= not crc_step_byte(crc, x"00");

    process (mii_tx_clk)
    begin
        if rising_edge(mii_tx_clk) then
            if tx_rst_n_s2 = '0' then
                st              <= S_IDLE;
                nib             <= '0';
                cur             <= (others => '0');
                cnt             <= (others => '0');
                dcnt            <= (others => '0');
                crc             <= (others => '1');
                crc_saved       <= (others => '0');
                cur_last        <= '0';
                frame_rd_bin    <= (others => '0');
                rd_en           <= '0';
                mii_txd_int     <= (others => '0');
                mii_tx_en_int   <= '0';
                tx_byte_tgl     <= '0';
                tx_done_tgl     <= '0';
                tx_active_media <= '0';
            else
                rd_en <= '0';

                case st is
                    when S_IDLE =>
                        mii_tx_en_int   <= '0';
                        nib             <= '0';
                        tx_active_media <= '0';
                        if frame_pending = '1' and rd_empty = '0' and start_ok_s2 = '1' then
                            -- tx_en is raised in the first S_PRE cycle (default
                            -- branch) together with the first nibble, so it stays
                            -- aligned with mii_txd. Raising it here would emit one
                            -- stale nibble while tx_en is already high.
                            st              <= S_PRE;
                            cur             <= x"55";
                            cnt             <= (others => '0');
                            nib             <= '0';
                            tx_active_media <= '1';
                        end if;

                    when others =>
                        -- Drive the nibble every cycle of a data-bearing state.
                        if nib = '1' then
                            mii_txd_int <= cur(7 downto 4);
                        else
                            mii_txd_int <= cur(3 downto 0);
                        end if;
                        if st /= S_IFG then
                            mii_tx_en_int <= '1';
                        else
                            mii_tx_en_int <= '0';
                        end if;

                        if nib = '0' then
                            nib <= '1';
                        else
                            nib <= '0';
                            if st /= S_IFG then
                                tx_byte_tgl <= not tx_byte_tgl;   -- one wire byte emitted
                            end if;

                            case st is
                                when S_PRE =>
                                    if cnt = PREAMBLE_LEN - 1 then
                                        st  <= S_SFD;
                                        cur <= x"D5";
                                    else
                                        cnt <= cnt + 1;
                                        cur <= x"55";
                                    end if;

                                when S_SFD =>
                                    -- Load the first payload byte (FWFT: rd_data is
                                    -- already the frame's byte 0) and consume it.
                                    st       <= S_DATA;
                                    cur      <= rd_data(7 downto 0);
                                    cur_last <= rd_data(8);
                                    rd_en    <= '1';
                                    dcnt     <= (others => '0');
                                    crc      <= (others => '1');

                                when S_DATA =>
                                    crc  <= crc_step_byte(crc, cur);
                                    dcnt <= dcnt + 1;
                                    if cur_last = '1' then
                                        -- Verilog sizes dcnt + 14'd1 to the 32-bit
                                        -- integer it is compared with (no 14-bit wrap).
                                        if resize(dcnt, 32) + 1 < MIN_FRAME then
                                            st  <= S_PAD;
                                            cur <= x"00";
                                        else
                                            crc_saved <= crc_final;
                                            cur       <= crc_final(7 downto 0);
                                            st        <= S_FCS;
                                            cnt       <= (others => '0');
                                        end if;
                                    else
                                        cur      <= rd_data(7 downto 0);
                                        cur_last <= rd_data(8);
                                        rd_en    <= '1';
                                    end if;

                                when S_PAD =>
                                    crc  <= crc_step_byte(crc, x"00");
                                    dcnt <= dcnt + 1;
                                    if resize(dcnt, 32) + 1 >= MIN_FRAME then
                                        crc_saved <= crc_pad0;
                                        cur       <= crc_pad0(7 downto 0);
                                        st        <= S_FCS;
                                        cnt       <= (others => '0');
                                    else
                                        cur <= x"00";
                                    end if;

                                when S_FCS =>
                                    case to_integer(cnt) is
                                        when 0      => cur <= crc_saved(15 downto 8);
                                        when 1      => cur <= crc_saved(23 downto 16);
                                        when 2      => cur <= crc_saved(31 downto 24);
                                        when others => cur <= x"00";
                                    end case;
                                    if cnt = 3 then
                                        st  <= S_IFG;
                                        cnt <= (others => '0');
                                    else
                                        cnt <= cnt + 1;
                                    end if;

                                when S_IFG =>
                                    if cnt = IFG_BYTES - 1 then
                                        st           <= S_IDLE;
                                        frame_rd_bin <= frame_rd_bin + 1;
                                        tx_done_tgl  <= not tx_done_tgl;
                                    else
                                        cnt <= cnt + 1;
                                    end if;

                                when others =>
                                    st <= S_IDLE;
                            end case;
                        end if;
                end case;
            end if;
        end if;
    end process;

    -- Dedicated IOB output registers (fanout=1, drive pad only).
    process (mii_tx_clk)
    begin
        if rising_edge(mii_tx_clk) then
            if tx_rst_n_s2 = '0' then
                mii_txd_iob   <= (others => '0');
                mii_tx_en_iob <= '0';
            else
                mii_txd_iob   <= mii_txd_int;
                mii_tx_en_iob <= mii_tx_en_int;
            end if;
        end if;
    end process;
    mii_txd   <= mii_txd_iob;
    mii_tx_en <= mii_tx_en_iob;

    -- =========================================================================
    -- TX observability CDC (media -> sys).
    -- =========================================================================
    process (clk, rst_n)
    begin
        if rst_n = '0' then
            tx_byte_s1 <= '0'; tx_byte_s2 <= '0'; tx_byte_s3 <= '0';
            tx_done_s1 <= '0'; tx_done_s2 <= '0'; tx_done_s3 <= '0';
            tx_active_s1 <= '0'; tx_active_s2 <= '0';
        elsif rising_edge(clk) then
            tx_byte_s1 <= tx_byte_tgl; tx_byte_s2 <= tx_byte_s1; tx_byte_s3 <= tx_byte_s2;
            tx_done_s1 <= tx_done_tgl; tx_done_s2 <= tx_done_s1; tx_done_s3 <= tx_done_s2;
            tx_active_s1 <= tx_active_media; tx_active_s2 <= tx_active_s1;
        end if;
    end process;
    tx_byte_stb   <= tx_byte_s2 xor tx_byte_s3;
    tx_frame_done <= tx_done_s2 xor tx_done_s3;
    tx_active     <= tx_active_s2;

    -- =========================================================================
    -- Debug: read-side framer signals synchronized into the sys domain.
    -- =========================================================================
    process (clk, rst_n)
    begin
        if rst_n = '0' then
            frame_rd_ws1 <= (others => '0'); frame_rd_ws2 <= (others => '0');
            rd_empty_ws1 <= '1';             rd_empty_ws2 <= '1';
            st_ws1       <= (others => '0'); st_ws2       <= (others => '0');
        elsif rising_edge(clk) then
            frame_rd_ws1 <= std_logic_vector(frame_rd_bin); frame_rd_ws2 <= frame_rd_ws1;
            rd_empty_ws1 <= rd_empty;                       rd_empty_ws2 <= rd_empty_ws1;
            st_ws1       <= std_logic_vector(st);           st_ws2       <= st_ws1;
        end if;
    end process;
    -- Needs FIFO_ADDR_WIDTH >= 5 (FRAME_CNT_W >= 6), as the Verilog part-selects do.
    dbg_saf <= st_ws2 & rd_empty_ws2 & frame_rd_ws2(5 downto 0) &
               std_logic_vector(frame_wr_bin(5 downto 0));

end architecture rtl;
