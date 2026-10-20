-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- uart_tx.vhd - Simple UART transmitter (115200 baud, 8N1)
-- VHDL port of fpga/arty_a7/rtl/uart_tx.v (formally proven equivalent; see
-- sim/parity/).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_tx is
    generic (
        CLK_FREQ : integer := 100000000;
        BAUD     : integer := 115200
    );
    port (
        clk        : in  std_logic;
        rst_n      : in  std_logic;
        data       : in  std_logic_vector(7 downto 0);
        data_valid : in  std_logic;
        busy       : out std_logic;
        txd        : out std_logic
    );
end entity uart_tx;

architecture rtl of uart_tx is

    constant DIVISOR : integer := CLK_FREQ / BAUD;  -- 868 for 100MHz/115200

    signal shift_reg : std_logic_vector(9 downto 0);  -- start(0) + 8 data + stop(1)
    signal bit_cnt   : unsigned(3 downto 0);
    signal clk_cnt   : unsigned(15 downto 0);

    -- busy is read back by the transmitter.
    signal busy_i    : std_logic;

begin

    busy <= busy_i;

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            shift_reg <= (others => '1');  -- 10'h3FF
            bit_cnt   <= (others => '0');
            clk_cnt   <= (others => '0');
            busy_i    <= '0';
            txd       <= '1';
        elsif rising_edge(clk) then
            if busy_i = '0' then
                txd <= '1';
                if data_valid = '1' then
                    shift_reg <= '1' & data & '0';  -- stop + data + start
                    bit_cnt   <= to_unsigned(10, 4);
                    clk_cnt   <= (others => '0');
                    busy_i    <= '1';
                    txd       <= '0';  -- start bit immediately
                end if;
            else
                -- Verilog compares the 16-bit clk_cnt with the 32-bit integer
                -- DIVISOR - 1; an integer compare keeps that (never true when
                -- DIVISOR - 1 does not fit 16 bits).
                if to_integer(clk_cnt) = DIVISOR - 1 then
                    clk_cnt <= (others => '0');
                    if bit_cnt = 1 then
                        -- Done
                        busy_i <= '0';
                        txd    <= '1';
                    else
                        shift_reg <= '1' & shift_reg(9 downto 1);
                        txd       <= shift_reg(1);
                        bit_cnt   <= bit_cnt - 1;
                    end if;
                else
                    clk_cnt <= clk_cnt + 1;
                end if;
            end if;
        end if;
    end process;

end architecture rtl;
