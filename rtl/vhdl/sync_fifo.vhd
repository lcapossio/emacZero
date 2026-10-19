-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- sync_fifo.vhd - Synchronous (single-clock) FIFO with BRAM storage and FWFT
-- output register. Width and depth (power of 2) are parameterizable.
--
-- FWFT semantics: when rd_valid=1, rd_data is the head of the FIFO. Pop
-- happens when (rd_valid && rd_en). Read latency from non-empty to first
-- rd_valid is 1 cycle (BRAM sync read). ram_style=block forces BRAM.
-- VHDL port of rtl/sync_fifo.v (formally proven equivalent; see sim/parity/).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sync_fifo is
    generic (
        DATA_WIDTH : integer := 8;
        ADDR_WIDTH : integer := 8
    );
    port (
        clk         : in  std_logic;
        rst_n       : in  std_logic;

        -- Write side
        wr_data     : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        wr_en       : in  std_logic;
        wr_full     : out std_logic;

        -- Read side (FWFT)
        rd_data     : out std_logic_vector(DATA_WIDTH-1 downto 0);
        rd_valid    : out std_logic;
        rd_en       : in  std_logic;
        rd_empty    : out std_logic;

        -- Occupancy (count of entries in BRAM, excludes the output register)
        count       : out std_logic_vector(ADDR_WIDTH downto 0);

        -- High for one cycle when a write was attempted but dropped (FIFO full).
        wr_overflow : out std_logic
    );
end entity sync_fifo;

architecture rtl of sync_fifo is

    constant DEPTH : integer := 2 ** ADDR_WIDTH;

    type mem_t is array (0 to DEPTH-1) of std_logic_vector(DATA_WIDTH-1 downto 0);
    signal mem : mem_t;
    attribute ram_style : string;
    attribute ram_style of mem : signal is "block";

    signal wr_ptr : unsigned(ADDR_WIDTH downto 0);
    signal rd_ptr : unsigned(ADDR_WIDTH downto 0);

    signal occ   : unsigned(ADDR_WIDTH downto 0);
    signal empty : std_logic;
    signal full  : std_logic;

    -- Output stage (BRAM dout register + valid bit)
    signal dout_r       : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal dout_valid_r : std_logic;

    signal pop        : std_logic;
    signal issue_read : std_logic;
    signal push_ok    : std_logic;

begin

    occ   <= wr_ptr - rd_ptr;
    empty <= '1' when occ = 0 else '0';
    full  <= '1' when occ = to_unsigned(DEPTH, ADDR_WIDTH+1) else '0';

    pop        <= dout_valid_r and rd_en;
    issue_read <= (not empty) and ((not dout_valid_r) or pop);

    -- Push gating: accept the write if there is room, or if a slot is being
    -- freed this cycle by issue_read.
    push_ok <= wr_en and ((not full) or issue_read);

    process (clk)
    begin
        if rising_edge(clk) then
            if push_ok = '1' then
                mem(to_integer(wr_ptr(ADDR_WIDTH-1 downto 0))) <= wr_data;
            end if;
        end if;
    end process;

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            wr_ptr <= (others => '0');
        elsif rising_edge(clk) then
            if push_ok = '1' then
                wr_ptr <= wr_ptr + 1;
            end if;
        end if;
    end process;

    process (clk)
    begin
        if rising_edge(clk) then
            if issue_read = '1' then
                dout_r <= mem(to_integer(rd_ptr(ADDR_WIDTH-1 downto 0)));
            end if;
        end if;
    end process;

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            rd_ptr       <= (others => '0');
            dout_valid_r <= '0';
        elsif rising_edge(clk) then
            if issue_read = '1' then
                rd_ptr       <= rd_ptr + 1;
                dout_valid_r <= '1';
            elsif pop = '1' then
                dout_valid_r <= '0';
            end if;
        end if;
    end process;

    rd_data     <= dout_r;
    rd_valid    <= dout_valid_r;
    rd_empty    <= empty and (not dout_valid_r);
    wr_full     <= full;
    count       <= std_logic_vector(occ);
    wr_overflow <= wr_en and (not push_ok);

end architecture rtl;
