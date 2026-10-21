-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- axil_arb2.vhd - Minimal 2:1 AXI4-Lite arbiter (two masters -> one slave).
-- VHDL port of rtl/axil_arb2.v (formally proven equivalent; see sim/parity/).
--
-- Write (AW/W/B) and read (AR/R) channels are arbitrated independently, so a
-- read from one master can overlap a write from the other. Within a channel,
-- one transaction is in flight at a time: a master is granted when it asserts
-- AWVALID (writes) / ARVALID (reads), and holds the grant until the matching
-- B / R handshake completes. Fixed priority: master 0 (m0) wins ties.
--
-- Grants are registered (one idle cycle of latency before the slave sees the
-- request), which keeps the mux purely combinational and avoids AW/AR->grant
-- combinational paths. Intended for low-rate CSR access where both masters lead
-- a transaction with AWVALID/ARVALID (the emacZero test_sequencer and the
-- fcapz EJTAG-AXI bridge both do). Not a general crossbar: single slave, no IDs,
-- no outstanding pipelining.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity axil_arb2 is
    generic (
        AW : integer := 8;      -- address width
        DW : integer := 32      -- data width
    );
    port (
        aclk       : in  std_logic;
        aresetn    : in  std_logic;

        -- ---- Master 0 (priority) ----
        m0_awaddr  : in  std_logic_vector(AW-1 downto 0);
        m0_awvalid : in  std_logic;
        m0_awready : out std_logic;
        m0_wdata   : in  std_logic_vector(DW-1 downto 0);
        m0_wstrb   : in  std_logic_vector(DW/8-1 downto 0);
        m0_wvalid  : in  std_logic;
        m0_wready  : out std_logic;
        m0_bresp   : out std_logic_vector(1 downto 0);
        m0_bvalid  : out std_logic;
        m0_bready  : in  std_logic;
        m0_araddr  : in  std_logic_vector(AW-1 downto 0);
        m0_arvalid : in  std_logic;
        m0_arready : out std_logic;
        m0_rdata   : out std_logic_vector(DW-1 downto 0);
        m0_rresp   : out std_logic_vector(1 downto 0);
        m0_rvalid  : out std_logic;
        m0_rready  : in  std_logic;

        -- ---- Master 1 ----
        m1_awaddr  : in  std_logic_vector(AW-1 downto 0);
        m1_awvalid : in  std_logic;
        m1_awready : out std_logic;
        m1_wdata   : in  std_logic_vector(DW-1 downto 0);
        m1_wstrb   : in  std_logic_vector(DW/8-1 downto 0);
        m1_wvalid  : in  std_logic;
        m1_wready  : out std_logic;
        m1_bresp   : out std_logic_vector(1 downto 0);
        m1_bvalid  : out std_logic;
        m1_bready  : in  std_logic;
        m1_araddr  : in  std_logic_vector(AW-1 downto 0);
        m1_arvalid : in  std_logic;
        m1_arready : out std_logic;
        m1_rdata   : out std_logic_vector(DW-1 downto 0);
        m1_rresp   : out std_logic_vector(1 downto 0);
        m1_rvalid  : out std_logic;
        m1_rready  : in  std_logic;

        -- ---- Slave ----
        s_awaddr   : out std_logic_vector(AW-1 downto 0);
        s_awvalid  : out std_logic;
        s_awready  : in  std_logic;
        s_wdata    : out std_logic_vector(DW-1 downto 0);
        s_wstrb    : out std_logic_vector(DW/8-1 downto 0);
        s_wvalid   : out std_logic;
        s_wready   : in  std_logic;
        s_bresp    : in  std_logic_vector(1 downto 0);
        s_bvalid   : in  std_logic;
        s_bready   : out std_logic;
        s_araddr   : out std_logic_vector(AW-1 downto 0);
        s_arvalid  : out std_logic;
        s_arready  : in  std_logic;
        s_rdata    : in  std_logic_vector(DW-1 downto 0);
        s_rresp    : in  std_logic_vector(1 downto 0);
        s_rvalid   : in  std_logic;
        s_rready   : out std_logic
    );
end entity axil_arb2;

architecture rtl of axil_arb2 is

    -- ---- Write-channel grant (registered) ----
    signal w_busy : std_logic;
    signal w_sel  : std_logic;      -- 0 = m0, 1 = m1
    signal w_g0   : std_logic;
    signal w_g1   : std_logic;

    -- ---- Read-channel grant (registered) ----
    signal r_busy : std_logic;
    signal r_sel  : std_logic;
    signal r_g0   : std_logic;
    signal r_g1   : std_logic;

    -- s_bready / s_rready are read back by the grant registers.
    signal s_bready_i : std_logic;
    signal s_rready_i : std_logic;

begin

    -- ---- Write-channel grant (registered) ----
    process (aclk, aresetn)
    begin
        if aresetn = '0' then
            w_busy <= '0';
            w_sel  <= '0';
        elsif rising_edge(aclk) then
            if w_busy = '0' then
                if m0_awvalid = '1' then
                    w_sel <= '0'; w_busy <= '1';
                elsif m1_awvalid = '1' then
                    w_sel <= '1'; w_busy <= '1';
                end if;
            elsif s_bvalid = '1' and s_bready_i = '1' then
                w_busy <= '0';
            end if;
        end if;
    end process;

    w_g0 <= w_busy and not w_sel;
    w_g1 <= w_busy and w_sel;

    -- AW / W (mux granted master -> slave)
    s_awaddr   <= m1_awaddr when w_g1 = '1' else m0_awaddr;
    s_awvalid  <= (w_g0 and m0_awvalid) or (w_g1 and m1_awvalid);
    m0_awready <= w_g0 and s_awready;
    m1_awready <= w_g1 and s_awready;

    s_wdata   <= m1_wdata when w_g1 = '1' else m0_wdata;
    s_wstrb   <= m1_wstrb when w_g1 = '1' else m0_wstrb;
    s_wvalid  <= (w_g0 and m0_wvalid) or (w_g1 and m1_wvalid);
    m0_wready <= w_g0 and s_wready;
    m1_wready <= w_g1 and s_wready;

    -- B (slave -> granted master)
    s_bready_i <= (w_g0 and m0_bready) or (w_g1 and m1_bready);
    s_bready   <= s_bready_i;
    m0_bvalid  <= w_g0 and s_bvalid;
    m1_bvalid  <= w_g1 and s_bvalid;
    m0_bresp   <= s_bresp;
    m1_bresp   <= s_bresp;

    -- ---- Read-channel grant (registered) ----
    process (aclk, aresetn)
    begin
        if aresetn = '0' then
            r_busy <= '0';
            r_sel  <= '0';
        elsif rising_edge(aclk) then
            if r_busy = '0' then
                if m0_arvalid = '1' then
                    r_sel <= '0'; r_busy <= '1';
                elsif m1_arvalid = '1' then
                    r_sel <= '1'; r_busy <= '1';
                end if;
            elsif s_rvalid = '1' and s_rready_i = '1' then
                r_busy <= '0';
            end if;
        end if;
    end process;

    r_g0 <= r_busy and not r_sel;
    r_g1 <= r_busy and r_sel;

    -- AR (mux granted master -> slave)
    s_araddr   <= m1_araddr when r_g1 = '1' else m0_araddr;
    s_arvalid  <= (r_g0 and m0_arvalid) or (r_g1 and m1_arvalid);
    m0_arready <= r_g0 and s_arready;
    m1_arready <= r_g1 and s_arready;

    -- R (slave -> granted master)
    s_rready_i <= (r_g0 and m0_rready) or (r_g1 and m1_rready);
    s_rready   <= s_rready_i;
    m0_rvalid  <= r_g0 and s_rvalid;
    m1_rvalid  <= r_g1 and s_rvalid;
    m0_rdata   <= s_rdata;
    m1_rdata   <= s_rdata;
    m0_rresp   <= s_rresp;
    m1_rresp   <= s_rresp;

end architecture rtl;
