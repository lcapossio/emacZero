-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- emz_util_pkg.vhd - Elaboration-time helpers shared by the VHDL port.
-- =============================================================================

package emz_util_pkg is
    -- Verilog $clog2: ceil(log2(n)), with clog2(0) = clog2(1) = 0.
    function clog2(n : natural) return natural;
end package emz_util_pkg;

package body emz_util_pkg is
    function clog2(n : natural) return natural is
        variable r : natural := 0;
        variable v : natural := 1;
    begin
        while v < n loop
            v := v * 2;
            r := r + 1;
        end loop;
        return r;
    end function clog2;
end package body emz_util_pkg;
