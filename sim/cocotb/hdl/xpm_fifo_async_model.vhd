-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- xpm_fifo_async_model.vhd - Small simulation model for Xilinx xpm_fifo_async
--
-- VHDL-93 twin of sim/tb/xpm_fifo_async_model.v (the model the
-- MII-RX-REPLAY-STRESS bench builds with -DXILINX_7SERIES), full size: the
-- memory has FIFO_WRITE_DEPTH words. Read that file for what it models. Like
-- the Verilog it is stricter than the generic async_fifo for FWFT replay
-- tests: after a read, data_valid drops for one rd_clk cycle before the next
-- word is presented.
--
-- The generics and ports are those of the xpm_fifo_async component that
-- rtl/vhdl/mii_if.vhd declares (Vivado's xpm_VCOMP.vhd), so that declaration
-- binds to this entity by default. Defaults follow the Verilog model where it
-- has the parameter; the rest (CASCADE_HEIGHT, RELATED_CLOCKS, ECC_MODE,
-- SIM_ASSERT_CHK, EN_SIM_ASSERT_ERR) are ignored, as are the Verilog model's
-- other parameters apart from FIFO_WRITE_DEPTH, the data widths, the count
-- widths and PROG_EMPTY_THRESH.
--
-- X handling follows the Verilog where a comparison sees an unknown count
-- (before reset): full, empty and prog_empty go 'X'; a count bit that the
-- Verilog part-select takes from beyond the counter reads 'X'.
-- NOT the vendor model. Equivalence with the Verilog model:
-- sim/parity/harness_xpm_models/.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity xpm_fifo_async is
    generic (
        FIFO_MEMORY_TYPE    : string  := "auto";
        FIFO_WRITE_DEPTH    : integer := 16;
        CASCADE_HEIGHT      : integer := 0;
        RELATED_CLOCKS      : integer := 0;
        WRITE_DATA_WIDTH    : integer := 8;
        READ_MODE           : string  := "fwft";
        FIFO_READ_LATENCY   : integer := 0;
        FULL_RESET_VALUE    : integer := 0;
        USE_ADV_FEATURES    : string  := "0000";
        READ_DATA_WIDTH     : integer := 8;
        CDC_SYNC_STAGES     : integer := 2;
        WR_DATA_COUNT_WIDTH : integer := 5;
        PROG_FULL_THRESH    : integer := 10;
        RD_DATA_COUNT_WIDTH : integer := 5;
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

architecture model of xpm_fifo_async is

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

    constant ADDR_WIDTH  : integer := clog2(FIFO_WRITE_DEPTH);
    constant COUNT_WIDTH : integer := ADDR_WIDTH + 1;

    -- FIFO_WRITE_DEPTH[COUNT_WIDTH-1:0], PROG_EMPTY_THRESH[COUNT_WIDTH-1:0]
    constant DEPTH_CW : unsigned(COUNT_WIDTH-1 downto 0) :=
        to_unsigned(FIFO_WRITE_DEPTH mod 2**COUNT_WIDTH, COUNT_WIDTH);
    constant PE_CW    : unsigned(COUNT_WIDTH-1 downto 0) :=
        to_unsigned(PROG_EMPTY_THRESH mod 2**COUNT_WIDTH, COUNT_WIDTH);

    -- Verilog ==: unknown when either side has an unknown bit.
    function eq_x(a, b : unsigned) return std_logic is
    begin
        if Is_X(std_logic_vector(a)) or Is_X(std_logic_vector(b)) then
            return 'X';
        elsif a = b then
            return '1';
        else
            return '0';
        end if;
    end function eq_x;

    -- Verilog <: unknown when either side has an unknown bit.
    function lt_x(a, b : unsigned) return std_logic is
    begin
        if Is_X(std_logic_vector(a)) or Is_X(std_logic_vector(b)) then
            return 'X';
        elsif a < b then
            return '1';
        else
            return '0';
        end if;
    end function lt_x;

    -- count[W-1:0]: bits past the counter read 'X', as an Icarus part-select.
    function count_sel(c : unsigned; w : integer) return std_logic_vector is
        variable r : std_logic_vector(w-1 downto 0);
    begin
        for i in 0 to w-1 loop
            if i < c'length then
                r(i) := c(c'low + i);
            else
                r(i) := 'X';
            end if;
        end loop;
        return r;
    end function count_sel;

    -- Width conversion of a Verilog assignment (zero-extend or truncate).
    function fit(v : std_logic_vector; w : integer) return std_logic_vector is
    begin
        return std_logic_vector(resize(unsigned(v), w));
    end function fit;

    type mem_t is array (0 to FIFO_WRITE_DEPTH-1) of std_logic_vector(WRITE_DATA_WIDTH-1 downto 0);
    signal mem            : mem_t;
    signal wr_ptr         : unsigned(ADDR_WIDTH-1 downto 0);
    signal rd_ptr         : unsigned(ADDR_WIDTH-1 downto 0);
    signal wr_count_total : unsigned(COUNT_WIDTH-1 downto 0);
    signal rd_count_total : unsigned(COUNT_WIDTH-1 downto 0);
    signal present_bubble : std_logic;

    signal count          : unsigned(COUNT_WIDTH-1 downto 0);
    signal full_i         : std_logic;
    signal empty_i        : std_logic;
    signal prog_empty_i   : std_logic;
    signal can_write      : std_logic;
    signal can_read       : std_logic;
    signal rd_ptr_next    : unsigned(ADDR_WIDTH-1 downto 0);

    signal dout_r         : std_logic_vector(READ_DATA_WIDTH-1 downto 0);
    signal data_valid_r   : std_logic;
    signal overflow_r     : std_logic;
    signal underflow_r    : std_logic;
    signal wr_ack_r       : std_logic;
begin
    count     <= wr_count_total - rd_count_total;
    can_write <= wr_en and (not full_i) and (not rst);
    can_read  <= rd_en and (not empty_i) and (not rst);
    rd_ptr_next <= (others => '0') when rd_ptr = FIFO_WRITE_DEPTH-1 else rd_ptr + 1;

    full_i       <= eq_x(count, DEPTH_CW);
    empty_i      <= eq_x(count, to_unsigned(0, COUNT_WIDTH));
    prog_empty_i <= lt_x(count, PE_CW);

    full          <= full_i;
    empty         <= empty_i;
    wr_rst_busy   <= '0';
    rd_rst_busy   <= '0';
    sbiterr       <= '0';
    dbiterr       <= '0';
    prog_full     <= full_i;
    prog_empty    <= prog_empty_i;
    almost_full   <= full_i;
    almost_empty  <= prog_empty_i;
    wr_data_count <= count_sel(count, WR_DATA_COUNT_WIDTH);
    rd_data_count <= count_sel(count, RD_DATA_COUNT_WIDTH);
    dout          <= dout_r;
    data_valid    <= data_valid_r;
    overflow      <= overflow_r;
    underflow     <= underflow_r;
    wr_ack        <= wr_ack_r;

    process (wr_clk, rst)
    begin
        if rst = '1' then
            wr_ptr         <= (others => '0');
            wr_count_total <= (others => '0');
            wr_ack_r       <= '0';
            overflow_r     <= '0';
        elsif rising_edge(wr_clk) then
            wr_ack_r   <= '0';
            overflow_r <= '0';
            if wr_en = '1' and full_i = '1' then
                overflow_r <= '1';
            elsif can_write = '1' then
                if wr_ptr = FIFO_WRITE_DEPTH-1 then
                    wr_ptr <= (others => '0');
                else
                    wr_ptr <= wr_ptr + 1;
                end if;
                wr_count_total <= wr_count_total + 1;
                wr_ack_r       <= '1';
            end if;
        end if;
    end process;

    -- The Verilog writes mem in the process above, in the can_write branch.
    -- can_write = '1' implies rst = '0' and full = '0', so this process writes
    -- exactly then (kept apart so the memory has no asynchronous reset).
    process (wr_clk)
    begin
        if rising_edge(wr_clk) then
            if can_write = '1' then
                mem(to_integer(wr_ptr)) <= din;
            end if;
        end if;
    end process;

    process (rd_clk, rst)
    begin
        if rst = '1' then
            rd_ptr         <= (others => '0');
            rd_count_total <= (others => '0');
            dout_r         <= (others => '0');
            data_valid_r   <= '0';
            underflow_r    <= '0';
            present_bubble <= '0';
        elsif rising_edge(rd_clk) then
            underflow_r <= '0';
            if rd_en = '1' and empty_i = '1' then
                underflow_r  <= '1';
                data_valid_r <= '0';
            elsif can_read = '1' then
                rd_ptr         <= rd_ptr_next;
                rd_count_total <= rd_count_total + 1;
                data_valid_r   <= '0';
                present_bubble <= '1';
            elsif present_bubble = '1' then
                present_bubble <= '0';
                if eq_x(count, to_unsigned(0, COUNT_WIDTH)) = '0' then
                    dout_r       <= fit(mem(to_integer(rd_ptr)), READ_DATA_WIDTH);
                    data_valid_r <= '1';
                else
                    data_valid_r <= '0';
                end if;
            elsif empty_i = '0' then
                dout_r       <= fit(mem(to_integer(rd_ptr)), READ_DATA_WIDTH);
                data_valid_r <= '1';
            else
                data_valid_r <= '0';
            end if;
        end if;
    end process;

end architecture model;
