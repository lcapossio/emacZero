-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- emz_util_pkg.vhd - Elaboration-time helpers shared by the VHDL port.
-- =============================================================================

package emz_util_pkg is
    -- Verilog $clog2: ceil(log2(n)), with clog2(0) = clog2(1) = 0.
    function clog2(n : natural) return natural;
    -- The larger of a and b (VHDL-2008's maximum, which VHDL-93 lacks).
    function max_int(a, b : integer) return integer;
    -- A Verilog parameter whose default is computed from another parameter
    -- cannot be written as a VHDL-93 generic default. Such generics default to
    -- 0, meaning "derive it", and the architecture uses auto_or(generic, derived).
    function auto_or(given, derived : integer) return integer;
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

    function max_int(a, b : integer) return integer is
    begin
        if a > b then
            return a;
        end if;
        return b;
    end function max_int;

    function auto_or(given, derived : integer) return integer is
    begin
        if given = 0 then
            return derived;
        end if;
        return given;
    end function auto_or;
end package body emz_util_pkg;
