-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- clk_gen.vhd - Clock generator for Arty A7 Ethernet test
-- Uses MMCME2_BASE to produce 25 MHz from 100 MHz input.
-- VCO = 100 MHz * 10 = 1000 MHz, CLKOUT0 = 1000 / 40 = 25 MHz.
-- The Xilinx primitives are declared as local components (no library unisim),
-- so the file analyses without vendor libraries; Vivado binds them to unisim.
-- VHDL port of fpga/arty_a7/rtl/clk_gen.v (formally proven equivalent; see
-- sim/parity/).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

-- VHDL-93 binds a component instance by default only to a directly visible
-- entity of the same name. This makes simulation models of the primitives
-- compiled into work (sim/parity/clk_gen/) bind; Vivado binds the real
-- primitives by name either way.
use work.all;

entity clk_gen is
    port (
        clk_in : in  std_logic;     -- 100 MHz input
        clk_25 : out std_logic;     -- 25 MHz output
        locked : out std_logic      -- MMCM lock indicator
    );
end entity clk_gen;

architecture rtl of clk_gen is

    -- Xilinx 7-series MMCM (unisim). Generic names, types and defaults follow
    -- unisim_VCOMP.vhd; STARTUP_WAIT and CLKOUT4_CASCADE are boolean there
    -- (the Verilog model takes the strings "FALSE"/"TRUE").
    component MMCME2_BASE is
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
    end component MMCME2_BASE;

    -- Xilinx global clock buffer (unisim).
    component BUFG is
        port (
            O : out std_ulogic;
            I : in  std_ulogic
        );
    end component BUFG;

    signal clk_25_buf : std_logic;
    signal clkfb      : std_logic;
    signal clkfb_buf  : std_logic;

begin

    u_mmcm : MMCME2_BASE
        generic map (
            BANDWIDTH          => "OPTIMIZED",
            CLKFBOUT_MULT_F    => 10.0,     -- VCO = 100 * 10 = 1000 MHz
            CLKFBOUT_PHASE     => 0.0,
            CLKIN1_PERIOD      => 10.0,     -- 100 MHz
            CLKOUT0_DIVIDE_F   => 40.0,     -- 1000 / 40 = 25 MHz
            CLKOUT0_PHASE      => 0.0,
            CLKOUT0_DUTY_CYCLE => 0.5,
            DIVCLK_DIVIDE      => 1,
            REF_JITTER1        => 0.010,
            STARTUP_WAIT       => FALSE
        )
        port map (
            CLKIN1    => clk_in,
            CLKFBIN   => clkfb_buf,
            CLKFBOUT  => clkfb,
            CLKOUT0   => clk_25_buf,
            CLKOUT1   => open,
            CLKOUT2   => open,
            CLKOUT3   => open,
            CLKOUT4   => open,
            CLKOUT5   => open,
            CLKOUT6   => open,
            CLKFBOUTB => open,
            CLKOUT0B  => open,
            CLKOUT1B  => open,
            CLKOUT2B  => open,
            CLKOUT3B  => open,
            LOCKED    => locked,
            PWRDWN    => '0',
            RST       => '0'
        );

    u_bufg_fb : BUFG port map (I => clkfb,      O => clkfb_buf);
    u_bufg_25 : BUFG port map (I => clk_25_buf, O => clk_25);

end architecture rtl;
