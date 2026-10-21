-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- xpm_memory_sdpram_model.vhd - Simulation model for Xilinx xpm_memory_sdpram
--
-- VHDL-93 twin of sim/tb/xpm_memory_sdpram_model.v (the model the
-- MII-RX-REPLAY-STRESS bench builds with -DXILINX_7SERIES), full size: the
-- memory has MEMORY_SIZE / READ_DATA_WIDTH_B words. Like the Verilog it covers
-- the simple-dual-port, READ_LATENCY_B=1 configuration that mii_if uses for
-- the RX frame buffer: write port A, 1-cycle registered read on port B, both
-- ports clocked by their own clock. rstb, regceb, sleep, READ_LATENCY_B,
-- WRITE_MODE_B, CLOCKING_MODE and every other generic are ignored, as in the
-- Verilog.
--
-- The generics and ports are those of the xpm_memory_sdpram component that
-- rtl/vhdl/mii_if.vhd declares (Vivado's xpm_VCOMP.vhd), so that declaration
-- binds to this entity by default. Defaults follow the Verilog model where it
-- has the parameter.
--
-- Verilog array semantics kept: a write to an address past the end or with an
-- unknown bit is dropped; such a read returns all 'X'. "wea != 0" is true when
-- any wea bit is '1'.
-- NOT the vendor model. Equivalence with the Verilog model:
-- sim/parity/harness_xpm_models/.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity xpm_memory_sdpram is
    generic (
        MEMORY_SIZE             : integer := 2048;
        MEMORY_PRIMITIVE        : string  := "auto";
        CLOCKING_MODE           : string  := "common_clock";
        ECC_MODE                : string  := "no_ecc";
        ECC_TYPE                : string  := "none";
        ECC_BIT_RANGE           : string  := "[7:0]";
        MEMORY_INIT_FILE        : string  := "none";
        MEMORY_INIT_PARAM       : string  := "0";
        USE_MEM_INIT            : integer := 1;
        USE_MEM_INIT_MMI        : integer := 0;
        WAKEUP_TIME             : string  := "disable_sleep";
        AUTO_SLEEP_TIME         : integer := 0;
        MESSAGE_CONTROL         : integer := 0;
        USE_EMBEDDED_CONSTRAINT : integer := 0;
        MEMORY_OPTIMIZATION     : string  := "true";
        CASCADE_HEIGHT          : integer := 0;
        SIM_ASSERT_CHK          : integer := 0;
        WRITE_PROTECT           : integer := 1;
        RAM_DECOMP              : string  := "auto";
        IGNORE_INIT_SYNTH       : integer := 0;
        WRITE_DATA_WIDTH_A      : integer := 32;
        BYTE_WRITE_WIDTH_A      : integer := 32;
        ADDR_WIDTH_A            : integer := 6;
        RST_MODE_A              : string  := "SYNC";
        READ_DATA_WIDTH_B       : integer := 32;
        ADDR_WIDTH_B            : integer := 6;
        READ_RESET_VALUE_B      : string  := "0";
        READ_LATENCY_B          : integer := 2;
        WRITE_MODE_B            : string  := "no_change";
        RST_MODE_B              : string  := "SYNC"
    );
    port (
        sleep          : in  std_logic;
        clka           : in  std_logic;
        ena            : in  std_logic;
        wea            : in  std_logic_vector((WRITE_DATA_WIDTH_A/BYTE_WRITE_WIDTH_A)-1 downto 0);
        addra          : in  std_logic_vector(ADDR_WIDTH_A-1 downto 0);
        dina           : in  std_logic_vector(WRITE_DATA_WIDTH_A-1 downto 0);
        injectsbiterra : in  std_logic;
        injectdbiterra : in  std_logic;
        clkb           : in  std_logic;
        rstb           : in  std_logic;
        enb            : in  std_logic;
        regceb         : in  std_logic;
        addrb          : in  std_logic_vector(ADDR_WIDTH_B-1 downto 0);
        doutb          : out std_logic_vector(READ_DATA_WIDTH_B-1 downto 0);
        sbiterrb       : out std_logic;
        dbiterrb       : out std_logic
    );
end entity xpm_memory_sdpram;

architecture model of xpm_memory_sdpram is

    constant DEPTH : integer := MEMORY_SIZE / READ_DATA_WIDTH_B;

    -- Verilog "wea != 0": true iff some bit is a known '1'.
    function any_one(v : std_logic_vector) return boolean is
    begin
        for i in v'range loop
            if v(i) = '1' then
                return true;
            end if;
        end loop;
        return false;
    end function any_one;

    -- True when an address selects an existing word.
    function in_range(a : std_logic_vector) return boolean is
    begin
        if Is_X(a) then
            return false;
        end if;
        return to_integer(unsigned(a)) < DEPTH;
    end function in_range;

    type mem_t is array (0 to DEPTH-1) of std_logic_vector(READ_DATA_WIDTH_B-1 downto 0);
    signal mem     : mem_t;
    signal doutb_r : std_logic_vector(READ_DATA_WIDTH_B-1 downto 0);
begin
    doutb    <= doutb_r;
    sbiterrb <= '0';
    dbiterrb <= '0';

    -- Write port A: whole-word write when enabled (wea covers the full word).
    process (clka)
    begin
        if rising_edge(clka) then
            if ena = '1' and any_one(wea) then
                if in_range(addra) then
                    mem(to_integer(unsigned(addra))) <=
                        std_logic_vector(resize(unsigned(dina), READ_DATA_WIDTH_B));
                end if;
            end if;
        end if;
    end process;

    -- Read port B: 1-cycle registered read (READ_LATENCY_B == 1).
    process (clkb)
    begin
        if rising_edge(clkb) then
            if enb = '1' then
                if in_range(addrb) then
                    doutb_r <= mem(to_integer(unsigned(addrb)));
                else
                    doutb_r <= (others => 'X');
                end if;
            end if;
        end if;
    end process;

end architecture model;
