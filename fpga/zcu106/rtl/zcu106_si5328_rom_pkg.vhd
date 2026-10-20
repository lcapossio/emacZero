-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- zcu106_si5328_rom_pkg.vhd - I2C writes that set the ZCU106 Si5328 (U20) to
-- 125 MHz for the SFP GTH reference clock (Quad 225 MGTREFCLK1, W10/W9).
-- UG1244 routes CKOUT1 there, but some board notes name CKOUT2, so both
-- outputs are enabled and both are set to 125 MHz.
-- Used by i2c_init.vhd. Only used when zcu106_top has REFCLK_SI5328 = 1.
-- VHDL mirror of fpga/zcu106/rtl/zcu106_si5328_rom.vh, which i2c_init.v
-- includes (the formal proof of i2c_init.vhd covers the table; edit both
-- files together, sim/parity/i2c_init/check_rom.py fails if they differ).
--
-- Bus: PL IIC1 -> TCA9548A U34 at 0x74, channel 4 (control byte 0x10).
-- Si5328 7-bit address: the ZCU106 user guide (UG1244) lists 0x68, while the
-- rev 1.0 schematic (A0 pulled up) and the Linux zcu106 device tree use 0x69.
-- i2c_init alternates `alt` on every retry, so the list is tried at 0x69
-- first and at 0x68 on the next pass; the part that ACKs gets programmed.
--
-- Free-run from the 114.285 MHz XA/XB crystal (routed to CKIN2 by FREE_RUN):
--   N31 = N32 = 4565  -> f3   = 114.285 MHz / 4565    = 25.035 kHz
--   N2  = 10 x 19972  -> fosc = f3 x 199720           = 5.000 GHz
--   N1  = 10 x 4      -> CKOUT1 = CKOUT2 = fosc / 40  = 125.000 MHz
-- These are the divider values ARTIQ uses for 125 MHz from the same crystal
-- (m-labs/artiq, rtio_clocking.rs, "Int_125"), with BWSEL = 4. Register
-- fields per the Si5328 datasheet. Verified on hardware: the si5328 build
-- passes the SFP0 <-> SFP1 loopback tests (fpga/zcu106/README.md).
--
-- Entry format: {last[1:0], b0, b1, b2}; b0 is the address+W byte and `last`
-- is the index of the final byte (1 = 2-byte write, 2 = 3-byte write).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package zcu106_si5328_rom_pkg is

    constant ROM_LEN : integer := 28;

    function rom_entry (i : std_logic_vector(15 downto 0); alt : std_logic)
        return std_logic_vector;

end package zcu106_si5328_rom_pkg;

package body zcu106_si5328_rom_pkg is

    -- 8'dN
    function d8 (n : integer) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned(n, 8));
    end function d8;

    -- {last[1:0], b0, b1, b2}
    function ent (last : integer; b0, b1, b2 : std_logic_vector(7 downto 0))
        return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned(last, 2)) & b0 & b1 & b2;
    end function ent;

    function rom_entry (i : std_logic_vector(15 downto 0); alt : std_logic)
        return std_logic_vector is
        variable si : std_logic_vector(7 downto 0);
        variable e  : std_logic_vector(25 downto 0);
    begin
        -- 0: Si5328 at 0x69, 1: at 0x68
        if alt = '1' then si := x"D0"; else si := x"D2"; end if;  -- 0x68 / 0x69, write
        case to_integer(unsigned(i)) is
        -- TCA9548A U34 (0x74): enable channel 4 only
        when 0  => e := ent(1, x"E8", x"10", x"00");
        -- Si5328 {register, value}
        when 1  => e := ent(2, si, d8(0),   x"54");  -- FREE_RUN=1
        when 2  => e := ent(2, si, d8(1),   x"E4");  -- CK_PRIOR default
        when 3  => e := ent(2, si, d8(2),   x"42");  -- BWSEL_REG=4
        when 4  => e := ent(2, si, d8(3),   x"55");  -- CKSEL_REG=CKIN2, SQ_ICAL=1
        when 5  => e := ent(2, si, d8(4),   x"12");  -- AUTOSEL_REG=manual
        when 6  => e := ent(2, si, d8(6),   x"3F");  -- SFOUT1/2 = LVDS
        when 7  => e := ent(2, si, d8(10),  x"00");  -- CKOUT1 and CKOUT2 enabled
        when 8  => e := ent(2, si, d8(11),  x"40");
        when 9  => e := ent(2, si, d8(21),  x"FE");  -- CKSEL_PIN=0 (use CKSEL_REG)
        when 10 => e := ent(2, si, d8(25),  x"C0");  -- N1_HS=10
        when 11 => e := ent(2, si, d8(31),  x"00");  -- NC1_LS=4 (value-1 = 3)
        when 12 => e := ent(2, si, d8(32),  x"00");
        when 13 => e := ent(2, si, d8(33),  x"03");
        when 14 => e := ent(2, si, d8(34),  x"00");  -- NC2_LS=4
        when 15 => e := ent(2, si, d8(35),  x"00");
        when 16 => e := ent(2, si, d8(36),  x"03");
        when 17 => e := ent(2, si, d8(40),  x"C0");  -- N2_HS=10, N2_LS=19972 (0x4E03+1)
        when 18 => e := ent(2, si, d8(41),  x"4E");
        when 19 => e := ent(2, si, d8(42),  x"03");
        when 20 => e := ent(2, si, d8(43),  x"00");  -- N31=4565 (0x11D4+1)
        when 21 => e := ent(2, si, d8(44),  x"11");
        when 22 => e := ent(2, si, d8(45),  x"D4");
        when 23 => e := ent(2, si, d8(46),  x"00");  -- N32=4565
        when 24 => e := ent(2, si, d8(47),  x"11");
        when 25 => e := ent(2, si, d8(48),  x"D4");
        when 26 => e := ent(2, si, d8(137), x"01");  -- FASTLOCK=1
        when others => e := ent(2, si, d8(136), x"40");  -- ICAL: calibrate, last
        end case;
        return e;
    end function rom_entry;

end package body zcu106_si5328_rom_pkg;
