-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- Parity wrapper: async_fifo with RAM_STYLE pinned to "BLOCK", so the
-- integer-only translateHDL param sets can reach that generate branch.
library ieee;
use ieee.std_logic_1164.all;

entity async_fifo_block is
    generic (
        DATA_WIDTH : integer := 9;
        ADDR_WIDTH : integer := 11
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
        wr_data_count : out std_logic_vector(ADDR_WIDTH downto 0)
    );
end entity async_fifo_block;

architecture rtl of async_fifo_block is
begin
    u_fifo : entity work.async_fifo
        generic map (DATA_WIDTH => DATA_WIDTH, ADDR_WIDTH => ADDR_WIDTH, RAM_STYLE => "BLOCK")
        port map (
            wr_clk => wr_clk, wr_rst_n => wr_rst_n, wr_data => wr_data, wr_en => wr_en,
            wr_full => wr_full, rd_clk => rd_clk, rd_rst_n => rd_rst_n, rd_data => rd_data,
            rd_en => rd_en, rd_empty => rd_empty, wr_data_count => wr_data_count
        );
end architecture rtl;
