-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- xpm_macros.vhd - Parity-only behavioural stubs of the Xilinx XPM macros
-- xpm_fifo_async and xpm_memory_sdpram.
-- Line-for-line VHDL twin of xpm_macros.v (read that file's header for what is
-- and is not modelled). Read on the candidate side of a translateHDL proof;
-- generics and ports match Vivado's xpm_VCOMP.vhd component declarations, so
-- a design's local component declaration binds to these entities by default.
-- NOT the vendor models.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package xpm_stub_pkg is
    function clog2(value : integer) return integer;
    -- Up to 4 hex digits (rightmost = least significant) -> 16 bits.
    function hex16(s : string) return unsigned;
    function to_sl(b : boolean) return std_logic;
    function min_int(a, b : integer) return integer;
end package xpm_stub_pkg;

package body xpm_stub_pkg is
    function clog2(value : integer) return integer is
        variable tmp : integer := value - 1;
        variable r   : integer := 0;
    begin
        while tmp > 0 loop
            r   := r + 1;
            tmp := tmp / 2;
        end loop;
        return r;
    end function clog2;

    function hex_nibble(c : character) return unsigned is
        variable p : integer := character'pos(c);
    begin
        if c >= '0' and c <= '9' then
            return to_unsigned(p - character'pos('0'), 4);
        elsif c >= 'a' and c <= 'f' then
            return to_unsigned(p - character'pos('a') + 10, 4);
        elsif c >= 'A' and c <= 'F' then
            return to_unsigned(p - character'pos('A') + 10, 4);
        else
            return to_unsigned(0, 4);
        end if;
    end function hex_nibble;

    function hex16(s : string) return unsigned is
        variable r : unsigned(15 downto 0) := (others => '0');
    begin
        for i in 0 to 3 loop
            if i < s'length then
                r(4*i+3 downto 4*i) := hex_nibble(s(s'right - i));
            end if;
        end loop;
        return r;
    end function hex16;

    function to_sl(b : boolean) return std_logic is
    begin
        if b then
            return '1';
        else
            return '0';
        end if;
    end function to_sl;

    function min_int(a, b : integer) return integer is
    begin
        if a < b then
            return a;
        end if;
        return b;
    end function min_int;
end package body xpm_stub_pkg;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.xpm_stub_pkg.all;

entity xpm_fifo_async is
    generic (
        FIFO_MEMORY_TYPE    : string  := "auto";
        FIFO_WRITE_DEPTH    : integer := 2048;
        CASCADE_HEIGHT      : integer := 0;
        RELATED_CLOCKS      : integer := 0;
        WRITE_DATA_WIDTH    : integer := 32;
        READ_MODE           : string  := "std";
        FIFO_READ_LATENCY   : integer := 1;
        FULL_RESET_VALUE    : integer := 0;
        USE_ADV_FEATURES    : string  := "0707";
        READ_DATA_WIDTH     : integer := 32;
        CDC_SYNC_STAGES     : integer := 2;
        WR_DATA_COUNT_WIDTH : integer := 1;
        PROG_FULL_THRESH    : integer := 10;
        RD_DATA_COUNT_WIDTH : integer := 1;
        PROG_EMPTY_THRESH   : integer := 10;
        DOUT_RESET_VALUE    : string  := "0";
        ECC_MODE            : string  := "no_ecc";
        SIM_ASSERT_CHK      : integer := 0;
        EN_SIM_ASSERT_ERR   : string  := "warning";
        WAKEUP_TIME         : integer := 0
    );
    port (
        sleep         : in  std_logic;
        rst           : in  std_logic;
        wr_clk        : in  std_logic;
        wr_en         : in  std_logic;
        din           : in  std_logic_vector(WRITE_DATA_WIDTH-1 downto 0);
        full          : out std_logic;
        prog_full     : out std_logic;
        wr_data_count : out std_logic_vector(WR_DATA_COUNT_WIDTH-1 downto 0);
        overflow      : out std_logic;
        wr_rst_busy   : out std_logic;
        almost_full   : out std_logic;
        wr_ack        : out std_logic;
        rd_clk        : in  std_logic;
        rd_en         : in  std_logic;
        dout          : out std_logic_vector(READ_DATA_WIDTH-1 downto 0);
        empty         : out std_logic;
        prog_empty    : out std_logic;
        rd_data_count : out std_logic_vector(RD_DATA_COUNT_WIDTH-1 downto 0);
        underflow     : out std_logic;
        rd_rst_busy   : out std_logic;
        almost_empty  : out std_logic;
        data_valid    : out std_logic;
        injectsbiterr : in  std_logic;
        injectdbiterr : in  std_logic;
        sbiterr       : out std_logic;
        dbiterr       : out std_logic
    );
end entity xpm_fifo_async;

architecture stub of xpm_fifo_async is
    constant CW       : integer := clog2(FIFO_WRITE_DEPTH) + 1;   -- occupancy width
    constant ADV      : unsigned(15 downto 0) := hex16(USE_ADV_FEATURES);
    constant FWFT     : boolean := (READ_MODE = "fwft") or (READ_MODE = "FWFT");
    constant DOUT_RST : std_logic_vector(READ_DATA_WIDTH-1 downto 0) :=
        std_logic_vector(resize(hex16(DOUT_RESET_VALUE), READ_DATA_WIDTH));

    signal wr_cnt      : unsigned(CW-1 downto 0);   -- words written (wr_clk)
    signal rd_cnt      : unsigned(CW-1 downto 0);   -- words popped (rd_clk)
    signal wr_busy_cnt : unsigned(3 downto 0);      -- wr_rst_busy countdown
    signal rd_busy_cnt : unsigned(3 downto 0);      -- rd_rst_busy countdown
    signal ovf_r       : std_logic;
    signal ack_r       : std_logic;
    signal unf_r       : std_logic;
    signal dv_r        : std_logic;
    signal bubble      : std_logic;
    signal dout_r      : std_logic_vector(READ_DATA_WIDTH-1 downto 0);
    signal mem0, mem1, mem2, mem3 : std_logic_vector(WRITE_DATA_WIDTH-1 downto 0);

    signal count     : unsigned(CW-1 downto 0);
    signal cnt_empty : std_logic;
    signal cnt_full  : std_logic;
    signal wr_busy   : std_logic;
    signal rd_busy   : std_logic;
    signal mem_rd    : std_logic_vector(WRITE_DATA_WIDTH-1 downto 0);
    signal full_i    : std_logic;
    signal empty_i   : std_logic;
    signal can_write : std_logic;
    signal can_read  : std_logic;
begin
    count     <= wr_cnt - rd_cnt;
    cnt_empty <= '1' when count = 0 else '0';
    cnt_full  <= '1' when to_integer(count) = FIFO_WRITE_DEPTH else '0';
    wr_busy   <= '1' when wr_busy_cnt /= 0 else '0';
    rd_busy   <= '1' when rd_busy_cnt /= 0 else '0';
    mem_rd    <= mem0 when rd_cnt(1 downto 0) = "00" else
                 mem1 when rd_cnt(1 downto 0) = "01" else
                 mem2 when rd_cnt(1 downto 0) = "10" else mem3;

    full_i    <= to_sl(FULL_RESET_VALUE /= 0) when wr_busy = '1' else cnt_full;
    empty_i   <= rd_busy or cnt_empty;
    can_write <= wr_en and (not wr_busy) and (not cnt_full);
    can_read  <= rd_en and (not empty_i);
    full      <= full_i;
    empty     <= empty_i;

    process (wr_clk, rst)
    begin
        if rst = '1' then
            wr_cnt      <= (others => '0');
            wr_busy_cnt <= to_unsigned(CDC_SYNC_STAGES, 4);
            ovf_r       <= '0';
            ack_r       <= '0';
        elsif rising_edge(wr_clk) then
            if wr_busy = '1' then
                wr_busy_cnt <= wr_busy_cnt - 1;
            end if;
            ovf_r <= wr_en and full_i;
            ack_r <= can_write;
            if can_write = '1' then
                wr_cnt <= wr_cnt + 1;
            end if;
        end if;
    end process;

    process (wr_clk)
    begin
        if rising_edge(wr_clk) then
            if can_write = '1' then
                if wr_cnt(1 downto 0) = "00" then
                    mem0 <= din;
                elsif wr_cnt(1 downto 0) = "01" then
                    mem1 <= din;
                elsif wr_cnt(1 downto 0) = "10" then
                    mem2 <= din;
                else
                    mem3 <= din;
                end if;
            end if;
        end if;
    end process;

    process (rd_clk, rst)
    begin
        if rst = '1' then
            rd_cnt      <= (others => '0');
            rd_busy_cnt <= to_unsigned(CDC_SYNC_STAGES, 4);
            unf_r       <= '0';
            dv_r        <= '0';
            bubble      <= '0';
            dout_r      <= DOUT_RST;
        elsif rising_edge(rd_clk) then
            if rd_busy = '1' then
                rd_busy_cnt <= rd_busy_cnt - 1;
            end if;
            unf_r <= rd_en and empty_i;
            if can_read = '1' then
                rd_cnt <= rd_cnt + 1;
            end if;
            if FWFT then
                -- After a pop data_valid drops for one rd_clk before the next
                -- word is presented (sim/tb/xpm_fifo_async_model.v).
                if can_read = '1' then
                    dv_r   <= '0';
                    bubble <= '1';
                else
                    bubble <= '0';
                    dv_r   <= not cnt_empty;
                    if cnt_empty = '0' then
                        dout_r <= std_logic_vector(resize(unsigned(mem_rd), READ_DATA_WIDTH));
                    end if;
                end if;
            else
                dv_r <= can_read;
                if can_read = '1' then
                    dout_r <= std_logic_vector(resize(unsigned(mem_rd), READ_DATA_WIDTH));
                end if;
            end if;
        end if;
    end process;

    dout          <= dout_r;
    wr_rst_busy   <= wr_busy;
    rd_rst_busy   <= rd_busy;
    overflow      <= ADV(0) and ovf_r;
    prog_full     <= ADV(1) and to_sl(to_integer(count) >= PROG_FULL_THRESH);
    wr_data_count <= std_logic_vector(count(CW-1 downto CW-WR_DATA_COUNT_WIDTH)) when ADV(2) = '1'
                     else (others => '0');
    almost_full   <= ADV(3) and to_sl(to_integer(count) >= FIFO_WRITE_DEPTH - 1);
    wr_ack        <= ADV(4) and ack_r;
    underflow     <= ADV(8) and unf_r;
    prog_empty    <= ADV(9) and (rd_busy or to_sl(to_integer(count) <= PROG_EMPTY_THRESH));
    rd_data_count <= std_logic_vector(count(CW-1 downto CW-RD_DATA_COUNT_WIDTH)) when ADV(10) = '1'
                     else (others => '0');
    almost_empty  <= ADV(11) and to_sl(to_integer(count) <= 1);
    data_valid    <= ADV(12) and dv_r;
    sbiterr       <= '0';
    dbiterr       <= '0';
end architecture stub;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.xpm_stub_pkg.all;

entity xpm_memory_sdpram is
    generic (
        MEMORY_SIZE             : integer := 2048;
        MEMORY_PRIMITIVE        : string  := "auto";
        CLOCKING_MODE           : string  := "common_clock";
        ECC_MODE                : string  := "no_ecc";
        ECC_TYPE                : string  := "none";
        ECC_BIT_RANGE           : string  := "[7:0]";
        MEMORY_INIT_FILE        : string  := "none";
        MEMORY_INIT_PARAM       : string  := "";
        USE_MEM_INIT            : integer := 1;
        USE_MEM_INIT_MMI        : integer := 0;
        WAKEUP_TIME             : string  := "disable_sleep";
        AUTO_SLEEP_TIME         : integer := 0;
        MESSAGE_CONTROL         : integer := 0;
        USE_EMBEDDED_CONSTRAINT : integer := 0;
        MEMORY_OPTIMIZATION     : string  := "true";
        CASCADE_HEIGHT          : integer := 0;
        SIM_ASSERT_CHK          : integer := 0;
        WRITE_PROTECT           : integer := 1;
        RAM_DECOMP              : string  := "auto";
        IGNORE_INIT_SYNTH       : integer := 0;
        WRITE_DATA_WIDTH_A      : integer := 32;
        BYTE_WRITE_WIDTH_A      : integer := 32;
        ADDR_WIDTH_A            : integer := 6;
        RST_MODE_A              : string  := "SYNC";
        READ_DATA_WIDTH_B       : integer := 32;
        ADDR_WIDTH_B            : integer := 6;
        READ_RESET_VALUE_B      : string  := "0";
        READ_LATENCY_B          : integer := 2;
        WRITE_MODE_B            : string  := "no_change";
        RST_MODE_B              : string  := "SYNC"
    );
    port (
        sleep          : in  std_logic;
        clka           : in  std_logic;
        ena            : in  std_logic;
        wea            : in  std_logic_vector((WRITE_DATA_WIDTH_A/BYTE_WRITE_WIDTH_A)-1 downto 0);
        addra          : in  std_logic_vector(ADDR_WIDTH_A-1 downto 0);
        dina           : in  std_logic_vector(WRITE_DATA_WIDTH_A-1 downto 0);
        injectsbiterra : in  std_logic;
        injectdbiterra : in  std_logic;
        clkb           : in  std_logic;
        rstb           : in  std_logic;
        enb            : in  std_logic;
        regceb         : in  std_logic;
        addrb          : in  std_logic_vector(ADDR_WIDTH_B-1 downto 0);
        doutb          : out std_logic_vector(READ_DATA_WIDTH_B-1 downto 0);
        sbiterrb       : out std_logic;
        dbiterrb       : out std_logic
    );
end entity xpm_memory_sdpram;

architecture stub of xpm_memory_sdpram is
    constant DEPTH    : integer := MEMORY_SIZE / WRITE_DATA_WIDTH_A;
    -- Storage clamped to 2**SAW words, indexed by the low address bits, to keep
    -- the proof small. DEPTH still matters: writes at addra >= DEPTH are dropped.
    constant SAW      : integer := min_int(ADDR_WIDTH_A, 3);
    constant RST_VAL  : std_logic_vector(READ_DATA_WIDTH_B-1 downto 0) :=
        std_logic_vector(resize(hex16(READ_RESET_VALUE_B), READ_DATA_WIDTH_B));
    constant COMMON   : boolean := CLOCKING_MODE = "common_clock";
    constant RD_FIRST : boolean := WRITE_MODE_B = "read_first";
    constant WR_FIRST : boolean := WRITE_MODE_B = "write_first";
    constant NO_CHG   : boolean := (not RD_FIRST) and (not WR_FIRST);

    type mem_t is array (integer range 0 to 2**SAW-1) of std_logic_vector(WRITE_DATA_WIDTH_A-1 downto 0);
    signal mem       : mem_t;
    signal doutb_r   : std_logic_vector(READ_DATA_WIDTH_B-1 downto 0);
    signal doutb_r2  : std_logic_vector(READ_DATA_WIDTH_B-1 downto 0);

    signal rd_clk    : std_logic;
    signal wr_now    : std_logic;
    signal wr_in_rng : std_logic;
    signal collision : std_logic;
begin
    rd_clk    <= clka when COMMON else clkb;
    wr_now    <= ena and wea(0);
    wr_in_rng <= to_sl(to_integer(unsigned(addra)) < DEPTH);
    collision <= wr_now and to_sl(addra = addrb);

    process (clka)
    begin
        if rising_edge(clka) then
            if (wr_now and wr_in_rng) = '1' then
                mem(to_integer(unsigned(addra(SAW-1 downto 0)))) <= dina;
            end if;
        end if;
    end process;

    process (rd_clk)
    begin
        if rising_edge(rd_clk) then
            if rstb = '1' then
                doutb_r <= RST_VAL;
            elsif enb = '1' then
                if WR_FIRST and collision = '1' then
                    doutb_r <= dina;
                elsif not (NO_CHG and wr_now = '1') then
                    doutb_r <= mem(to_integer(unsigned(addrb(SAW-1 downto 0))));
                end if;
            end if;
        end if;
    end process;

    process (rd_clk)
    begin
        if rising_edge(rd_clk) then
            if rstb = '1' then
                doutb_r2 <= RST_VAL;
            elsif regceb = '1' then
                doutb_r2 <= doutb_r;
            end if;
        end if;
    end process;

    doutb    <= doutb_r2 when READ_LATENCY_B >= 2 else doutb_r;
    sbiterrb <= '0';
    dbiterrb <= '0';
end architecture stub;
