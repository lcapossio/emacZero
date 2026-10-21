-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- ddr_input.vhd - Vendor-agnostic DDR input primitive wrapper
-- Captures data on both edges: q1 from rising, q2 from falling.
-- Vendor selection via emz_target_pkg.EMZ_TARGET (compile exactly one
-- rtl/vhdl/target/emz_target_*.vhd): "XILINX_7SERIES",
-- "XILINX_ULTRASCALE_PLUS", "INTEL_CYCLONE", "SIM", or "" (none).
-- The vendor primitives are declared as local components (no library unisim),
-- so the file analyses without vendor libraries.
-- VHDL port of rtl/ddr_input.v (formally proven equivalent; see sim/parity/).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

use work.emz_target_pkg.all;
-- VHDL-93 binds a component instance by default only to a directly visible
-- entity of the same name. This makes simulation models of the vendor
-- primitives compiled into work (sim/parity/stubs/) bind; Vivado binds the
-- real primitives by name either way.
use work.all;

entity ddr_input is
    port (
        clk : in  std_logic;
        d   : in  std_logic;    -- DDR input
        q1  : out std_logic;    -- data captured on rising edge
        q2  : out std_logic     -- data captured on falling edge
    );
end entity ddr_input;

architecture rtl of ddr_input is

    -- Xilinx 7-series input DDR (unisim).
    component IDDR is
        generic (
            DDR_CLK_EDGE  : string := "OPPOSITE_EDGE";
            INIT_Q1       : bit    := '0';
            INIT_Q2       : bit    := '0';
            IS_C_INVERTED : bit    := '0';
            IS_D_INVERTED : bit    := '0';
            SRTYPE        : string := "SYNC"
        );
        port (
            Q1 : out std_ulogic;
            Q2 : out std_ulogic;
            C  : in  std_ulogic;
            CE : in  std_ulogic;
            D  : in  std_ulogic;
            R  : in  std_ulogic := 'L';
            S  : in  std_ulogic := 'L'
        );
    end component IDDR;

    -- Xilinx UltraScale+ input DDR (unisim).
    component IDDRE1 is
        generic (
            DDR_CLK_EDGE   : string := "OPPOSITE_EDGE";
            IS_CB_INVERTED : bit    := '0';
            IS_C_INVERTED  : bit    := '0'
        );
        port (
            Q1 : out std_ulogic;
            Q2 : out std_ulogic;
            C  : in  std_ulogic;
            CB : in  std_ulogic;
            D  : in  std_ulogic;
            R  : in  std_ulogic
        );
    end component IDDRE1;

    -- Behavioral-model registers (INTEL_CYCLONE and SIM branches only).
    signal q1_pipe, q1_r, q2_pipe, q2_r : std_logic;

begin

    gen_xilinx_7series : if EMZ_TARGET = "XILINX_7SERIES" generate
        u_iddr : IDDR
            generic map (
                DDR_CLK_EDGE => "SAME_EDGE_PIPELINED",
                INIT_Q1      => '0',
                INIT_Q2      => '0',
                SRTYPE       => "ASYNC"
            )
            port map (
                Q1 => q1,
                Q2 => q2,
                C  => clk,
                CE => '1',
                D  => d,
                R  => '0',
                S  => '0'
            );
    end generate gen_xilinx_7series;

    gen_xilinx_ultrascale_plus : if EMZ_TARGET = "XILINX_ULTRASCALE_PLUS" generate
        -- IDDRE1 SAME_EDGE_PIPELINED matches the 7-series IDDR mode above. CB
        -- takes the same clock, inverted inside the cell.
        u_iddr : IDDRE1
            generic map (
                DDR_CLK_EDGE   => "SAME_EDGE_PIPELINED",
                IS_CB_INVERTED => '1',
                IS_C_INVERTED  => '0'
            )
            port map (
                Q1 => q1,
                Q2 => q2,
                C  => clk,
                CB => clk,
                D  => d,
                R  => '0'
            );
    end generate gen_xilinx_ultrascale_plus;

    gen_intel_cyclone : if EMZ_TARGET = "INTEL_CYCLONE" generate
        -- ---------------------------------------------------------------------
        -- STUB - NOT a real Intel DDR input. ALTDDIO_IN / DDIO atoms are NOT
        -- instantiated here; this is only a behavioral model so an Intel-target
        -- elaboration completes. It will NOT meet DDR input setup/hold on real
        -- silicon. Replace with a true ALTDDIO_IN instance before targeting
        -- Intel.
        -- ---------------------------------------------------------------------
        process (clk)
        begin
            if rising_edge(clk) then
                q1_pipe <= d;
                q1_r    <= q1_pipe;
                q2_r    <= q2_pipe;
            end if;
        end process;

        process (clk)
        begin
            if falling_edge(clk) then
                q2_pipe <= d;
            end if;
        end process;

        q1 <= q1_r;
        q2 <= q2_r;
    end generate gen_intel_cyclone;

    gen_sim : if EMZ_TARGET = "SIM" generate
        -- Simulation-only behavioral model (SAME_EDGE_PIPELINED equivalent, not
        -- for synthesis). Xilinx IDDR SAME_EDGE_PIPELINED: at posedge N+1,
        -- q1 = data from posedge N, q2 = data from negedge N. Both from the
        -- same DDR cycle.
        process (clk)
        begin
            if rising_edge(clk) then
                q1_pipe <= d;        -- capture rising-edge data
                q1_r    <= q1_pipe;  -- pipeline to align with q2
                q2_r    <= q2_pipe;  -- pipeline falling-edge data
            end if;
        end process;

        process (clk)
        begin
            if falling_edge(clk) then
                q2_pipe <= d;        -- capture falling-edge data
            end if;
        end process;

        q1 <= q1_r;
        q2 <= q2_r;
    end generate gen_sim;

    -- No DDR primitive selected (EMZ_TARGET = ""). Compile the XILINX_7SERIES
    -- or XILINX_ULTRASCALE_PLUS (or INTEL_CYCLONE) target package for
    -- synthesis, or SIM for simulation. q1/q2 are intentionally left undriven
    -- so an accidental synthesis of this file fails loudly instead of silently
    -- inferring a soft model.

end architecture rtl;
