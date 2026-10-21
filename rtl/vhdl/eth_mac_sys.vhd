-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- eth_mac_sys.vhd - Ethernet MAC System Wrapper
-- Integrates eth_mac + AXI4-Lite CSR + statistics + MDIO + PHY selection
-- VHDL port of rtl/eth_mac_sys.v (formally proven equivalent; see sim/parity/).
-- =============================================================================
--
-- PHY_INTERFACE selects the media interface:
--   "MII"   10/100 only.   mii_if + mii_tx_saf (CDC + nibble conversion).
--   "GMII"  1000 Mbps only. gmii_cdc + gmii_if (CDC + registered SDR I/O).
--   "RGMII" 10/100/1G.     gmii_cdc + rgmii_if (CDC + DDR I/O).
--
-- GMII is a 1000 Mbps-only interface by definition - a tri-speed PHY exposing
-- GMII falls back to 4-bit MII at 10/100, which is the "MII" mode above. The
-- GMII branch therefore pins gmii_cdc's pacing to 1G and ignores cfg_speed's
-- speed field. Its main use is feeding a vendor 1G PCS/PMA core (SGMII /
-- 1000BASE-X), which presents a GMII bus rather than PHY pins.
--
-- System clock and 1G: the datapath moves one byte per clk. At 1000 Mbps the
-- PHY delivers one byte per 8 ns, so clk must be at least 125 MHz or the RX
-- CDC FIFO falls behind under sustained traffic and drops frames (at 100 MHz a
-- back-to-back 1518-byte stream loses ~3 us per frame). The 12-byte IFG and
-- the preamble leave ~11 clk cycles of slack per frame at exactly 125 MHz,
-- which absorbs a ppm offset between clk and the PHY clock. Set CLK_FREQ_HZ to
-- the real clk frequency: a build that can run at 1G (GMII, or RGMII with
-- RGMII_SPEEDS other than "10_100") fails elaboration below 125 MHz, and the
-- PAUSE-quantum and MDC dividers are derived from it.
--
-- Vendor DDR / XPM selection comes from emz_target_pkg (one of
-- rtl/vhdl/target/emz_target_*.vhd), which replaces the Verilog `defines.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.emz_util_pkg.all;

entity eth_mac_sys is
    generic (
        PHY_INTERFACE      : string  := "MII";   -- "MII", "GMII" or "RGMII"
        MCAST_HASH_FILTER  : integer := 0;       -- 1 = enable 64-bit multicast hash filter
        MAX_FRAME          : integer := 9018;    -- jumbo MTU + headers; 1518 standard
        -- RX AXIS buffer depth (address width). Defaults to hold one full
        -- MAX_FRAME frame so a jumbo frame can be absorbed under sustained
        -- downstream backpressure, with a 2048-byte (addr-width 11) floor for
        -- standard frames. Override smaller to save BRAM when the downstream sink
        -- never stalls for a full frame.
        RX_AXIS_ADDR_WIDTH : integer := 0;   -- 0 = max(clog2(MAX_FRAME), 11), as the Verilog default
        -- Checksum offload (IPv4 header, TCP, UDP, ICMP, ICMPv6; IPv4 and IPv6;
        -- one optional VLAN tag). 1 = synthesize the TX inserter (tx_csum_off,
        -- CTRL[7] turns insertion on) / the RX checker (in eth_mac_rx, CTRL[9]
        -- turns dropping on).
        TX_CSUM_OFFLOAD    : integer := 0;
        RX_CSUM_OFFLOAD    : integer := 0;
        -- GMII/RGMII CDC FIFO storage: "BLOCK" (block RAM) or "DISTRIBUTED"
        -- (LUTRAM). Jumbo depths need "BLOCK" to fit and close timing.
        CDC_RAM_STYLE      : string  := "BLOCK";
        -- Frequency of clk in Hz. Must be >= 125 MHz for any build that can run
        -- at 1G (see header); sets the PAUSE-quantum and MDC dividers.
        CLK_FREQ_HZ        : integer := 100_000_000;
        -- RGMII speeds to synthesize: "ALL", "1G_ONLY" or "10_100". "10_100"
        -- removes 1G, and with it the 125 MHz clk requirement.
        RGMII_SPEEDS       : string  := "ALL";
        MII_DEBUG          : integer := 0
    );
    port (
        clk             : in  std_logic;   -- system clock, CLK_FREQ_HZ
        rst_n           : in  std_logic;

        -- ---- AXI4-Lite CSR slave (8-bit address: 0x00-0x90 used) ----
        s_axi_awaddr    : in  std_logic_vector(7 downto 0);
        s_axi_awvalid   : in  std_logic;
        s_axi_awready   : out std_logic;
        s_axi_wdata     : in  std_logic_vector(31 downto 0);
        s_axi_wstrb     : in  std_logic_vector(3 downto 0);
        s_axi_wvalid    : in  std_logic;
        s_axi_wready    : out std_logic;
        s_axi_bresp     : out std_logic_vector(1 downto 0);
        s_axi_bvalid    : out std_logic;
        s_axi_bready    : in  std_logic;
        s_axi_araddr    : in  std_logic_vector(7 downto 0);
        s_axi_arvalid   : in  std_logic;
        s_axi_arready   : out std_logic;
        s_axi_rdata     : out std_logic_vector(31 downto 0);
        s_axi_rresp     : out std_logic_vector(1 downto 0);
        s_axi_rvalid    : out std_logic;
        s_axi_rready    : in  std_logic;

        -- ---- AXI4-Stream TX slave ----
        s_axis_tdata    : in  std_logic_vector(7 downto 0);
        s_axis_tvalid   : in  std_logic;
        s_axis_tready   : out std_logic;
        s_axis_tlast    : in  std_logic;

        -- ---- AXI4-Stream RX master ----
        m_axis_tdata    : out std_logic_vector(7 downto 0);
        m_axis_tvalid   : out std_logic;
        m_axis_tready   : in  std_logic;
        m_axis_tlast    : out std_logic;
        m_axis_terror   : out std_logic;
        m_axis_tsof     : out std_logic;

        -- ---- MII PHY pins (active when PHY_INTERFACE="MII") ----
        mii_txd         : out std_logic_vector(3 downto 0);
        mii_tx_en       : out std_logic;
        mii_tx_clk      : in  std_logic;
        mii_rxd         : in  std_logic_vector(3 downto 0);
        mii_rx_dv       : in  std_logic;
        mii_rx_er       : in  std_logic;
        mii_rx_clk      : in  std_logic;
        mii_col         : in  std_logic;
        mii_crs         : in  std_logic;

        -- ---- RGMII PHY pins (active when PHY_INTERFACE="RGMII") ----
        clk_125         : in  std_logic;
        clk_125_90      : in  std_logic;   -- 90 deg; TXC clock when 1G is built
        clk_25          : in  std_logic;   -- unused, kept for compatibility
        clk_2_5         : in  std_logic;   -- unused, kept for compatibility
        rgmii_txd       : out std_logic_vector(3 downto 0);
        rgmii_tx_ctl    : out std_logic;
        rgmii_txc       : out std_logic;
        rgmii_rxd       : in  std_logic_vector(3 downto 0);
        rgmii_rx_ctl    : in  std_logic;
        rgmii_rxc       : in  std_logic;

        -- ---- GMII PHY pins (active when PHY_INTERFACE="GMII") ----
        -- Prefixed phy_gmii_* to stay distinct from the internal GMII bus wires
        -- below. Uses clk_125 from the RGMII clock group above; clk_125_90 is
        -- RGMII-only and unused on the GMII branch.
        phy_gmii_txd    : out std_logic_vector(7 downto 0);
        phy_gmii_tx_en  : out std_logic;
        phy_gmii_tx_er  : out std_logic;
        phy_gmii_txc    : out std_logic;
        phy_gmii_rx_clk : in  std_logic;
        phy_gmii_rxd    : in  std_logic_vector(7 downto 0);
        phy_gmii_rx_dv  : in  std_logic;
        phy_gmii_rx_er  : in  std_logic;

        -- ---- MDIO ----
        mdc             : out std_logic;
        mdio_i          : in  std_logic;
        mdio_o          : out std_logic;
        mdio_oe         : out std_logic;

        -- ---- Demo L3 config (IP_ADDR CSR @ 0x40; drives a board-level L3 stack) ----
        cfg_ip_addr     : out std_logic_vector(31 downto 0);

        -- ---- Interrupt ----
        irq             : out std_logic
    );
end entity eth_mac_sys;

architecture rtl of eth_mac_sys is

    -- RX_AXIS_ADDR_WIDTH resolved (its Verilog default depends on MAX_FRAME,
    -- which a VHDL-93 generic default cannot; see emz_util_pkg.auto_or).
    constant RX_AXIS_AW : integer := auto_or(RX_AXIS_ADDR_WIDTH, max_int(clog2(MAX_FRAME), 11));

    -- =========================================================================
    -- CSR outputs
    -- =========================================================================
    signal cfg_tx_en            : std_logic;
    signal cfg_rx_en            : std_logic;
    signal cfg_promisc          : std_logic;
    signal cfg_speed            : std_logic_vector(1 downto 0);   -- 00=1G, 01=100M, 10=10M
    signal cfg_full_duplex      : std_logic;
    signal cfg_jumbo_en         : std_logic;
    signal cfg_tx_csum_off      : std_logic;
    signal cfg_passthrough      : std_logic;
    signal cfg_rx_csum_off      : std_logic;
    signal cfg_mac_addr         : std_logic_vector(47 downto 0);
    signal cfg_mcast_hash_table : std_logic_vector(63 downto 0);

    -- PAUSE
    signal cfg_pause_rx_en     : std_logic;
    signal cfg_pause_tx_send   : std_logic;
    signal cfg_pause_tx_quanta : std_logic_vector(15 downto 0);
    signal stat_pause_rx_cnt   : std_logic_vector(31 downto 0);
    signal stat_pause_tx_cnt   : std_logic_vector(31 downto 0);
    signal stat_clr_pause      : std_logic;
    signal tx_paused           : std_logic;
    signal pause_tdata         : std_logic_vector(7 downto 0);
    signal pause_tvalid        : std_logic;
    signal pause_tready        : std_logic;
    signal pause_tlast         : std_logic;

    -- MDIO CSR <-> mdio_master
    signal mdio_go        : std_logic;
    signal mdio_write     : std_logic;
    signal mdio_phy_addr  : std_logic_vector(4 downto 0);
    signal mdio_reg_addr  : std_logic_vector(4 downto 0);
    signal mdio_wdata_csr : std_logic_vector(15 downto 0);
    signal mdio_rdata_csr : std_logic_vector(15 downto 0);
    signal mdio_c45_en    : std_logic;
    signal mdio_c45_op    : std_logic_vector(1 downto 0);
    signal mdio_done      : std_logic;

    -- Stats
    signal stat_tx_frame_cnt          : std_logic_vector(31 downto 0);
    signal stat_tx_byte_cnt           : std_logic_vector(31 downto 0);
    signal stat_rx_frame_cnt          : std_logic_vector(31 downto 0);
    signal stat_rx_byte_cnt           : std_logic_vector(31 downto 0);
    signal stat_rx_err_cnt            : std_logic_vector(31 downto 0);
    signal stat_rx_err_align_cnt      : std_logic_vector(31 downto 0);
    signal stat_rx_err_overflow_cnt   : std_logic_vector(31 downto 0);
    signal stat_rx_err_oversize_cnt   : std_logic_vector(31 downto 0);
    signal stat_rx_bcast_cnt          : std_logic_vector(31 downto 0);
    signal stat_rx_mcast_cnt          : std_logic_vector(31 downto 0);
    signal stat_rx_size_64_cnt        : std_logic_vector(31 downto 0);
    signal stat_rx_size_65_127_cnt    : std_logic_vector(31 downto 0);
    signal stat_rx_size_128_255_cnt   : std_logic_vector(31 downto 0);
    signal stat_rx_size_256_511_cnt   : std_logic_vector(31 downto 0);
    signal stat_rx_size_512_1023_cnt  : std_logic_vector(31 downto 0);
    signal stat_rx_size_1024_1518_cnt : std_logic_vector(31 downto 0);
    signal stat_rx_size_jumbo_cnt     : std_logic_vector(31 downto 0);
    signal stat_rx_drop_cnt           : std_logic_vector(31 downto 0);
    signal stat_rx_err_csum_cnt       : std_logic_vector(31 downto 0);

    -- RX classification bus (from eth_mac_rx)
    signal rx_stat_done         : std_logic;
    signal rx_stat_len          : std_logic_vector(13 downto 0);
    signal rx_stat_err_fcs      : std_logic;
    signal rx_stat_err_align    : std_logic;
    signal rx_stat_err_overflow : std_logic;
    signal rx_stat_err_oversize : std_logic;
    signal rx_stat_err_csum     : std_logic;
    signal rx_stat_is_bcast     : std_logic;
    signal rx_stat_is_mcast     : std_logic;
    signal rx_stat_drop         : std_logic;

    signal stat_clr_tx : std_logic;
    signal stat_clr_rx : std_logic;

    -- Status
    signal tx_active      : std_logic;
    signal tx_fifo_busy   : std_logic;
    signal tx_fifo_level  : std_logic_vector(12 downto 0);
    signal dbg_mii_tx_saf : std_logic_vector(15 downto 0);   -- mii_tx_saf read-side debug (0 on RGMII)

    -- MDIO busy tracking
    signal mdio_busy_r : std_logic;

    -- =========================================================================
    -- Internal GMII bus (sys_clk domain)
    -- TX-side GMII now lives inside the RGMII generate branch (the MII branch
    -- frames on the media clock in mii_tx_saf), so only the RX bus is top-level.
    -- tx_byte_ev / tx_frame_done_ev are the per-PHY TX events fed to eth_stats.
    -- =========================================================================
    signal tx_byte_ev       : std_logic;   -- 1 pulse per wire byte transmitted (sys_clk)
    signal tx_frame_done_ev : std_logic;   -- 1 pulse per transmitted frame (sys_clk)
    signal gmii_rxd         : std_logic_vector(7 downto 0);
    signal gmii_rx_dv       : std_logic;
    signal gmii_rx_er       : std_logic;

    -- TX gating: hold tready low when tx disabled
    signal s_axis_tvalid_gated : std_logic;
    signal s_axis_tready_mac   : std_logic;

    signal user_tx_tdata  : std_logic_vector(7 downto 0);
    signal user_tx_tvalid : std_logic;
    signal user_tx_tlast  : std_logic;
    signal user_tx_tready : std_logic;

    signal mac_tx_in_tdata  : std_logic_vector(7 downto 0);
    signal mac_tx_in_tvalid : std_logic;
    signal mac_tx_in_tlast  : std_logic;

    signal user_mid  : std_logic;   -- a user frame is part-way accepted
    signal pause_sel : std_logic;

    -- RX gating: mask tvalid when rx disabled
    signal m_axis_tdata_mac  : std_logic_vector(7 downto 0);
    signal m_axis_tvalid_mac : std_logic;
    signal m_axis_tlast_mac  : std_logic;
    signal m_axis_terror_mac : std_logic;
    signal m_axis_tsof_mac   : std_logic;
    signal m_axis_tready_mac : std_logic;

    signal cfg_speed_eff : std_logic_vector(1 downto 0);

    signal rx_tlast_hs   : std_logic;
    signal rx_frame_good : std_logic;
    signal rx_frame_bad  : std_logic;

    signal tx_active_d1 : std_logic;
    signal evt_tx_done  : std_logic;
    signal evt_rx_frame : std_logic;

    -- =========================================================================
    -- Clock-frequency configuration
    -- =========================================================================
    constant CAN_RUN_1G : boolean := (PHY_INTERFACE = "GMII") or
                                     ((PHY_INTERFACE = "RGMII") and (RGMII_SPEEDS /= "10_100"));

    -- PAUSE quantum = 512 bit times: 512 ns at 1G, 5.12 us at 100M, 51.2 us at
    -- 10M, in clk cycles rounded up (52 / 512 / 5120 at 100 MHz):
    -- ceil(f / 1953125), ceil(2f / 390625), ceil(4f / 78125). Split into
    -- quotient and remainder so the result is exact for any frequency and no
    -- product leaves 32-bit integer arithmetic. The Verilog localparams are
    -- [15:0], hence the mod 2**16.
    constant P1G_Q   : integer := CLK_FREQ_HZ / 1_953_125;
    constant P1G_R   : integer := CLK_FREQ_HZ mod 1_953_125;
    constant P100M_Q : integer := CLK_FREQ_HZ / 390_625;
    constant P100M_R : integer := CLK_FREQ_HZ mod 390_625;
    constant P10M_Q  : integer := CLK_FREQ_HZ / 78_125;
    constant P10M_R  : integer := CLK_FREQ_HZ mod 78_125;
    function ceil_bit(r : integer) return integer is
    begin
        if r /= 0 then
            return 1;
        end if;
        return 0;
    end function ceil_bit;
    constant PAUSE_DIV_1G   : integer := (P1G_Q + ceil_bit(P1G_R)) mod 2**16;
    constant PAUSE_DIV_100M : integer := (2 * P100M_Q + (2 * P100M_R + 390_624) / 390_625) mod 2**16;
    constant PAUSE_DIV_10M  : integer := (4 * P10M_Q  + (4 * P10M_R  +  78_124) /  78_125) mod 2**16;

begin

    -- MDIO busy tracking
    process (clk, rst_n)
    begin
        if rst_n = '0' then
            mdio_busy_r <= '0';
        elsif rising_edge(clk) then
            if mdio_go = '1' then
                mdio_busy_r <= '1';
            elsif mdio_done = '1' then
                mdio_busy_r <= '0';
            end if;
        end if;
    end process;

    -- =========================================================================
    -- TX/RX gating
    -- =========================================================================
    s_axis_tvalid_gated <= s_axis_tvalid and cfg_tx_en;

    -- =========================================================================
    -- Optional TX checksum offload.
    -- TX_CSUM_OFFLOAD=0 removes the frame-buffering checksum inserter from
    -- synthesis; CTRL[7] then reads/writes normally but has no datapath effect.
    -- TX_CSUM_OFFLOAD=1 sends every frame through the inserter, which stores
    -- each frame whole (one MAX_FRAME of buffer) and fills in its checksums
    -- when CTRL[7] was set at the frame's first byte. The path never switches
    -- while a frame is in flight, so CTRL[7] may change at any time.
    -- =========================================================================
    gen_tx_csum : if TX_CSUM_OFFLOAD /= 0 generate
        signal csum_s_tready : std_logic;
    begin
        u_tx_csum : entity work.tx_csum_off
            generic map (MAX_FRAME => MAX_FRAME)
            port map (
                clk           => clk,
                rst_n         => rst_n,
                enable        => cfg_tx_csum_off,
                s_axis_tdata  => s_axis_tdata,
                s_axis_tvalid => s_axis_tvalid_gated,
                s_axis_tready => csum_s_tready,
                s_axis_tlast  => s_axis_tlast,
                m_axis_tdata  => user_tx_tdata,
                m_axis_tvalid => user_tx_tvalid,
                m_axis_tready => user_tx_tready,
                m_axis_tlast  => user_tx_tlast
            );

        s_axis_tready <= csum_s_tready and cfg_tx_en;
    end generate gen_tx_csum;

    gen_no_tx_csum : if TX_CSUM_OFFLOAD = 0 generate
        user_tx_tdata  <= s_axis_tdata;
        user_tx_tvalid <= s_axis_tvalid_gated;
        user_tx_tlast  <= s_axis_tlast;
        s_axis_tready  <= user_tx_tready and cfg_tx_en;
    end generate gen_no_tx_csum;

    -- PAUSE-priority mux, switched only between user frames. A PAUSE frame
    -- requested while a user frame is part-way through waits (eth_pause holds
    -- in TX_RUN until pause_tready) for that frame's tlast; switching on
    -- pause_tvalid alone spliced the PAUSE bytes into the user frame. Once
    -- the PAUSE frame has the bus, user_tx_tready is low, so user_mid stays
    -- clear and the PAUSE frame keeps the bus until its own tlast.
    process (clk, rst_n)
    begin
        if rst_n = '0' then
            user_mid <= '0';
        elsif rising_edge(clk) then
            if user_tx_tvalid = '1' and user_tx_tready = '1' then
                user_mid <= not user_tx_tlast;
            end if;
        end if;
    end process;
    pause_sel        <= pause_tvalid and (not user_mid);
    mac_tx_in_tdata  <= pause_tdata  when pause_sel = '1' else user_tx_tdata;
    mac_tx_in_tvalid <= pause_tvalid when pause_sel = '1' else user_tx_tvalid;
    mac_tx_in_tlast  <= pause_tlast  when pause_sel = '1' else user_tx_tlast;
    pause_tready     <= pause_sel and s_axis_tready_mac;
    user_tx_tready   <= (not pause_sel) and s_axis_tready_mac;

    -- RX gating: mask tvalid when rx disabled
    m_axis_tready_mac <= m_axis_tready when cfg_rx_en = '1' else '1';

    m_axis_tdata  <= m_axis_tdata_mac;
    m_axis_tvalid <= m_axis_tvalid_mac and cfg_rx_en;
    m_axis_tlast  <= m_axis_tlast_mac;
    m_axis_terror <= m_axis_terror_mac;
    m_axis_tsof   <= m_axis_tsof_mac;

    -- =========================================================================
    -- MAC TX framer is instantiated per-PHY below:
    --   - MII:  mii_tx_saf   (store-and-forward, single frame FIFO, media-clk
    --           framer; tolerates AXIS bubbles - no cut-through underrun)
    --   - RGMII: eth_mac_tx  (cut-through framer) -> gmii_cdc
    -- Both are fed by the pause-muxed AXIS (mac_tx_in_*) and drive the shared
    -- tx_active / tx_fifo_busy / tx_byte_ev / tx_frame_done_ev / s_axis_tready_mac.
    -- =========================================================================

    -- =========================================================================
    -- MAC RX - strips preamble/SFD, validates CRC
    -- =========================================================================
    -- With jumbo_en, RX accepts up to MAX_FRAME wire bytes (FCS included),
    -- the size the RX FIFOs here are built for.
    u_mac_rx : entity work.eth_mac_rx
        generic map (
            MCAST_HASH_FILTER    => MCAST_HASH_FILTER,
            AXIS_FIFO_ADDR_WIDTH => RX_AXIS_AW,
            MAX_FRAME_JUMBO      => MAX_FRAME,
            RX_CSUM_OFFLOAD      => RX_CSUM_OFFLOAD
        )
        port map (
            clk               => clk,
            rst_n             => rst_n,
            gmii_rxd          => gmii_rxd,
            gmii_rx_dv        => gmii_rx_dv,
            gmii_rx_er        => gmii_rx_er,
            our_mac           => cfg_mac_addr,
            promisc           => cfg_promisc,
            passthrough       => cfg_passthrough,
            jumbo_en          => cfg_jumbo_en,
            rx_csum_en        => cfg_rx_csum_off,
            mcast_hash_table  => cfg_mcast_hash_table,
            m_axis_tdata      => m_axis_tdata_mac,
            m_axis_tvalid     => m_axis_tvalid_mac,
            m_axis_tready     => m_axis_tready_mac,
            m_axis_tlast      => m_axis_tlast_mac,
            m_axis_terror     => m_axis_terror_mac,
            m_axis_tsof       => m_axis_tsof_mac,
            stat_done         => rx_stat_done,
            stat_len          => rx_stat_len,
            stat_err_fcs      => rx_stat_err_fcs,
            stat_err_align    => rx_stat_err_align,
            stat_err_overflow => rx_stat_err_overflow,
            stat_err_oversize => rx_stat_err_oversize,
            stat_err_csum     => rx_stat_err_csum,
            stat_is_bcast     => rx_stat_is_bcast,
            stat_is_mcast     => rx_stat_is_mcast,
            stat_drop         => rx_stat_drop
        );

    -- =========================================================================
    -- 802.3x PAUSE flow control
    -- =========================================================================
    -- GMII is 1000 Mbps only, so the writable CSR speed field must not reach
    -- speed-dependent logic on that branch. eth_pause scales its pause-quantum
    -- prescaler from cfg_speed; a CSR write selecting 10M would otherwise
    -- stretch received PAUSE quanta ~100x while the datapath keeps running at
    -- 1G. The GMII branch ties gmii_cdc's pacing to 1G for the same reason.
    cfg_speed_eff <= "00" when PHY_INTERFACE = "GMII" else cfg_speed;

    -- 1G needs one clk per wire byte (see header). The Verilog instantiates a
    -- module named after the error; VHDL states it directly.
    assert not (CAN_RUN_1G and (CLK_FREQ_HZ < 125_000_000))
        report "EMACZERO_CONFIG_ERROR_1G_needs_CLK_FREQ_HZ_at_least_125MHz_or_RGMII_SPEEDS_10_100"
        severity failure;

    u_pause : entity work.eth_pause
        generic map (
            TICK_DIV_1G   => PAUSE_DIV_1G,
            TICK_DIV_100M => PAUSE_DIV_100M,
            TICK_DIV_10M  => PAUSE_DIV_10M
        )
        port map (
            clk                 => clk,
            rst_n               => rst_n,
            our_mac             => cfg_mac_addr,
            cfg_speed           => cfg_speed_eff,
            cfg_pause_rx_en     => cfg_pause_rx_en,
            cfg_pause_tx_send   => cfg_pause_tx_send,
            cfg_pause_tx_quanta => cfg_pause_tx_quanta,
            gmii_rxd            => gmii_rxd,
            gmii_rx_dv          => gmii_rx_dv,
            gmii_rx_er          => gmii_rx_er,
            tx_paused           => tx_paused,
            pause_tdata         => pause_tdata,
            pause_tvalid        => pause_tvalid,
            pause_tready        => pause_tready,
            pause_tlast         => pause_tlast,
            stat_clr            => stat_clr_pause,
            pause_rx_cnt        => stat_pause_rx_cnt,
            pause_tx_cnt        => stat_pause_tx_cnt
        );

    -- =========================================================================
    -- PHY interface selection (MII or RGMII)
    -- =========================================================================
    gen_mii : if PHY_INTERFACE = "MII" generate
        signal tx_start_ok : std_logic;
    begin
        -- NOTE: the MII path is standard-MTU only. mii_if's TX FIFO and RX
        -- replay buffer are 4096 bytes, which cannot hold a jumbo frame
        -- while the 12.5 MB/s MII side drains the 100 MB/s write side. Use
        -- MAX_FRAME=1518 for MII; jumbo requires PHY_INTERFACE="RGMII".
        -- TX_ENABLE(0): mii_tx_saf (u_mii_tx) drives the MII TX pins on this
        -- branch, so mii_if is RX-only here - omit its dead TX FIFO's BRAM.
        u_mii_if : entity work.mii_if
            generic map (MII_DEBUG => MII_DEBUG, TX_ENABLE => 0)
            port map (
                clk            => clk,
                rst_n          => rst_n,
                mii_rxd        => mii_rxd,
                mii_rx_dv      => mii_rx_dv,
                mii_rx_er      => mii_rx_er,
                mii_rx_clk     => mii_rx_clk,
                mii_col        => mii_col,
                mii_crs        => mii_crs,
                -- mii_if TX path is unused on this branch: MII pins are driven
                -- by u_mii_tx (mii_tx_saf) below; disable its TX FIFO by tying
                -- gmii_tx_en low and leave its TX outputs unconnected.
                mii_txd        => open,
                mii_tx_en      => open,
                mii_tx_clk     => mii_tx_clk,
                gmii_txd       => (others => '0'),
                gmii_tx_en     => '0',
                gmii_tx_er     => '0',
                gmii_rxd       => gmii_rxd,
                gmii_rx_dv     => gmii_rx_dv,
                gmii_rx_er     => gmii_rx_er,
                mii_tx_clk_out => open,
                tx_busy                => open,
                tx_fifo_level          => open,
                dbg_tx_fifo_empty      => open,
                dbg_rx_prog_empty      => open,
                dbg_rx_rd_empty        => open,
                dbg_rx_reading         => open,
                dbg_rx_frames_pending  => open,
                dbg_tx_wr_en           => open,
                dbg_tx_len_wr_en       => open,
                dbg_tx_wr_full         => open,
                dbg_tx_wr_rst_busy_out => open,
                dbg_tx_rd_en           => open,
                dbg_tx_frame_loaded    => open,
                dbg_tx_frames_queued   => open,
                dbg_tx_frames_drained  => open,
                dbg_last_tx_len_wr     => open,
                dbg_mii_cap_done       => open,
                dbg_mii_cap_frame_len  => open,
                dbg_mii_cap_word0      => open,
                dbg_mii_cap_word1      => open,
                dbg_mii_cap_word2      => open,
                dbg_mii_cap_word3      => open,
                dbg_mii_cap_word4      => open,
                dbg_mii_cap_word5      => open,
                dbg_mii_cap_word6      => open,
                dbg_mii_cap_word7      => open,
                dbg_mii_cap_word8      => open,
                dbg_mii_cap_word9      => open,
                dbg_mii_cap_word10     => open,
                dbg_mii_cap_word11     => open,
                dbg_mii_cap_word12     => open,
                dbg_mii_cap_word13     => open,
                dbg_mii_cap_word14     => open,
                dbg_mii_cap_word15     => open,
                dbg_mii_txd_pre_iob    => open,
                dbg_mii_tx_en_pre_iob  => open,
                dbg_rx_fifo_full_frames     => open,
                dbg_rx_fifo_full_writes     => open,
                dbg_rx_fifo_overflow_pulses => open,
                dbg_rx_fifo_wr_level_max    => open,
                dbg_rx_replay_gap_frames    => open,
                dbg_rx_replay_gap_cycles    => open,
                dbg_rx_replay_gap_byte_max  => open,
                dbg_rx_mii_last_len     => open,
                dbg_rx_mii_word0        => open,
                dbg_rx_mii_word1        => open,
                dbg_rx_mii_word2        => open,
                dbg_rx_mii_word3        => open,
                dbg_rx_mii_word4        => open,
                dbg_rx_mii_word5        => open,
                dbg_rx_mii_word6        => open,
                dbg_rx_mii_word7        => open,
                dbg_rx_mii_word8        => open,
                dbg_rx_mii_word9        => open,
                dbg_rx_mii_word10       => open,
                dbg_rx_mii_word11       => open,
                dbg_rx_mii_word12       => open,
                dbg_rx_mii_word13       => open,
                dbg_rx_mii_word14       => open,
                dbg_rx_mii_word15       => open,
                dbg_rx_replay_last_len  => open,
                dbg_rx_replay_word0     => open,
                dbg_rx_replay_word1     => open,
                dbg_rx_replay_word2     => open,
                dbg_rx_replay_word3     => open,
                dbg_rx_replay_eof_count => open,
                dbg_tx_er_pulses        => open,
                dbg_tx_er_frames        => open
            );

        -- Store-and-forward MII transmit: single frame FIFO + media-clk
        -- framer. Drives the MII TX pins and the shared TX status/stats.
        -- Size the frame FIFO from MAX_FRAME so it always holds one whole
        -- frame (mii_tx_saf's oversize cap requires FIFO_DEPTH > MAX_FRAME,
        -- else a MAX_FRAME-sized frame wedges the TX path). A standard build
        -- (MAX_FRAME=1518) gets a 2048-deep FIFO; a jumbo build (9018) gets
        -- 16384 - the jumbo cost is paid only when jumbo is actually built.
        tx_start_ok <= not tx_paused;

        u_mii_tx : entity work.mii_tx_saf
            generic map (
                MAX_FRAME       => MAX_FRAME,
                FIFO_ADDR_WIDTH => max_int(clog2(MAX_FRAME + 1), 11)
            )
            port map (
                clk           => clk,
                rst_n         => rst_n,
                s_axis_tdata  => mac_tx_in_tdata,
                s_axis_tvalid => mac_tx_in_tvalid,
                s_axis_tready => s_axis_tready_mac,
                s_axis_tlast  => mac_tx_in_tlast,
                tx_start_ok   => tx_start_ok,
                mii_tx_clk    => mii_tx_clk,
                mii_txd       => mii_txd,
                mii_tx_en     => mii_tx_en,
                tx_busy       => tx_fifo_busy,
                tx_fifo_level => tx_fifo_level,
                tx_active     => tx_active,
                tx_byte_stb   => tx_byte_ev,
                tx_frame_done => tx_frame_done_ev,
                dbg_saf       => dbg_mii_tx_saf
            );

        -- Tie off RGMII outputs
        rgmii_txd    <= (others => '0');
        rgmii_tx_ctl <= '0';
        rgmii_txc    <= '0';

        -- Tie off GMII outputs
        phy_gmii_txd   <= (others => '0');
        phy_gmii_tx_en <= '0';
        phy_gmii_tx_er <= '0';
        phy_gmii_txc   <= '0';
    end generate gen_mii;

    gen_gmii : if PHY_INTERFACE = "GMII" generate
        -- 1000 Mbps only. Structurally this is the RGMII branch with the
        -- DDR stage replaced by registered SDR I/O: same cut-through
        -- eth_mac_tx framer, same gmii_cdc store-and-forward CDC, so jumbo
        -- frames work here exactly as they do on RGMII.
        signal media_gmii_txd   : std_logic_vector(7 downto 0);
        signal media_gmii_tx_en : std_logic;
        signal media_gmii_tx_er : std_logic;
        signal media_gmii_rxd   : std_logic_vector(7 downto 0);
        signal media_gmii_rx_dv : std_logic;
        signal media_gmii_rx_er : std_logic;

        signal gmii_tx_fifo_level : std_logic_vector(11 downto 0);

        signal gmii_txd_mac   : std_logic_vector(7 downto 0);
        signal gmii_tx_en_mac : std_logic;
        signal gmii_tx_er_mac : std_logic;
        signal mac_tx_active  : std_logic;
        signal tx_start_ok    : std_logic;

        signal gmii_tx_en_mac_d1 : std_logic;
    begin
        tx_start_ok <= (not tx_fifo_busy) and (not tx_paused);

        u_mac_tx : entity work.eth_mac_tx
            generic map (MAX_FRAME => MAX_FRAME)
            port map (
                clk           => clk,
                rst_n         => rst_n,
                tx_start_ok   => tx_start_ok,
                gmii_txd      => gmii_txd_mac,
                gmii_tx_en    => gmii_tx_en_mac,
                gmii_tx_er    => gmii_tx_er_mac,
                s_axis_tdata  => mac_tx_in_tdata,
                s_axis_tvalid => mac_tx_in_tvalid,
                s_axis_tready => s_axis_tready_mac,
                s_axis_tkeep  => "1",
                s_axis_tlast  => mac_tx_in_tlast,
                tx_active     => mac_tx_active,
                dbg_state     => open,
                dbg_stall_cnt => open
            );

        -- TX stats events: one byte per cycle while tx_en is high, plus a
        -- frame-done pulse on its falling edge.
        process (clk, rst_n)
        begin
            if rst_n = '0' then
                gmii_tx_en_mac_d1 <= '0';
            elsif rising_edge(clk) then
                gmii_tx_en_mac_d1 <= gmii_tx_en_mac;
            end if;
        end process;
        tx_byte_ev       <= gmii_tx_en_mac;
        tx_frame_done_ev <= gmii_tx_en_mac_d1 and (not gmii_tx_en_mac);
        tx_active        <= mac_tx_active;

        -- cfg_speed is pinned to 2'b00 (1G): GMII has no 10/100 mode, so
        -- gmii_cdc must never engage its byte-pacing dividers here. A CSR
        -- write selecting 100M/10M is ignored on this branch by design.
        u_gmii_cdc : entity work.gmii_cdc
            generic map (MAX_FRAME => MAX_FRAME, FIFO_RAM_STYLE => CDC_RAM_STYLE)
            port map (
                sys_clk        => clk,
                sys_rst_n      => rst_n,
                media_clk      => clk_125,
                media_rx_clk   => phy_gmii_rx_clk,
                cfg_speed      => "00",
                gmii_txd_in    => gmii_txd_mac,
                gmii_tx_en_in  => gmii_tx_en_mac,
                gmii_tx_er_in  => gmii_tx_er_mac,
                gmii_rxd_out   => gmii_rxd,
                gmii_rx_dv_out => gmii_rx_dv,
                gmii_rx_er_out => gmii_rx_er,
                gmii_txd_out   => media_gmii_txd,
                gmii_tx_en_out => media_gmii_tx_en,
                gmii_tx_er_out => media_gmii_tx_er,
                gmii_rxd_in    => media_gmii_rxd,
                gmii_rx_dv_in  => media_gmii_rx_dv,
                gmii_rx_er_in  => media_gmii_rx_er,
                gmii_rx_ce_in  => '1',
                tx_busy        => tx_fifo_busy,
                tx_fifo_level  => gmii_tx_fifo_level
            );

        tx_fifo_level <= '0' & gmii_tx_fifo_level;

        u_gmii_if : entity work.gmii_if
            port map (
                clk_125        => clk_125,
                rst_n          => rst_n,
                gmii_txd       => phy_gmii_txd,
                gmii_tx_en     => phy_gmii_tx_en,
                gmii_tx_er     => phy_gmii_tx_er,
                gmii_txc       => phy_gmii_txc,
                gmii_rx_clk    => phy_gmii_rx_clk,
                gmii_rxd       => phy_gmii_rxd,
                gmii_rx_dv     => phy_gmii_rx_dv,
                gmii_rx_er     => phy_gmii_rx_er,
                gmii_txd_int   => media_gmii_txd,
                gmii_tx_en_int => media_gmii_tx_en,
                gmii_tx_er_int => media_gmii_tx_er,
                gmii_rxd_int   => media_gmii_rxd,
                gmii_rx_dv_int => media_gmii_rx_dv,
                gmii_rx_er_int => media_gmii_rx_er
            );

        -- Tie off MII outputs
        mii_txd        <= (others => '0');
        mii_tx_en      <= '0';
        dbg_mii_tx_saf <= (others => '0');

        -- Tie off RGMII outputs
        rgmii_txd    <= (others => '0');
        rgmii_tx_ctl <= '0';
        rgmii_txc    <= '0';
    end generate gen_gmii;

    gen_rgmii : if PHY_INTERFACE /= "MII" and PHY_INTERFACE /= "GMII" generate
        -- GMII-level signals between CDC and RGMII interface
        signal media_gmii_txd   : std_logic_vector(7 downto 0);
        signal media_gmii_tx_en : std_logic;
        signal media_gmii_tx_er : std_logic;
        signal media_gmii_rxd   : std_logic_vector(7 downto 0);
        signal media_gmii_rx_dv : std_logic;
        signal media_gmii_rx_er : std_logic;
        signal media_gmii_rx_ce : std_logic;   -- byte strobe: every other RXC at 10/100

        signal rgmii_tx_fifo_level : std_logic_vector(11 downto 0);

        -- Cut-through MAC TX framer -> GMII (sys_clk), then CDC to media.
        signal gmii_txd      : std_logic_vector(7 downto 0);
        signal gmii_tx_en    : std_logic;
        signal gmii_tx_er    : std_logic;
        signal mac_tx_active : std_logic;
        signal tx_start_ok   : std_logic;

        signal gmii_tx_en_d1 : std_logic;
    begin
        -- tx_start_ok blocked by tx_fifo_busy (store-and-forward FIFO
        -- headroom) and tx_paused (inbound PAUSE). eth_mac_tx samples it
        -- only in S_IDLE, so an in-flight frame always completes.
        tx_start_ok <= (not tx_fifo_busy) and (not tx_paused);

        u_mac_tx : entity work.eth_mac_tx
            generic map (MAX_FRAME => MAX_FRAME)
            port map (
                clk           => clk,
                rst_n         => rst_n,
                tx_start_ok   => tx_start_ok,
                gmii_txd      => gmii_txd,
                gmii_tx_en    => gmii_tx_en,
                gmii_tx_er    => gmii_tx_er,
                s_axis_tdata  => mac_tx_in_tdata,
                s_axis_tvalid => mac_tx_in_tvalid,
                s_axis_tready => s_axis_tready_mac,
                s_axis_tkeep  => "1",
                s_axis_tlast  => mac_tx_in_tlast,
                tx_active     => mac_tx_active,
                dbg_state     => open,
                dbg_stall_cnt => open
            );

        -- TX stats events: one byte per cycle while gmii_tx_en is high, plus
        -- a frame-done pulse on its falling edge.
        process (clk, rst_n)
        begin
            if rst_n = '0' then
                gmii_tx_en_d1 <= '0';
            elsif rising_edge(clk) then
                gmii_tx_en_d1 <= gmii_tx_en;
            end if;
        end process;
        tx_byte_ev       <= gmii_tx_en;
        tx_frame_done_ev <= gmii_tx_en_d1 and (not gmii_tx_en);
        tx_active        <= mac_tx_active;

        u_gmii_cdc : entity work.gmii_cdc
            generic map (MAX_FRAME => MAX_FRAME, FIFO_RAM_STYLE => CDC_RAM_STYLE)
            port map (
                sys_clk        => clk,
                sys_rst_n      => rst_n,
                media_clk      => clk_125,
                media_rx_clk   => rgmii_rxc,
                cfg_speed      => cfg_speed,
                gmii_txd_in    => gmii_txd,
                gmii_tx_en_in  => gmii_tx_en,
                gmii_tx_er_in  => gmii_tx_er,
                gmii_rxd_out   => gmii_rxd,
                gmii_rx_dv_out => gmii_rx_dv,
                gmii_rx_er_out => gmii_rx_er,
                gmii_txd_out   => media_gmii_txd,
                gmii_tx_en_out => media_gmii_tx_en,
                gmii_tx_er_out => media_gmii_tx_er,
                gmii_rxd_in    => media_gmii_rxd,
                gmii_rx_dv_in  => media_gmii_rx_dv,
                gmii_rx_er_in  => media_gmii_rx_er,
                gmii_rx_ce_in  => media_gmii_rx_ce,
                tx_busy        => tx_fifo_busy,
                tx_fifo_level  => rgmii_tx_fifo_level
            );

        tx_fifo_level <= '0' & rgmii_tx_fifo_level;

        u_rgmii_if : entity work.rgmii_if
            generic map (RGMII_SPEEDS => RGMII_SPEEDS)
            port map (
                clk_125      => clk_125,
                clk_125_90   => clk_125_90,
                rst_n        => rst_n,
                cfg_speed    => cfg_speed,
                rgmii_txd    => rgmii_txd,
                rgmii_tx_ctl => rgmii_tx_ctl,
                rgmii_txc    => rgmii_txc,
                rgmii_rxd    => rgmii_rxd,
                rgmii_rx_ctl => rgmii_rx_ctl,
                rgmii_rxc    => rgmii_rxc,
                gmii_txd     => media_gmii_txd,
                gmii_tx_en   => media_gmii_tx_en,
                gmii_tx_er   => media_gmii_tx_er,
                gmii_rxd     => media_gmii_rxd,
                gmii_rx_dv   => media_gmii_rx_dv,
                gmii_rx_er   => media_gmii_rx_er,
                gmii_rx_ce   => media_gmii_rx_ce
            );

        -- Tie off MII outputs
        mii_txd        <= (others => '0');
        mii_tx_en      <= '0';
        dbg_mii_tx_saf <= (others => '0');

        -- Tie off GMII outputs
        phy_gmii_txd   <= (others => '0');
        phy_gmii_tx_en <= '0';
        phy_gmii_tx_er <= '0';
        phy_gmii_txc   <= '0';
    end generate gen_rgmii;

    -- =========================================================================
    -- Statistics counters
    -- =========================================================================
    -- TX byte / frame-done events come from the active PHY's TX framer
    -- (tx_byte_ev / tx_frame_done_ev), muxed in the generate branches above.

    -- RX frame done pulses: one per TLAST handshake. Without tready, a TLAST
    -- word held at the FIFO head by a stalled sink would count once per cycle.
    rx_tlast_hs   <= m_axis_tvalid_mac and m_axis_tready_mac and m_axis_tlast_mac;
    rx_frame_good <= rx_tlast_hs and (not m_axis_terror_mac);
    rx_frame_bad  <= rx_tlast_hs and m_axis_terror_mac;

    u_stats : entity work.eth_stats
        port map (
            clk                   => clk,
            rst_n                 => rst_n,
            gmii_tx_en            => tx_byte_ev,
            gmii_rx_dv            => gmii_rx_dv,
            tx_frame_done         => tx_frame_done_ev,
            rx_frame_good         => rx_frame_good,
            rx_frame_bad          => rx_frame_bad,
            rx_stat_done          => rx_stat_done,
            rx_stat_len           => rx_stat_len,
            rx_stat_err_fcs       => rx_stat_err_fcs,
            rx_stat_err_align     => rx_stat_err_align,
            rx_stat_err_overflow  => rx_stat_err_overflow,
            rx_stat_err_oversize  => rx_stat_err_oversize,
            rx_stat_err_csum      => rx_stat_err_csum,
            rx_stat_is_bcast      => rx_stat_is_bcast,
            rx_stat_is_mcast      => rx_stat_is_mcast,
            rx_stat_drop          => rx_stat_drop,
            tx_frame_cnt          => stat_tx_frame_cnt,
            tx_byte_cnt           => stat_tx_byte_cnt,
            rx_frame_cnt          => stat_rx_frame_cnt,
            rx_byte_cnt           => stat_rx_byte_cnt,
            rx_crc_err_cnt        => stat_rx_err_cnt,
            rx_err_align_cnt      => stat_rx_err_align_cnt,
            rx_err_overflow_cnt   => stat_rx_err_overflow_cnt,
            rx_err_oversize_cnt   => stat_rx_err_oversize_cnt,
            rx_err_csum_cnt       => stat_rx_err_csum_cnt,
            rx_bcast_cnt          => stat_rx_bcast_cnt,
            rx_mcast_cnt          => stat_rx_mcast_cnt,
            rx_size_64_cnt        => stat_rx_size_64_cnt,
            rx_size_65_127_cnt    => stat_rx_size_65_127_cnt,
            rx_size_128_255_cnt   => stat_rx_size_128_255_cnt,
            rx_size_256_511_cnt   => stat_rx_size_256_511_cnt,
            rx_size_512_1023_cnt  => stat_rx_size_512_1023_cnt,
            rx_size_1024_1518_cnt => stat_rx_size_1024_1518_cnt,
            rx_size_jumbo_cnt     => stat_rx_size_jumbo_cnt,
            rx_drop_cnt           => stat_rx_drop_cnt,
            clr_tx                => stat_clr_tx,
            clr_rx                => stat_clr_rx
        );

    -- =========================================================================
    -- TX done event for IRQ (falling edge of tx_active)
    -- =========================================================================
    process (clk, rst_n)
    begin
        if rst_n = '0' then
            tx_active_d1 <= '0';
        elsif rising_edge(clk) then
            tx_active_d1 <= tx_active;
        end if;
    end process;
    evt_tx_done  <= tx_active_d1 and (not tx_active);
    evt_rx_frame <= m_axis_tvalid_mac and m_axis_tlast_mac;

    -- =========================================================================
    -- AXI4-Lite CSR
    -- =========================================================================
    u_csr : entity work.axilite_regs
        generic map (ADDR_WIDTH => 8, MCAST_HASH_FILTER => MCAST_HASH_FILTER)
        port map (
            s_axi_aclk                 => clk,
            s_axi_aresetn              => rst_n,
            s_axi_awaddr               => s_axi_awaddr,
            s_axi_awvalid              => s_axi_awvalid,
            s_axi_awready              => s_axi_awready,
            s_axi_wdata                => s_axi_wdata,
            s_axi_wstrb                => s_axi_wstrb,
            s_axi_wvalid               => s_axi_wvalid,
            s_axi_wready               => s_axi_wready,
            s_axi_bresp                => s_axi_bresp,
            s_axi_bvalid               => s_axi_bvalid,
            s_axi_bready               => s_axi_bready,
            s_axi_araddr               => s_axi_araddr,
            s_axi_arvalid              => s_axi_arvalid,
            s_axi_arready              => s_axi_arready,
            s_axi_rdata                => s_axi_rdata,
            s_axi_rresp                => s_axi_rresp,
            s_axi_rvalid               => s_axi_rvalid,
            s_axi_rready               => s_axi_rready,
            cfg_tx_en                  => cfg_tx_en,
            cfg_rx_en                  => cfg_rx_en,
            cfg_promisc                => cfg_promisc,
            cfg_speed                  => cfg_speed,
            cfg_full_duplex            => cfg_full_duplex,
            cfg_jumbo_en               => cfg_jumbo_en,
            cfg_tx_csum_off            => cfg_tx_csum_off,
            cfg_passthrough            => cfg_passthrough,
            cfg_rx_csum_off            => cfg_rx_csum_off,
            cfg_mac_addr               => cfg_mac_addr,
            cfg_ip_addr                => cfg_ip_addr,
            dbg_saf                    => dbg_mii_tx_saf,
            cfg_mcast_hash_table       => cfg_mcast_hash_table,
            mdio_go                    => mdio_go,
            mdio_write                 => mdio_write,
            mdio_phy_addr              => mdio_phy_addr,
            mdio_reg_addr              => mdio_reg_addr,
            mdio_wdata                 => mdio_wdata_csr,
            mdio_c45_en                => mdio_c45_en,
            mdio_c45_op                => mdio_c45_op,
            mdio_rdata                 => mdio_rdata_csr,
            mdio_done                  => mdio_done,
            mdio_busy                  => mdio_busy_r,
            stat_tx_frame_cnt          => stat_tx_frame_cnt,
            stat_tx_byte_cnt           => stat_tx_byte_cnt,
            stat_rx_frame_cnt          => stat_rx_frame_cnt,
            stat_rx_byte_cnt           => stat_rx_byte_cnt,
            stat_rx_err_cnt            => stat_rx_err_cnt,
            stat_rx_err_align_cnt      => stat_rx_err_align_cnt,
            stat_rx_err_overflow_cnt   => stat_rx_err_overflow_cnt,
            stat_rx_err_oversize_cnt   => stat_rx_err_oversize_cnt,
            stat_rx_bcast_cnt          => stat_rx_bcast_cnt,
            stat_rx_mcast_cnt          => stat_rx_mcast_cnt,
            stat_rx_size_64_cnt        => stat_rx_size_64_cnt,
            stat_rx_size_65_127_cnt    => stat_rx_size_65_127_cnt,
            stat_rx_size_128_255_cnt   => stat_rx_size_128_255_cnt,
            stat_rx_size_256_511_cnt   => stat_rx_size_256_511_cnt,
            stat_rx_size_512_1023_cnt  => stat_rx_size_512_1023_cnt,
            stat_rx_size_1024_1518_cnt => stat_rx_size_1024_1518_cnt,
            stat_rx_err_csum_cnt       => stat_rx_err_csum_cnt,
            stat_rx_size_jumbo_cnt     => stat_rx_size_jumbo_cnt,
            stat_rx_drop_cnt           => stat_rx_drop_cnt,
            cfg_pause_rx_en            => cfg_pause_rx_en,
            cfg_pause_tx_send          => cfg_pause_tx_send,
            cfg_pause_tx_quanta        => cfg_pause_tx_quanta,
            stat_pause_rx_cnt          => stat_pause_rx_cnt,
            stat_pause_tx_cnt          => stat_pause_tx_cnt,
            stat_clr_pause             => stat_clr_pause,
            stat_clr_tx                => stat_clr_tx,
            stat_clr_rx                => stat_clr_rx,
            sts_tx_active              => tx_active,
            sts_tx_fifo_busy           => tx_fifo_busy,
            evt_tx_done                => evt_tx_done,
            evt_rx_frame               => evt_rx_frame,
            irq                        => irq
        );

    -- =========================================================================
    -- MDIO master
    -- =========================================================================
    u_mdio : entity work.mdio_master
        generic map (CLK_FREQ_HZ => CLK_FREQ_HZ)
        port map (
            clk            => clk,
            rst_n          => rst_n,
            mdc            => mdc,
            mdio_o         => mdio_o,
            mdio_oe        => mdio_oe,
            mdio_i         => mdio_i,
            cmd_valid      => mdio_go,
            cmd_write      => mdio_write,
            cmd_phy        => mdio_phy_addr,
            cmd_reg        => mdio_reg_addr,
            cmd_wdata      => mdio_wdata_csr,
            cmd_c45_en     => mdio_c45_en,
            cmd_c45_op     => mdio_c45_op,
            cmd_rdata      => mdio_rdata_csr,
            cmd_done       => mdio_done,
            dbg_rd_low_cnt => open,
            dbg_rd_raw     => open
        );

end architecture rtl;
