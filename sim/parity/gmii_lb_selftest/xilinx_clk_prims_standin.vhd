-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- xilinx_clk_prims_standin.vhd - Parity-only stand-ins for the Xilinx clocking
-- primitives MMCME2_BASE and BUFG (7-series unisim). Analysed into work on the
-- VHDL (candidate) side, so the local component declarations in
-- fpga/arty_a7/rtl/gmii_lb_selftest.vhd bind to them by default.
-- Line-for-line twin of xilinx_clk_prims_standin.v (read on the golden side);
-- see that file for what is and is not modelled. Generic and port types
-- follow unisim_VCOMP.vhd (only the generics gmii_lb_selftest sets).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity MMCME2_BASE is
    generic (
        CLKFBOUT_MULT_F  : real    := 5.000;
        CLKIN1_PERIOD    : real    := 0.000;
        CLKOUT0_DIVIDE_F : real    := 1.000;
        DIVCLK_DIVIDE    : integer := 1
    );
    port (
        CLKFBOUT  : out std_ulogic;
        CLKFBOUTB : out std_ulogic;
        CLKOUT0   : out std_ulogic;
        CLKOUT0B  : out std_ulogic;
        CLKOUT1   : out std_ulogic;
        CLKOUT1B  : out std_ulogic;
        CLKOUT2   : out std_ulogic;
        CLKOUT2B  : out std_ulogic;
        CLKOUT3   : out std_ulogic;
        CLKOUT3B  : out std_ulogic;
        CLKOUT4   : out std_ulogic;
        CLKOUT5   : out std_ulogic;
        CLKOUT6   : out std_ulogic;
        LOCKED    : out std_ulogic;
        CLKFBIN   : in  std_ulogic;
        CLKIN1    : in  std_ulogic;
        PWRDWN    : in  std_ulogic;
        RST       : in  std_ulogic
    );
end entity MMCME2_BASE;

architecture standin of MMCME2_BASE is
    constant FP_FB  : integer := integer(CLKFBOUT_MULT_F * 8.0);
    constant FP_IN  : integer := integer(CLKIN1_PERIOD * 8.0);
    constant FP_O0  : integer := integer(CLKOUT0_DIVIDE_F * 8.0);
    constant GEN_FP : std_logic_vector(31 downto 0) :=
        std_logic_vector(to_unsigned(DIVCLK_DIVIDE, 8)) &
        std_logic_vector(to_unsigned(FP_O0, 8)) &
        std_logic_vector(to_unsigned(FP_IN, 8)) &
        std_logic_vector(to_unsigned(FP_FB, 8));

    signal lk : std_logic_vector(31 downto 0);
begin
    process (CLKIN1, RST)
    begin
        if RST = '1' then
            lk <= (others => '0');
        elsif rising_edge(CLKIN1) then
            lk <= (lk(30 downto 0) & lk(31)) xor GEN_FP xor
                  (std_logic_vector(to_unsigned(0, 31)) & PWRDWN);
        end if;
    end process;

    CLKFBOUT  <= CLKIN1;
    CLKFBOUTB <= '0';
    CLKOUT0   <= CLKIN1 and CLKFBIN;
    CLKOUT0B  <= '0';
    CLKOUT1   <= '0';
    CLKOUT1B  <= '0';
    CLKOUT2   <= '0';
    CLKOUT2B  <= '0';
    CLKOUT3   <= '0';
    CLKOUT3B  <= '0';
    CLKOUT4   <= '0';
    CLKOUT5   <= '0';
    CLKOUT6   <= '0';
    LOCKED    <= lk(0);
end architecture standin;

library ieee;
use ieee.std_logic_1164.all;

entity BUFG is
    port (
        O : out std_ulogic;
        I : in  std_ulogic
    );
end entity BUFG;

architecture standin of BUFG is
begin
    O <= I;
end architecture standin;
