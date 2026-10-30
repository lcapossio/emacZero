-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- xilinx_io_standin.vhd - Parity-only stand-ins for IOBUF, IDELAYE2 and
-- IDELAYCTRL (VHDL side; xilinx_io_standin.v is the Verilog twin). Read
-- identically by both sides of the rgmii_lb_selftest proof in place of unisim.
--
-- IDELAYE2 keeps a register `st` clocked by C, and IDELAYCTRL one clocked by
-- REFCLK (no reset, no initial value, so each pairs by name and starts free).
-- The next value is `st` rotated by one XOR {inputs, fingerprint}: every
-- input pin sits above a fingerprint of every parameter at full width, so a
-- pin can never cancel a parameter. In the fingerprint: each integer in its
-- own 32-bit field, REFCLK_FREQUENCY as round(value * 1000) in 32 bits, each
-- IS_*_INVERTED bit as itself, and each string parameter as one bit per legal
-- value. Distinct legal values give distinct fingerprints, with two limits:
-- the real is compared only to 0.001, and an illegal string sets no bit.
-- Each bit i also XORs in st[i+40] AND st[i+80] (mod 126; IDELAYCTRL: st[i+1]
-- AND st[i+2] mod 3), bits no output shows, so no output is a delayed copy
-- of another (with the rotation alone CNTVALUEOUT[0] was DATAOUT one cycle
-- late). Every output is its own bit of `st`. Nothing about real IDELAY
-- behaviour is modelled: DATAOUT is not IDATAIN delayed, only a register
-- that IDATAIN and every other input feed.
--
-- IOBUF is a plain tri-state buffer, as on silicon (O reads the pad). The
-- proof's L2 runs on a split model with no IOBUF (translateHDL does not model
-- inout ports; see sim/parity/rgmii_lb_selftest/gen_split.py); L0, L1 and L4
-- read this one.
-- Keep the two files in step by hand.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity IOBUF is
    port (
        O  : out   std_ulogic;
        IO : inout std_ulogic;
        I  : in    std_ulogic;
        T  : in    std_ulogic
    );
end entity IOBUF;

architecture standin of IOBUF is
begin
    IO <= 'Z' when T = '1' else I;
    O  <= IO;
end architecture standin;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity IDELAYE2 is
    generic (
        CINVCTRL_SEL          : string  := "FALSE";
        DELAY_SRC             : string  := "IDATAIN";
        HIGH_PERFORMANCE_MODE : string  := "FALSE";
        IDELAY_TYPE           : string  := "FIXED";
        IDELAY_VALUE          : integer := 0;
        IS_C_INVERTED         : bit     := '0';
        IS_DATAIN_INVERTED    : bit     := '0';
        IS_IDATAIN_INVERTED   : bit     := '0';
        PIPE_SEL              : string  := "FALSE";
        REFCLK_FREQUENCY      : real    := 200.0;
        SIGNAL_PATTERN        : string  := "DATA";
        SIM_DELAY_D           : integer := 0
    );
    port (
        CNTVALUEOUT : out std_logic_vector(4 downto 0);
        DATAOUT     : out std_ulogic;
        C           : in  std_ulogic;
        CE          : in  std_ulogic;
        CINVCTRL    : in  std_ulogic;
        CNTVALUEIN  : in  std_logic_vector(4 downto 0);
        DATAIN      : in  std_ulogic;
        IDATAIN     : in  std_ulogic;
        INC         : in  std_ulogic;
        LD          : in  std_ulogic;
        LDPIPEEN    : in  std_ulogic;
        REGRST      : in  std_ulogic
    );
end entity IDELAYE2;

architecture standin of IDELAYE2 is
    function b(x : boolean) return std_logic_vector is
    begin
        if x then return "1"; end if;
        return "0";
    end function b;
    function bt(x : bit) return std_logic_vector is
    begin
        return b(x = '1');
    end function bt;
    function r32(x : real) return std_logic_vector is
    begin
        return std_logic_vector(to_signed(integer(x * 1000.0), 32));
    end function r32;
    function i32(x : integer) return std_logic_vector is
    begin
        return std_logic_vector(to_signed(x, 32));
    end function i32;
    constant GEN_FP : std_logic_vector(112 downto 0) :=
        i32(SIM_DELAY_D) &
        b(SIGNAL_PATTERN = "CLOCK") & b(SIGNAL_PATTERN = "DATA") &
        r32(REFCLK_FREQUENCY) &
        b(PIPE_SEL = "TRUE") & b(PIPE_SEL = "FALSE") &
        bt(IS_IDATAIN_INVERTED) & bt(IS_DATAIN_INVERTED) & bt(IS_C_INVERTED) &
        i32(IDELAY_VALUE) &
        b(IDELAY_TYPE = "VAR_LOAD_PIPE") & b(IDELAY_TYPE = "VAR_LOAD") &
        b(IDELAY_TYPE = "VARIABLE") & b(IDELAY_TYPE = "FIXED") &
        b(HIGH_PERFORMANCE_MODE = "TRUE") & b(HIGH_PERFORMANCE_MODE = "FALSE") &
        b(DELAY_SRC = "DATAIN") & b(DELAY_SRC = "IDATAIN") &
        b(CINVCTRL_SEL = "TRUE") & b(CINVCTRL_SEL = "FALSE");
    signal st : std_logic_vector(125 downto 0);
begin
    process (C)
    begin
        if rising_edge(C) then
            st <= (st(124 downto 0) & st(125)) xor
                  (REGRST & LDPIPEEN & LD & INC & IDATAIN & DATAIN &
                   CNTVALUEIN & CINVCTRL & CE & GEN_FP) xor
                  ((st(39 downto 0) & st(125 downto 40)) and
                   (st(79 downto 0) & st(125 downto 80)));
        end if;
    end process;

    DATAOUT     <= st(0);
    CNTVALUEOUT <= st(5 downto 1);
end architecture standin;

library ieee;
use ieee.std_logic_1164.all;

entity IDELAYCTRL is
    generic (
        SIM_DEVICE : string := "7SERIES"
    );
    port (
        RDY    : out std_ulogic;
        REFCLK : in  std_ulogic;
        RST    : in  std_ulogic
    );
end entity IDELAYCTRL;

architecture standin of IDELAYCTRL is
    function b(c : boolean) return std_logic_vector is
    begin
        if c then return "1"; end if;
        return "0";
    end function b;
    constant GEN_FP : std_logic_vector(1 downto 0) :=
        b(SIM_DEVICE = "ULTRASCALE") & b(SIM_DEVICE = "7SERIES");
    signal st : std_logic_vector(2 downto 0);
begin
    process (REFCLK)
    begin
        if rising_edge(REFCLK) then
            st <= (st(1 downto 0) & st(2)) xor (RST & GEN_FP) xor
                  ((st(0) & st(2 downto 1)) and (st(1 downto 0) & st(2)));
        end if;
    end process;

    RDY <= st(0);
end architecture standin;
