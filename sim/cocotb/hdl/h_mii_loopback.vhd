-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- h_mii_loopback.vhd - cocotb harness: eth_mac_tx -> mii_if (MII looped back)
-- -> eth_mac_rx
--
-- The DUT wiring of sim/tb/tb_mii_loopback.v (bench MII-LOOPBACK): mii_if's
-- MII TX pins drive its own MII RX pins (mii_rxd = mii_txd, mii_rx_dv =
-- mii_tx_en), RX sampled on a separate, phase-shifted mii_rx_clk that the test
-- drives. eth_mac_tx feeds mii_if's GMII TX side with tx_start_ok tied high;
-- eth_mac_rx takes mii_if's GMII RX side, our_mac = broadcast, jumbo on.
-- The connections and tie-offs are the bench's; port names are the bench's
-- net names. The bench also declares a never-driven mac_rx_tuser bus as a
-- second (z) driver of mac_rx_error / mac_rx_sof; z resolves to the
-- eth_mac_rx output, so it is left out here.
-- TX_MAX_FRAME / AXIS_FIFO_ADDR_WIDTH only pass through to eth_mac_tx
-- MAX_FRAME / eth_mac_rx AXIS_FIFO_ADDR_WIDTH (the bench uses the defaults)
-- so the equivalence proof can shrink them. Same entity in h_mii_loopback.v.
-- VHDL-93.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity h_mii_loopback is
    generic (
        TX_MAX_FRAME         : integer := 9018;
        AXIS_FIFO_ADDR_WIDTH : integer := 11
    );
    port (
        clk          : in  std_logic;
        rst_n        : in  std_logic;
        mii_tx_clk   : in  std_logic;
        mii_rx_clk   : in  std_logic;

        -- MAC TX AXI4-Stream input
        tx_data      : in  std_logic_vector(7 downto 0);
        tx_valid     : in  std_logic;
        tx_ready     : out std_logic;
        tx_last      : in  std_logic;

        -- MAC RX AXI4-Stream output (m_axis_tready tied high, as in the bench)
        mac_rx_data  : out std_logic_vector(7 downto 0);
        mac_rx_valid : out std_logic;
        mac_rx_last  : out std_logic;
        mac_rx_error : out std_logic;
        mac_rx_sof   : out std_logic;

        -- Nets the bench observes
        gmii_txd     : out std_logic_vector(7 downto 0);
        gmii_tx_en   : out std_logic;
        gmii_tx_er   : out std_logic;
        gmii_rxd     : out std_logic_vector(7 downto 0);
        gmii_rx_dv   : out std_logic;
        gmii_rx_er   : out std_logic;
        mii_txd      : out std_logic_vector(3 downto 0);
        mii_tx_en    : out std_logic
    );
end entity h_mii_loopback;

architecture rtl of h_mii_loopback is
    -- Internal copies of the nets that are both read and driven here
    -- (VHDL-93 cannot read an out port).
    signal gmii_txd_i   : std_logic_vector(7 downto 0);
    signal gmii_tx_en_i : std_logic;
    signal gmii_tx_er_i : std_logic;
    signal gmii_rxd_i   : std_logic_vector(7 downto 0);
    signal gmii_rx_dv_i : std_logic;
    signal gmii_rx_er_i : std_logic;
    signal mii_txd_i    : std_logic_vector(3 downto 0);
    signal mii_tx_en_i  : std_logic;

    -- MII loopback wires
    signal mii_rxd      : std_logic_vector(3 downto 0);
    signal mii_rx_dv    : std_logic;

    signal tx_fifo_busy : std_logic;
begin
    mii_rxd   <= mii_txd_i;
    mii_rx_dv <= mii_tx_en_i;

    gmii_txd   <= gmii_txd_i;
    gmii_tx_en <= gmii_tx_en_i;
    gmii_tx_er <= gmii_tx_er_i;
    gmii_rxd   <= gmii_rxd_i;
    gmii_rx_dv <= gmii_rx_dv_i;
    gmii_rx_er <= gmii_rx_er_i;
    mii_txd    <= mii_txd_i;
    mii_tx_en  <= mii_tx_en_i;

    u_mii : entity work.mii_if
        port map (
            clk => clk, rst_n => rst_n,
            mii_rxd => mii_rxd, mii_rx_dv => mii_rx_dv, mii_rx_er => '0',
            mii_rx_clk => mii_rx_clk, mii_col => '0', mii_crs => '0',
            mii_txd => mii_txd_i, mii_tx_en => mii_tx_en_i, mii_tx_clk => mii_tx_clk,
            gmii_txd => gmii_txd_i, gmii_tx_en => gmii_tx_en_i, gmii_tx_er => gmii_tx_er_i,
            gmii_rxd => gmii_rxd_i, gmii_rx_dv => gmii_rx_dv_i, gmii_rx_er => gmii_rx_er_i,
            mii_tx_clk_out => open,
            tx_busy => tx_fifo_busy,
            dbg_tx_fifo_empty => open, dbg_rx_prog_empty => open,
            dbg_rx_rd_empty => open, dbg_rx_reading => open, dbg_rx_frames_pending => open
        );

    u_mac_tx : entity work.eth_mac_tx
        generic map (MAX_FRAME => TX_MAX_FRAME)
        port map (
            clk => clk, rst_n => rst_n,
            tx_start_ok => '1',
            gmii_txd => gmii_txd_i, gmii_tx_en => gmii_tx_en_i, gmii_tx_er => gmii_tx_er_i,
            s_axis_tdata => tx_data, s_axis_tvalid => tx_valid,
            s_axis_tready => tx_ready, s_axis_tkeep => "1", s_axis_tlast => tx_last,
            tx_active => open
        );

    u_mac_rx : entity work.eth_mac_rx
        generic map (AXIS_FIFO_ADDR_WIDTH => AXIS_FIFO_ADDR_WIDTH)
        port map (
            clk => clk, rst_n => rst_n,
            gmii_rxd => gmii_rxd_i, gmii_rx_dv => gmii_rx_dv_i, gmii_rx_er => gmii_rx_er_i,
            our_mac => x"FFFFFFFFFFFF",  -- accept broadcast
            promisc => '0',
            passthrough => '0',
            jumbo_en => '1', rx_csum_en => '0',
            mcast_hash_table => (others => '0'),
            m_axis_tdata => mac_rx_data, m_axis_tvalid => mac_rx_valid,
            m_axis_tready => '1',
            m_axis_tlast => mac_rx_last, m_axis_terror => mac_rx_error, m_axis_tsof => mac_rx_sof,
            stat_done => open, stat_len => open, stat_err_fcs => open, stat_err_align => open,
            stat_err_overflow => open, stat_err_oversize => open, stat_err_csum => open,
            stat_is_bcast => open, stat_is_mcast => open, stat_drop => open
        );

end architecture rtl;
