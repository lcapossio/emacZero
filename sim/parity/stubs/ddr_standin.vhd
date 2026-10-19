-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- ddr_standin.vhd - Parity-only stateless stand-ins for ddr_output / ddr_input.
-- Line-for-line twin of ddr_standin.v (read on the golden side); see that file
-- for why the stand-ins carry no state.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity ddr_output is
    port (
        clk : in  std_logic;
        d1  : in  std_logic;
        d2  : in  std_logic;
        q   : out std_logic
    );
end entity ddr_output;

architecture standin of ddr_output is
begin
    q <= d1 when clk = '1' else d2;
end architecture standin;

library ieee;
use ieee.std_logic_1164.all;

entity ddr_input is
    port (
        clk : in  std_logic;
        d   : in  std_logic;
        q1  : out std_logic;
        q2  : out std_logic
    );
end entity ddr_input;

architecture standin of ddr_input is
begin
    q1 <= d;
    q2 <= d xor clk;
end architecture standin;
