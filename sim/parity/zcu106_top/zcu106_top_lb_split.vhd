-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- PARITY MODEL ONLY - not for synthesis. GENERATED from
-- fpga/zcu106/rtl/zcu106_top_lb.vhd by sim/parity/zcu106_top/gen_split.py; do not edit.
-- Renamed to zcu106_top_split, with the open-drain I2C pins split into
-- IIC_SCL_t, IIC_SDA_t and IIC_SDA_i, and the EIO probe_in brought out on
-- PARITY_PROBE_IN. Everything else is the source verbatim.
-- =============================================================================
-- zcu106_top_lb.vhd - emacZero over SFP (1000BASE-X) on the AMD ZCU106,
-- SFP0 <-> SFP1 loopback build
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
-- This is the build with ZCU106_SFP1_LB defined (build_zcu106.tcl ... lb):
-- SFP cage 1 gets a second PCS/PMA and sfp_lb_tester, which exercises the
-- demo on SFP0 over a fiber between the two cages; the LEDs then show the
-- loopback test (see the LED block at the end) and an fcapz EIO drives and
-- reads the tester. The EIO can also switch either laser off, reset the SFP1
-- core, turn auto-negotiation off or restart it, and reads per-hop GMII frame
-- counters and a userclk2 frequency meter (see the EIO block).
--
-- Both builds have JTAG access to the MAC's CSRs, for its statistics
-- counters: an fcapz JTAG-to-AXI bridge on USER4.
--
-- VHDL has no preprocessor, and ZCU106_SFP1_LB changes the port list (the
-- SFP1 pins sit on GT pads, which a build without the second core cannot
-- carry). So each build is its own file with the same entity name:
-- zcu106_top.vhd is zcu106_top.v without ZCU106_SFP1_LB, this file is
-- zcu106_top.v with it. A build reads exactly one of the two.
--
-- Vendor primitives (IBUFDS, BUFGCE_DIV), the PCS/PMA IP cores, the fcapz
-- cores and the Verilog-only children are declared as local components (no
-- library unisim); Vivado binds them in mixed-language synthesis.
-- VHDL port of fpga/zcu106/rtl/zcu106_top.v with ZCU106_SFP1_LB defined
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
        -- SFP cage 1 (loopback tester), same GTH quad
        SFP1_TX_P           : out   std_logic;
        SFP1_TX_N           : out   std_logic;
        SFP1_RX_P           : in    std_logic;
        SFP1_RX_N           : in    std_logic;
        SFP1_TX_DISABLE_B   : out   std_logic;

        -- PL I2C to the Si5328 (through the TCA9548A mux); released (high-Z)
        -- when REFCLK_SI5328 = 0
        IIC_SCL_t           : out   std_logic;  -- parity split: scl_t
        IIC_SDA_t           : out   std_logic;  -- parity split: sda_t
        IIC_SDA_i           : in    std_logic;  -- parity split: the pin as read
        PARITY_PROBE_IN     : out   std_logic_vector(607 downto 0);  -- parity split: EIO probe_in

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

    -- Vivado IP gig_ethernet_pcs_pma (build_zcu106.tcl lb), shared logic in
    -- the example design: takes its clocks and resets from pcs_pma_1000basex.
    component pcs_pma_1000basex_ns is
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
    end component pcs_pma_1000basex_ns;

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

    -- fpga/zcu106/rtl/sfp_lb_tester.v
    component sfp_lb_tester is
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
    end component sfp_lb_tester;

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

    signal lb_ctrl : std_logic_vector(15 downto 0);
    signal laser0_off_sync, laser1_off_sync, sfp1_rst_sync : std_logic_vector(1 downto 0);
    attribute ASYNC_REG of laser0_off_sync : signal is "TRUE";
    attribute ASYNC_REG of laser1_off_sync : signal is "TRUE";
    attribute ASYNC_REG of sfp1_rst_sync   : signal is "TRUE";

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
    signal an_off_sync, an_rst_sync, lb_clr_sync : std_logic_vector(1 downto 0);
    attribute ASYNC_REG of an_off_sync : signal is "TRUE";
    attribute ASYNC_REG of an_rst_sync : signal is "TRUE";
    attribute ASYNC_REG of lb_clr_sync : signal is "TRUE";
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

    -- SFP1 loopback tester
    signal lb_gmii_txd, lb_gmii_rxd : std_logic_vector(7 downto 0);
    signal lb_gmii_tx_en, lb_gmii_tx_er, lb_gmii_rx_dv, lb_gmii_rx_er : std_logic;
    signal lb_pcs_status   : std_logic_vector(15 downto 0);
    signal lb_gt_resetdone : std_logic;
    signal lb_pcs_reset    : std_logic;   -- pcs_reset | sfp1_rst_sync[1]

    signal link0_q, link1_q : std_logic;
    signal link0_downs, link1_downs : unsigned(15 downto 0);

    signal d_rx_q, d_tx_q, t_rx_q, t_tx_q, d_er_q, t_er_q : std_logic;
    signal demo_rx_frames, demo_tx_frames, tst_rx_frames, tst_tx_frames : unsigned(15 downto 0);
    signal demo_rx_errs, tst_rx_errs : unsigned(15 downto 0);

    signal fm_div  : unsigned(21 downto 0) := (others => '0');
    signal fm_tog  : std_logic := '0';
    signal fm_sync : std_logic_vector(2 downto 0) := (others => '0');
    attribute ASYNC_REG of fm_sync : signal is "TRUE";
    signal fm_cnt  : unsigned(23 downto 0) := (others => '0');
    signal fm_meas : unsigned(23 downto 0) := (others => '0');

    signal lb_status : std_logic_vector(383 downto 0);
    signal lb_ok_pulse, lb_bad_pulse : std_logic;
    signal lb_link_ok : std_logic;   -- pcs_status[0] && lb_pcs_status[0]

    signal refclk_sel  : std_logic;
    signal lb_probe_in : std_logic_vector(607 downto 0);

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
    -- The loopback build can also switch either laser off, and reset the
    -- SFP1 core, from the EIO (bits listed with the PCS/PMA AN controls).
    process (clk_50)
    begin
        if rising_edge(clk_50) then
            laser0_off_sync <= laser0_off_sync(0) & lb_ctrl(8);
            laser1_off_sync <= laser1_off_sync(0) & lb_ctrl(4);
            sfp1_rst_sync   <= sfp1_rst_sync(0)   & lb_ctrl(5);
        end if;
    end process;
    SFP0_TX_DISABLE_B <= refclk_ready and not laser0_off_sync(1);

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

    -- fcapz EIO outputs (TCK domain, static levels set by the host):
    --   [0] run  [1] clear  [2] negative frames  [3] short payloads
    --       (all four go to sfp_lb_tester, which synchronizes them)
    --   [4] SFP1 laser off  [5] SFP1 PCS/PMA reset  [6] AN off (both cores,
    --   ORed with DIP 0)  [7] AN restart (both, rising edge)  [8] SFP0 laser
    --   off (no effect while J16 forces the laser on)
    process (userclk2)
    begin
        if rising_edge(userclk2) then
            an_off_sync <= an_off_sync(0) & lb_ctrl(6);
            an_rst_sync <= an_rst_sync(0) & lb_ctrl(7);
            lb_clr_sync <= lb_clr_sync(0) & lb_ctrl(1);
        end if;
    end process;
    an_disable <= an_dis_sync(1) or an_off_sync(1);
    an_restart <= an_rst_sync(1);

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

    demo_cnt_clear <= '0';

    -- =========================================================================
    -- SFP1 loopback tester: a second PCS/PMA on the neighboring GTH channel
    -- (sharing core 0's reference clock, user clocks and resets), with
    -- sfp_lb_tester playing a host that pings / ARPs / UDP-echoes the demo
    -- on SFP0 over the fiber. Driven and read over JTAG by the fcapz EIO.
    -- =========================================================================
    lb_pcs_reset <= pcs_reset or sfp1_rst_sync(1);

    u_pcs_pma_sfp1 : pcs_pma_1000basex_ns
        port map (
            gtrefclk               => gtrefclk,
            txn                    => SFP1_TX_N,
            txp                    => SFP1_TX_P,
            rxn                    => SFP1_RX_N,
            rxp                    => SFP1_RX_P,
            independent_clock_bufg => clk_50,
            txoutclk               => open,
            gtpowergood            => open,
            rxoutclk               => open,
            resetdone              => lb_gt_resetdone,
            cplllock               => open,
            mmcm_reset             => open,
            userclk                => userclk,
            userclk2               => userclk2,
            pma_reset              => pma_reset_out,
            mmcm_locked            => gt_mmcm_locked,
            rxuserclk              => rxuserclk,
            rxuserclk2             => rxuserclk2,
            gmii_txd               => lb_gmii_txd,
            gmii_tx_en             => lb_gmii_tx_en,
            gmii_tx_er             => lb_gmii_tx_er,
            gmii_rxd               => lb_gmii_rxd,
            gmii_rx_dv             => lb_gmii_rx_dv,
            gmii_rx_er             => lb_gmii_rx_er,
            gmii_isolate           => open,
            configuration_vector   => pcs_cfg_vector,
            an_interrupt           => open,
            an_adv_config_vector   => x"0020",
            an_restart_config      => an_restart,
            status_vector          => lb_pcs_status,
            reset                  => lb_pcs_reset,
            signal_detect          => '1'
        );

    SFP1_TX_DISABLE_B <= refclk_ready and not laser1_off_sync(1);

    -- Link-down events per core (falling edges of status_vector[0])
    process (userclk2, rst_n)
    begin
        if rst_n = '0' then
            link0_q     <= '0';
            link1_q     <= '0';
            link0_downs <= (others => '0');
            link1_downs <= (others => '0');
        elsif rising_edge(userclk2) then
            link0_q <= pcs_status(0);
            link1_q <= lb_pcs_status(0);
            if lb_clr_sync(1) = '1' then
                link0_downs <= (others => '0');
                link1_downs <= (others => '0');
            else
                if link0_q = '1' and pcs_status(0) = '0' then
                    link0_downs <= link0_downs + 1;
                end if;
                if link1_q = '1' and lb_pcs_status(0) = '0' then
                    link1_downs <= link1_downs + 1;
                end if;
            end if;
        end if;
    end process;

    -- Frame counters at each GMII hop (starts of tx_en / rx_dv, and frames
    -- with rx_er), to show where frames get lost: tester TX -> SFP1 PCS ->
    -- fiber -> SFP0 PCS -> demo RX, and back.
    process (userclk2, rst_n)
    begin
        if rst_n = '0' then
            d_rx_q <= '0';
            d_tx_q <= '0';
            t_rx_q <= '0';
            t_tx_q <= '0';
            d_er_q <= '0';
            t_er_q <= '0';
            demo_rx_frames <= (others => '0');
            demo_tx_frames <= (others => '0');
            tst_rx_frames  <= (others => '0');
            tst_tx_frames  <= (others => '0');
            demo_rx_errs   <= (others => '0');
            tst_rx_errs    <= (others => '0');
        elsif rising_edge(userclk2) then
            d_rx_q <= gmii_rx_dv;
            d_tx_q <= gmii_tx_en;
            t_rx_q <= lb_gmii_rx_dv;
            t_tx_q <= lb_gmii_tx_en;
            d_er_q <= gmii_rx_er;
            t_er_q <= lb_gmii_rx_er;
            if lb_clr_sync(1) = '1' then
                demo_rx_frames <= (others => '0');
                demo_tx_frames <= (others => '0');
                tst_rx_frames  <= (others => '0');
                tst_tx_frames  <= (others => '0');
                demo_rx_errs   <= (others => '0');
                tst_rx_errs    <= (others => '0');
            else
                if gmii_rx_dv    = '1' and d_rx_q = '0' then demo_rx_frames <= demo_rx_frames + 1; end if;
                if gmii_tx_en    = '1' and d_tx_q = '0' then demo_tx_frames <= demo_tx_frames + 1; end if;
                if lb_gmii_rx_dv = '1' and t_rx_q = '0' then tst_rx_frames  <= tst_rx_frames  + 1; end if;
                if lb_gmii_tx_en = '1' and t_tx_q = '0' then tst_tx_frames  <= tst_tx_frames  + 1; end if;
                if gmii_rx_er    = '1' and d_er_q = '0' then demo_rx_errs   <= demo_rx_errs   + 1; end if;
                if lb_gmii_rx_er = '1' and t_er_q = '0' then tst_rx_errs    <= tst_rx_errs    + 1; end if;
            end if;
        end if;
    end process;

    -- userclk2 frequency: cycles per 2^22 clk_50 cycles (83.9 ms); 125 MHz
    -- reads as about 10,485,760. The window is a clk_50 toggle synchronized
    -- into userclk2; the result holds for a whole window.
    process (clk_50)
    begin
        if rising_edge(clk_50) then
            fm_div <= fm_div + 1;
            if fm_div = to_unsigned(16#3FFFFF#, 22) then
                fm_tog <= not fm_tog;
            end if;
        end if;
    end process;

    process (userclk2)
    begin
        if rising_edge(userclk2) then
            fm_sync <= fm_sync(1 downto 0) & fm_tog;
            if fm_sync(2) /= fm_sync(1) then
                fm_meas <= fm_cnt;
                fm_cnt  <= to_unsigned(1, 24);
            elsif fm_cnt /= to_unsigned(16#FFFFFF#, 24) then
                fm_cnt  <= fm_cnt + 1;
            end if;
        end if;
    end process;

    lb_link_ok <= pcs_status(0) and lb_pcs_status(0);

    u_lb : sfp_lb_tester
        port map (
            clk        => userclk2,
            rst_n      => rst_n,
            ctrl       => lb_ctrl(3 downto 0),
            link_ok    => lb_link_ok,
            gmii_txd   => lb_gmii_txd,
            gmii_tx_en => lb_gmii_tx_en,
            gmii_tx_er => lb_gmii_tx_er,
            gmii_rxd   => lb_gmii_rxd,
            gmii_rx_dv => lb_gmii_rx_dv,
            gmii_rx_er => lb_gmii_rx_er,
            status     => lb_status,
            ok_pulse   => lb_ok_pulse,
            bad_pulse  => lb_bad_pulse
        );

    -- EIO (USER3). eio-write: lb_ctrl, see the AN controls above.
    -- eio-read: [383:0] tester status (see sfp_lb_tester.v),
    --   [399:384] SFP0 PCS status_vector, [415:400] SFP1 PCS status_vector,
    --   [431:416] SFP0 link-down count, [447:432] SFP1 link-down count,
    --   [463:448] demo RX frames, [479:464] demo TX frames,
    --   [495:480] tester TX frames, [511:496] tester RX frames,
    --   [527:512] demo RX error frames, [543:528] tester RX error frames,
    --   [567:544] userclk2 cycles per 2^22 clk_50 cycles,
    --   [576] SFP0 GT reset done, [577] SFP1 GT reset done,
    --   [578] refclk ready, [579] AN disabled, [580] REFCLK_SI5328,
    --   [581] MAC out of reset, [595:592] layout version 2,
    --   [607:596] marker 12'h106.
    refclk_sel <= '1' when REFCLK_SI5328 /= 0 else '0';

    lb_probe_in <= x"106" & "0010" & "0000000000" & rst_n & refclk_sel & an_disable &
                   refclk_ready & lb_gt_resetdone & gt_resetdone &
                   x"00" & std_logic_vector(fm_meas) &
                   std_logic_vector(tst_rx_errs) & std_logic_vector(demo_rx_errs) &
                   std_logic_vector(tst_rx_frames) & std_logic_vector(tst_tx_frames) &
                   std_logic_vector(demo_tx_frames) & std_logic_vector(demo_rx_frames) &
                   std_logic_vector(link1_downs) & std_logic_vector(link0_downs) &
                   lb_pcs_status & pcs_status & lb_status;

    PARITY_PROBE_IN <= lb_probe_in;
    u_eio : fcapz_eio_xilinxus
        generic map (
            IN_W  => 608,
            OUT_W => 16,
            CHAIN => 3
        )
        port map (
            probe_in  => lb_probe_in,
            probe_out => lb_ctrl
        );

    -- =========================================================================
    -- LEDs
    -- =========================================================================
    -- Activity: stretch a one-cycle pulse to ~67 ms at 125 MHz.
    rx_ev <= lb_ok_pulse;
    tx_ev <= lb_bad_pulse;

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

    -- Loopback build: 0 SFP0 link up  1 SFP1 link up  2 both GTs reset done
    --   3 correct reply seen  4 bad reply / timeout seen  5 tester running
    --   6 any failure counted since clear (sticky)  7 heartbeat
    LED(0) <= pcs_status(0);
    LED(1) <= lb_pcs_status(0);
    LED(2) <= gt_resetdone and lb_gt_resetdone;
    LED(3) <= '1' when rx_led_cnt /= 0 else '0';
    LED(4) <= '1' when tx_led_cnt /= 0 else '0';
    LED(5) <= lb_status(263);
    LED(6) <= '1' when lb_status(191 downto 128) /= x"0000000000000000" else '0';
    LED(7) <= heartbeat(26);

end architecture rtl;
