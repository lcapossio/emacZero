-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- xilinx_clk_standin.v - Parity-only stand-ins for MMCME2_BASE and BUFG (VHDL
-- side; xilinx_clk_standin.v is the Verilog twin). Read identically by both
-- sides of the clk_gen and gmii_lb_selftest proofs in place of unisim.
--
-- MMCME2_BASE keeps a register `st` clocked by CLKIN1 (no reset, no initial
-- value, so it pairs by name and starts free) whose next value is `st`
-- rotated by one, XOR RST and PWRDWN at bits 0 and 1, XOR a fingerprint of
-- every parameter at full width: each real parameter as round(value * 1000)
-- in its own 32-bit field, each integer in its own 32-bit field, BANDWIDTH and
-- the two booleans as one bit per value. Distinct parameter values give
-- distinct fingerprints, so a wrong value on either side diverges (`st` is a
-- paired state point). Every output is its own bit of `st`; CLKOUT0 also XORs
-- CLKFBIN, so the feedback connection is checked. The output clocks are
-- therefore state, not the input clock: a process clocked from CLKOUT0 has
-- different edges from one clocked from CLKIN1, and moving logic between the
-- two domains diverges. Nothing about real MMCM behaviour is modelled.
-- BUFG is a wire, as on silicon.
-- Generated once by a script; keep the two files in step by hand.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

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

architecture standin of MMCME2_BASE is
    function b(c : boolean) return std_logic_vector is
    begin
        if c then return "1"; end if;
        return "0";
    end function b;
    function r32(x : real) return std_logic_vector is
    begin
        return std_logic_vector(to_signed(integer(x * 1000.0), 32));
    end function r32;
    function i32(x : integer) return std_logic_vector is
    begin
        return std_logic_vector(to_signed(x, 32));
    end function i32;
    constant GEN_FP : std_logic_vector(839 downto 0) :=
        "000" &
        b(STARTUP_WAIT) &
        r32(REF_JITTER1) &
        i32(DIVCLK_DIVIDE) &
        r32(CLKOUT6_PHASE) &
        r32(CLKOUT6_DUTY_CYCLE) &
        i32(CLKOUT6_DIVIDE) &
        r32(CLKOUT5_PHASE) &
        r32(CLKOUT5_DUTY_CYCLE) &
        i32(CLKOUT5_DIVIDE) &
        r32(CLKOUT4_PHASE) &
        r32(CLKOUT4_DUTY_CYCLE) &
        i32(CLKOUT4_DIVIDE) &
        b(CLKOUT4_CASCADE) &
        r32(CLKOUT3_PHASE) &
        r32(CLKOUT3_DUTY_CYCLE) &
        i32(CLKOUT3_DIVIDE) &
        r32(CLKOUT2_PHASE) &
        r32(CLKOUT2_DUTY_CYCLE) &
        i32(CLKOUT2_DIVIDE) &
        r32(CLKOUT1_PHASE) &
        r32(CLKOUT1_DUTY_CYCLE) &
        i32(CLKOUT1_DIVIDE) &
        r32(CLKOUT0_PHASE) &
        r32(CLKOUT0_DUTY_CYCLE) &
        r32(CLKOUT0_DIVIDE_F) &
        r32(CLKIN1_PERIOD) &
        r32(CLKFBOUT_PHASE) &
        r32(CLKFBOUT_MULT_F) &
        b(BANDWIDTH = "HIGH") & b(BANDWIDTH = "LOW") & b(BANDWIDTH = "OPTIMIZED");
    signal st : std_logic_vector(839 downto 0);
begin
    process (CLKIN1)
    begin
        if rising_edge(CLKIN1) then
            st <= (st(838 downto 0) & st(839)) xor GEN_FP xor
                  (std_logic_vector(to_unsigned(0, 838)) & PWRDWN & RST);
        end if;
    end process;

    CLKFBOUT  <= st(0);
    CLKFBOUTB <= st(1);
    CLKOUT0   <= st(2) xor CLKFBIN;
    CLKOUT0B  <= st(3);
    CLKOUT1   <= st(4);
    CLKOUT1B  <= st(5);
    CLKOUT2   <= st(6);
    CLKOUT2B  <= st(7);
    CLKOUT3   <= st(8);
    CLKOUT3B  <= st(9);
    CLKOUT4   <= st(10);
    CLKOUT5   <= st(11);
    CLKOUT6   <= st(12);
    LOCKED    <= st(13);
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
