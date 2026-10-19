-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- ddr_output.vhd - Vendor-agnostic DDR output primitive wrapper
-- Outputs d1 on rising edge, d2 on falling edge.
-- Vendor selection via emz_target_pkg.EMZ_TARGET (compile exactly one
-- rtl/vhdl/target/emz_target_*.vhd): "XILINX_7SERIES",
-- "XILINX_ULTRASCALE_PLUS", "INTEL_CYCLONE", "SIM", or "" (none).
-- The vendor primitives are declared as local components (no library unisim),
-- so the file analyses without vendor libraries.
-- VHDL port of rtl/ddr_output.v (formally proven equivalent; see sim/parity/).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

use work.emz_target_pkg.all;

entity ddr_output is
    port (
        clk : in  std_logic;
        d1  : in  std_logic;    -- data captured on rising edge
        d2  : in  std_logic;    -- data captured on falling edge
        q   : out std_logic     -- DDR output
    );
end entity ddr_output;

architecture rtl of ddr_output is

    -- Xilinx 7-series output DDR (unisim).
    component ODDR is
        generic (
            DDR_CLK_EDGE   : string := "OPPOSITE_EDGE";
            INIT           : bit    := '0';
            IS_C_INVERTED  : bit    := '0';
            IS_D1_INVERTED : bit    := '0';
            IS_D2_INVERTED : bit    := '0';
            SRTYPE         : string := "SYNC"
        );
        port (
            Q  : out std_ulogic;
            C  : in  std_ulogic;
            CE : in  std_ulogic;
            D1 : in  std_ulogic;
            D2 : in  std_ulogic;
            R  : in  std_ulogic := 'L';
            S  : in  std_ulogic := 'L'
        );
    end component ODDR;

    -- Xilinx UltraScale+ output DDR (unisim).
    component ODDRE1 is
        generic (
            IS_C_INVERTED  : bit    := '0';
            IS_D1_INVERTED : bit    := '0';
            IS_D2_INVERTED : bit    := '0';
            SIM_DEVICE     : string := "ULTRASCALE";
            SRVAL          : bit    := '0'
        );
        port (
            Q  : out std_ulogic;
            C  : in  std_ulogic;
            D1 : in  std_ulogic;
            D2 : in  std_ulogic;
            SR : in  std_ulogic
        );
    end component ODDRE1;

    -- Behavioral-model registers (INTEL_CYCLONE and SIM branches only).
    signal q1_r, q2_r, q2_s : std_logic;

begin

    gen_xilinx_7series : if EMZ_TARGET = "XILINX_7SERIES" generate
        u_oddr : ODDR
            generic map (
                DDR_CLK_EDGE => "SAME_EDGE",
                INIT         => '0',
                SRTYPE       => "ASYNC"
            )
            port map (
                Q  => q,
                C  => clk,
                CE => '1',
                D1 => d1,
                D2 => d2,
                R  => '0',
                S  => '0'
            );
    end generate gen_xilinx_7series;

    gen_xilinx_ultrascale_plus : if EMZ_TARGET = "XILINX_ULTRASCALE_PLUS" generate
        -- ODDRE1 samples D1 and D2 on the rising edge and drives D2 in the
        -- falling half, which is ODDR's SAME_EDGE behaviour above.
        u_oddr : ODDRE1
            generic map (
                IS_C_INVERTED  => '0',
                IS_D1_INVERTED => '0',
                IS_D2_INVERTED => '0',
                SIM_DEVICE     => "ULTRASCALE_PLUS",
                SRVAL          => '0'
            )
            port map (
                Q  => q,
                C  => clk,
                D1 => d1,
                D2 => d2,
                SR => '0'
            );
    end generate gen_xilinx_ultrascale_plus;

    gen_intel_cyclone : if EMZ_TARGET = "INTEL_CYCLONE" generate
        -- ---------------------------------------------------------------------
        -- STUB - NOT a real Intel DDR output. ALTDDIO_OUT / DDIO atoms are NOT
        -- instantiated here; this is only a behavioral mux so an Intel-target
        -- elaboration completes. It will NOT meet DDR output timing on real
        -- silicon. Replace with a true ALTDDIO_OUT instance before targeting
        -- Intel.
        -- ---------------------------------------------------------------------
        process (clk)
        begin
            if rising_edge(clk) then
                q1_r <= d1;
            end if;
        end process;

        process (clk)
        begin
            if falling_edge(clk) then
                q2_r <= d2;
            end if;
        end process;

        q <= q1_r when clk = '1' else q2_r;
    end generate gen_intel_cyclone;

    gen_sim : if EMZ_TARGET = "SIM" generate
        -- Simulation-only behavioral DDR model (not for synthesis), SAME_EDGE
        -- like the vendor cells above: d1 and d2 are both sampled on the rising
        -- edge, d1 is driven in the high half and d2 in the low half.
        -- Single-edge registers muxed by clk - never drives one register from
        -- two clock edges.
        process (clk)
        begin
            if rising_edge(clk) then
                q1_r <= d1;
                q2_s <= d2;
            end if;
        end process;

        process (clk)
        begin
            if falling_edge(clk) then
                q2_r <= q2_s;
            end if;
        end process;

        q <= q1_r when clk = '1' else q2_r;
    end generate gen_sim;

    -- No DDR primitive selected (EMZ_TARGET = ""). Compile the XILINX_7SERIES
    -- or XILINX_ULTRASCALE_PLUS (or INTEL_CYCLONE) target package for
    -- synthesis, or SIM for simulation. `q` is intentionally left undriven so
    -- an accidental synthesis of this file fails loudly instead of silently
    -- inferring a non-DDR soft register.

end architecture rtl;
