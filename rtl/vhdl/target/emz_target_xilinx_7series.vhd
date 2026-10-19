-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- emz_target_pkg (xilinx_7series) - replaces the Verilog vendor `define.
-- Synthesis for XILINX_7SERIES (Verilog: `define XILINX_7SERIES).
-- Compile exactly one rtl/vhdl/target/emz_target_*.vhd file.
-- =============================================================================

package emz_target_pkg is
    -- One of "SIM", "XILINX_7SERIES", "XILINX_ULTRASCALE_PLUS", "INTEL_CYCLONE", or "".
    constant EMZ_TARGET : string := "XILINX_7SERIES";
end package emz_target_pkg;
