-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- PARITY MODEL ONLY - not for synthesis. GENERATED from
-- fpga/arty_a7/rtl/rgmii_lb_selftest.vhd by sim/parity/rgmii_lb_selftest/gen_split.py; do not edit.
-- Renamed to rgmii_lb_selftest_split, with the IOBUF pads split into
-- pad_o and pad_i, the five IDELAYE2s unrolled and (Verilog) the
-- IDELAYCTRL instance named u_dlyctrl. Everything else is the source
-- verbatim.
-- =============================================================================
-- rgmii_lb_selftest.vhd - On-silicon RGMII-path self-test for the Arty A7
-- VHDL port of fpga/arty_a7/rtl/rgmii_lb_selftest.v (formally proven
-- equivalent; see sim/parity/).
--
-- The Arty's DP83848J PHY is 10/100 MII only, so the board build never
-- instantiates rgmii_if. This block puts a second eth_mac_sys on the die with
-- PHY_INTERFACE="RGMII" and MAX_FRAME=9018 and loops its RGMII pins back at
-- the pads: each of the six signals (TXD[3:0], TX_CTL, TXC) leaves through an
-- IOBUF on Pmod header JC and the same IOBUF's input buffer reads the pad back
-- as RXD[3:0], RX_CTL and RXC. Nothing may be plugged into JC.
--
--   generator -> AXIS TX -> eth_mac_tx -> gmii_cdc TX -> rgmii_if (ODDR)
--   -> pad -> IBUF -> IDELAYE2 -> rgmii_if (IDDR) -> gmii_cdc RX
--   -> eth_mac_rx (FCS check) -> AXIS RX -> checker
--
-- It runs at 1G, 100M and 10M (CTRL speed field, set from ctrl[3:2]). The
-- generator and checker are those of gmii_lb_selftest: payload lengths cycle
-- through 46, 60, 1500, 1501, 4000, 4097, 8000 and 9000 bytes, every frame
-- carries a 32-bit sequence number and a sequence-seeded byte pattern, and the
-- checker verifies length, header, pattern, terror and order.
--
-- RX timing. rgmii_if samples RXD / RX_CTL on RXC with no delay of its own, so
-- RXC must reach its IDDRs centred on the data. TXC leaves TXC_PHASE degrees
-- after TXD / TX_CTL (90 = centred at the pad), but RXC then passes through a
-- BUFG while the data goes straight to the IDDR, so at 1G it arrives late by
-- the clock insertion delay. No JC pin is clock-capable, so RXC reaches the
-- BUFG over general routing, which makes that delay larger than on a board.
-- Each data input therefore goes through an IDELAYE2 (VAR_LOAD, ~78 ps per
-- tap at a 200 MHz reference) whose tap the host sets at run time; sweeping
-- it at 1G measures the window of taps that pass (on the first board, taps
-- 19..31 of 0..31). At 10/100 every TXC edge is at least 8 ns from a data
-- change, so those taps pass there too. RXC has no IDELAY: the board-level
-- delay the README asks for is modelled by delaying the data instead. Post-
-- route STA cannot judge the RX inputs here: it sees only the IDELAY_INIT tap
-- and its slow-corner RXC delay is well above what the sweep measures.
--
-- PAUSE. The MAC receives its own PAUSE frames, so a PAUSE it sends pauses
-- its own TX: the frame goes out through rgmii_if, comes back through the
-- pads, the IDDRs and (at 10/100) the nibble pairing, and eth_pause_rx must
-- recognize it there. The checker sees the frame too (promiscuous mode) and
-- counts it as a PAUSE frame, good if every byte but the source address is
-- as sent and it is 60 bytes long, instead of as a data frame. The gap
-- between generator frames shows the pause: max_gap is the longest run of
-- clk_125 cycles between two frames the MAC accepted while run was high, so
-- a PAUSE of Q quanta with PAUSE_CTRL rx_en set should make it about
-- Q x 512 bit times, and leave it at about one frame time with rx_en clear.
--
-- Control (ctrl, async - synchronized here):
--   [0]     run    - generate traffic while high (the current frame completes)
--   [1]     clear  - hold high to zero all counters
--   [3:2]   speed  - 00 = 1G, 01 = 100M, 10 = 10M; written to CTRL[4:3] once
--                    it has been stable for 16 clk_125 cycles. Change it only
--                    while traffic is stopped.
--   [8:4]   tap    - IDELAYE2 tap for all five RX data inputs
--   [9]     load   - a rising edge loads tap into the IDELAYE2s
--   [25:10] quanta - PAUSE_QUANTA for the next send; set it before send
--   [26]    rx_en  - PAUSE_CTRL rx_en (honor received PAUSE frames)
--   [27]    send   - a rising edge writes PAUSE_QUANTA = quanta, then
--                    PAUSE_CTRL = {rx_en, tx_send}
--   [31:28] spare
-- Status (clk_125 domain; stop traffic before reading for a coherent view):
--   [255:0] as gmii_lb_selftest, except [240] = no CSR write in flight,
--           [243] = IDELAYCTRL RDY and [255:244] = 12'hB0C (marker: this
--           bitstream has this self-test)
--   [257:256] speed written to CTRL   [262:258] tap loaded
--   [263] rx_en written to PAUSE_CTRL [295:264] max_gap (clk_125 cycles)
--   [311:296] PAUSE frames good       [327:312] PAUSE frames bad
--
-- The Verilog `ifdef SIM selects behavioural clocks and a plain-wire pad
-- loopback; here that is EMZ_TARGET = "SIM" from emz_target_pkg (one of
-- rtl/vhdl/target/emz_target_*.vhd). Every other target instantiates the
-- MMCM, BUFGs, IOBUFs, IDELAYE2s and IDELAYCTRL, declared as local components
-- (no library unisim), so the file analyses without vendor libraries and
-- Vivado binds the real primitives.
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

entity rgmii_lb_selftest_split is
    generic (
        TXC_PHASE   : real    := 90.0;    -- TXC clock phase behind clk_125, degrees
        IDELAY_INIT : integer := 0        -- RX data tap after configuration
    );
    port (
        clk    : in    std_logic;                       -- 100 MHz system clock
        rst_n  : in    std_logic;
        ctrl   : in    std_logic_vector(31 downto 0);
        status : out   std_logic_vector(327 downto 0);
        pad_o  : out   std_logic_vector(5 downto 0);    -- parity split: the pads as driven
        pad_i  : in    std_logic_vector(5 downto 0)     -- parity split: the pads as read
    );
end entity rgmii_lb_selftest_split;

architecture rtl of rgmii_lb_selftest_split is

    -- Xilinx 7-series MMCM (unisim; only the generics set here).
    component MMCME2_BASE is
        generic (
            CLKFBOUT_MULT_F  : real    := 5.000;
            CLKIN1_PERIOD    : real    := 0.000;
            CLKOUT0_DIVIDE_F : real    := 1.000;
            CLKOUT1_DIVIDE   : integer := 1;
            CLKOUT1_PHASE    : real    := 0.000;
            CLKOUT2_DIVIDE   : integer := 1;
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

    -- Xilinx bidirectional I/O buffer (unisim; no generics set here).
    component IOBUF is
        port (
            O  : out   std_ulogic;
            IO : inout std_ulogic;
            I  : in    std_ulogic;
            T  : in    std_ulogic
        );
    end component IOBUF;

    -- Xilinx 7-series input delay (unisim; only the generics set here).
    component IDELAYE2 is
        generic (
            CINVCTRL_SEL          : string  := "FALSE";
            DELAY_SRC             : string  := "IDATAIN";
            HIGH_PERFORMANCE_MODE : string  := "FALSE";
            IDELAY_TYPE           : string  := "FIXED";
            IDELAY_VALUE          : integer := 0;
            PIPE_SEL              : string  := "FALSE";
            REFCLK_FREQUENCY      : real    := 200.0;
            SIGNAL_PATTERN        : string  := "DATA"
        );
        port (
            CNTVALUEOUT : out std_logic_vector(4 downto 0);
            DATAOUT     : out std_ulogic;
            C           : in  std_ulogic;
            CE          : in  std_ulogic;
            CINVCTRL    : in  std_ulogic;
            CNTVALUEIN  : in  std_logic_vector(4 downto 0);
            DATAIN      : in  std_ulogic;
            IDATAIN     : in  std_ulogic;
            INC         : in  std_ulogic;
            LD          : in  std_ulogic;
            LDPIPEEN    : in  std_ulogic;
            REGRST      : in  std_ulogic
        );
    end component IDELAYE2;

    -- Xilinx IDELAY tap calibration (unisim).
    component IDELAYCTRL is
        port (
            RDY    : out std_ulogic;
            REFCLK : in  std_ulogic;
            RST    : in  std_ulogic
        );
    end component IDELAYCTRL;

    attribute ASYNC_REG     : string;
    attribute DONT_TOUCH    : string;
    attribute IODELAY_GROUP : string;

    -- =========================================================================
    -- Clocks: 125 MHz (0 deg), 125 MHz (TXC_PHASE), 200 MHz IDELAY reference
    -- =========================================================================
    signal clk_125, clk_125_90, clk_200, mmcm_locked : std_logic;
    signal clk_125_mmcm, clk_125_90_mmcm, clk_200_mmcm, clkfb, clkfb_buf : std_logic;
    signal mmcm_rst : std_logic;              -- !rst_n (VHDL-93: no expression in a port map)

    signal lock_s : std_logic_vector(1 downto 0);
    attribute ASYNC_REG of lock_s : signal is "TRUE";
    signal lb_rst_n : std_logic;

    signal ctrl_s1, ctrl_s2 : std_logic_vector(31 downto 0);
    attribute ASYNC_REG of ctrl_s1 : signal is "TRUE";
    attribute ASYNC_REG of ctrl_s2 : signal is "TRUE";
    signal run      : std_logic;
    signal clear    : std_logic;
    signal spd_req  : std_logic_vector(1 downto 0);
    signal tap_req  : std_logic_vector(4 downto 0);
    signal tap_ld   : std_logic;
    signal p_quanta : std_logic_vector(15 downto 0);
    signal p_rx_en  : std_logic;
    signal p_send   : std_logic;

    -- =========================================================================
    -- RGMII pads
    -- =========================================================================
    signal rgmii_txd                : std_logic_vector(3 downto 0);
    signal rgmii_tx_ctl, rgmii_txc  : std_logic;
    signal pad_out, pad_in          : std_logic_vector(5 downto 0);

    signal dly_rst_cnt  : unsigned(6 downto 0);
    signal dly_rst      : std_logic;
    signal dly_rdy      : std_logic;

    signal tap_ld_d     : std_logic;
    signal tap_cur      : unsigned(4 downto 0);
    signal tap_ld_pulse : std_logic;

    signal rx_dly       : std_logic_vector(4 downto 0);   -- RXD[3:0], RX_CTL after the IDELAYE2s
    signal rx_clk       : std_logic;                      -- RXC after its BUFG

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

    -- =========================================================================
    -- CSR writes
    -- =========================================================================
    signal spd_last, spd_cur : std_logic_vector(1 downto 0);
    signal spd_stable        : unsigned(3 downto 0);
    signal spd_new           : std_logic;

    signal init_done        : std_logic;
    signal aw_done, w_done  : std_logic;
    signal p_rx_cur         : std_logic;               -- rx_en last written to PAUSE_CTRL
    signal p_send_d, p_pend, p_chain : std_logic;

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

    signal tx_accept           : std_logic;
    signal gap_cnt, max_gap    : unsigned(31 downto 0);

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

    signal rx_pfr    : std_logic;
    signal cur_pfr   : std_logic;
    signal p_exp     : std_logic_vector(7 downto 0);
    signal pbyte_bad : std_logic;

    signal s_valid, s_first, s_last, s_terror, s_bad, s_pfr, s_pbad : std_logic;
    signal s_idx    : unsigned(13 downto 0);
    signal s_seq    : unsigned(31 downto 0);

    signal mism_now   : std_logic;
    signal fr_len     : unsigned(15 downto 0);
    signal exp_len    : unsigned(15 downto 0);
    signal fr_good    : std_logic;
    signal p_mismatch : std_logic;
    signal p_mism_now : std_logic;
    signal p_good     : std_logic;

    signal p_ok, p_bad : unsigned(15 downto 0);

begin

    -- =========================================================================
    -- Clocks: 125 MHz (0 deg), 125 MHz (TXC_PHASE), 200 MHz IDELAY reference
    -- (MMCM: 100 MHz x 10 = 1000 MHz VCO; / 8, / 8, / 5), and the RGMII pads
    -- =========================================================================
    gen_sim : if EMZ_TARGET = "SIM" generate
        -- No MMCM in simulation: free-running behavioral clocks, locked after
        -- reset.
        signal clk_125_sim, clk_125_90_sim, clk_200_sim : std_logic := '0';
    begin
        clk_125_sim <= not clk_125_sim after 4 ns;
        process
        begin
            wait for 8 ns * (TXC_PHASE / 360.0);
            loop
                clk_125_90_sim <= not clk_125_90_sim;
                wait for 4 ns;
            end loop;
        end process;
        clk_200_sim <= not clk_200_sim after 2500 ps;
        clk_125     <= clk_125_sim;
        clk_125_90  <= clk_125_90_sim;
        clk_200     <= clk_200_sim;
        mmcm_locked <= rst_n;

        -- Pad loopback: RXC is TXC, centred on the data by TXC_PHASE. A 1 ns
        -- inertial delay stands for the pad round trip; it also filters the
        -- zero-width pulses the behavioral ddr_output can drive when its two
        -- registers update on the same edge, which would otherwise clock RX.
        -- The IDELAY tap is recorded but not modelled.
        pad_o   <= pad_out;
        pad_in  <= pad_i after 1 ns;
        rx_dly  <= pad_in(4 downto 0);
        rx_clk  <= pad_in(5);
        dly_rdy <= not dly_rst;
    end generate gen_sim;

    -- Every other target (the Verilog `else` of `ifdef SIM). The generate is
    -- labelled u and the instances mmcm / bufg_*, so they flatten to the
    -- Verilog instance names u_mmcm / u_bufg_*. The IDELAYCTRL is dlyctrl (a
    -- label cannot share the component's name; the parity model renames the
    -- Verilog u_idelayctrl to match).
    u : if EMZ_TARGET /= "SIM" generate
        attribute IODELAY_GROUP of dlyctrl : label is "rgmii_lb";
    begin
        mmcm_rst <= not rst_n;

        mmcm : MMCME2_BASE
            generic map (
                CLKIN1_PERIOD    => 10.0,
                DIVCLK_DIVIDE    => 1,
                CLKFBOUT_MULT_F  => 10.0,
                CLKOUT0_DIVIDE_F => 8.0,
                CLKOUT1_DIVIDE   => 8,
                CLKOUT1_PHASE    => TXC_PHASE,
                CLKOUT2_DIVIDE   => 5
            )
            port map (
                CLKIN1    => clk,
                CLKFBIN   => clkfb_buf,
                CLKFBOUT  => clkfb,
                CLKOUT0   => clk_125_mmcm,
                CLKOUT1   => clk_125_90_mmcm,
                CLKOUT2   => clk_200_mmcm,
                LOCKED    => mmcm_locked,
                PWRDWN    => '0',
                RST       => mmcm_rst,
                CLKFBOUTB => open, CLKOUT0B => open, CLKOUT1B => open, CLKOUT2B => open,
                CLKOUT3   => open, CLKOUT3B => open, CLKOUT4  => open, CLKOUT5  => open,
                CLKOUT6   => open
            );
        bufg_fb  : BUFG port map (I => clkfb,           O => clkfb_buf);
        bufg_125 : BUFG port map (I => clk_125_mmcm,    O => clk_125);
        bufg_90  : BUFG port map (I => clk_125_90_mmcm, O => clk_125_90);
        bufg_200 : BUFG port map (I => clk_200_mmcm,    O => clk_200);

        -- RGMII pads: each output leaves through an IOBUF whose input buffer
        -- reads the pad back. ODDR -> IOBUF.I has nothing in between (an
        -- OLOGIC cell must drive its pad directly); IOBUF.O -> IDELAYE2 ->
        -- IDDR is the ILOGIC input path.
        pad_o  <= pad_out;           -- parity split: IOBUF I, T = '0'
        pad_in <= pad_i;             -- parity split: IOBUF O

            idelay_0 : IDELAYE2
                generic map (
                    CINVCTRL_SEL          => "FALSE",
                    DELAY_SRC             => "IDATAIN",
                    HIGH_PERFORMANCE_MODE => "TRUE",
                    IDELAY_TYPE           => "VAR_LOAD",
                    IDELAY_VALUE          => IDELAY_INIT,
                    PIPE_SEL              => "FALSE",
                    REFCLK_FREQUENCY      => 200.0,
                    SIGNAL_PATTERN        => "DATA"
                )
                port map (
                    CNTVALUEOUT => open,
                    DATAOUT     => rx_dly(0),
                    C           => clk_125,
                    CE          => '0',
                    CINVCTRL    => '0',
                    CNTVALUEIN  => tap_req,
                    DATAIN      => '0',
                    IDATAIN     => pad_in(0),
                    INC         => '0',
                    LD          => tap_ld_pulse,
                    LDPIPEEN    => '0',
                    REGRST      => '0'
                );
            idelay_1 : IDELAYE2
                generic map (
                    CINVCTRL_SEL          => "FALSE",
                    DELAY_SRC             => "IDATAIN",
                    HIGH_PERFORMANCE_MODE => "TRUE",
                    IDELAY_TYPE           => "VAR_LOAD",
                    IDELAY_VALUE          => IDELAY_INIT,
                    PIPE_SEL              => "FALSE",
                    REFCLK_FREQUENCY      => 200.0,
                    SIGNAL_PATTERN        => "DATA"
                )
                port map (
                    CNTVALUEOUT => open,
                    DATAOUT     => rx_dly(1),
                    C           => clk_125,
                    CE          => '0',
                    CINVCTRL    => '0',
                    CNTVALUEIN  => tap_req,
                    DATAIN      => '0',
                    IDATAIN     => pad_in(1),
                    INC         => '0',
                    LD          => tap_ld_pulse,
                    LDPIPEEN    => '0',
                    REGRST      => '0'
                );
            idelay_2 : IDELAYE2
                generic map (
                    CINVCTRL_SEL          => "FALSE",
                    DELAY_SRC             => "IDATAIN",
                    HIGH_PERFORMANCE_MODE => "TRUE",
                    IDELAY_TYPE           => "VAR_LOAD",
                    IDELAY_VALUE          => IDELAY_INIT,
                    PIPE_SEL              => "FALSE",
                    REFCLK_FREQUENCY      => 200.0,
                    SIGNAL_PATTERN        => "DATA"
                )
                port map (
                    CNTVALUEOUT => open,
                    DATAOUT     => rx_dly(2),
                    C           => clk_125,
                    CE          => '0',
                    CINVCTRL    => '0',
                    CNTVALUEIN  => tap_req,
                    DATAIN      => '0',
                    IDATAIN     => pad_in(2),
                    INC         => '0',
                    LD          => tap_ld_pulse,
                    LDPIPEEN    => '0',
                    REGRST      => '0'
                );
            idelay_3 : IDELAYE2
                generic map (
                    CINVCTRL_SEL          => "FALSE",
                    DELAY_SRC             => "IDATAIN",
                    HIGH_PERFORMANCE_MODE => "TRUE",
                    IDELAY_TYPE           => "VAR_LOAD",
                    IDELAY_VALUE          => IDELAY_INIT,
                    PIPE_SEL              => "FALSE",
                    REFCLK_FREQUENCY      => 200.0,
                    SIGNAL_PATTERN        => "DATA"
                )
                port map (
                    CNTVALUEOUT => open,
                    DATAOUT     => rx_dly(3),
                    C           => clk_125,
                    CE          => '0',
                    CINVCTRL    => '0',
                    CNTVALUEIN  => tap_req,
                    DATAIN      => '0',
                    IDATAIN     => pad_in(3),
                    INC         => '0',
                    LD          => tap_ld_pulse,
                    LDPIPEEN    => '0',
                    REGRST      => '0'
                );
            idelay_4 : IDELAYE2
                generic map (
                    CINVCTRL_SEL          => "FALSE",
                    DELAY_SRC             => "IDATAIN",
                    HIGH_PERFORMANCE_MODE => "TRUE",
                    IDELAY_TYPE           => "VAR_LOAD",
                    IDELAY_VALUE          => IDELAY_INIT,
                    PIPE_SEL              => "FALSE",
                    REFCLK_FREQUENCY      => 200.0,
                    SIGNAL_PATTERN        => "DATA"
                )
                port map (
                    CNTVALUEOUT => open,
                    DATAOUT     => rx_dly(4),
                    C           => clk_125,
                    CE          => '0',
                    CINVCTRL    => '0',
                    CNTVALUEIN  => tap_req,
                    DATAIN      => '0',
                    IDATAIN     => pad_in(4),
                    INC         => '0',
                    LD          => tap_ld_pulse,
                    LDPIPEEN    => '0',
                    REGRST      => '0'
                );

        dlyctrl : IDELAYCTRL
            port map (
                RDY    => dly_rdy,
                REFCLK => clk_200,
                RST    => dly_rst
            );

        bufg_rxc : BUFG port map (I => pad_in(5), O => rx_clk);
    end generate u;

    -- Everything below runs on clk_125, as in gmii_lb_selftest: the MAC's
    -- system clock equals the 1G media clock. Reset it until the MMCM locks.
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
            ctrl_s1 <= (others => '0');
            ctrl_s2 <= (others => '0');
        elsif rising_edge(clk_125) then
            ctrl_s1 <= ctrl;
            ctrl_s2 <= ctrl_s1;
        end if;
    end process;
    run      <= ctrl_s2(0);
    clear    <= ctrl_s2(1);
    spd_req  <= ctrl_s2(3 downto 2);
    tap_req  <= ctrl_s2(8 downto 4);
    tap_ld   <= ctrl_s2(9);
    -- quanta has been synchronized for at least as long as send and is
    -- stable by the time send rises.
    p_quanta <= ctrl_s2(25 downto 10);
    p_rx_en  <= ctrl_s2(26);
    p_send   <= ctrl_s2(27);

    pad_out <= rgmii_txc & rgmii_tx_ctl & rgmii_txd;

    -- IDELAYCTRL: reset for 64 reference cycles (>= 52 ns) after the MMCM
    -- locks, then RDY follows.
    dly_rst <= not dly_rst_cnt(6);
    process (clk_200, mmcm_locked)
    begin
        if mmcm_locked = '0' then
            dly_rst_cnt <= (others => '0');
        elsif rising_edge(clk_200) then
            if dly_rst = '1' then dly_rst_cnt <= dly_rst_cnt + 1; end if;
        end if;
    end process;

    -- Tap load: one LD pulse per rising edge of ctrl[9]. tap_req has been
    -- synchronized for at least as long as tap_ld and is stable by then.
    process (clk_125, lb_rst_n)
    begin
        if lb_rst_n = '0' then
            tap_ld_d <= '0';
            tap_cur  <= to_unsigned(IDELAY_INIT mod 32, 5);
        elsif rising_edge(clk_125) then
            tap_ld_d <= tap_ld;
            if tap_ld = '1' and tap_ld_d = '0' then tap_cur <= unsigned(tap_req); end if;
        end if;
    end process;
    tap_ld_pulse <= tap_ld and not tap_ld_d;

    -- =========================================================================
    -- Loopback MAC
    -- =========================================================================
    u_lb_mac : entity work.eth_mac_sys
        generic map (
            PHY_INTERFACE => "RGMII",
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
            clk_125_90      => clk_125_90,
            clk_25          => '0',
            clk_2_5         => '0',
            rgmii_txd       => rgmii_txd,
            rgmii_tx_ctl    => rgmii_tx_ctl,
            rgmii_txc       => rgmii_txc,
            rgmii_rxd       => rx_dly(3 downto 0),
            rgmii_rx_ctl    => rx_dly(4),
            rgmii_rxc       => rx_clk,
            phy_gmii_txd    => open,
            phy_gmii_tx_en  => open,
            phy_gmii_tx_er  => open,
            phy_gmii_txc    => open,
            phy_gmii_rx_clk => '0',
            phy_gmii_rxd    => x"00",
            phy_gmii_rx_dv  => '0',
            phy_gmii_rx_er  => '0',
            mdc             => open,
            mdio_i          => '1',
            mdio_o          => open,
            mdio_oe         => open,
            cfg_ip_addr     => open,
            irq             => open
        );

    -- =========================================================================
    -- CSR writes, one at a time:
    --   CTRL = tx_en | rx_en | promisc | speed | full_duplex | jumbo_en after
    --     reset, and whenever the requested speed has been stable for 16
    --     cycles and differs from the one last written;
    --   PAUSE_QUANTA = quanta, then PAUSE_CTRL = {rx_en, tx_send}, on a rising
    --     edge of send (PAUSE_CTRL takes rx_en from every write, so the send
    --     carries it);
    --   PAUSE_CTRL = {rx_en, 0} when rx_en differs from the one last written.
    -- init_done is high while no write is in flight.
    -- =========================================================================
    process (clk_125, lb_rst_n)
    begin
        if lb_rst_n = '0' then
            spd_last   <= "00";
            spd_stable <= (others => '0');
        elsif rising_edge(clk_125) then
            spd_last <= spd_req;
            if spd_req /= spd_last then
                spd_stable <= (others => '0');
            elsif spd_stable /= 15 then
                spd_stable <= spd_stable + 1;
            end if;
        end if;
    end process;
    spd_new <= '1' when spd_stable = 15 and spd_last /= spd_cur else '0';

    process (clk_125, lb_rst_n)
    begin
        if lb_rst_n = '0' then
            awaddr    <= x"04";
            wdata     <= x"00000067";
            spd_cur   <= "00";
            awvalid   <= '0';
            wvalid    <= '0';
            bready    <= '0';
            aw_done   <= '0';
            w_done    <= '0';
            init_done <= '0';
            p_rx_cur  <= '0';
            p_send_d  <= '0';
            p_pend    <= '0';
            p_chain   <= '0';
        elsif rising_edge(clk_125) then
            if init_done = '0' then
                awvalid <= (not aw_done) and not (awvalid and awready);
                wvalid  <= (not w_done)  and not (wvalid  and wready);
                if awvalid = '1' and awready = '1' then aw_done <= '1'; end if;
                if wvalid = '1' and wready = '1' then w_done <= '1'; end if;
                bready <= '1';
                if bvalid = '1' and bready = '1' then
                    bready <= '0';
                    if p_chain = '1' then               -- PAUSE_QUANTA written
                        awaddr   <= x"84";
                        wdata    <= (31 downto 2 => '0') & p_rx_en & '1';
                        p_rx_cur <= p_rx_en;
                        p_chain  <= '0';
                        aw_done  <= '0';
                        w_done   <= '0';
                    else
                        init_done <= '1';
                    end if;
                end if;
            elsif spd_new = '1' then
                awaddr    <= x"04";
                wdata     <= x"00000067" or
                             std_logic_vector(shift_left(resize(unsigned(spd_last), 32), 3));
                spd_cur   <= spd_last;
                aw_done   <= '0';
                w_done    <= '0';
                init_done <= '0';
            elsif p_pend = '1' then
                awaddr    <= x"88";
                wdata     <= x"0000" & p_quanta;
                p_pend    <= '0';
                p_chain   <= '1';
                aw_done   <= '0';
                w_done    <= '0';
                init_done <= '0';
            elsif p_rx_en /= p_rx_cur then
                awaddr    <= x"84";
                wdata     <= (31 downto 2 => '0') & p_rx_en & '0';
                p_rx_cur  <= p_rx_en;
                aw_done   <= '0';
                w_done    <= '0';
                init_done <= '0';
            end if;
            p_send_d <= p_send;
            if p_send = '1' and p_send_d = '0' then p_pend <= '1'; end if;
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

    -- Longest gap between frames the MAC accepted while run was high.
    tx_accept <= tx_busy and tx_tready and tx_tlast;
    process (clk_125, lb_rst_n)
    begin
        if lb_rst_n = '0' then
            gap_cnt <= (others => '0');
            max_gap <= (others => '0');
        elsif rising_edge(clk_125) then
            if run = '0' or tx_accept = '1' then
                gap_cnt <= (others => '0');
            elsif gap_cnt /= x"FFFFFFFF" then
                gap_cnt <= gap_cnt + 1;
            end if;
            if clear = '1' then
                max_gap <= (others => '0');
            elsif gap_cnt > max_gap then
                max_gap <= gap_cnt;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- Checker
    -- =========================================================================
    -- Input register stage: keeps the RX AXIS buffer's block-RAM clock-to-out
    -- off the compare/count logic below.
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
    -- A frame whose first byte is 01 (data frames start FF) is judged as a
    -- PAUSE frame from eth_pause: DA 01:80:C2:00:00:01, type 0x8808, opcode
    -- 0x0001, the quanta last sent, zero padding. The SA is not checked.
    cur_pfr <= rx_pfr when rx_tsof = '0' else
               '1'    when rx_tdata = x"01" else
               '0';
    p_exp <= x"01" when cur_idx = 0 else
             x"80" when cur_idx = 1 else
             x"C2" when cur_idx = 2 else
             x"01" when cur_idx = 5 else
             x"88" when cur_idx = 12 else
             x"08" when cur_idx = 13 else
             x"01" when cur_idx = 15 else
             p_quanta(15 downto 8) when cur_idx = 16 else
             p_quanta(7 downto 0) when cur_idx = 17 else
             x"00";
    pbyte_bad <= '1' when ((cur_idx < 6) or (cur_idx > 11)) and (rx_tdata /= p_exp) else '0';

    -- Stage 1: track index and sequence, compare each byte.
    process (clk_125, lb_rst_n)
    begin
        if lb_rst_n = '0' then
            rx_idx   <= (others => '0');
            rx_seq   <= (others => '0');
            rx_pfr   <= '0';
            s_pfr    <= '0';
            s_pbad   <= '0';
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
                rx_pfr   <= cur_pfr;
                s_pfr    <= cur_pfr;
                s_pbad   <= pbyte_bad;
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
    mism_now   <= (rx_mismatch and not s_first) or s_bad;
    fr_len     <= ("00" & s_idx) + 1;
    exp_len    <= 14 + ("00" & payload_len(s_seq(2 downto 0)));
    fr_good    <= '1' when mism_now = '0' and s_terror = '0' and fr_len = exp_len else '0';
    p_mism_now <= (p_mismatch and not s_first) or s_pbad;
    p_good     <= '1' when p_mism_now = '0' and s_terror = '0' and fr_len = 60 else '0';

    -- The mismatch flags follow every beat, clear or not: a bad byte that
    -- arrives while clear is high must still fail its frame if clear drops
    -- before the frame ends.
    process (clk_125, lb_rst_n)
    begin
        if lb_rst_n = '0' then
            rx_mismatch <= '0';
            p_mismatch  <= '0';
        elsif rising_edge(clk_125) then
            if s_valid = '1' then
                rx_mismatch <= mism_now;
                p_mismatch  <= p_mism_now;
            end if;
        end if;
    end process;

    -- PAUSE frames are counted here and nowhere else: they carry no sequence
    -- number, so they neither count as data frames nor break the sequence.
    process (clk_125, lb_rst_n)
    begin
        if lb_rst_n = '0' then
            p_ok  <= (others => '0');
            p_bad <= (others => '0');
        elsif rising_edge(clk_125) then
            if clear = '1' then
                p_ok  <= (others => '0');
                p_bad <= (others => '0');
            elsif s_valid = '1' and s_last = '1' and s_pfr = '1' then
                if p_good = '1' then
                    p_ok <= p_ok + 1;
                else
                    p_bad <= p_bad + 1;
                end if;
            end if;
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
                if s_last = '1' and s_pfr = '0' then
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

    status <= std_logic_vector(p_bad) & std_logic_vector(p_ok) & std_logic_vector(max_gap) &
              p_rx_cur & std_logic_vector(tap_cur) & spd_cur &
              x"B0C" & dly_rdy & mmcm_locked & run & init_done &
              std_logic_vector(first_bad_seq) & std_logic_vector(first_bad_len) &
              std_logic_vector(max_ok_len) &
              std_logic_vector(seq_gap) & std_logic_vector(rx_terr) &
              std_logic_vector(rx_bad) & std_logic_vector(rx_ok_big) &
              std_logic_vector(rx_ok) & std_logic_vector(tx_frames);

end architecture rtl;
