-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- eth_mac_sys_standin.vhd - Parity-only stand-in for eth_mac_sys.
-- Line-for-line twin of eth_mac_sys_standin.v (read on the golden side); see
-- that file for why the stand-in is a register that mixes every input and a
-- parameter fingerprint rather than an empty (port-only) entity.
-- Same entity name, generics and ports as rtl/vhdl/eth_mac_sys.vhd, including
-- the RX_AXIS_ADDR_WIDTH 0-sentinel, resolved with auto_or as there.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.emz_util_pkg.all;

entity eth_mac_sys is
    generic (
        PHY_INTERFACE      : string  := "MII";
        MCAST_HASH_FILTER  : integer := 0;
        MAX_FRAME          : integer := 9018;
        RX_AXIS_ADDR_WIDTH : integer := 0;   -- 0 = max(clog2(MAX_FRAME), 11), as the Verilog default
        TX_CSUM_OFFLOAD    : integer := 0;
        RX_CSUM_OFFLOAD    : integer := 0;
        CDC_RAM_STYLE      : string  := "BLOCK";
        CLK_FREQ_HZ        : integer := 100_000_000;
        RGMII_SPEEDS       : string  := "ALL";
        MII_DEBUG          : integer := 0;
        TXRX_EN_AT_RESET   : integer := 1
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;
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
        s_axis_tdata    : in  std_logic_vector(7 downto 0);
        s_axis_tvalid   : in  std_logic;
        s_axis_tready   : out std_logic;
        s_axis_tlast    : in  std_logic;
        m_axis_tdata    : out std_logic_vector(7 downto 0);
        m_axis_tvalid   : out std_logic;
        m_axis_tready   : in  std_logic;
        m_axis_tlast    : out std_logic;
        m_axis_terror   : out std_logic;
        m_axis_tsof     : out std_logic;
        mii_txd         : out std_logic_vector(3 downto 0);
        mii_tx_en       : out std_logic;
        mii_tx_clk      : in  std_logic;
        mii_rxd         : in  std_logic_vector(3 downto 0);
        mii_rx_dv       : in  std_logic;
        mii_rx_er       : in  std_logic;
        mii_rx_clk      : in  std_logic;
        mii_col         : in  std_logic;
        mii_crs         : in  std_logic;
        clk_125         : in  std_logic;
        clk_125_90      : in  std_logic;
        clk_25          : in  std_logic;
        clk_2_5         : in  std_logic;
        rgmii_txd       : out std_logic_vector(3 downto 0);
        rgmii_tx_ctl    : out std_logic;
        rgmii_txc       : out std_logic;
        rgmii_rxd       : in  std_logic_vector(3 downto 0);
        rgmii_rx_ctl    : in  std_logic;
        rgmii_rxc       : in  std_logic;
        phy_gmii_txd    : out std_logic_vector(7 downto 0);
        phy_gmii_tx_en  : out std_logic;
        phy_gmii_tx_er  : out std_logic;
        phy_gmii_txc    : out std_logic;
        phy_gmii_rx_clk : in  std_logic;
        phy_gmii_rxd    : in  std_logic_vector(7 downto 0);
        phy_gmii_rx_dv  : in  std_logic;
        phy_gmii_rx_er  : in  std_logic;
        mdc             : out std_logic;
        mdio_i          : in  std_logic;
        mdio_o          : out std_logic;
        mdio_oe         : out std_logic;
        cfg_ip_addr     : out std_logic_vector(31 downto 0);
        irq             : out std_logic
    );
end entity eth_mac_sys;

architecture standin of eth_mac_sys is

    function b2sl(b : boolean) return std_logic is
    begin
        if b then
            return '1';
        else
            return '0';
        end if;
    end function b2sl;

    constant RX_AXIS_AW : integer := auto_or(RX_AXIS_ADDR_WIDTH, max_int(clog2(MAX_FRAME), 11));

    -- Generic fingerprint
    constant FP_MAX : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(MAX_FRAME, 32));
    constant FP_CLK : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(CLK_FREQ_HZ, 32));
    constant FP_AW  : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(RX_AXIS_AW, 32));
    constant FP_MCF : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(MCAST_HASH_FILTER, 32));
    constant FP_TXC : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(TX_CSUM_OFFLOAD, 32));
    constant FP_RXC : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(RX_CSUM_OFFLOAD, 32));
    constant FP_DBG : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(MII_DEBUG, 32));
    constant FP_TXRX : std_logic_vector(31 downto 0) := std_logic_vector(to_unsigned(TXRX_EN_AT_RESET, 32));
    constant FP_STR : std_logic_vector(7 downto 0)  :=
        b2sl(PHY_INTERFACE = "MII") & b2sl(PHY_INTERFACE = "GMII") &
        b2sl(PHY_INTERFACE = "RGMII") &
        b2sl(CDC_RAM_STYLE = "BLOCK") & b2sl(CDC_RAM_STYLE = "DISTRIBUTED") &
        b2sl(RGMII_SPEEDS = "ALL") & b2sl(RGMII_SPEEDS = "1G_ONLY") &
        b2sl(RGMII_SPEEDS = "10_100");
    constant GEN_FP : std_logic_vector(263 downto 0) :=
        FP_TXRX & FP_STR & FP_DBG & FP_RXC & FP_TXC & FP_MCF & FP_AW & FP_CLK & FP_MAX;

    -- Every input but clk / rst_n, in port order (100 bits)
    signal in_bits : std_logic_vector(99 downto 0);

    signal bb_q : std_logic_vector(363 downto 0);

begin

    in_bits <= s_axi_awaddr & s_axi_awvalid & s_axi_wdata & s_axi_wstrb &
               s_axi_wvalid & s_axi_bready & s_axi_araddr & s_axi_arvalid &
               s_axi_rready & s_axis_tdata & s_axis_tvalid & s_axis_tlast &
               m_axis_tready & mii_tx_clk & mii_rxd & mii_rx_dv & mii_rx_er &
               mii_rx_clk & mii_col & mii_crs & clk_125 & clk_125_90 & clk_25 &
               clk_2_5 & rgmii_rxd & rgmii_rx_ctl & rgmii_rxc &
               phy_gmii_rx_clk & phy_gmii_rxd & phy_gmii_rx_dv &
               phy_gmii_rx_er & mdio_i;

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            bb_q <= (others => '0');
        elsif rising_edge(clk) then
            bb_q <= (bb_q(362 downto 0) & bb_q(363)) xor (in_bits & GEN_FP)
                    xor ((bb_q(149 downto 0) & bb_q(363 downto 150)) and
                         (bb_q(219 downto 0) & bb_q(363 downto 220)));
        end if;
    end process;

    -- Every output bit from its own register bit, in port order (112 bits)
    s_axi_awready  <= bb_q(0);
    s_axi_wready   <= bb_q(1);
    s_axi_bresp    <= bb_q(3 downto 2);
    s_axi_bvalid   <= bb_q(4);
    s_axi_arready  <= bb_q(5);
    s_axi_rdata    <= bb_q(37 downto 6);
    s_axi_rresp    <= bb_q(39 downto 38);
    s_axi_rvalid   <= bb_q(40);
    s_axis_tready  <= bb_q(41);
    m_axis_tdata   <= bb_q(49 downto 42);
    m_axis_tvalid  <= bb_q(50);
    m_axis_tlast   <= bb_q(51);
    m_axis_terror  <= bb_q(52);
    m_axis_tsof    <= bb_q(53);
    mii_txd        <= bb_q(57 downto 54);
    mii_tx_en      <= bb_q(58);
    rgmii_txd      <= bb_q(62 downto 59);
    rgmii_tx_ctl   <= bb_q(63);
    rgmii_txc      <= bb_q(64);
    phy_gmii_txd   <= bb_q(72 downto 65);
    phy_gmii_tx_en <= bb_q(73);
    phy_gmii_tx_er <= bb_q(74);
    phy_gmii_txc   <= bb_q(75);
    mdc            <= bb_q(76);
    mdio_o         <= bb_q(77);
    mdio_oe        <= bb_q(78);
    cfg_ip_addr    <= bb_q(110 downto 79);
    irq            <= bb_q(111);

end architecture standin;
