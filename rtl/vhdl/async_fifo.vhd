-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- async_fifo.vhd - Asynchronous FIFO with Gray-code pointer CDC
-- Parameterizable width and depth (depth must be power of 2).
--
-- Two storage implementations behind one first-word-fall-through interface
-- (rd_data is valid whenever !rd_empty; rd_en && !rd_empty pops it):
--   RAM_STYLE = "DISTRIBUTED"  combinational read of the memory array. Maps to
--               LUTRAM on FPGAs; lowest latency. Right for shallow FIFOs - deep
--               ones cost ~DEPTH*WIDTH/64 LUTs plus a wide write decode that
--               will not close timing at 100+ MHz (16K words fails on Artix-7).
--   RAM_STYLE = "BLOCK"        registered read into a one-word output stage,
--               which is the FWFT head. Maps to block RAM. rd_empty deasserts
--               one rd_clk later than DISTRIBUTED after a write lands; pops
--               still sustain one word per rd_clk. The head word has left the
--               memory, so once it is loaded the FIFO holds DEPTH+1 words
--               before wr_full.
-- VHDL port of rtl/async_fifo.v (formally proven equivalent; see sim/parity/).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity async_fifo is
    generic (
        DATA_WIDTH : integer := 9;
        ADDR_WIDTH : integer := 11;
        RAM_STYLE  : string  := "DISTRIBUTED"   -- "DISTRIBUTED" | "BLOCK"
    );
    port (
        wr_clk        : in  std_logic;
        wr_rst_n      : in  std_logic;
        wr_data       : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        wr_en         : in  std_logic;
        wr_full       : out std_logic;

        rd_clk        : in  std_logic;
        rd_rst_n      : in  std_logic;
        rd_data       : out std_logic_vector(DATA_WIDTH-1 downto 0);
        rd_en         : in  std_logic;
        rd_empty      : out std_logic;

        -- Write-side occupancy of the memory array (wr_ptr - synced rd_ptr), in
        -- the wr_clk domain. Lags reads by the pointer-sync latency, so it never
        -- under-reports how full the memory is - safe for fill-level / "busy"
        -- decisions. With RAM_STYLE="BLOCK" the word held in the output stage has
        -- already left the memory and is not counted. Leave unconnected if unused.
        wr_data_count : out std_logic_vector(ADDR_WIDTH downto 0)
    );
end entity async_fifo;

architecture rtl of async_fifo is

    constant DEPTH : integer := 2 ** ADDR_WIDTH;

    type mem_t is array (0 to DEPTH-1) of std_logic_vector(DATA_WIDTH-1 downto 0);

    signal wr_ptr_bin  : unsigned(ADDR_WIDTH downto 0);
    signal wr_ptr_gray : std_logic_vector(ADDR_WIDTH downto 0);
    signal rd_ptr_bin  : unsigned(ADDR_WIDTH downto 0);
    signal rd_ptr_gray : std_logic_vector(ADDR_WIDTH downto 0);

    signal wr_ptr_gray_sync1 : std_logic_vector(ADDR_WIDTH downto 0);
    signal wr_ptr_gray_sync2 : std_logic_vector(ADDR_WIDTH downto 0);
    signal rd_ptr_gray_sync1 : std_logic_vector(ADDR_WIDTH downto 0);
    signal rd_ptr_gray_sync2 : std_logic_vector(ADDR_WIDTH downto 0);

    attribute ASYNC_REG : string;
    attribute ASYNC_REG of wr_ptr_gray_sync1 : signal is "TRUE";
    attribute ASYNC_REG of wr_ptr_gray_sync2 : signal is "TRUE";
    attribute ASYNC_REG of rd_ptr_gray_sync1 : signal is "TRUE";
    attribute ASYNC_REG of rd_ptr_gray_sync2 : signal is "TRUE";

    signal wr_addr_valid : std_logic;
    signal wr_full_i     : std_logic;
    signal mem_empty     : std_logic;
    signal mem_rd        : std_logic;   -- pop one word from the memory array

    function bin2gray(bin : unsigned) return std_logic_vector is
    begin
        return std_logic_vector(bin xor shift_right(bin, 1));
    end function bin2gray;

    function gray2bin(gray : std_logic_vector) return unsigned is
        variable g : unsigned(gray'length-1 downto 0);
        variable b : unsigned(gray'length-1 downto 0);
    begin
        g := unsigned(gray);
        b := g;
        for i in 1 to gray'length-1 loop
            b := b xor shift_right(g, i);
        end loop;
        return b;
    end function gray2bin;

begin

    wr_addr_valid <= wr_en and (not wr_full_i);

    process (wr_clk, wr_rst_n)
    begin
        if wr_rst_n = '0' then
            wr_ptr_bin  <= (others => '0');
            wr_ptr_gray <= (others => '0');
        elsif rising_edge(wr_clk) then
            if wr_addr_valid = '1' then
                wr_ptr_bin  <= wr_ptr_bin + 1;
                wr_ptr_gray <= bin2gray(wr_ptr_bin + 1);
            end if;
        end if;
    end process;

    process (wr_clk, wr_rst_n)
    begin
        if wr_rst_n = '0' then
            rd_ptr_gray_sync1 <= (others => '0');
            rd_ptr_gray_sync2 <= (others => '0');
        elsif rising_edge(wr_clk) then
            rd_ptr_gray_sync1 <= rd_ptr_gray;
            rd_ptr_gray_sync2 <= rd_ptr_gray_sync1;
        end if;
    end process;

    wr_full_i <= '1' when wr_ptr_gray = ((not rd_ptr_gray_sync2(ADDR_WIDTH downto ADDR_WIDTH-1))
                                         & rd_ptr_gray_sync2(ADDR_WIDTH-2 downto 0))
                 else '0';
    wr_full   <= wr_full_i;

    -- Write-side occupancy from the already-synchronized read Gray pointer.
    wr_data_count <= std_logic_vector(wr_ptr_bin - gray2bin(rd_ptr_gray_sync2));

    -- rd_ptr_bin / rd_ptr_gray count words read out of the memory array.
    -- mem_empty compares that pointer against the synced write pointer; what
    -- the user sees as rd_empty depends on the storage style below.
    mem_empty <= '1' when rd_ptr_gray = wr_ptr_gray_sync2 else '0';

    process (rd_clk, rd_rst_n)
    begin
        if rd_rst_n = '0' then
            rd_ptr_bin  <= (others => '0');
            rd_ptr_gray <= (others => '0');
        elsif rising_edge(rd_clk) then
            if mem_rd = '1' then
                rd_ptr_bin  <= rd_ptr_bin + 1;
                rd_ptr_gray <= bin2gray(rd_ptr_bin + 1);
            end if;
        end if;
    end process;

    -- VHDL is case-insensitive: the Vivado `ram_style` attribute declared in
    -- each branch hides the RAM_STYLE generic there (GHDL -Whide). Harmless,
    -- the generic is only read by the generate conditions.
    gen_block : if RAM_STYLE = "BLOCK" generate
        signal mem : mem_t;
        attribute ram_style : string;
        attribute ram_style of mem : signal is "block";

        -- One-word output stage = the FWFT head. Refill it whenever it is
        -- empty or being popped this cycle, so back-to-back pops run at
        -- one word per clock. head_q is the block RAM's registered read
        -- port: no reset, so the tool can absorb it into the RAM.
        signal head_q     : std_logic_vector(DATA_WIDTH-1 downto 0);
        signal head_valid : std_logic;
        signal pop        : std_logic;
    begin
        process (wr_clk)
        begin
            if rising_edge(wr_clk) then
                if wr_addr_valid = '1' then
                    mem(to_integer(wr_ptr_bin(ADDR_WIDTH-1 downto 0))) <= wr_data;
                end if;
            end if;
        end process;

        pop    <= rd_en and head_valid;
        mem_rd <= (not mem_empty) and ((not head_valid) or pop);

        process (rd_clk)
        begin
            if rising_edge(rd_clk) then
                if mem_rd = '1' then
                    head_q <= mem(to_integer(rd_ptr_bin(ADDR_WIDTH-1 downto 0)));
                end if;
            end if;
        end process;

        process (rd_clk, rd_rst_n)
        begin
            if rd_rst_n = '0' then
                head_valid <= '0';
            elsif rising_edge(rd_clk) then
                if mem_rd = '1' then
                    head_valid <= '1';
                elsif pop = '1' then
                    head_valid <= '0';
                end if;
            end if;
        end process;

        rd_data  <= head_q;
        rd_empty <= not head_valid;
    end generate gen_block;

    gen_distributed : if RAM_STYLE /= "BLOCK" generate
        signal mem : mem_t;
        attribute ram_style : string;
        attribute ram_style of mem : signal is "distributed";
    begin
        process (wr_clk)
        begin
            if rising_edge(wr_clk) then
                if wr_addr_valid = '1' then
                    mem(to_integer(wr_ptr_bin(ADDR_WIDTH-1 downto 0))) <= wr_data;
                end if;
            end if;
        end process;

        mem_rd   <= rd_en and (not mem_empty);
        rd_data  <= mem(to_integer(rd_ptr_bin(ADDR_WIDTH-1 downto 0)));
        rd_empty <= mem_empty;
    end generate gen_distributed;

    process (rd_clk, rd_rst_n)
    begin
        if rd_rst_n = '0' then
            wr_ptr_gray_sync1 <= (others => '0');
            wr_ptr_gray_sync2 <= (others => '0');
        elsif rising_edge(rd_clk) then
            wr_ptr_gray_sync1 <= wr_ptr_gray;
            wr_ptr_gray_sync2 <= wr_ptr_gray_sync1;
        end if;
    end process;

end architecture rtl;
