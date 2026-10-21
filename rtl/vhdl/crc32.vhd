-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- crc32.vhd - Ethernet CRC-32 (IEEE 802.3), byte-at-a-time
-- Polynomial: 0x04C11DB7 (reflected: 0xEDB88320)
-- VHDL port of rtl/crc32.v (formally proven equivalent; see sim/parity/).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity crc32 is
    port (
        clk        : in  std_logic;
        rst_n      : in  std_logic;
        data_in    : in  std_logic_vector(7 downto 0);
        data_valid : in  std_logic;
        crc_init   : in  std_logic;                      -- pulse to reset CRC to 0xFFFFFFFF
        crc_out    : out std_logic_vector(31 downto 0);  -- current CRC (bit-reversed, inverted)
        crc_raw    : out std_logic_vector(31 downto 0)   -- raw CRC register value
    );
end entity crc32;

architecture rtl of crc32 is

    signal crc_reg  : std_logic_vector(31 downto 0);
    signal crc_next : std_logic_vector(31 downto 0);

    -- Byte-at-a-time CRC calculation (LSB-first / reflected)
    -- Processes one byte per clock, XORing bit-by-bit through the polynomial
    function crc_step(crc_in : std_logic_vector(31 downto 0);
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
    end function crc_step;

begin

    crc_next <= crc_step(crc_reg, data_in);

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            crc_reg <= x"FFFFFFFF";
        elsif rising_edge(clk) then
            if crc_init = '1' then
                crc_reg <= x"FFFFFFFF";
            elsif data_valid = '1' then
                crc_reg <= crc_next;
            end if;
        end if;
    end process;

    -- Final CRC: invert (complement) the register
    -- Bit order: transmitted LSB-first, so we bit-reverse each byte
    crc_raw <= crc_reg;
    crc_out <= not crc_reg;

end architecture rtl;
