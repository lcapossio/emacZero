-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- PARITY MODEL ONLY - not for synthesis. GENERATED from
-- fpga/zcu106/rtl/zcu106_top.vhd by sim/parity/zcu106_top/gen_split.py; do not edit.
-- Renamed to zcu106_top_split, with the open-drain I2C pins split into
-- IIC_SCL_t, IIC_SDA_t and IIC_SDA_i. Everything else is the source verbatim.
-- =============================================================================
-- zcu106_top.vhd - emacZero over SFP (1000BASE-X) on the AMD ZCU106
--
--   SFP cage 0 <-> GTH <-> 1G/2.5G PCS/PMA IP (1000BASE-X) <-GMII-> eth_mac_sys
--
-- eth_mac_sys runs in PHY_INTERFACE="GMII" mode with its system clock, its
-- GMII TX clock and its GMII RX clock all on the PCS/PMA 125 MHz userclk2, so
-- the whole MAC and the demo L3 stack (ARP, ICMP echo, UDP echo on port 9999)
-- are one 125 MHz clock domain.
--
-- GTH reference clock (REFCLK_SI5328, set by build_zcu106.tcl):
--   0 (default): USER_MGT_SI570 (U56), 156.25 MHz at power-up, Quad 226
--      MGTREFCLK1 (U10/U9), shared into Quad 225. No setup needed; this is
--      the clock the AMD and verilog-ethernet ZCU102/ZCU106 SFP designs use.
--   1: Si5328 (U20), Quad 225 MGTREFCLK1 (W10/W9). It has no non-volatile
--      memory, so i2c_init programs it to 125 MHz over PL IIC1 (through the
--      TCA9548A mux) before the PCS/PMA reset is released.
-- Either way the GT makes the 125 MHz userclk2. A watchdog re-pulses the
-- PCS/PMA reset every 2 s until the GT reports reset done (covers the Si5328
-- lock time, which can be ~20 s). This logic runs from the free-running
-- 300 MHz user clock divided to 50 MHz, which is also the PCS/PMA independent
-- (DRP / reset) clock.
--
-- LEDs: 0 refclk ready (Si5328 programmed, or always on with the Si570)
--       1 I2C NACK seen        2 GT reset done
--       3 PCS link sync        4 1000BASE-X link up 5 RX frame activity
--       6 TX frame activity    7 userclk2 heartbeat (GT clock running)
-- DIP 0: 1 disables 1000BASE-X auto-negotiation (for partners without AN).
--
-- With ZCU106_SFP1_LB defined (build_zcu106.tcl ... lb), SFP cage 1 gets a
-- second PCS/PMA and sfp_lb_tester, which exercises the demo on SFP0 over a
-- fiber between the two cages; that build is zcu106_top_lb.vhd.
--
-- Both builds have JTAG access to the MAC's CSRs, for its statistics
-- counters: an fcapz JTAG-to-AXI bridge on USER4. Without the loopback, an
-- fcapz EIO on USER3 adds PCS/PMA event counters (see the counter block);
-- scripts/sfp_counters.py reads both.
--
-- VHDL has no preprocessor, and ZCU106_SFP1_LB changes the port list (the
-- SFP1 pins sit on GT pads, which a build without the second core cannot
-- carry). So each build is its own file with the same entity name:
-- this file is zcu106_top.v without ZCU106_SFP1_LB, zcu106_top_lb.vhd is
-- zcu106_top.v with it. A build reads exactly one of the two.
--
-- Vendor primitives (IBUFDS, BUFGCE_DIV), the PCS/PMA IP cores, the fcapz
-- cores and the Verilog-only children are declared as local components (no
-- library unisim); Vivado binds them in mixed-language synthesis.
-- VHDL port of fpga/zcu106/rtl/zcu106_top.v without ZCU106_SFP1_LB
-- (formally proven equivalent; see sim/parity/).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- VHDL-93 binds a component instance by default only to a directly visible
-- entity of the same name; Vivado binds the primitives, IP cores and Verilog
-- modules by name either way.
use work.all;

entity zcu106_top_split is
    generic (
        REFCLK_SI5328 : integer := 0        -- 0: USER_MGT_SI570, 1: Si5328
    );
    port (
        -- 300 MHz free-running user clock (Si570)
        USER_SI570_SYSCLK_P : in    std_logic;
        USER_SI570_SYSCLK_N : in    std_logic;
        CPU_RESET           : in    std_logic;  -- active high

        -- SFP cage 0, GTH, and its reference clock (see REFCLK_SI5328)
        SFP_REFCLK_P        : in    std_logic;
        SFP_REFCLK_N        : in    std_logic;
        SFP0_TX_P           : out   std_logic;
        SFP0_TX_N           : out   std_logic;
        SFP0_RX_P           : in    std_logic;
        SFP0_RX_N           : in    std_logic;
        SFP0_TX_DISABLE_B   : out   std_logic;  -- high = laser on (J16 also forces on)

        -- PL I2C to the Si5328 (through the TCA9548A mux); released (high-Z)
        -- when REFCLK_SI5328 = 0
        IIC_SCL_t           : out   std_logic;  -- parity split: scl_t
        IIC_SDA_t           : out   std_logic;  -- parity split: sda_t
        IIC_SDA_i           : in    std_logic;  -- parity split: the pin as read

        DIP_AN_DISABLE      : in    std_logic;
        LED                 : out   std_logic_vector(7 downto 0)
    );
end entity zcu106_top_split;

architecture rtl of zcu106_top_split is

    -- =========================================================================
    -- Components: vendor primitives, IP cores, fcapz cores, Verilog modules
    -- =========================================================================
    component IBUFDS is
        port (
            O  : out std_ulogic;
            I  : in  std_ulogic;
            IB : in  std_ulogic
        );
    end component IBUFDS;

    component BUFGCE_DIV is
        generic (
            BUFGCE_DIVIDE : integer := 1
        );
        port (
            O   : out std_ulogic;
            CE  : in  std_ulogic;
            CLR : in  std_ulogic;
            I   : in  std_ulogic
        );
    end component BUFGCE_DIV;

    component i2c_init is
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
    end component i2c_init;

    -- Vivado IP gig_ethernet_pcs_pma (build_zcu106.tcl), shared logic in core.
    component pcs_pma_1000basex is
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
    end component pcs_pma_1000basex;

    -- fcapz (fcapz/rtl/fcapz_ejtagaxi_xilinxus.v). CMD_FIFO_DEPTH and
    -- RESP_FIFO_DEPTH default to FIFO_DEPTH * 2 in Verilog; a VHDL-93 generic
    -- default cannot read another generic, so they carry the value that gives
    -- at the default FIFO_DEPTH (32).
    component fcapz_ejtagaxi_xilinxus is
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
    end component fcapz_ejtagaxi_xilinxus;

    -- fcapz (fcapz/rtl/fcapz_eio_xilinxus.v)
    component fcapz_eio_xilinxus is
        generic (
            IN_W  : integer := 32;
            OUT_W : integer := 32;
            CHAIN : integer := 3
        );
        port (
            probe_in  : in  std_logic_vector(IN_W-1 downto 0);
            probe_out : out std_logic_vector(OUT_W-1 downto 0)
        );
    end component fcapz_eio_xilinxus;

    -- fpga/zcu106/rtl/zcu106_eth_demo.v (Verilog)
    component zcu106_eth_demo is
        generic (
            OUR_MAC           : std_logic_vector(47 downto 0) := x"020000000001";
            UDP_ECHO_PORT     : std_logic_vector(15 downto 0) := x"270F";      -- 16'd9999
            BLAST_START_DELAY : std_logic_vector(31 downto 0) := x"07735940"   -- 32'd125_000_000
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
    end component zcu106_eth_demo;

    constant OUR_MAC       : std_logic_vector(47 downto 0) := x"020000000001";
    constant UDP_ECHO_PORT : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(9999, 16));

    attribute ASYNC_REG : string;

    -- 50 MHz free-running clock
    signal clk_300_ibuf : std_logic;
    signal clk_50       : std_logic;

    signal rst50_sync : std_logic_vector(2 downto 0);
    attribute ASYNC_REG of rst50_sync : signal is "TRUE";
    signal rst50_n    : std_logic;

    -- Reference clock bring-up
    signal scl_t, sda_t : std_logic;
    signal refclk_ready : std_logic;
    signal i2c_nacks    : std_logic_vector(7 downto 0);

    -- GT bring-up watchdog
    constant WD_PERIOD   : integer := 100_000_000;  -- 2 s at 50 MHz
    constant RESET_PULSE : integer := 50_000;       -- 1 ms
    signal gt_resetdone : std_logic;
    signal gt_done_sync : std_logic_vector(2 downto 0);
    attribute ASYNC_REG of gt_done_sync : signal is "TRUE";
    signal wd_cnt       : unsigned(26 downto 0);
    signal pcs_reset    : std_logic;

    -- PCS/PMA
    signal userclk2       : std_logic;
    signal gtrefclk, userclk, rxuserclk, rxuserclk2 : std_logic;   -- shared with SFP1
    signal gt_mmcm_locked : std_logic;
    signal pma_reset_out  : std_logic;
    signal pcs_status     : std_logic_vector(15 downto 0);

    signal gmii_txd   : std_logic_vector(7 downto 0);
    signal gmii_tx_en : std_logic;
    signal gmii_tx_er : std_logic;
    signal gmii_rxd   : std_logic_vector(7 downto 0);
    signal gmii_rx_dv : std_logic;
    signal gmii_rx_er : std_logic;

    signal an_dis_sync : std_logic_vector(1 downto 0);
    attribute ASYNC_REG of an_dis_sync : signal is "TRUE";
    signal an_disable : std_logic;
    signal an_restart : std_logic;
    -- {~an_disable, 4'b0000} (VHDL-93 port maps take names, not expressions)
    signal pcs_cfg_vector : std_logic_vector(4 downto 0);

    -- MAC reset
    signal gt_locked_sync, pma_rst_sync : std_logic_vector(1 downto 0);
    attribute ASYNC_REG of gt_locked_sync : signal is "TRUE";
    attribute ASYNC_REG of pma_rst_sync   : signal is "TRUE";
    signal mac_rst_async_n : std_logic;
    signal mac_rst_sync    : std_logic_vector(2 downto 0);
    attribute ASYNC_REG of mac_rst_sync : signal is "TRUE";
    signal rst_n           : std_logic;

    -- emacZero MAC + demo L3 stack on SFP0
    signal demo_rx_frame, demo_tx_frame : std_logic;
    signal demo_cnt_clear    : std_logic;
    signal demo_blast_frames : std_logic_vector(31 downto 0);

    -- JTAG-to-AXI bridge (USER4) -> MAC CSRs
    signal jaxi_awaddr, jaxi_araddr, jaxi_wdata, jaxi_rdata : std_logic_vector(31 downto 0);
    signal jaxi_wstrb  : std_logic_vector(3 downto 0);
    signal jaxi_bresp, jaxi_rresp : std_logic_vector(1 downto 0);
    signal jaxi_awvalid, jaxi_awready, jaxi_wvalid, jaxi_wready : std_logic;
    signal jaxi_bvalid, jaxi_bready, jaxi_arvalid, jaxi_arready : std_logic;
    signal jaxi_rvalid, jaxi_rready : std_logic;
    signal jaxi_axi_rst : std_logic;   -- ~rst_n

    -- PCS/PMA event counters
    signal cnt_ctrl     : std_logic_vector(7 downto 0);
    signal cnt_clr_sync : std_logic_vector(1 downto 0);
    attribute ASYNC_REG of cnt_clr_sync : signal is "TRUE";

    signal st_link_q, st_sync_q, st_rudi_q, st_rxer_q : std_logic;
    signal link_downs, sync_losses, rudi_inv_events : unsigned(31 downto 0);
    signal disperr_cycles, notintable_cycles, rx_er_events : unsigned(31 downto 0);
    signal cnt_probe_in : std_logic_vector(255 downto 0);

    -- LEDs
    signal rx_ev, tx_ev : std_logic;
    signal rx_led_cnt, tx_led_cnt : unsigned(22 downto 0);
    signal heartbeat : unsigned(26 downto 0) := (others => '0');

begin

    -- =========================================================================
    -- 50 MHz free-running clock: 300 MHz / 6
    -- =========================================================================
    u_sysclk_ibuf : IBUFDS
        port map (
            I  => USER_SI570_SYSCLK_P,
            IB => USER_SI570_SYSCLK_N,
            O  => clk_300_ibuf
        );

    u_clk_50_buf : BUFGCE_DIV
        generic map (BUFGCE_DIVIDE => 6)
        port map (
            I   => clk_300_ibuf,
            CE  => '1',
            CLR => '0',
            O   => clk_50
        );

    -- CPU_RESET synchronized into clk_50 (async assert, sync release)
    process (clk_50, CPU_RESET)
    begin
        if CPU_RESET = '1' then
            rst50_sync <= "000";
        elsif rising_edge(clk_50) then
            rst50_sync <= rst50_sync(1 downto 0) & '1';
        end if;
    end process;
    rst50_n <= rst50_sync(2);

    -- =========================================================================
    -- Reference clock bring-up (Si5328 over I2C, or nothing for the Si570)
    -- =========================================================================
    IIC_SCL_t <= scl_t;
    IIC_SDA_t <= sda_t;

    gen_si5328 : if REFCLK_SI5328 /= 0 generate
        u_si5328_init : i2c_init
            generic map (
                CLK_HZ      => 50_000_000,
                I2C_HZ      => 100_000,
                START_DELAY => 50_000_000,        -- 1 s: let the system controller
                                                  -- finish its own Si5328 setup
                RETRY_DELAY => 50_000_000 / 10,
                DONE_DELAY  => 50_000_000 / 10    -- lock wait is the GT watchdog's job
            )
            port map (
                clk        => clk_50,
                rst_n      => rst50_n,
                scl_t      => scl_t,
                sda_t      => sda_t,
                sda_i      => IIC_SDA_i,
                done       => refclk_ready,
                busy       => open,
                nack_count => i2c_nacks
            );
    end generate gen_si5328;

    gen_si570 : if REFCLK_SI5328 = 0 generate
        -- The USER_MGT_SI570 runs at 156.25 MHz from power-up; leave I2C alone.
        scl_t        <= '1';
        sda_t        <= '1';
        refclk_ready <= '1';
        i2c_nacks    <= x"00";
    end generate gen_si570;

    -- Keep the SFP laser off until the reference clock is ready.
    SFP0_TX_DISABLE_B <= refclk_ready;

    -- GT bring-up watchdog: hold the PCS/PMA in reset until the reference
    -- clock is ready, then pulse its reset for 1 ms every 2 s until the GT
    -- reports reset done (covers the Si5328 lock time).
    process (clk_50)
    begin
        if rising_edge(clk_50) then
            gt_done_sync <= gt_done_sync(1 downto 0) & gt_resetdone;
        end if;
    end process;

    process (clk_50, rst50_n)
    begin
        if rst50_n = '0' then
            wd_cnt    <= (others => '0');
            pcs_reset <= '1';
        elsif rising_edge(clk_50) then
            if refclk_ready = '0' then
                wd_cnt    <= (others => '0');
                pcs_reset <= '1';
            elsif gt_done_sync(2) = '1' then
                wd_cnt    <= (others => '0');
                pcs_reset <= '0';
            else
                if wd_cnt = to_unsigned(WD_PERIOD - 1, 27) then
                    wd_cnt <= (others => '0');
                else
                    wd_cnt <= wd_cnt + 1;
                end if;
                if wd_cnt < to_unsigned(RESET_PULSE, 27) then
                    pcs_reset <= '1';
                else
                    pcs_reset <= '0';
                end if;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- PCS/PMA (1000BASE-X over GTH, shared logic in core)
    -- =========================================================================

    -- DIP_AN_DISABLE is a static strap; synchronize it into userclk2, the
    -- clock the PCS/PMA samples configuration_vector on.
    process (userclk2)
    begin
        if rising_edge(userclk2) then
            an_dis_sync <= an_dis_sync(0) & DIP_AN_DISABLE;
        end if;
    end process;

    an_disable <= an_dis_sync(1);
    an_restart <= '0';

    -- [4] AN enable, [3] isolate, [2] powerdown, [1] loopback, [0] unidir
    pcs_cfg_vector <= (not an_disable) & "0000";

    u_pcs_pma : pcs_pma_1000basex
        port map (
            gtrefclk_p             => SFP_REFCLK_P,
            gtrefclk_n             => SFP_REFCLK_N,
            gtrefclk_out           => gtrefclk,
            txn                    => SFP0_TX_N,
            txp                    => SFP0_TX_P,
            rxn                    => SFP0_RX_N,
            rxp                    => SFP0_RX_P,
            independent_clock_bufg => clk_50,
            userclk_out            => userclk,
            userclk2_out           => userclk2,
            rxuserclk_out          => rxuserclk,
            rxuserclk2_out         => rxuserclk2,
            gtpowergood            => open,
            resetdone              => gt_resetdone,
            pma_reset_out          => pma_reset_out,
            mmcm_locked_out        => gt_mmcm_locked,
            gmii_txd               => gmii_txd,
            gmii_tx_en             => gmii_tx_en,
            gmii_tx_er             => gmii_tx_er,
            gmii_rxd               => gmii_rxd,
            gmii_rx_dv             => gmii_rx_dv,
            gmii_rx_er             => gmii_rx_er,
            gmii_isolate           => open,
            configuration_vector   => pcs_cfg_vector,
            an_interrupt           => open,
            -- 1000BASE-X base page: full duplex only, no PAUSE advertised
            an_adv_config_vector   => x"0020",
            an_restart_config      => an_restart,
            status_vector          => pcs_status,
            reset                  => pcs_reset,
            signal_detect          => '1'
        );

    -- MAC reset: released once the GT is up and userclk2 is running. The
    -- three PCS/PMA status bits are each synchronized into clk_50 (reset done
    -- reuses the watchdog's gt_done_sync) and then combined in a flop, so the
    -- async reset below is driven glitch-free.
    process (clk_50, rst50_n)
    begin
        if rst50_n = '0' then
            gt_locked_sync  <= "00";
            pma_rst_sync    <= "11";
            mac_rst_async_n <= '0';
        elsif rising_edge(clk_50) then
            gt_locked_sync  <= gt_locked_sync(0) & gt_mmcm_locked;
            pma_rst_sync    <= pma_rst_sync(0)   & pma_reset_out;
            mac_rst_async_n <= gt_done_sync(2) and gt_locked_sync(1) and not pma_rst_sync(1);
        end if;
    end process;

    process (userclk2, mac_rst_async_n)
    begin
        if mac_rst_async_n = '0' then
            mac_rst_sync <= "000";
        elsif rising_edge(userclk2) then
            mac_rst_sync <= mac_rst_sync(1 downto 0) & '1';
        end if;
    end process;
    rst_n <= mac_rst_sync(2);

    -- =========================================================================
    -- emacZero MAC + demo L3 stack on SFP0
    -- =========================================================================

    -- JTAG-to-AXI bridge (USER4) -> MAC CSRs. Single-beat accesses; the CSR
    -- address is the low byte of the AXI address.
    jaxi_axi_rst <= not rst_n;

    u_jtag_axi : fcapz_ejtagaxi_xilinxus
        generic map (
            ADDR_W => 32,
            DATA_W => 32,
            CHAIN  => 4
        )
        port map (
            axi_clk        => userclk2,
            axi_rst        => jaxi_axi_rst,
            m_axi_awaddr   => jaxi_awaddr,
            m_axi_awlen    => open,
            m_axi_awsize   => open,
            m_axi_awburst  => open,
            m_axi_awvalid  => jaxi_awvalid,
            m_axi_awready  => jaxi_awready,
            m_axi_awprot   => open,
            m_axi_wdata    => jaxi_wdata,
            m_axi_wstrb    => jaxi_wstrb,
            m_axi_wvalid   => jaxi_wvalid,
            m_axi_wready   => jaxi_wready,
            m_axi_wlast    => open,
            m_axi_bresp    => jaxi_bresp,
            m_axi_bvalid   => jaxi_bvalid,
            m_axi_bready   => jaxi_bready,
            m_axi_araddr   => jaxi_araddr,
            m_axi_arlen    => open,
            m_axi_arsize   => open,
            m_axi_arburst  => open,
            m_axi_arvalid  => jaxi_arvalid,
            m_axi_arready  => jaxi_arready,
            m_axi_arprot   => open,
            m_axi_rdata    => jaxi_rdata,
            m_axi_rresp    => jaxi_rresp,
            m_axi_rvalid   => jaxi_rvalid,
            m_axi_rlast    => '1',
            m_axi_rready   => jaxi_rready,
            debug_tck      => open,
            debug_tck_edge => open,
            debug_axi      => open,
            debug_axi_edge => open
        );

    u_demo : zcu106_eth_demo
        generic map (
            OUR_MAC       => OUR_MAC,
            UDP_ECHO_PORT => UDP_ECHO_PORT
        )
        port map (
            clk                => userclk2,
            rst_n              => rst_n,
            gmii_txd           => gmii_txd,
            gmii_tx_en         => gmii_tx_en,
            gmii_tx_er         => gmii_tx_er,
            gmii_rxd           => gmii_rxd,
            gmii_rx_dv         => gmii_rx_dv,
            gmii_rx_er         => gmii_rx_er,
            rx_frame           => demo_rx_frame,
            tx_frame           => demo_tx_frame,
            s_axi_awaddr       => jaxi_awaddr(7 downto 0),
            s_axi_awvalid      => jaxi_awvalid,
            s_axi_awready      => jaxi_awready,
            s_axi_wdata        => jaxi_wdata,
            s_axi_wstrb        => jaxi_wstrb,
            s_axi_wvalid       => jaxi_wvalid,
            s_axi_wready       => jaxi_wready,
            s_axi_bresp        => jaxi_bresp,
            s_axi_bvalid       => jaxi_bvalid,
            s_axi_bready       => jaxi_bready,
            s_axi_araddr       => jaxi_araddr(7 downto 0),
            s_axi_arvalid      => jaxi_arvalid,
            s_axi_arready      => jaxi_arready,
            s_axi_rdata        => jaxi_rdata,
            s_axi_rresp        => jaxi_rresp,
            s_axi_rvalid       => jaxi_rvalid,
            s_axi_rready       => jaxi_rready,
            blast_frames_clear => demo_cnt_clear,
            blast_frames       => demo_blast_frames
        );

    -- =========================================================================
    -- PCS/PMA event counters (32-bit, wrapping), read over the EIO (USER3)
    -- with the MAC statistics, to tell a physical-layer event on SFP0 from a
    -- frame lost in the logic. All in userclk2; status_vector bits per PG047:
    -- [0] link, [1] sync, [4] RUDI(INVALID), [5] RXDISPERR, [6] RXNOTINTABLE.
    -- eio-write: [0] clear (these counters and the demo's blast_frames).
    -- eio-read:  [15:0] status_vector, [47:16] link-down events,
    --   [79:48] sync-loss events, [111:80] RUDI(INVALID) events,
    --   [143:112] disparity-error cycles, [175:144] not-in-table cycles,
    --   [207:176] GMII rx_er events, [239:208] blast frames generated,
    --   [243:240] layout version 1, [255:244] marker 12'h107.
    -- =========================================================================
    process (userclk2)
    begin
        if rising_edge(userclk2) then
            cnt_clr_sync <= cnt_clr_sync(0) & cnt_ctrl(0);
        end if;
    end process;
    demo_cnt_clear <= cnt_clr_sync(1);

    process (userclk2, rst_n)
    begin
        if rst_n = '0' then
            st_link_q <= '0';
            st_sync_q <= '0';
            st_rudi_q <= '0';
            st_rxer_q <= '0';
            link_downs        <= (others => '0');
            sync_losses       <= (others => '0');
            rudi_inv_events   <= (others => '0');
            disperr_cycles    <= (others => '0');
            notintable_cycles <= (others => '0');
            rx_er_events      <= (others => '0');
        elsif rising_edge(userclk2) then
            st_link_q <= pcs_status(0);
            st_sync_q <= pcs_status(1);
            st_rudi_q <= pcs_status(4);
            st_rxer_q <= gmii_rx_er;
            if demo_cnt_clear = '1' then
                link_downs        <= (others => '0');
                sync_losses       <= (others => '0');
                rudi_inv_events   <= (others => '0');
                disperr_cycles    <= (others => '0');
                notintable_cycles <= (others => '0');
                rx_er_events      <= (others => '0');
            else
                if st_link_q = '1' and pcs_status(0) = '0' then link_downs      <= link_downs + 1; end if;
                if st_sync_q = '1' and pcs_status(1) = '0' then sync_losses     <= sync_losses + 1; end if;
                if st_rudi_q = '0' and pcs_status(4) = '1' then rudi_inv_events <= rudi_inv_events + 1; end if;
                if pcs_status(5) = '1' then disperr_cycles    <= disperr_cycles + 1; end if;
                if pcs_status(6) = '1' then notintable_cycles <= notintable_cycles + 1; end if;
                if st_rxer_q = '0' and gmii_rx_er = '1'    then rx_er_events    <= rx_er_events + 1; end if;
            end if;
        end if;
    end process;

    cnt_probe_in <= x"107" & "0001" & demo_blast_frames & std_logic_vector(rx_er_events) &
                    std_logic_vector(notintable_cycles) & std_logic_vector(disperr_cycles) &
                    std_logic_vector(rudi_inv_events) &
                    std_logic_vector(sync_losses) & std_logic_vector(link_downs) & pcs_status;

    u_cnt_eio : fcapz_eio_xilinxus
        generic map (
            IN_W  => 256,
            OUT_W => 8,
            CHAIN => 3
        )
        port map (
            probe_in  => cnt_probe_in,
            probe_out => cnt_ctrl
        );

    -- =========================================================================
    -- LEDs
    -- =========================================================================
    -- Activity: stretch a one-cycle pulse to ~67 ms at 125 MHz.
    rx_ev <= demo_rx_frame;
    tx_ev <= demo_tx_frame;

    process (userclk2, rst_n)
    begin
        if rst_n = '0' then
            rx_led_cnt <= (others => '0');
            tx_led_cnt <= (others => '0');
        elsif rising_edge(userclk2) then
            if rx_ev = '1' then
                rx_led_cnt <= (others => '1');
            elsif rx_led_cnt /= 0 then
                rx_led_cnt <= rx_led_cnt - 1;
            end if;
            if tx_ev = '1' then
                tx_led_cnt <= (others => '1');
            elsif tx_led_cnt /= 0 then
                tx_led_cnt <= tx_led_cnt - 1;
            end if;
        end if;
    end process;

    process (userclk2)
    begin
        if rising_edge(userclk2) then
            heartbeat <= heartbeat + 1;
        end if;
    end process;

    LED(0) <= refclk_ready;
    LED(1) <= '1' when i2c_nacks /= x"00" else '0';
    LED(2) <= gt_resetdone;
    LED(3) <= pcs_status(1);
    LED(4) <= pcs_status(0);
    LED(5) <= '1' when rx_led_cnt /= 0 else '0';
    LED(6) <= '1' when tx_led_cnt /= 0 else '0';
    LED(7) <= heartbeat(26);

end architecture rtl;
