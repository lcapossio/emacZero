-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- xilinx_ddr_prims.vhd - Parity-only behavioural stubs of the Xilinx DDR I/O
-- primitives ODDR, IDDR (7-series) and ODDRE1, IDDRE1 (UltraScale+).
-- Analysed into work on the VHDL (candidate) side of a translateHDL proof, so
-- the local component declarations in rtl/vhdl/ddr_*.vhd bind to them by
-- default. Line-for-line twin of xilinx_ddr_prims.v (read on the golden side);
-- see that file for what is and is not modelled. Generic types follow
-- unisim_VCOMP.vhd.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity ODDR is
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
end entity ODDR;

architecture stub of ODDR is
    constant SAME : boolean := DDR_CLK_EDGE = "SAME_EDGE";
    signal c_i, d1_i, d2_i : std_ulogic;
    signal q1  : std_ulogic := to_stdulogic(INIT);
    signal q2s : std_ulogic := to_stdulogic(INIT);
    signal q2  : std_ulogic := to_stdulogic(INIT);
begin
    c_i  <= C  xor to_stdulogic(IS_C_INVERTED);
    d1_i <= D1 xor to_stdulogic(IS_D1_INVERTED);
    d2_i <= D2 xor to_stdulogic(IS_D2_INVERTED);

    -- Rising edge: D1 (and D2 for SAME_EDGE).
    process (c_i)
    begin
        if rising_edge(c_i) then
            if R = '1' then
                q1 <= '0'; q2s <= '0';
            elsif S = '1' then
                q1 <= '1'; q2s <= '1';
            elsif CE = '1' then
                q1 <= d1_i; q2s <= d2_i;
            end if;
        end if;
    end process;

    -- Falling edge: D2 (OPPOSITE_EDGE) or the D2 taken on the rising edge.
    process (c_i)
    begin
        if falling_edge(c_i) then
            if R = '1' then
                q2 <= '0';
            elsif S = '1' then
                q2 <= '1';
            elsif CE = '1' then
                if SAME then
                    q2 <= q2s;
                else
                    q2 <= d2_i;
                end if;
            end if;
        end if;
    end process;

    Q <= q1 when c_i = '1' else q2;
end architecture stub;

library ieee;
use ieee.std_logic_1164.all;

entity ODDRE1 is
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
end entity ODDRE1;

architecture stub of ODDRE1 is
    signal c_i, d1_i, d2_i : std_ulogic;
    signal q1  : std_ulogic := to_stdulogic(SRVAL);
    signal q2s : std_ulogic := to_stdulogic(SRVAL);
    signal q2  : std_ulogic := to_stdulogic(SRVAL);
begin
    c_i  <= C  xor to_stdulogic(IS_C_INVERTED);
    d1_i <= D1 xor to_stdulogic(IS_D1_INVERTED);
    d2_i <= D2 xor to_stdulogic(IS_D2_INVERTED);

    -- D1 and D2 both sampled on the rising edge; D2 driven in the low half.
    process (c_i)
    begin
        if rising_edge(c_i) then
            if SR = '1' then
                q1 <= to_stdulogic(SRVAL); q2s <= to_stdulogic(SRVAL);
            else
                q1 <= d1_i; q2s <= d2_i;
            end if;
        end if;
    end process;

    process (c_i)
    begin
        if falling_edge(c_i) then
            if SR = '1' then
                q2 <= to_stdulogic(SRVAL);
            else
                q2 <= q2s;
            end if;
        end if;
    end process;

    Q <= q1 when c_i = '1' else q2;
end architecture stub;

library ieee;
use ieee.std_logic_1164.all;

entity IDDR is
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
end entity IDDR;

architecture stub of IDDR is
    constant OPP  : boolean := DDR_CLK_EDGE = "OPPOSITE_EDGE";
    constant PIPE : boolean := DDR_CLK_EDGE = "SAME_EDGE_PIPELINED";
    signal c_i, d_i : std_ulogic;
    signal q1p : std_ulogic := to_stdulogic(INIT_Q1);
    signal q1r : std_ulogic := to_stdulogic(INIT_Q1);
    signal q2p : std_ulogic := to_stdulogic(INIT_Q2);
    signal q2r : std_ulogic := to_stdulogic(INIT_Q2);
begin
    c_i <= C xor to_stdulogic(IS_C_INVERTED);
    d_i <= D xor to_stdulogic(IS_D_INVERTED);

    -- Rising edge: D into q1p; Q1 takes D (OPPOSITE/SAME_EDGE) or q1p
    -- (SAME_EDGE_PIPELINED); Q2 re-times the falling-edge capture.
    process (c_i)
    begin
        if rising_edge(c_i) then
            if R = '1' then
                q1p <= '0'; q1r <= '0'; q2r <= '0';
            elsif S = '1' then
                q1p <= '1'; q1r <= '1'; q2r <= '1';
            elsif CE = '1' then
                q1p <= d_i;
                if PIPE then
                    q1r <= q1p;
                else
                    q1r <= d_i;
                end if;
                q2r <= q2p;
            end if;
        end if;
    end process;

    -- Falling edge: D into q2p (Q2 directly for OPPOSITE_EDGE).
    process (c_i)
    begin
        if falling_edge(c_i) then
            if R = '1' then
                q2p <= '0';
            elsif S = '1' then
                q2p <= '1';
            elsif CE = '1' then
                q2p <= d_i;
            end if;
        end if;
    end process;

    Q1 <= q1r;
    Q2 <= q2p when OPP else q2r;
end architecture stub;

library ieee;
use ieee.std_logic_1164.all;

entity IDDRE1 is
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
end entity IDDRE1;

architecture stub of IDDRE1 is
    constant OPP  : boolean := DDR_CLK_EDGE = "OPPOSITE_EDGE";
    constant PIPE : boolean := DDR_CLK_EDGE = "SAME_EDGE_PIPELINED";
    signal c_i, cb_i : std_ulogic;
    signal q1p : std_ulogic := '0';
    signal q1r : std_ulogic := '0';
    signal q2p : std_ulogic := '0';
    signal q2r : std_ulogic := '0';
begin
    c_i  <= C  xor to_stdulogic(IS_C_INVERTED);
    cb_i <= CB xor to_stdulogic(IS_CB_INVERTED);

    -- Rising C: as IDDR's rising edge.
    process (c_i)
    begin
        if rising_edge(c_i) then
            if R = '1' then
                q1p <= '0'; q1r <= '0'; q2r <= '0';
            else
                q1p <= D;
                if PIPE then
                    q1r <= q1p;
                else
                    q1r <= D;
                end if;
                q2r <= q2p;
            end if;
        end if;
    end process;

    -- Rising CB (after IS_CB_INVERTED): the second-half capture.
    process (cb_i)
    begin
        if rising_edge(cb_i) then
            if R = '1' then
                q2p <= '0';
            else
                q2p <= D;
            end if;
        end if;
    end process;

    Q1 <= q1r;
    Q2 <= q2p when OPP else q2r;
end architecture stub;
