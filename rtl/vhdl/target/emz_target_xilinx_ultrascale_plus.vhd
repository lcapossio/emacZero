-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- emz_target_pkg (xilinx_ultrascale_plus) - replaces the Verilog vendor `define.
-- Synthesis for XILINX_ULTRASCALE_PLUS (Verilog: `define XILINX_ULTRASCALE_PLUS).
-- Compile exactly one rtl/vhdl/target/emz_target_*.vhd file.
-- =============================================================================

package emz_target_pkg is
    -- One of "SIM", "XILINX_7SERIES", "XILINX_ULTRASCALE_PLUS", "INTEL_CYCLONE", or "".
    constant EMZ_TARGET : string := "XILINX_ULTRASCALE_PLUS";
end package emz_target_pkg;
