-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- eth_mac.vhd - Ethernet MAC with MII PHY interface
-- Wraps eth_mac_tx + eth_mac_rx + mii_if into a single module.
-- AXI4-Stream interfaces for frame TX/RX, MII pins for PHY connection.
-- VHDL port of rtl/eth_mac.v (formally proven equivalent; see sim/parity/).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;

library work;
use work.emz_util_pkg.all;

entity eth_mac is
    generic (
        MAX_FRAME          : integer := 9018;   -- jumbo MTU + headers (1518 = standard)
        -- RX AXIS buffer depth (address width). Scales with MAX_FRAME so a jumbo
        -- frame can be absorbed under backpressure; 2048-byte floor for standard.
        RX_AXIS_ADDR_WIDTH : integer := 0;   -- 0 = max(clog2(MAX_FRAME), 11), as the Verilog default
        MII_DEBUG          : integer := 0
    );
    port (
        clk                         : in  std_logic;  -- system clock (100 MHz)
        rst_n                       : in  std_logic;
        -- ---- MII PHY pins ----
        mii_txd                     : out std_logic_vector(3 downto 0);
        mii_tx_en                   : out std_logic;
        mii_tx_clk                  : in  std_logic;
        mii_rxd                     : in  std_logic_vector(3 downto 0);
        mii_rx_dv                   : in  std_logic;
        mii_rx_er                   : in  std_logic;
        mii_rx_clk                  : in  std_logic;
        mii_col                     : in  std_logic;
        mii_crs                     : in  std_logic;
        -- ---- Configuration ----
        our_mac                     : in  std_logic_vector(47 downto 0);  -- MAC address filter
        promisc                     : in  std_logic;  -- accept all frames regardless of MAC
        -- ---- AXI4-Stream slave - frame TX (from network stack) ----
        s_axis_tdata                : in  std_logic_vector(7 downto 0);
        s_axis_tvalid               : in  std_logic;
        s_axis_tready               : out std_logic;
        s_axis_tlast                : in  std_logic;
        s_axis_tkeep                : in  std_logic_vector(0 downto 0);  -- unused (byte-wide, always 1)
        -- ---- AXI4-Stream master - frame RX (to network stack) ----
        m_axis_tdata                : out std_logic_vector(7 downto 0);
        m_axis_tvalid               : out std_logic;
        m_axis_tready               : in  std_logic;
        m_axis_tlast                : out std_logic;
        m_axis_terror               : out std_logic;  -- bad CRC or receive error
        m_axis_tsof                 : out std_logic;  -- start of frame (first byte)
        -- ---- Status ----
        tx_active                   : out std_logic;
        tx_fifo_busy_out            : out std_logic;  -- insufficient room for a max-sized frame
        tx_fifo_level_out           : out std_logic_vector(12 downto 0);  -- queued TX symbols in GMII->MII FIFO
        -- ---- Debug ----
        dbg_tx_fifo_empty           : out std_logic;
        dbg_rx_prog_empty           : out std_logic;
        dbg_rx_rd_empty             : out std_logic;
        dbg_rx_reading              : out std_logic;
        dbg_rx_frames_pending       : out std_logic_vector(1 downto 0);
        -- GMII debug (exposed for ILA)
        dbg_gmii_txd                : out std_logic_vector(7 downto 0);
        dbg_gmii_tx_en              : out std_logic;
        dbg_gmii_rxd                : out std_logic_vector(7 downto 0);
        dbg_gmii_rx_dv              : out std_logic;
        -- MAC TX internals
        dbg_mac_tx_state            : out std_logic_vector(3 downto 0);
        dbg_mac_tx_stall_cnt        : out std_logic_vector(3 downto 0);
        -- TX FIFO internals
        dbg_tx_wr_en                : out std_logic;
        dbg_tx_len_wr_en            : out std_logic;
        dbg_tx_wr_full              : out std_logic;
        dbg_tx_wr_rst_busy          : out std_logic;
        dbg_tx_rd_en                : out std_logic;
        dbg_tx_frame_loaded         : out std_logic;
        dbg_tx_frames_queued        : out std_logic_vector(11 downto 0);
        dbg_tx_frames_drained       : out std_logic_vector(11 downto 0);
        dbg_last_tx_len_wr          : out std_logic_vector(11 downto 0);
        -- MII TX capture
        dbg_mii_cap_done            : out std_logic;
        dbg_mii_cap_frame_len       : out std_logic_vector(11 downto 0);
        dbg_mii_cap_word0           : out std_logic_vector(31 downto 0);
        dbg_mii_cap_word1           : out std_logic_vector(31 downto 0);
        dbg_mii_cap_word2           : out std_logic_vector(31 downto 0);
        dbg_mii_cap_word3           : out std_logic_vector(31 downto 0);
        dbg_rx_fifo_full_frames     : out std_logic_vector(31 downto 0);
        dbg_rx_fifo_full_writes     : out std_logic_vector(31 downto 0);
        dbg_rx_fifo_overflow_pulses : out std_logic_vector(31 downto 0);
        dbg_rx_fifo_wr_level_max    : out std_logic_vector(31 downto 0);
        dbg_rx_replay_gap_frames    : out std_logic_vector(31 downto 0);
        dbg_rx_replay_gap_cycles    : out std_logic_vector(31 downto 0);
        dbg_rx_replay_gap_byte_max  : out std_logic_vector(31 downto 0)
    );
end entity eth_mac;

architecture rtl of eth_mac is

    -- RX_AXIS_ADDR_WIDTH resolved (its Verilog default depends on MAX_FRAME,
    -- which a VHDL-93 generic default cannot; see emz_util_pkg.auto_or).
    constant RX_AXIS_AW : integer := auto_or(RX_AXIS_ADDR_WIDTH, max_int(clog2(MAX_FRAME), 11));

    -- =========================================================================
    -- Internal GMII bus (sys_clk domain, hidden from external)
    -- =========================================================================
    signal gmii_txd   : std_logic_vector(7 downto 0);
    signal gmii_tx_en : std_logic;
    signal gmii_tx_er : std_logic;
    signal gmii_rxd   : std_logic_vector(7 downto 0);
    signal gmii_rx_dv : std_logic;
    signal gmii_rx_er : std_logic;

    signal tx_fifo_busy  : std_logic;
    signal tx_fifo_level : std_logic_vector(12 downto 0);
    signal tx_start_ok   : std_logic;

begin

    dbg_gmii_txd   <= gmii_txd   when MII_DEBUG /= 0 else (others => '0');
    dbg_gmii_tx_en <= gmii_tx_en when MII_DEBUG /= 0 else '0';
    dbg_gmii_rxd   <= gmii_rxd   when MII_DEBUG /= 0 else (others => '0');
    dbg_gmii_rx_dv <= gmii_rx_dv when MII_DEBUG /= 0 else '0';

    -- =========================================================================
    -- MII PHY Interface (clock-domain crossing)
    -- =========================================================================
    tx_fifo_busy_out  <= tx_fifo_busy;
    tx_fifo_level_out <= tx_fifo_level;

    u_mii_if : entity work.mii_if
        generic map (MII_DEBUG => MII_DEBUG)
        port map (
            clk            => clk,
            rst_n          => rst_n,
            -- MII pins
            mii_rxd        => mii_rxd,
            mii_rx_dv      => mii_rx_dv,
            mii_rx_er      => mii_rx_er,
            mii_rx_clk     => mii_rx_clk,
            mii_col        => mii_col,
            mii_crs        => mii_crs,
            mii_txd        => mii_txd,
            mii_tx_en      => mii_tx_en,
            mii_tx_clk     => mii_tx_clk,
            -- GMII (sys_clk domain)
            gmii_txd       => gmii_txd,
            gmii_tx_en     => gmii_tx_en,
            gmii_tx_er     => gmii_tx_er,
            gmii_rxd       => gmii_rxd,
            gmii_rx_dv     => gmii_rx_dv,
            gmii_rx_er     => gmii_rx_er,
            mii_tx_clk_out => open,
            tx_busy                => tx_fifo_busy,
            tx_fifo_level          => tx_fifo_level,
            dbg_tx_fifo_empty      => dbg_tx_fifo_empty,
            dbg_rx_prog_empty      => dbg_rx_prog_empty,
            dbg_rx_rd_empty        => dbg_rx_rd_empty,
            dbg_rx_reading         => dbg_rx_reading,
            dbg_rx_frames_pending  => dbg_rx_frames_pending,
            dbg_tx_wr_en           => dbg_tx_wr_en,
            dbg_tx_len_wr_en       => dbg_tx_len_wr_en,
            dbg_tx_wr_full         => dbg_tx_wr_full,
            dbg_tx_wr_rst_busy_out => dbg_tx_wr_rst_busy,
            dbg_tx_rd_en           => dbg_tx_rd_en,
            dbg_tx_frame_loaded    => dbg_tx_frame_loaded,
            dbg_tx_frames_queued   => dbg_tx_frames_queued,
            dbg_tx_frames_drained  => dbg_tx_frames_drained,
            dbg_last_tx_len_wr     => dbg_last_tx_len_wr,
            dbg_mii_cap_done       => dbg_mii_cap_done,
            dbg_mii_cap_frame_len  => dbg_mii_cap_frame_len,
            dbg_mii_cap_word0      => dbg_mii_cap_word0,
            dbg_mii_cap_word1      => dbg_mii_cap_word1,
            dbg_mii_cap_word2      => dbg_mii_cap_word2,
            dbg_mii_cap_word3      => dbg_mii_cap_word3,
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
            dbg_rx_fifo_full_frames     => dbg_rx_fifo_full_frames,
            dbg_rx_fifo_full_writes     => dbg_rx_fifo_full_writes,
            dbg_rx_fifo_overflow_pulses => dbg_rx_fifo_overflow_pulses,
            dbg_rx_fifo_wr_level_max    => dbg_rx_fifo_wr_level_max,
            dbg_rx_replay_gap_frames    => dbg_rx_replay_gap_frames,
            dbg_rx_replay_gap_cycles    => dbg_rx_replay_gap_cycles,
            dbg_rx_replay_gap_byte_max  => dbg_rx_replay_gap_byte_max,
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

    -- =========================================================================
    -- MAC RX - strips preamble/SFD, validates CRC
    -- =========================================================================
    u_mac_rx : entity work.eth_mac_rx
        generic map (
            AXIS_FIFO_ADDR_WIDTH => RX_AXIS_AW,
            MAX_FRAME_JUMBO      => MAX_FRAME          -- with jumbo_en, FCS included
        )
        port map (
            clk               => clk,
            rst_n             => rst_n,
            gmii_rxd          => gmii_rxd,
            gmii_rx_dv        => gmii_rx_dv,
            gmii_rx_er        => gmii_rx_er,
            our_mac           => our_mac,
            promisc           => promisc,
            passthrough       => '0',
            jumbo_en          => '1',       -- standalone wrapper: always allow jumbo
            rx_csum_en        => '0',
            mcast_hash_table  => (others => '0'),
            m_axis_tdata      => m_axis_tdata,
            m_axis_tvalid     => m_axis_tvalid,
            m_axis_tready     => m_axis_tready,
            m_axis_tlast      => m_axis_tlast,
            m_axis_terror     => m_axis_terror,
            m_axis_tsof       => m_axis_tsof,
            stat_done         => open,
            stat_len          => open,
            stat_err_fcs      => open,
            stat_err_align    => open,
            stat_err_overflow => open,
            stat_err_oversize => open,
            stat_err_csum     => open,
            stat_is_bcast     => open,
            stat_is_mcast     => open,
            stat_drop         => open
        );

    -- =========================================================================
    -- MAC TX - adds preamble/SFD, pads, appends CRC
    -- =========================================================================
    tx_start_ok <= not tx_fifo_busy;

    u_mac_tx : entity work.eth_mac_tx
        generic map (MAX_FRAME => MAX_FRAME)
        port map (
            clk           => clk,
            rst_n         => rst_n,
            tx_start_ok   => tx_start_ok,
            gmii_txd      => gmii_txd,
            gmii_tx_en    => gmii_tx_en,
            gmii_tx_er    => gmii_tx_er,
            s_axis_tdata  => s_axis_tdata,
            s_axis_tvalid => s_axis_tvalid,
            s_axis_tready => s_axis_tready,
            s_axis_tkeep  => s_axis_tkeep,
            s_axis_tlast  => s_axis_tlast,
            tx_active     => tx_active,
            dbg_state     => dbg_mac_tx_state,
            dbg_stall_cnt => dbg_mac_tx_stall_cnt
        );

end architecture rtl;
