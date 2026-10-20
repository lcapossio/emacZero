-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- gmii_lb_selftest.vhd - On-silicon GMII-path self-test for the Arty A7
-- VHDL port of fpga/arty_a7/rtl/gmii_lb_selftest.v (formally proven
-- equivalent; see sim/parity/).
--
-- The Arty's DP83848J PHY is 10/100 MII only, so the board build never
-- instantiates gmii_cdc. This block puts a second eth_mac_sys on the die with
-- PHY_INTERFACE="GMII" and MAX_FRAME=9018, loops its GMII pins back in fabric
-- on a 125 MHz MMCM clock, and runs generated traffic through the full path:
--
--   generator -> AXIS TX -> eth_mac_tx -> gmii_cdc TX -> gmii_if -> loopback
--   -> gmii_if -> gmii_cdc RX -> eth_mac_rx (FCS check) -> AXIS RX -> checker
--
-- Payload lengths cycle through 46, 60, 1500, 1501, 4000, 4097, 8000 and 9000
-- bytes (9000 = MAX_FRAME on the wire), so every eighth-frame group includes
-- frames above the ~4083-byte size the old fixed RX CDC FIFO truncated.
-- Every frame carries a 32-bit sequence number and a sequence-seeded byte
-- pattern; the checker verifies length, header, pattern, terror and order.
--
-- The MAC's system clock is the same 125 MHz as the GMII media clock, so the TX
-- framer fills the wire at line rate and RX must sustain a full 1 Gb/s. At
-- clk = 125 MHz the RX reader has ~11 cycles of slack per frame (IFG +
-- preamble), so the loopback is lossless: any rx_bad / rx_terror / seq_gap
-- count is a real failure. (At a 100 MHz clk RX would fall behind and drop.)
--
-- Control (ctrl, async - synchronized here):
--   [0] run   - generate traffic while high (the current frame completes)
--   [1] clear - hold high to zero all counters
-- Status (clk_125 domain; stop traffic before reading for a coherent view):
--   [31:0]    tx_frames       frames handed to the MAC
--   [63:32]   rx_ok           frames received exact and clean
--   [95:64]   rx_ok_big       of those, frames longer than 4083 bytes
--   [127:96]  rx_bad          frames with wrong length / header / payload
--   [159:128] rx_terror       frames delivered with terror
--   [191:160] seq_gap         frames received out of sequence (lost/merged)
--   [207:192] max_ok_len      longest exact frame (bytes, FCS stripped)
--   [223:208] first_bad_len   length of the first bad frame
--   [239:224] first_bad_seq   sequence number [15:0] of the first bad frame
--   [240] init_done  [241] run (synced)  [242] mmcm_locked
--   [255:244] 12'hB0A        marker: this bitstream has the self-test
--
-- The Verilog `ifdef SIM selects a behavioural 125 MHz clock; here that is
-- EMZ_TARGET = "SIM" from emz_target_pkg (one of rtl/vhdl/target/
-- emz_target_*.vhd). Every other target instantiates the MMCM and BUFGs,
-- declared as local components (no library unisim), so the file analyses
-- without vendor libraries and Vivado binds the real primitives.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.emz_target_pkg.all;
-- VHDL-93 binds a component instance by default only to a directly visible
-- entity of the same name. This makes simulation models of the vendor
-- primitives compiled into work (sim/parity/) bind; Vivado binds the real
-- primitives by name either way.
use work.all;

entity gmii_lb_selftest is
    port (
        clk    : in  std_logic;                        -- 100 MHz system clock
        rst_n  : in  std_logic;
        ctrl   : in  std_logic_vector(1 downto 0);
        status : out std_logic_vector(255 downto 0)
    );
end entity gmii_lb_selftest;

architecture rtl of gmii_lb_selftest is

    -- Xilinx 7-series MMCM (unisim; only the generics set here).
    component MMCME2_BASE is
        generic (
            CLKFBOUT_MULT_F  : real    := 5.000;
            CLKIN1_PERIOD    : real    := 0.000;
            CLKOUT0_DIVIDE_F : real    := 1.000;
            DIVCLK_DIVIDE    : integer := 1
        );
        port (
            CLKFBOUT  : out std_ulogic;
            CLKFBOUTB : out std_ulogic;
            CLKOUT0   : out std_ulogic;
            CLKOUT0B  : out std_ulogic;
            CLKOUT1   : out std_ulogic;
            CLKOUT1B  : out std_ulogic;
            CLKOUT2   : out std_ulogic;
            CLKOUT2B  : out std_ulogic;
            CLKOUT3   : out std_ulogic;
            CLKOUT3B  : out std_ulogic;
            CLKOUT4   : out std_ulogic;
            CLKOUT5   : out std_ulogic;
            CLKOUT6   : out std_ulogic;
            LOCKED    : out std_ulogic;
            CLKFBIN   : in  std_ulogic;
            CLKIN1    : in  std_ulogic;
            PWRDWN    : in  std_ulogic;
            RST       : in  std_ulogic
        );
    end component MMCME2_BASE;

    -- Xilinx global clock buffer (unisim).
    component BUFG is
        port (
            O : out std_ulogic;
            I : in  std_ulogic
        );
    end component BUFG;

    -- =========================================================================
    -- 125 MHz media clock (MMCM: 100 MHz x 10 / 8)
    -- =========================================================================
    signal clk_125, mmcm_locked : std_logic;
    signal clk_125_mmcm, clkfb, clkfb_buf : std_logic;
    signal mmcm_rst : std_logic;              -- !rst_n (VHDL-93: no expression in a port map)

    signal lock_s : std_logic_vector(1 downto 0);
    attribute ASYNC_REG : string;
    attribute ASYNC_REG of lock_s : signal is "TRUE";
    signal lb_rst_n : std_logic;

    signal run_s, clr_s : std_logic_vector(1 downto 0);
    attribute ASYNC_REG of run_s : signal is "TRUE";
    attribute ASYNC_REG of clr_s : signal is "TRUE";
    signal run   : std_logic;
    signal clear : std_logic;

    -- =========================================================================
    -- Loopback MAC
    -- =========================================================================
    signal awaddr                   : std_logic_vector(7 downto 0);
    signal awvalid, wvalid, bready  : std_logic;
    signal wdata                    : std_logic_vector(31 downto 0);
    signal awready, wready, bvalid  : std_logic;

    signal tx_tdata                 : std_logic_vector(7 downto 0);
    signal tx_tvalid, tx_tlast      : std_logic;
    signal tx_tready                : std_logic;

    signal m_rx_tdata               : std_logic_vector(7 downto 0);
    signal m_rx_tvalid, m_rx_tlast, m_rx_terror, m_rx_tsof : std_logic;

    signal gmii_txd                 : std_logic_vector(7 downto 0);
    signal gmii_tx_en, gmii_tx_er   : std_logic;

    -- =========================================================================
    -- CSR init
    -- =========================================================================
    signal init_done        : std_logic;
    signal aw_done, w_done  : std_logic;
    signal awaddr_keep      : std_logic_vector(7 downto 0);    -- = awaddr (see below)
    signal wdata_keep       : std_logic_vector(31 downto 0);   -- = wdata

    -- =========================================================================
    -- Frame length table (payload bytes; frame = 14 + payload, FCS added)
    -- =========================================================================
    function payload_len(sel : unsigned(2 downto 0)) return unsigned is
        variable r : unsigned(13 downto 0);
    begin
        case to_integer(sel) is
            when 0 => r := to_unsigned(46, 14);
            when 1 => r := to_unsigned(60, 14);
            when 2 => r := to_unsigned(1500, 14);
            when 3 => r := to_unsigned(1501, 14);
            when 4 => r := to_unsigned(4000, 14);
            when 5 => r := to_unsigned(4097, 14);
            when 6 => r := to_unsigned(8000, 14);
            when others => r := to_unsigned(9000, 14);
        end case;
        return r;
    end function payload_len;

    -- Expected byte at index idx of frame seq (header + seq + pattern).
    function frame_byte(seq : unsigned(31 downto 0); idx : unsigned(13 downto 0))
        return std_logic_vector is
        variable r : std_logic_vector(7 downto 0);
    begin
        if idx < 6 then       r := x"FF";                               -- DA bcast
        elsif idx = 6 then    r := x"02";                               -- SA
        elsif idx < 11 then   r := x"00";
        elsif idx = 11 then   r := x"02";
        elsif idx = 12 then   r := x"88";                               -- EtherType
        elsif idx = 13 then   r := x"B5";                               -- 0x88B5
        elsif idx = 14 then   r := std_logic_vector(seq(31 downto 24));
        elsif idx = 15 then   r := std_logic_vector(seq(23 downto 16));
        elsif idx = 16 then   r := std_logic_vector(seq(15 downto 8));
        elsif idx = 17 then   r := std_logic_vector(seq(7 downto 0));
        else                  r := std_logic_vector(seq(7 downto 0) + idx(7 downto 0));
        end if;
        return r;
    end function frame_byte;

    -- =========================================================================
    -- Generator
    -- =========================================================================
    signal tx_seq              : unsigned(31 downto 0);
    signal tx_idx, tx_last_idx : unsigned(13 downto 0);
    signal tx_busy             : std_logic;
    signal tx_frames           : unsigned(31 downto 0);

    -- =========================================================================
    -- Checker
    -- =========================================================================
    signal rx_tdata  : std_logic_vector(7 downto 0);
    signal rx_tvalid, rx_tlast, rx_terror, rx_tsof : std_logic;

    signal rx_idx        : unsigned(13 downto 0);
    signal rx_seq        : unsigned(31 downto 0);
    signal rx_mismatch   : std_logic;
    signal rx_exp_seq    : unsigned(31 downto 0);
    signal rx_seen_any   : std_logic;
    signal rx_ok, rx_ok_big, rx_bad, rx_terr, seq_gap : unsigned(31 downto 0);
    signal max_ok_len, first_bad_len, first_bad_seq : unsigned(15 downto 0);
    signal first_bad_set : std_logic;

    signal cur_idx  : unsigned(13 downto 0);
    signal cur_seq  : unsigned(31 downto 0);
    signal byte_bad : std_logic;

    signal s_valid, s_first, s_last, s_terror, s_bad : std_logic;
    signal s_idx    : unsigned(13 downto 0);
    signal s_seq    : unsigned(31 downto 0);

    signal mism_now : std_logic;
    signal fr_len   : unsigned(15 downto 0);
    signal exp_len  : unsigned(15 downto 0);
    signal fr_good  : std_logic;

begin

    -- =========================================================================
    -- 125 MHz media clock (MMCM: 100 MHz x 10 / 8)
    -- =========================================================================
    gen_sim : if EMZ_TARGET = "SIM" generate
        -- Icarus has no MMCM: free-running behavioral 125 MHz, locked after reset.
        signal clk_125_sim : std_logic := '0';
    begin
        clk_125_sim <= not clk_125_sim after 4 ns;
        clk_125     <= clk_125_sim;
        mmcm_locked <= rst_n;
    end generate gen_sim;

    -- Every other target (the Verilog `else` of `ifdef SIM). The generate is
    -- labelled u and the instances mmcm / bufg_fb / bufg_125, so they flatten
    -- to the Verilog instance names u_mmcm / u_bufg_fb / u_bufg_125.
    u : if EMZ_TARGET /= "SIM" generate
        mmcm_rst <= not rst_n;

        mmcm : MMCME2_BASE
            generic map (
                CLKIN1_PERIOD    => 10.0,
                DIVCLK_DIVIDE    => 1,
                CLKFBOUT_MULT_F  => 10.0,
                CLKOUT0_DIVIDE_F => 8.0
            )
            port map (
                CLKIN1    => clk,
                CLKFBIN   => clkfb_buf,
                CLKFBOUT  => clkfb,
                CLKOUT0   => clk_125_mmcm,
                LOCKED    => mmcm_locked,
                PWRDWN    => '0',
                RST       => mmcm_rst,
                CLKFBOUTB => open, CLKOUT0B => open, CLKOUT1 => open, CLKOUT1B => open,
                CLKOUT2   => open, CLKOUT2B => open, CLKOUT3 => open, CLKOUT3B => open,
                CLKOUT4   => open, CLKOUT5  => open, CLKOUT6 => open
            );
        bufg_fb  : BUFG port map (I => clkfb,        O => clkfb_buf);
        bufg_125 : BUFG port map (I => clk_125_mmcm, O => clk_125);
    end generate u;

    -- Everything below runs on clk_125: the MAC's system clock equals the GMII
    -- media clock, so the TX framer fills the wire at line rate and the RX
    -- side must keep up at a sustained 1 Gb/s (eth_mac_sys requires clk >=
    -- 125 MHz for 1G). Reset the loopback logic until the MMCM is locked.
    process (clk_125, rst_n)
    begin
        if rst_n = '0' then
            lock_s <= "00";
        elsif rising_edge(clk_125) then
            lock_s <= lock_s(0) & mmcm_locked;
        end if;
    end process;
    lb_rst_n <= rst_n and lock_s(1);

    process (clk_125, lb_rst_n)
    begin
        if lb_rst_n = '0' then
            run_s <= "00";
            clr_s <= "00";
        elsif rising_edge(clk_125) then
            run_s <= run_s(0) & ctrl(0);
            clr_s <= clr_s(0) & ctrl(1);
        end if;
    end process;
    run   <= run_s(1);
    clear <= clr_s(1);

    -- =========================================================================
    -- Loopback MAC
    -- =========================================================================
    u_lb_mac : entity work.eth_mac_sys
        generic map (
            PHY_INTERFACE => "GMII",
            MAX_FRAME     => 9018,
            CLK_FREQ_HZ   => 125_000_000
        )
        port map (
            clk             => clk_125,
            rst_n           => lb_rst_n,
            s_axi_awaddr    => awaddr,
            s_axi_awvalid   => awvalid,
            s_axi_awready   => awready,
            s_axi_wdata     => wdata,
            s_axi_wstrb     => x"F",
            s_axi_wvalid    => wvalid,
            s_axi_wready    => wready,
            s_axi_bresp     => open,
            s_axi_bvalid    => bvalid,
            s_axi_bready    => bready,
            s_axi_araddr    => x"00",
            s_axi_arvalid   => '0',
            s_axi_arready   => open,
            s_axi_rdata     => open,
            s_axi_rresp     => open,
            s_axi_rvalid    => open,
            s_axi_rready    => '1',
            s_axis_tdata    => tx_tdata,
            s_axis_tvalid   => tx_tvalid,
            s_axis_tready   => tx_tready,
            s_axis_tlast    => tx_tlast,
            m_axis_tdata    => m_rx_tdata,
            m_axis_tvalid   => m_rx_tvalid,
            m_axis_tready   => '1',
            m_axis_tlast    => m_rx_tlast,
            m_axis_terror   => m_rx_terror,
            m_axis_tsof     => m_rx_tsof,
            mii_txd         => open,
            mii_tx_en       => open,
            mii_tx_clk      => '0',
            mii_rxd         => "0000",
            mii_rx_dv       => '0',
            mii_rx_er       => '0',
            mii_rx_clk      => '0',
            mii_col         => '0',
            mii_crs         => '0',
            clk_125         => clk_125,
            clk_125_90      => '0',
            clk_25          => '0',
            clk_2_5         => '0',
            rgmii_txd       => open,
            rgmii_tx_ctl    => open,
            rgmii_txc       => open,
            rgmii_rxd       => "0000",
            rgmii_rx_ctl    => '0',
            rgmii_rxc       => '0',
            -- GMII pins looped back in fabric. The RX side samples on the same
            -- 125 MHz clock, so the loop is a plain one-cycle register path.
            phy_gmii_txd    => gmii_txd,
            phy_gmii_tx_en  => gmii_tx_en,
            phy_gmii_tx_er  => gmii_tx_er,
            phy_gmii_txc    => open,
            phy_gmii_rx_clk => clk_125,
            phy_gmii_rxd    => gmii_txd,
            phy_gmii_rx_dv  => gmii_tx_en,
            phy_gmii_rx_er  => gmii_tx_er,
            mdc             => open,
            mdio_i          => '1',
            mdio_o          => open,
            mdio_oe         => open,
            cfg_ip_addr     => open,
            irq             => open
        );

    -- =========================================================================
    -- CSR init: CTRL = tx_en | rx_en | promisc | full_duplex | jumbo_en
    -- =========================================================================
    awaddr_keep <= awaddr;
    wdata_keep  <= wdata;

    process (clk_125, lb_rst_n)
    begin
        if lb_rst_n = '0' then
            awaddr    <= x"04";
            wdata     <= x"00000067";
            awvalid   <= '0';
            wvalid    <= '0';
            bready    <= '0';
            aw_done   <= '0';
            w_done    <= '0';
            init_done <= '0';
        elsif rising_edge(clk_125) then
            -- awaddr / wdata only ever take their reset values (as in the
            -- Verilog). The hold through awaddr_keep / wdata_keep keeps them
            -- flip-flops: assigned under the reset alone (or from themselves,
            -- which GHDL drops as a no-op), GHDL synthesis infers a latch.
            awaddr <= awaddr_keep;
            wdata  <= wdata_keep;
            if init_done = '0' then
                awvalid <= (not aw_done) and not (awvalid and awready);
                wvalid  <= (not w_done)  and not (wvalid  and wready);
                if awvalid = '1' and awready = '1' then aw_done <= '1'; end if;
                if wvalid = '1' and wready = '1' then w_done <= '1'; end if;
                bready <= '1';
                if bvalid = '1' and bready = '1' then
                    bready    <= '0';
                    init_done <= '1';
                end if;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- Generator
    -- =========================================================================
    process (clk_125, lb_rst_n)
    begin
        if lb_rst_n = '0' then
            tx_seq      <= (others => '0');
            tx_idx      <= (others => '0');
            tx_last_idx <= (others => '0');
            tx_busy     <= '0';
            tx_tvalid   <= '0';
            tx_tlast    <= '0';
            tx_tdata    <= (others => '0');
            tx_frames   <= (others => '0');
        elsif rising_edge(clk_125) then
            if clear = '1' then tx_frames <= (others => '0'); end if;
            if tx_busy = '0' then
                if run = '1' and init_done = '1' then
                    tx_busy     <= '1';
                    tx_idx      <= (others => '0');
                    tx_last_idx <= 13 + payload_len(tx_seq(2 downto 0));
                    tx_tvalid   <= '1';
                    tx_tdata    <= frame_byte(tx_seq, to_unsigned(0, 14));
                    tx_tlast    <= '0';
                end if;
            elsif tx_tready = '1' then
                if tx_tlast = '1' then
                    tx_busy   <= '0';
                    tx_tvalid <= '0';
                    tx_tlast  <= '0';
                    tx_seq    <= tx_seq + 1;
                    if clear = '0' then tx_frames <= tx_frames + 1; end if;
                else
                    tx_idx   <= tx_idx + 1;
                    tx_tdata <= frame_byte(tx_seq, tx_idx + 1);
                    if tx_idx + 1 = tx_last_idx then
                        tx_tlast <= '1';
                    else
                        tx_tlast <= '0';
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- Checker
    -- =========================================================================
    -- Input register stage: keeps the RX AXIS buffer's block-RAM clock-to-out
    -- off the compare/count logic below (one path failed 100 MHz without it).
    process (clk_125, lb_rst_n)
    begin
        if lb_rst_n = '0' then
            rx_tdata  <= (others => '0');
            rx_tvalid <= '0';
            rx_tlast  <= '0';
            rx_terror <= '0';
            rx_tsof   <= '0';
        elsif rising_edge(clk_125) then
            rx_tdata  <= m_rx_tdata;
            rx_tvalid <= m_rx_tvalid;
            rx_tlast  <= m_rx_tlast;
            rx_terror <= m_rx_terror;
            rx_tsof   <= m_rx_tsof;
        end if;
    end process;

    cur_idx <= to_unsigned(0, 14) when rx_tsof = '1' else rx_idx;
    cur_seq <= unsigned(rx_tdata) & rx_seq(23 downto 0) when cur_idx = 14 else
               rx_seq(31 downto 24) & unsigned(rx_tdata) & rx_seq(15 downto 0) when cur_idx = 15 else
               rx_seq(31 downto 16) & unsigned(rx_tdata) & rx_seq(7 downto 0) when cur_idx = 16 else
               rx_seq(31 downto 8) & unsigned(rx_tdata) when cur_idx = 17 else
               rx_seq;
    -- Header bytes and the pattern are checked; the seq bytes define the frame.
    byte_bad <= '1' when ((cur_idx < 14) or (cur_idx > 17)) and
                         (rx_tdata /= frame_byte(cur_seq, cur_idx)) else '0';
    -- Stage 1: track index and sequence, compare each byte. Registering the
    -- per-byte result keeps the expected-byte compare off the frame-verdict
    -- and counter-enable logic below (together they missed 125 MHz).
    process (clk_125, lb_rst_n)
    begin
        if lb_rst_n = '0' then
            rx_idx   <= (others => '0');
            rx_seq   <= (others => '0');
            s_valid  <= '0';
            s_first  <= '0';
            s_last   <= '0';
            s_terror <= '0';
            s_bad    <= '0';
            s_idx    <= (others => '0');
            s_seq    <= (others => '0');
        elsif rising_edge(clk_125) then
            s_valid <= rx_tvalid;
            if rx_tvalid = '1' then
                rx_seq   <= cur_seq;
                if rx_tlast = '1' then
                    rx_idx <= (others => '0');
                elsif cur_idx = 16#3FFF# then
                    rx_idx <= cur_idx;
                else
                    rx_idx <= cur_idx + 1;
                end if;
                s_first  <= rx_tsof;
                s_last   <= rx_tlast;
                s_terror <= rx_terror;
                s_bad    <= byte_bad;
                s_idx    <= cur_idx;
                s_seq    <= cur_seq;
            end if;
        end if;
    end process;

    -- Stage 2: accumulate mismatches and judge the frame at its last byte.
    mism_now <= (rx_mismatch and not s_first) or s_bad;
    fr_len   <= ("00" & s_idx) + 1;
    exp_len  <= 14 + ("00" & payload_len(s_seq(2 downto 0)));
    fr_good  <= '1' when mism_now = '0' and s_terror = '0' and fr_len = exp_len else '0';

    -- The mismatch flag follows every beat, clear or not: a bad byte that
    -- arrives while clear is high must still fail its frame if clear drops
    -- before the frame ends.
    process (clk_125, lb_rst_n)
    begin
        if lb_rst_n = '0' then
            rx_mismatch <= '0';
        elsif rising_edge(clk_125) then
            if s_valid = '1' then rx_mismatch <= mism_now; end if;
        end if;
    end process;

    process (clk_125, lb_rst_n)
    begin
        if lb_rst_n = '0' then
            rx_exp_seq    <= (others => '0');
            rx_seen_any   <= '0';
            rx_ok         <= (others => '0');
            rx_ok_big     <= (others => '0');
            rx_bad        <= (others => '0');
            rx_terr       <= (others => '0');
            seq_gap       <= (others => '0');
            max_ok_len    <= (others => '0');
            first_bad_len <= (others => '0');
            first_bad_seq <= (others => '0');
            first_bad_set <= '0';
        elsif rising_edge(clk_125) then
            if clear = '1' then
                rx_ok         <= (others => '0');
                rx_ok_big     <= (others => '0');
                rx_bad        <= (others => '0');
                rx_terr       <= (others => '0');
                seq_gap       <= (others => '0');
                max_ok_len    <= (others => '0');
                first_bad_len <= (others => '0');
                first_bad_seq <= (others => '0');
                first_bad_set <= '0';
                rx_seen_any   <= '0';
            elsif s_valid = '1' then
                if s_last = '1' then
                    if fr_good = '1' then
                        rx_ok <= rx_ok + 1;
                        if fr_len > 4083 then rx_ok_big <= rx_ok_big + 1; end if;
                        if fr_len > max_ok_len then max_ok_len <= fr_len; end if;
                    else
                        rx_bad <= rx_bad + 1;
                        if first_bad_set = '0' then
                            first_bad_set <= '1';
                            first_bad_len <= fr_len;
                            first_bad_seq <= s_seq(15 downto 0);
                        end if;
                    end if;
                    if s_terror = '1' then rx_terr <= rx_terr + 1; end if;
                    if rx_seen_any = '1' and s_seq /= rx_exp_seq then seq_gap <= seq_gap + 1; end if;
                    rx_seen_any <= '1';
                    rx_exp_seq  <= s_seq + 1;
                end if;
            end if;
        end if;
    end process;

    status <= x"B0A" & '0' & mmcm_locked & run & init_done &
              std_logic_vector(first_bad_seq) & std_logic_vector(first_bad_len) &
              std_logic_vector(max_ok_len) &
              std_logic_vector(seq_gap) & std_logic_vector(rx_terr) &
              std_logic_vector(rx_bad) & std_logic_vector(rx_ok_big) &
              std_logic_vector(rx_ok) & std_logic_vector(tx_frames);

end architecture rtl;
