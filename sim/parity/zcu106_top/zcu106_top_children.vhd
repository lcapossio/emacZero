-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- zcu106_top_children.vhd - Parity-only stand-ins for every child of
-- zcu106_top (VHDL side; line-for-line twin of zcu106_top_children.v, which
-- explains the model). Entity, generic and port names and types match the
-- component declarations in fpga/zcu106/rtl/zcu106_top.vhd and
-- zcu106_top_lb.vhd, so GHDL binds those components to these entities.
-- =============================================================================

-- ---- unisim -----------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity IBUFDS is
    port (
        O  : out std_ulogic;
        I  : in  std_ulogic;
        IB : in  std_ulogic
    );
end entity IBUFDS;

architecture standin of IBUFDS is
begin
    O <= I and not IB;
end architecture standin;

-- A register on I that mixes CE, CLR and BUFGCE_DIVIDE (all 32 bits); O is
-- one of its bits. So O is a different clock from I, and a wrong divide value
-- or a miswired CE / CLR diverges.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity BUFGCE_DIV is
    generic (
        BUFGCE_DIVIDE : integer := 1
    );
    port (
        O   : out std_ulogic;
        CE  : in  std_ulogic;
        CLR : in  std_ulogic;
        I   : in  std_ulogic
    );
end entity BUFGCE_DIV;

architecture standin of BUFGCE_DIV is
    constant FP : std_logic_vector(31 downto 0) :=
        std_logic_vector(to_signed(BUFGCE_DIVIDE, 32));
    signal st : std_logic_vector(33 downto 0);
begin
    process (I)
    begin
        if rising_edge(I) then
            st <= (st(32 downto 0) & st(33)) xor (CLR & CE & FP);
        end if;
    end process;
    O <= st(0);
end architecture standin;

-- ---- fpga/zcu106/rtl/i2c_init.v -----------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity i2c_init is
    generic (
        CLK_HZ      : integer := 50_000_000;
        I2C_HZ      : integer := 100_000;
        START_DELAY : integer := 50_000_000 / 10;
        RETRY_DELAY : integer := 50_000_000 / 10;
        DONE_DELAY  : integer := 50_000_000 / 2
    );
    port (
        clk        : in  std_logic;
        rst_n      : in  std_logic;
        scl_t      : out std_logic;
        sda_t      : out std_logic;
        sda_i      : in  std_logic;
        done       : out std_logic;
        busy       : out std_logic;
        nack_count : out std_logic_vector(7 downto 0)
    );
end entity i2c_init;

architecture standin of i2c_init is
    constant G0 : unsigned(31 downto 0) := to_unsigned(CLK_HZ, 32);
    constant G1 : unsigned(31 downto 0) := to_unsigned(I2C_HZ, 32);
    constant G2 : unsigned(31 downto 0) := to_unsigned(START_DELAY, 32);
    constant G3 : unsigned(31 downto 0) := to_unsigned(RETRY_DELAY, 32);
    constant G4 : unsigned(31 downto 0) := to_unsigned(DONE_DELAY, 32);
    constant FP : std_logic_vector(159 downto 0) :=
        std_logic_vector(G4) & std_logic_vector(G3) & std_logic_vector(G2) &
        std_logic_vector(G1) & std_logic_vector(G0);

    signal st  : std_logic_vector(161 downto 0);
begin
    process (clk)
    begin
        if rising_edge(clk) then
            st <= (st(160 downto 0) & st(161)) xor (rst_n & sda_i & FP);
        end if;
    end process;

    scl_t      <= st(0);
    sda_t      <= st(1);
    done       <= st(2);
    busy       <= st(3);
    nack_count <= st(11 downto 4);
end architecture standin;

-- ---- Vivado IP gig_ethernet_pcs_pma, shared logic in core --------------------
library ieee;
use ieee.std_logic_1164.all;

entity pcs_pma_1000basex is
    port (
        gtrefclk_p             : in  std_logic;
        gtrefclk_n             : in  std_logic;
        gtrefclk_out           : out std_logic;
        txp                    : out std_logic;
        txn                    : out std_logic;
        rxp                    : in  std_logic;
        rxn                    : in  std_logic;
        resetdone              : out std_logic;
        userclk_out            : out std_logic;
        userclk2_out           : out std_logic;
        rxuserclk_out          : out std_logic;
        rxuserclk2_out         : out std_logic;
        independent_clock_bufg : in  std_logic;
        pma_reset_out          : out std_logic;
        mmcm_locked_out        : out std_logic;
        gmii_txd               : in  std_logic_vector(7 downto 0);
        gmii_tx_en             : in  std_logic;
        gmii_tx_er             : in  std_logic;
        gmii_rxd               : out std_logic_vector(7 downto 0);
        gmii_rx_dv             : out std_logic;
        gmii_rx_er             : out std_logic;
        gmii_isolate           : out std_logic;
        configuration_vector   : in  std_logic_vector(4 downto 0);
        an_interrupt           : out std_logic;
        an_adv_config_vector   : in  std_logic_vector(15 downto 0);
        an_restart_config      : in  std_logic;
        status_vector          : out std_logic_vector(15 downto 0);
        reset                  : in  std_logic;
        gtpowergood            : out std_logic;
        signal_detect          : in  std_logic
    );
end entity pcs_pma_1000basex;

architecture standin of pcs_pma_1000basex is
    signal st  : std_logic_vector(35 downto 0);
    signal din : std_logic_vector(35 downto 0);
begin
    gtrefclk_out   <= gtrefclk_p and gtrefclk_n;
    userclk_out    <= gtrefclk_p or gtrefclk_n;
    userclk2_out   <= gtrefclk_p xor gtrefclk_n;
    rxuserclk_out  <= gtrefclk_p and not gtrefclk_n;
    rxuserclk2_out <= not gtrefclk_p and gtrefclk_n;

    din <= rxp & rxn & gmii_txd & gmii_tx_en & gmii_tx_er & configuration_vector &
           an_adv_config_vector & an_restart_config & reset & signal_detect;
    process (independent_clock_bufg)
    begin
        if rising_edge(independent_clock_bufg) then
            st <= (st(34 downto 0) & st(35)) xor din;
        end if;
    end process;

    txp             <= st(0);
    txn             <= st(1);
    resetdone       <= st(2);
    pma_reset_out   <= st(3);
    mmcm_locked_out <= st(4);
    gmii_rxd        <= st(12 downto 5);
    gmii_rx_dv      <= st(13);
    gmii_rx_er      <= st(14);
    gmii_isolate    <= st(15);
    an_interrupt    <= st(16);
    status_vector   <= st(32 downto 17);
    gtpowergood     <= st(33);
end architecture standin;

-- ---- Vivado IP gig_ethernet_pcs_pma, shared logic in example design ----------
library ieee;
use ieee.std_logic_1164.all;

entity pcs_pma_1000basex_ns is
    port (
        gtrefclk               : in  std_logic;
        txp                    : out std_logic;
        txn                    : out std_logic;
        rxp                    : in  std_logic;
        rxn                    : in  std_logic;
        resetdone              : out std_logic;
        cplllock               : out std_logic;
        mmcm_reset             : out std_logic;
        txoutclk               : out std_logic;
        rxoutclk               : out std_logic;
        userclk                : in  std_logic;
        userclk2               : in  std_logic;
        rxuserclk              : in  std_logic;
        rxuserclk2             : in  std_logic;
        independent_clock_bufg : in  std_logic;
        pma_reset              : in  std_logic;
        mmcm_locked            : in  std_logic;
        gmii_txd               : in  std_logic_vector(7 downto 0);
        gmii_tx_en             : in  std_logic;
        gmii_tx_er             : in  std_logic;
        gmii_rxd               : out std_logic_vector(7 downto 0);
        gmii_rx_dv             : out std_logic;
        gmii_rx_er             : out std_logic;
        gmii_isolate           : out std_logic;
        configuration_vector   : in  std_logic_vector(4 downto 0);
        an_interrupt           : out std_logic;
        an_adv_config_vector   : in  std_logic_vector(15 downto 0);
        an_restart_config      : in  std_logic;
        status_vector          : out std_logic_vector(15 downto 0);
        reset                  : in  std_logic;
        gtpowergood            : out std_logic;
        signal_detect          : in  std_logic
    );
end entity pcs_pma_1000basex_ns;

architecture standin of pcs_pma_1000basex_ns is
    signal st  : std_logic_vector(42 downto 0);
    signal din : std_logic_vector(42 downto 0);
begin
    din <= gtrefclk & rxp & rxn & userclk & userclk2 & rxuserclk & rxuserclk2 &
           pma_reset & mmcm_locked & gmii_txd & gmii_tx_en & gmii_tx_er &
           configuration_vector & an_adv_config_vector & an_restart_config &
           reset & signal_detect;
    process (independent_clock_bufg)
    begin
        if rising_edge(independent_clock_bufg) then
            st <= (st(41 downto 0) & st(42)) xor din;
        end if;
    end process;

    txp           <= st(0);
    txn           <= st(1);
    resetdone     <= st(2);
    cplllock      <= st(3);
    mmcm_reset    <= st(4);
    txoutclk      <= st(5);
    rxoutclk      <= st(6);
    gmii_rxd      <= st(14 downto 7);
    gmii_rx_dv    <= st(15);
    gmii_rx_er    <= st(16);
    gmii_isolate  <= st(17);
    an_interrupt  <= st(18);
    status_vector <= st(34 downto 19);
    gtpowergood   <= st(35);
end architecture standin;

-- ---- fcapz/rtl/fcapz_ejtagaxi_xilinxus.v --------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fcapz_ejtagaxi_xilinxus is
    generic (
        ADDR_W                 : integer := 32;
        DATA_W                 : integer := 32;
        FIFO_DEPTH             : integer := 16;
        CMD_FIFO_DEPTH         : integer := 32;
        RESP_FIFO_DEPTH        : integer := 32;
        TIMEOUT                : integer := 4096;
        DEBUG_EN               : integer := 0;
        CMD_FIFO_MEMORY_TYPE   : string  := "auto";
        RESP_FIFO_MEMORY_TYPE  : string  := "auto";
        BURST_FIFO_MEMORY_TYPE : string  := "auto";
        ASYNC_FIFO_IMPL        : integer := 1;
        CHAIN                  : integer := 4
    );
    port (
        axi_clk        : in  std_logic;
        axi_rst        : in  std_logic;
        m_axi_awaddr   : out std_logic_vector(ADDR_W-1 downto 0);
        m_axi_awlen    : out std_logic_vector(7 downto 0);
        m_axi_awsize   : out std_logic_vector(2 downto 0);
        m_axi_awburst  : out std_logic_vector(1 downto 0);
        m_axi_awvalid  : out std_logic;
        m_axi_awready  : in  std_logic;
        m_axi_awprot   : out std_logic_vector(2 downto 0);
        m_axi_wdata    : out std_logic_vector(DATA_W-1 downto 0);
        m_axi_wstrb    : out std_logic_vector(DATA_W/8-1 downto 0);
        m_axi_wvalid   : out std_logic;
        m_axi_wready   : in  std_logic;
        m_axi_wlast    : out std_logic;
        m_axi_bresp    : in  std_logic_vector(1 downto 0);
        m_axi_bvalid   : in  std_logic;
        m_axi_bready   : out std_logic;
        m_axi_araddr   : out std_logic_vector(ADDR_W-1 downto 0);
        m_axi_arlen    : out std_logic_vector(7 downto 0);
        m_axi_arsize   : out std_logic_vector(2 downto 0);
        m_axi_arburst  : out std_logic_vector(1 downto 0);
        m_axi_arvalid  : out std_logic;
        m_axi_arready  : in  std_logic;
        m_axi_arprot   : out std_logic_vector(2 downto 0);
        m_axi_rdata    : in  std_logic_vector(DATA_W-1 downto 0);
        m_axi_rresp    : in  std_logic_vector(1 downto 0);
        m_axi_rvalid   : in  std_logic;
        m_axi_rlast    : in  std_logic;
        m_axi_rready   : out std_logic;
        debug_tck      : out std_logic_vector(255 downto 0);
        debug_tck_edge : out std_logic_vector(255 downto 0);
        debug_axi      : out std_logic_vector(255 downto 0);
        debug_axi_edge : out std_logic_vector(255 downto 0)
    );
end entity fcapz_ejtagaxi_xilinxus;

architecture standin of fcapz_ejtagaxi_xilinxus is
    -- Every generic: the integers in their own 32-bit fields, each memory-type
    -- string as one bit per legal value.
    function b (c : boolean) return std_logic_vector is
    begin
        if c then return "1"; end if;
        return "0";
    end function b;
    constant G0 : unsigned(31 downto 0) := to_unsigned(ADDR_W, 32);
    constant G1 : unsigned(31 downto 0) := to_unsigned(DATA_W, 32);
    constant G2 : unsigned(31 downto 0) := to_unsigned(FIFO_DEPTH, 32);
    constant G3 : unsigned(31 downto 0) := to_unsigned(CMD_FIFO_DEPTH, 32);
    constant G4 : unsigned(31 downto 0) := to_unsigned(RESP_FIFO_DEPTH, 32);
    constant G5 : unsigned(31 downto 0) := to_unsigned(TIMEOUT, 32);
    constant G6 : unsigned(31 downto 0) := to_unsigned(DEBUG_EN, 32);
    constant G7 : unsigned(31 downto 0) := to_unsigned(ASYNC_FIFO_IMPL, 32);
    constant G8 : unsigned(31 downto 0) := to_unsigned(CHAIN, 32);
    constant S0 : std_logic_vector(3 downto 0) :=
        b(CMD_FIFO_MEMORY_TYPE = "ultra") & b(CMD_FIFO_MEMORY_TYPE = "distributed") &
        b(CMD_FIFO_MEMORY_TYPE = "block") & b(CMD_FIFO_MEMORY_TYPE = "auto");
    constant S1 : std_logic_vector(3 downto 0) :=
        b(RESP_FIFO_MEMORY_TYPE = "ultra") & b(RESP_FIFO_MEMORY_TYPE = "distributed") &
        b(RESP_FIFO_MEMORY_TYPE = "block") & b(RESP_FIFO_MEMORY_TYPE = "auto");
    constant S2 : std_logic_vector(3 downto 0) :=
        b(BURST_FIFO_MEMORY_TYPE = "ultra") & b(BURST_FIFO_MEMORY_TYPE = "distributed") &
        b(BURST_FIFO_MEMORY_TYPE = "block") & b(BURST_FIFO_MEMORY_TYPE = "auto");
    constant FP : std_logic_vector(299 downto 0) :=
        S2 & S1 & S0 & std_logic_vector(G8) & std_logic_vector(G7) & std_logic_vector(G6) &
        std_logic_vector(G5) & std_logic_vector(G4) & std_logic_vector(G3) &
        std_logic_vector(G2) & std_logic_vector(G1) & std_logic_vector(G0);

    constant P_RREADY  : integer := 0;
    constant P_ARPROT  : integer := 1;
    constant P_ARVALID : integer := 4;
    constant P_ARBURST : integer := 5;
    constant P_ARSIZE  : integer := 7;
    constant P_ARLEN   : integer := 10;
    constant P_ARADDR  : integer := 18;
    constant P_BREADY  : integer := P_ARADDR + ADDR_W;
    constant P_WLAST   : integer := P_BREADY + 1;
    constant P_WVALID  : integer := P_BREADY + 2;
    constant P_WSTRB   : integer := P_BREADY + 3;
    constant P_WDATA   : integer := P_WSTRB + DATA_W/8;
    constant P_AWPROT  : integer := P_WDATA + DATA_W;
    constant P_AWVALID : integer := P_AWPROT + 3;
    constant P_AWBURST : integer := P_AWVALID + 1;
    constant P_AWSIZE  : integer := P_AWBURST + 2;
    constant P_AWLEN   : integer := P_AWSIZE + 3;
    constant P_AWADDR  : integer := P_AWLEN + 8;
    constant W         : integer := P_AWADDR + ADDR_W;   -- >= DATA_W + 11 and >= 32
    constant IN_N      : integer := DATA_W + 11;
    constant WS        : integer := W + 300;          -- room for the whole FP

    signal st    : std_logic_vector(WS-1 downto 0);
    signal din_i : std_logic_vector(IN_N-1 downto 0);
    signal din   : std_logic_vector(WS-1 downto 0);
    signal fp_w  : std_logic_vector(WS-1 downto 0);
begin
    din_i <= axi_rst & m_axi_awready & m_axi_wready & m_axi_bresp & m_axi_bvalid &
             m_axi_arready & m_axi_rdata & m_axi_rresp & m_axi_rvalid & m_axi_rlast;
    din   <= (WS-1 downto IN_N => '0') & din_i;
    fp_w  <= FP & (W-1 downto 0 => '0');     -- above every input bit
    process (axi_clk)
    begin
        if rising_edge(axi_clk) then
            st <= (st(WS-2 downto 0) & st(WS-1)) xor din xor fp_w;
        end if;
    end process;

    m_axi_rready  <= st(P_RREADY);
    m_axi_arprot  <= st(P_ARPROT+2 downto P_ARPROT);
    m_axi_arvalid <= st(P_ARVALID);
    m_axi_arburst <= st(P_ARBURST+1 downto P_ARBURST);
    m_axi_arsize  <= st(P_ARSIZE+2 downto P_ARSIZE);
    m_axi_arlen   <= st(P_ARLEN+7 downto P_ARLEN);
    m_axi_araddr  <= st(P_ARADDR+ADDR_W-1 downto P_ARADDR);
    m_axi_bready  <= st(P_BREADY);
    m_axi_wlast   <= st(P_WLAST);
    m_axi_wvalid  <= st(P_WVALID);
    m_axi_wstrb   <= st(P_WSTRB+DATA_W/8-1 downto P_WSTRB);
    m_axi_wdata   <= st(P_WDATA+DATA_W-1 downto P_WDATA);
    m_axi_awprot  <= st(P_AWPROT+2 downto P_AWPROT);
    m_axi_awvalid <= st(P_AWVALID);
    m_axi_awburst <= st(P_AWBURST+1 downto P_AWBURST);
    m_axi_awsize  <= st(P_AWSIZE+2 downto P_AWSIZE);
    m_axi_awlen   <= st(P_AWLEN+7 downto P_AWLEN);
    m_axi_awaddr  <= st(P_AWADDR+ADDR_W-1 downto P_AWADDR);

    -- Unconnected in zcu106_top.
    debug_tck      <= (others => '0');
    debug_tck_edge <= (others => '0');
    debug_axi      <= (others => '0');
    debug_axi_edge <= (others => '0');
end architecture standin;

-- ---- fcapz/rtl/fcapz_eio_xilinxus.v -------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fcapz_eio_xilinxus is
    generic (
        IN_W  : integer := 32;
        OUT_W : integer := 32;
        CHAIN : integer := 3
    );
    port (
        probe_in  : in  std_logic_vector(IN_W-1 downto 0);
        probe_out : out std_logic_vector(OUT_W-1 downto 0)
    );
end entity fcapz_eio_xilinxus;

architecture standin of fcapz_eio_xilinxus is
    constant G0 : unsigned(31 downto 0) := to_unsigned(IN_W, 32);
    constant G1 : unsigned(31 downto 0) := to_unsigned(OUT_W, 32);
    constant G2 : unsigned(31 downto 0) := to_unsigned(CHAIN, 32);
    constant FP : std_logic_vector(95 downto 0) :=
        std_logic_vector(G2) & std_logic_vector(G1) & std_logic_vector(G0);
begin
    -- lin, q, r: see zcu106_top_children.v.
    process (probe_in)
        variable lin  : std_logic_vector(OUT_W-1 downto 0);
        variable q, r : std_logic;
    begin
        lin := (others => '0');
        for i in integer range 0 to IN_W - 1 loop
            lin((i + i / OUT_W) mod OUT_W) := lin((i + i / OUT_W) mod OUT_W) xor probe_in(i);
        end loop;
        q := '0';
        for i in integer range 0 to IN_W - 2 loop
            q := q xor (probe_in(i) and probe_in(i + 1));
        end loop;
        r := '0';
        for i in integer range 0 to 95 loop
            r := r xor (FP(i) and probe_in(i mod IN_W));
        end loop;
        for j in integer range 0 to OUT_W - 1 loop
            lin(j) := lin(j) xor q xor r;
        end loop;
        probe_out <= lin;
    end process;
end architecture standin;

-- ---- fpga/zcu106/rtl/zcu106_eth_demo.v ----------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity zcu106_eth_demo is
    generic (
        OUR_MAC           : std_logic_vector(47 downto 0) := x"020000000001";
        UDP_ECHO_PORT     : std_logic_vector(15 downto 0) := x"270F";
        BLAST_START_DELAY : std_logic_vector(31 downto 0) := x"07735940"
    );
    port (
        clk                : in  std_logic;
        rst_n              : in  std_logic;
        gmii_txd           : out std_logic_vector(7 downto 0);
        gmii_tx_en         : out std_logic;
        gmii_tx_er         : out std_logic;
        gmii_rxd           : in  std_logic_vector(7 downto 0);
        gmii_rx_dv         : in  std_logic;
        gmii_rx_er         : in  std_logic;
        rx_frame           : out std_logic;
        tx_frame           : out std_logic;
        s_axi_awaddr       : in  std_logic_vector(7 downto 0);
        s_axi_awvalid      : in  std_logic;
        s_axi_awready      : out std_logic;
        s_axi_wdata        : in  std_logic_vector(31 downto 0);
        s_axi_wstrb        : in  std_logic_vector(3 downto 0);
        s_axi_wvalid       : in  std_logic;
        s_axi_wready       : out std_logic;
        s_axi_bresp        : out std_logic_vector(1 downto 0);
        s_axi_bvalid       : out std_logic;
        s_axi_bready       : in  std_logic;
        s_axi_araddr       : in  std_logic_vector(7 downto 0);
        s_axi_arvalid      : in  std_logic;
        s_axi_arready      : out std_logic;
        s_axi_rdata        : out std_logic_vector(31 downto 0);
        s_axi_rresp        : out std_logic_vector(1 downto 0);
        s_axi_rvalid       : out std_logic;
        s_axi_rready       : in  std_logic;
        blast_frames_clear : in  std_logic;
        blast_frames       : out std_logic_vector(31 downto 0)
    );
end entity zcu106_eth_demo;

architecture standin of zcu106_eth_demo is
    signal st  : std_logic_vector(164 downto 0);
    signal din : std_logic_vector(68 downto 0);
    signal fp  : std_logic_vector(95 downto 0);
begin
    din <= rst_n & gmii_rxd & gmii_rx_dv & gmii_rx_er &
           s_axi_awaddr & s_axi_awvalid & s_axi_wdata & s_axi_wstrb & s_axi_wvalid &
           s_axi_bready & s_axi_araddr & s_axi_arvalid & s_axi_rready &
           blast_frames_clear;
    fp  <= OUR_MAC & UDP_ECHO_PORT & BLAST_START_DELAY;
    process (clk)
    begin
        if rising_edge(clk) then
            st <= (st(163 downto 0) & st(164)) xor (din & fp);
        end if;
    end process;

    gmii_txd      <= st(7 downto 0);
    gmii_tx_en    <= st(8);
    gmii_tx_er    <= st(9);
    rx_frame      <= st(10);
    tx_frame      <= st(11);
    s_axi_awready <= st(12);
    s_axi_wready  <= st(13);
    s_axi_bresp   <= st(15 downto 14);
    s_axi_bvalid  <= st(16);
    s_axi_arready <= st(17);
    s_axi_rdata   <= st(49 downto 18);
    s_axi_rresp   <= st(51 downto 50);
    s_axi_rvalid  <= st(52);
    blast_frames  <= st(84 downto 53);
end architecture standin;

-- ---- fpga/zcu106/rtl/sfp_lb_tester.v ------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity sfp_lb_tester is
    port (
        clk        : in  std_logic;
        rst_n      : in  std_logic;
        ctrl       : in  std_logic_vector(3 downto 0);
        link_ok    : in  std_logic;
        gmii_txd   : out std_logic_vector(7 downto 0);
        gmii_tx_en : out std_logic;
        gmii_tx_er : out std_logic;
        gmii_rxd   : in  std_logic_vector(7 downto 0);
        gmii_rx_dv : in  std_logic;
        gmii_rx_er : in  std_logic;
        status     : out std_logic_vector(383 downto 0);
        ok_pulse   : out std_logic;
        bad_pulse  : out std_logic
    );
end entity sfp_lb_tester;

architecture standin of sfp_lb_tester is
    signal st  : std_logic_vector(395 downto 0);
    signal din : std_logic_vector(395 downto 0);
begin
    din <= (379 downto 0 => '0') & rst_n & ctrl & link_ok & gmii_rxd & gmii_rx_dv & gmii_rx_er;
    process (clk)
    begin
        if rising_edge(clk) then
            st <= (st(394 downto 0) & st(395)) xor din;
        end if;
    end process;

    gmii_txd   <= st(7 downto 0);
    gmii_tx_en <= st(8);
    gmii_tx_er <= st(9);
    status     <= st(393 downto 10);
    ok_pulse   <= st(394);
    bad_pulse  <= st(395);
end architecture standin;
