-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- xilinx_clk_prims.vhd - Parity-only stand-ins for the Xilinx clocking
-- primitives MMCME2_BASE and BUFG (7-series).
-- Analysed into work on the VHDL (candidate) side of the clk_gen proof, so the
-- local component declarations in fpga/arty_a7/rtl/clk_gen.vhd bind to them by
-- default. Line-for-line twin of xilinx_clk_prims.v (read on the golden side);
-- see that file for what is and is not modelled. Generic names, types and
-- defaults follow unisim_VCOMP.vhd.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity MMCME2_BASE is
    generic (
        BANDWIDTH          : string  := "OPTIMIZED";
        CLKFBOUT_MULT_F    : real    := 5.000;
        CLKFBOUT_PHASE     : real    := 0.000;
        CLKIN1_PERIOD      : real    := 0.000;
        CLKOUT0_DIVIDE_F   : real    := 1.000;
        CLKOUT0_DUTY_CYCLE : real    := 0.500;
        CLKOUT0_PHASE      : real    := 0.000;
        CLKOUT1_DIVIDE     : integer := 1;
        CLKOUT1_DUTY_CYCLE : real    := 0.500;
        CLKOUT1_PHASE      : real    := 0.000;
        CLKOUT2_DIVIDE     : integer := 1;
        CLKOUT2_DUTY_CYCLE : real    := 0.500;
        CLKOUT2_PHASE      : real    := 0.000;
        CLKOUT3_DIVIDE     : integer := 1;
        CLKOUT3_DUTY_CYCLE : real    := 0.500;
        CLKOUT3_PHASE      : real    := 0.000;
        CLKOUT4_CASCADE    : boolean := FALSE;
        CLKOUT4_DIVIDE     : integer := 1;
        CLKOUT4_DUTY_CYCLE : real    := 0.500;
        CLKOUT4_PHASE      : real    := 0.000;
        CLKOUT5_DIVIDE     : integer := 1;
        CLKOUT5_DUTY_CYCLE : real    := 0.500;
        CLKOUT5_PHASE      : real    := 0.000;
        CLKOUT6_DIVIDE     : integer := 1;
        CLKOUT6_DUTY_CYCLE : real    := 0.500;
        CLKOUT6_PHASE      : real    := 0.000;
        DIVCLK_DIVIDE      : integer := 1;
        REF_JITTER1        : real    := 0.010;
        STARTUP_WAIT       : boolean := FALSE
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

architecture stub of MMCME2_BASE is
begin
    CLKFBOUT  <= CLKIN1 xor RST;
    CLKOUT0   <= not (CLKFBIN xor PWRDWN);
    LOCKED    <= CLKFBIN xor PWRDWN xor RST;
    CLKFBOUTB <= '0';
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
end architecture stub;

library ieee;
use ieee.std_logic_1164.all;

entity BUFG is
    port (
        O : out std_ulogic;
        I : in  std_ulogic
    );
end entity BUFG;

architecture stub of BUFG is
begin
    O <= I;
end architecture stub;
