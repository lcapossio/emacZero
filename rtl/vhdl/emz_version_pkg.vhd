-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- emz_version_pkg.vhd - VHDL mirror of rtl/version.vh (core version, reg 1).
-- Keep in step with rtl/version.vh; build_and_test.py checks they agree.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

package emz_version_pkg is
    constant EMZ_VERSION_MAJOR : std_logic_vector(7 downto 0)  := x"00";
    constant EMZ_VERSION_MINOR : std_logic_vector(7 downto 0)  := x"02";
    constant EMZ_VERSION_ID    : std_logic_vector(15 downto 0) := x"454D";  -- ASCII "EM"
end package emz_version_pkg;
