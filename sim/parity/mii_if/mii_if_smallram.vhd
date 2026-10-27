-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- PARITY MODEL ONLY - not for synthesis or the core. GENERATED from
-- rtl/vhdl/mii_if.vhd by sim/parity/mii_if/gen_smallram.py; do not edit.
-- The inline RX frame RAM is cut from 4096 to 8 words, indexed by the
-- low three address bits; rx_frame_mem_tag keeps each word's write
-- address bits 11:3, XORed with the read address bits 11:3 on a read
-- (see gen_smallram.py).
-- Everything else is the source verbatim.
-- =============================================================================
-- mii_if.vhd - MII PHY Interface with Store-and-Forward CDC
-- Converts between 8-bit GMII (100 MHz sys_clk) and 4-bit MII (25 MHz PHY)
-- Vendor selection via emz_target_pkg.EMZ_TARGET (compile exactly one
-- rtl/vhdl/target/emz_target_*.vhd): "XILINX_7SERIES" uses xpm_fifo_async /
-- xpm_memory_sdpram, every other target the portable async_fifo and an
-- inferred block RAM. The xpm macros are declared as local components (same
-- interface as Vivado's xpm_VCOMP.vhd), so the file analyses without vendor libraries.
-- VHDL port of rtl/mii_if.v (formally proven equivalent; see sim/parity/).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.emz_target_pkg.all;
-- VHDL-93 binds a component instance by default only to a directly visible
-- entity of the same name. This makes simulation models of the vendor
-- primitives compiled into work (sim/parity/stubs/) bind; Vivado binds the
-- real primitives by name either way.
use work.all;

entity mii_if is
    generic (
        MII_DEBUG : integer := 0;
        -- TX_ENABLE=0 omits the TX data FIFO (and its inferred BRAM); the framer
        -- then sees a permanently-empty FIFO and the MII TX outputs stay idle.
        -- Used by the store-and-forward MII path in eth_mac_sys, where mii_tx_saf
        -- drives the MII TX pins and mii_if is effectively RX-only.
        TX_ENABLE : integer := 1
    );
    port (
        clk                         : in  std_logic;
        rst_n                       : in  std_logic;

        mii_rxd                     : in  std_logic_vector(3 downto 0);
        mii_rx_dv                   : in  std_logic;
        mii_rx_er                   : in  std_logic;
        mii_rx_clk                  : in  std_logic;
        mii_col                     : in  std_logic;
        mii_crs                     : in  std_logic;

        mii_txd                     : out std_logic_vector(3 downto 0);
        mii_tx_en                   : out std_logic;
        mii_tx_clk                  : in  std_logic;

        gmii_txd                    : in  std_logic_vector(7 downto 0);
        gmii_tx_en                  : in  std_logic;
        gmii_tx_er                  : in  std_logic;
        gmii_rxd                    : out std_logic_vector(7 downto 0);
        gmii_rx_dv                  : out std_logic;
        gmii_rx_er                  : out std_logic;
        -- The IOB-registered MII receive nibbles, in the mii_rx_clk domain, ahead
        -- of the RX FIFO (eth_pause_rx watches these for PAUSE frames).
        mii_rxd_q                   : out std_logic_vector(3 downto 0);
        mii_rx_dv_q                 : out std_logic;
        mii_rx_er_q                 : out std_logic;
        mii_tx_clk_out              : out std_logic;
        tx_busy                     : out std_logic;
        tx_fifo_level               : out std_logic_vector(12 downto 0);
        dbg_tx_fifo_empty           : out std_logic;
        dbg_rx_prog_empty           : out std_logic;
        dbg_rx_rd_empty             : out std_logic;
        dbg_rx_reading              : out std_logic;
        dbg_rx_frames_pending       : out std_logic_vector(1 downto 0);
        -- TX path internals for debug
        dbg_tx_wr_en                : out std_logic;
        dbg_tx_len_wr_en            : out std_logic;
        dbg_tx_wr_full              : out std_logic;
        dbg_tx_wr_rst_busy_out      : out std_logic;
        dbg_tx_rd_en                : out std_logic;
        dbg_tx_frame_loaded         : out std_logic;
        dbg_tx_frames_queued        : out std_logic_vector(11 downto 0);
        dbg_tx_frames_drained       : out std_logic_vector(11 downto 0);
        dbg_last_tx_len_wr          : out std_logic_vector(11 downto 0);
        -- MII TX byte capture (CDC'd to sys_clk) - first 64 bytes per frame, latest
        dbg_mii_cap_done            : out std_logic;
        dbg_mii_cap_frame_len       : out std_logic_vector(11 downto 0);
        dbg_mii_cap_word0           : out std_logic_vector(31 downto 0);
        dbg_mii_cap_word1           : out std_logic_vector(31 downto 0);
        dbg_mii_cap_word2           : out std_logic_vector(31 downto 0);
        dbg_mii_cap_word3           : out std_logic_vector(31 downto 0);
        dbg_mii_cap_word4           : out std_logic_vector(31 downto 0);
        dbg_mii_cap_word5           : out std_logic_vector(31 downto 0);
        dbg_mii_cap_word6           : out std_logic_vector(31 downto 0);
        dbg_mii_cap_word7           : out std_logic_vector(31 downto 0);
        dbg_mii_cap_word8           : out std_logic_vector(31 downto 0);
        dbg_mii_cap_word9           : out std_logic_vector(31 downto 0);
        dbg_mii_cap_word10          : out std_logic_vector(31 downto 0);
        dbg_mii_cap_word11          : out std_logic_vector(31 downto 0);
        dbg_mii_cap_word12          : out std_logic_vector(31 downto 0);
        dbg_mii_cap_word13          : out std_logic_vector(31 downto 0);
        dbg_mii_cap_word14          : out std_logic_vector(31 downto 0);
        dbg_mii_cap_word15          : out std_logic_vector(31 downto 0);
        dbg_mii_txd_pre_iob         : out std_logic_vector(3 downto 0);
        dbg_mii_tx_en_pre_iob       : out std_logic;
        dbg_rx_fifo_full_frames     : out std_logic_vector(31 downto 0);
        dbg_rx_fifo_full_writes     : out std_logic_vector(31 downto 0);
        dbg_rx_fifo_overflow_pulses : out std_logic_vector(31 downto 0);
        dbg_rx_fifo_wr_level_max    : out std_logic_vector(31 downto 0);
        dbg_rx_replay_gap_frames    : out std_logic_vector(31 downto 0);
        dbg_rx_replay_gap_cycles    : out std_logic_vector(31 downto 0);
        dbg_rx_replay_gap_byte_max  : out std_logic_vector(31 downto 0);
        dbg_rx_mii_last_len         : out std_logic_vector(31 downto 0);
        dbg_rx_mii_word0            : out std_logic_vector(31 downto 0);
        dbg_rx_mii_word1            : out std_logic_vector(31 downto 0);
        dbg_rx_mii_word2            : out std_logic_vector(31 downto 0);
        dbg_rx_mii_word3            : out std_logic_vector(31 downto 0);
        dbg_rx_mii_word4            : out std_logic_vector(31 downto 0);
        dbg_rx_mii_word5            : out std_logic_vector(31 downto 0);
        dbg_rx_mii_word6            : out std_logic_vector(31 downto 0);
        dbg_rx_mii_word7            : out std_logic_vector(31 downto 0);
        dbg_rx_mii_word8            : out std_logic_vector(31 downto 0);
        dbg_rx_mii_word9            : out std_logic_vector(31 downto 0);
        dbg_rx_mii_word10           : out std_logic_vector(31 downto 0);
        dbg_rx_mii_word11           : out std_logic_vector(31 downto 0);
        dbg_rx_mii_word12           : out std_logic_vector(31 downto 0);
        dbg_rx_mii_word13           : out std_logic_vector(31 downto 0);
        dbg_rx_mii_word14           : out std_logic_vector(31 downto 0);
        dbg_rx_mii_word15           : out std_logic_vector(31 downto 0);
        dbg_rx_replay_last_len      : out std_logic_vector(31 downto 0);
        dbg_rx_replay_word0         : out std_logic_vector(31 downto 0);
        dbg_rx_replay_word1         : out std_logic_vector(31 downto 0);
        dbg_rx_replay_word2         : out std_logic_vector(31 downto 0);
        dbg_rx_replay_word3         : out std_logic_vector(31 downto 0);
        dbg_rx_replay_eof_count     : out std_logic_vector(31 downto 0);
        -- gmii_tx_er visibility (sys_clk domain). pulse count = rising-edge
        -- assertions of gmii_tx_er; frame count = frames during which gmii_tx_er
        -- was asserted at least once.
        dbg_tx_er_pulses            : out std_logic_vector(31 downto 0);
        dbg_tx_er_frames            : out std_logic_vector(31 downto 0)
    );
end entity mii_if;

architecture rtl of mii_if is

    -- -------------------------------------------------------------------------
    -- Xilinx XPM macros (XILINX_7SERIES only). Declarations copied from Vivado's
    -- data/ip/xpm/xpm_VCOMP.vhd so default binding finds the real macros.
    -- -------------------------------------------------------------------------
    component xpm_fifo_async
        generic (
            -- Common module generics
            FIFO_MEMORY_TYPE    : string  := "auto";
            FIFO_WRITE_DEPTH    : integer := 2048;
            CASCADE_HEIGHT      : integer := 0;
            RELATED_CLOCKS      : integer := 0;
            WRITE_DATA_WIDTH    : integer := 32;
            READ_MODE           : string  := "std";
            FIFO_READ_LATENCY   : integer := 1;
            FULL_RESET_VALUE    : integer := 0;
            USE_ADV_FEATURES    : string  := "0707";
            READ_DATA_WIDTH     : integer := 32;
            CDC_SYNC_STAGES     : integer := 2;
            WR_DATA_COUNT_WIDTH : integer := 1;
            PROG_FULL_THRESH    : integer := 10;
            RD_DATA_COUNT_WIDTH : integer := 1;
            PROG_EMPTY_THRESH   : integer := 10;
            DOUT_RESET_VALUE    : string  := "0";
            ECC_MODE            : string  := "no_ecc";
            SIM_ASSERT_CHK      : integer := 0;
            EN_SIM_ASSERT_ERR   : string  := "warning";
            WAKEUP_TIME         : integer := 0
        );
        port (
            sleep         : in  std_logic;
            rst           : in  std_logic;
            wr_clk        : in  std_logic;
            wr_en         : in  std_logic;
            din           : in  std_logic_vector(WRITE_DATA_WIDTH-1 downto 0);
            full          : out std_logic;
            prog_full     : out std_logic;
            wr_data_count : out std_logic_vector(WR_DATA_COUNT_WIDTH-1 downto 0);
            overflow      : out std_logic;
            wr_rst_busy   : out std_logic;
            almost_full   : out std_logic;
            wr_ack        : out std_logic;
            rd_clk        : in  std_logic;
            rd_en         : in  std_logic;
            dout          : out std_logic_vector(READ_DATA_WIDTH-1 downto 0);
            empty         : out std_logic;
            prog_empty    : out std_logic;
            rd_data_count : out std_logic_vector(RD_DATA_COUNT_WIDTH-1 downto 0);
            underflow     : out std_logic;
            rd_rst_busy   : out std_logic;
            almost_empty  : out std_logic;
            data_valid    : out std_logic;
            injectsbiterr : in  std_logic;
            injectdbiterr : in  std_logic;
            sbiterr       : out std_logic;
            dbiterr       : out std_logic
        );
    end component;

    component xpm_memory_sdpram
        generic (
            -- Common module generics
            MEMORY_SIZE             : integer := 2048;
            MEMORY_PRIMITIVE        : string  := "auto";
            CLOCKING_MODE           : string  := "common_clock";
            ECC_MODE                : string  := "no_ecc";
            ECC_TYPE                : string  := "none";
            ECC_BIT_RANGE           : string  := "[7:0]";
            MEMORY_INIT_FILE        : string  := "none";
            MEMORY_INIT_PARAM       : string  := "";
            USE_MEM_INIT            : integer := 1;
            USE_MEM_INIT_MMI        : integer := 0;
            WAKEUP_TIME             : string  := "disable_sleep";
            AUTO_SLEEP_TIME         : integer := 0;
            MESSAGE_CONTROL         : integer := 0;
            USE_EMBEDDED_CONSTRAINT : integer := 0;
            MEMORY_OPTIMIZATION     : string  := "true";
            CASCADE_HEIGHT          : integer := 0;
            SIM_ASSERT_CHK          : integer := 0;
            WRITE_PROTECT           : integer := 1;
            RAM_DECOMP              : string  := "auto";
            IGNORE_INIT_SYNTH       : integer := 0;
            -- Port A module generics
            WRITE_DATA_WIDTH_A      : integer := 32;
            BYTE_WRITE_WIDTH_A      : integer := 32;
            ADDR_WIDTH_A            : integer := 6;
            RST_MODE_A              : string  := "SYNC";
            -- Port B module generics
            READ_DATA_WIDTH_B       : integer := 32;
            ADDR_WIDTH_B            : integer := 6;
            READ_RESET_VALUE_B      : string  := "0";
            READ_LATENCY_B          : integer := 2;
            WRITE_MODE_B            : string  := "no_change";
            RST_MODE_B              : string  := "SYNC"
        );
        port (
            -- Common module ports
            sleep          : in  std_logic;
            -- Port A module ports
            clka           : in  std_logic;
            ena            : in  std_logic;
            wea            : in  std_logic_vector((WRITE_DATA_WIDTH_A/BYTE_WRITE_WIDTH_A)-1 downto 0);
            addra          : in  std_logic_vector(ADDR_WIDTH_A-1 downto 0);
            dina           : in  std_logic_vector(WRITE_DATA_WIDTH_A-1 downto 0);
            injectsbiterra : in  std_logic;
            injectdbiterra : in  std_logic;
            -- Port B module ports
            clkb           : in  std_logic;
            rstb           : in  std_logic;
            enb            : in  std_logic;
            regceb         : in  std_logic;
            addrb          : in  std_logic_vector(ADDR_WIDTH_B-1 downto 0);
            doutb          : out std_logic_vector(READ_DATA_WIDTH_B-1 downto 0);
            sbiterrb       : out std_logic;
            dbiterrb       : out std_logic
        );
    end component;

    -- Vivado attributes (same names and values as the Verilog).
    attribute ASYNC_REG : string;
    attribute IOB       : string;
    attribute ram_style : string;

    type byte64_t is array (0 to 63) of std_logic_vector(7 downto 0);
    type word16_t is array (0 to 15) of std_logic_vector(31 downto 0);
    type frame_mem_t is array (0 to 7) of std_logic_vector(8 downto 0);

    function gray4_to_bin(gray : std_logic_vector(3 downto 0)) return unsigned is
        variable b : unsigned(3 downto 0);
    begin
        b(3) := gray(3);
        b(2) := b(3) xor gray(2);
        b(1) := b(2) xor gray(1);
        b(0) := b(1) xor gray(0);
        return b;
    end function gray4_to_bin;

    -- Verilog: localparam [31:0] RX_FIFO_ADV_FEATURES = (MII_DEBUG != 0) ? "1F1F" : "1000";
    function adv_features_sel(dbg : integer) return string is
    begin
        if dbg /= 0 then
            return "1F1F";
        else
            return "1000";
        end if;
    end function adv_features_sel;

    constant RX_FIFO_ADV_FEATURES : string(1 to 4) := adv_features_sel(MII_DEBUG);

    signal rx_rst_n_s1, rx_rst_n_s2 : std_logic;
    signal tx_rst_n_s1, tx_rst_n_s2 : std_logic;
    attribute ASYNC_REG of rx_rst_n_s1 : signal is "TRUE";
    attribute ASYNC_REG of rx_rst_n_s2 : signal is "TRUE";
    attribute ASYNC_REG of tx_rst_n_s1 : signal is "TRUE";
    attribute ASYNC_REG of tx_rst_n_s2 : signal is "TRUE";

    -- =========================================================================
    -- RX path: MII -> store-and-forward FIFO -> GMII
    -- =========================================================================
    signal rx_nib_sel : std_logic;
    signal rx_nib_low : std_logic_vector(3 downto 0);
    signal rx_er_low  : std_logic;
    signal rx_dv_d1   : std_logic;

    -- Dedicated RX input capture stage so Vivado has a clean IOB-friendly
    -- first register bank on the PHY-facing MII inputs.
    signal mii_rxd_iob   : std_logic_vector(3 downto 0);
    signal mii_rx_dv_iob : std_logic;
    signal mii_rx_er_iob : std_logic;
    attribute IOB of mii_rxd_iob   : signal is "TRUE";
    attribute IOB of mii_rx_dv_iob : signal is "TRUE";
    attribute IOB of mii_rx_er_iob : signal is "TRUE";

    signal rx_wr_data                 : std_logic_vector(9 downto 0);
    signal rx_wr_en                   : std_logic;
    signal rx_wr_full                 : std_logic;
    signal rx_wr_rst_busy             : std_logic;
    signal rx_wr_accept               : std_logic;
    signal rx_full_write              : std_logic;
    signal rx_fifo_overflow           : std_logic;
    signal rx_wr_data_count           : std_logic_vector(12 downto 0);
    signal rx_fifo_full_seen          : std_logic;
    signal rx_fifo_full_frame_toggle  : std_logic;
    signal rx_fifo_full_write_toggle  : std_logic;
    signal rx_fifo_overflow_toggle    : std_logic;
    signal rx_fifo_wr_level_max_rxclk : unsigned(12 downto 0);
    signal rx_mii_frame_toggle        : std_logic;
    signal rx_mii_byte_count_rxclk    : unsigned(15 downto 0);
    signal rx_mii_last_len_rxclk      : unsigned(15 downto 0);
    -- 64-byte raw MII-RX byte capture (first 64 bytes of each frame, overwriting).
    -- Packed into 16 32-bit words for CDC + CSR exposure.
    signal rx_mii_cap_rxclk           : byte64_t;
    signal rx_mii_word_rxclk          : word16_t;

    signal rx_rd_data       : std_logic_vector(9 downto 0);
    signal rx_rd_empty      : std_logic;
    signal rx_rd_valid      : std_logic;
    signal rx_rd_en         : std_logic;
    signal rx_rd_rst_busy   : std_logic;
    signal rx_prog_empty    : std_logic;
    signal rx_rd_word_valid : std_logic;
    signal rx_rd_data_count : std_logic_vector(12 downto 0);

    signal rx_frame_wr_count_bin  : unsigned(3 downto 0);
    signal rx_frame_wr_count_gray : std_logic_vector(3 downto 0);
    signal rx_frame_wr_count_s1   : std_logic_vector(3 downto 0);
    signal rx_frame_wr_count_s2   : std_logic_vector(3 downto 0);
    signal rx_frame_wr_count_s3   : std_logic_vector(3 downto 0);
    attribute ASYNC_REG of rx_frame_wr_count_s1 : signal is "TRUE";
    attribute ASYNC_REG of rx_frame_wr_count_s2 : signal is "TRUE";
    attribute ASYNC_REG of rx_frame_wr_count_s3 : signal is "TRUE";
    signal rx_frame_rd_count_bin  : unsigned(3 downto 0);
    signal rx_frame_done_pulse    : std_logic;   -- pulse from RX replay FSM, consumed in sys clk

    signal rx_frame_wr_count_sys : unsigned(3 downto 0);
    signal rx_frame_pending_sys  : std_logic;

    -- xpm_fifo_async port expressions (XILINX_7SERIES only)
    signal xpm_rx_rd_en : std_logic;
    signal xpm_rx_rst   : std_logic;

    constant RX_REPLAY_IDLE  : std_logic_vector(2 downto 0) := "000";
    constant RX_REPLAY_LOAD  : std_logic_vector(2 downto 0) := "001";
    constant RX_REPLAY_PRIME : std_logic_vector(2 downto 0) := "010";
    constant RX_REPLAY_WAIT  : std_logic_vector(2 downto 0) := "011";
    constant RX_REPLAY_SEND  : std_logic_vector(2 downto 0) := "100";

    signal rx_replay_state     : std_logic_vector(2 downto 0);
    signal rx_load_wait        : std_logic;
    signal rx_load_count       : unsigned(15 downto 0);
    signal rx_replay_len       : unsigned(15 downto 0);
    signal rx_replay_index     : unsigned(15 downto 0);
    signal rx_mem_rd_addr      : unsigned(15 downto 0);
    signal rx_mem_rd_data      : std_logic_vector(8 downto 0);
    signal rx_mem_wr_en        : std_logic;
    signal rx_mem_wr_addr      : unsigned(11 downto 0);
    signal rx_mem_wr_data      : std_logic_vector(8 downto 0);
    signal rx_mem_rd_en        : std_logic;
    signal rx_mem_rd_addr_reg  : std_logic_vector(11 downto 0);
    signal rx_frame_mem_dout   : std_logic_vector(8 downto 0);
    signal rx_full_frame_s1, rx_full_frame_s2, rx_full_frame_s3 : std_logic;
    signal rx_full_write_s1, rx_full_write_s2, rx_full_write_s3 : std_logic;
    signal rx_overflow_s1, rx_overflow_s2, rx_overflow_s3       : std_logic;
    signal rx_mii_frame_s1, rx_mii_frame_s2, rx_mii_frame_s3    : std_logic;
    signal rx_wr_level_max_s1, rx_wr_level_max_s2               : unsigned(12 downto 0);
    attribute ASYNC_REG of rx_full_frame_s1   : signal is "TRUE";
    attribute ASYNC_REG of rx_full_frame_s2   : signal is "TRUE";
    attribute ASYNC_REG of rx_full_frame_s3   : signal is "TRUE";
    attribute ASYNC_REG of rx_full_write_s1   : signal is "TRUE";
    attribute ASYNC_REG of rx_full_write_s2   : signal is "TRUE";
    attribute ASYNC_REG of rx_full_write_s3   : signal is "TRUE";
    attribute ASYNC_REG of rx_overflow_s1     : signal is "TRUE";
    attribute ASYNC_REG of rx_overflow_s2     : signal is "TRUE";
    attribute ASYNC_REG of rx_overflow_s3     : signal is "TRUE";
    attribute ASYNC_REG of rx_mii_frame_s1    : signal is "TRUE";
    attribute ASYNC_REG of rx_mii_frame_s2    : signal is "TRUE";
    attribute ASYNC_REG of rx_mii_frame_s3    : signal is "TRUE";
    attribute ASYNC_REG of rx_wr_level_max_s1 : signal is "TRUE";
    attribute ASYNC_REG of rx_wr_level_max_s2 : signal is "TRUE";
    signal rx_fifo_full_frames_sys     : unsigned(31 downto 0);
    signal rx_fifo_full_writes_sys     : unsigned(31 downto 0);
    signal rx_fifo_overflow_pulses_sys : unsigned(31 downto 0);
    signal rx_fifo_wr_level_max_sys    : unsigned(31 downto 0);
    signal rx_replay_gap_frames_sys    : unsigned(31 downto 0);
    signal rx_replay_gap_cycles_sys    : unsigned(31 downto 0);
    signal rx_replay_gap_byte_max_sys  : unsigned(31 downto 0);
    signal rx_replay_byte_count        : unsigned(15 downto 0);
    signal rx_replay_gap_seen          : std_logic;
    signal rx_mii_last_len_sys         : unsigned(31 downto 0);
    -- 16 sysclk-domain capture words (64 bytes per frame, latched on frame-end)
    signal rx_mii_word_sys             : word16_t;
    signal rx_replay_last_len_sys      : unsigned(31 downto 0);
    signal rx_replay_word0_sys         : std_logic_vector(31 downto 0);
    signal rx_replay_word1_sys         : std_logic_vector(31 downto 0);
    signal rx_replay_word2_sys         : std_logic_vector(31 downto 0);
    signal rx_replay_word3_sys         : std_logic_vector(31 downto 0);
    signal rx_replay_eof_count_sys     : unsigned(31 downto 0);

    signal rx_frame_ready : std_logic;

    -- Inferred RX frame buffer (every target except XILINX_7SERIES). Declared
    -- here rather than inside the generate so its name matches the Verilog.
    signal rx_frame_mem        : frame_mem_t;
    signal rx_frame_mem_tag    : frame_mem_t;
    attribute ram_style of rx_frame_mem : signal is "block";
    signal rx_frame_mem_dout_r : std_logic_vector(8 downto 0);

    -- =========================================================================
    -- TX path: GMII -> data FIFO with EOF sideband -> MII
    -- =========================================================================
    signal tx_en_d1   : std_logic;
    signal tx_er_d1   : std_logic;
    signal tx_en_fall : std_logic;
    signal tx_er_rise : std_logic;

    signal tx_er_pulses_r        : unsigned(31 downto 0);
    signal tx_er_frames_r        : unsigned(31 downto 0);
    signal tx_er_seen_this_frame : std_logic;

    signal tx_frame_len_wr : unsigned(11 downto 0);
    signal tx_len_wr_data  : std_logic_vector(11 downto 0);
    signal tx_len_wr_en    : std_logic;
    signal tx_data_d1      : std_logic_vector(7 downto 0);
    signal tx_wr_valid_d1  : std_logic;

    signal tx_rd_data       : std_logic_vector(8 downto 0);
    signal tx_rd_empty      : std_logic;
    signal tx_rd_valid      : std_logic;
    signal tx_rd_word_valid : std_logic;
    signal tx_rd_en         : std_logic;
    signal tx_wr_rst_busy   : std_logic;
    signal tx_rd_rst_busy   : std_logic;
    signal tx_wr_data_count : std_logic_vector(12 downto 0);
    signal tx_wr_full       : std_logic;

    signal tx_wr_data       : std_logic_vector(8 downto 0);
    signal tx_wr_en         : std_logic;
    signal tx_wr_accept     : std_logic;
    signal tx_eof_wr_accept : std_logic;

    signal tx_fifo_count : unsigned(12 downto 0);
    -- Read-pulse CDC for tx_fifo_count (every target except XILINX_7SERIES).
    signal tx_rd_toggle    : std_logic;
    signal tx_rd_sync1     : std_logic;
    signal tx_rd_sync2     : std_logic;
    attribute ASYNC_REG of tx_rd_sync1 : signal is "TRUE";
    attribute ASYNC_REG of tx_rd_sync2 : signal is "TRUE";
    signal tx_rd_sync3     : std_logic;
    signal tx_rd_pulse_sys : std_logic;
    constant TX_FIFO_DEPTH      : unsigned(12 downto 0) := to_unsigned(4096, 13);
    -- Headroom must cover (frame_bytes_written - frame_bytes_drained) during
    -- a single eth_mac_tx frame *plus* CDC slop on wr_data_count. With
    -- sys_clk=100MHz writing at 1B/cycle and MII=12.5MB/s draining, a
    -- 1518-byte frame nets ~1340 bytes of growth - but mii_if also sits in
    -- a 40-cycle IFG between drained frames where no drain occurs, so the
    -- worst-case growth approaches 1530. Reserve 3072 bytes of headroom to
    -- absorb wr_data_count CDC latency and keep the FIFO out of drop
    -- territory during sustained line-rate bursts.
    constant TX_MAX_FRAME_BYTES : unsigned(12 downto 0) := to_unsigned(3072, 13);
    constant TX_START_LIMIT     : unsigned(12 downto 0) := TX_FIFO_DEPTH - TX_MAX_FRAME_BYTES;

    signal tx_frames_pending_r : unsigned(2 downto 0);
    signal tx_frame_loaded     : std_logic;

    -- Frame counters (sys_clk domain)
    signal tx_frames_queued_r     : unsigned(11 downto 0);
    signal tx_frames_drained_r    : unsigned(11 downto 0);
    signal tx_frame_wr_count_bin  : unsigned(3 downto 0);
    signal tx_frame_wr_count_gray : std_logic_vector(3 downto 0);
    signal tx_frame_wr_count_s1   : std_logic_vector(3 downto 0);
    signal tx_frame_wr_count_s2   : std_logic_vector(3 downto 0);
    signal tx_frame_wr_count_s3   : std_logic_vector(3 downto 0);
    attribute ASYNC_REG of tx_frame_wr_count_s1 : signal is "TRUE";
    attribute ASYNC_REG of tx_frame_wr_count_s2 : signal is "TRUE";
    attribute ASYNC_REG of tx_frame_wr_count_s3 : signal is "TRUE";
    signal tx_frame_rd_count_bin  : unsigned(3 downto 0);
    -- Drain counter CDC: toggle in mii_tx_clk, sync to sys_clk
    signal drain_toggle    : std_logic;
    signal drain_sync1     : std_logic;
    signal drain_sync2     : std_logic;
    attribute ASYNC_REG of drain_sync1 : signal is "TRUE";
    attribute ASYNC_REG of drain_sync2 : signal is "TRUE";
    signal drain_sync3     : std_logic;
    signal drain_pulse     : std_logic;
    signal tx_len_write_ok : std_logic;

    signal tx_frame_wr_count_mii : unsigned(3 downto 0);
    signal tx_frame_pending_mii  : std_logic;

    -- xpm_fifo_async port expressions (XILINX_7SERIES only)
    signal xpm_tx_rd_en : std_logic;
    signal xpm_tx_rst   : std_logic;

    constant TX_IDLE : std_logic_vector(1 downto 0) := "00";
    constant TX_LOW  : std_logic_vector(1 downto 0) := "01";
    constant TX_HIGH : std_logic_vector(1 downto 0) := "10";

    signal tx_st        : std_logic_vector(1 downto 0);
    signal tx_byte      : std_logic_vector(7 downto 0);
    signal tx_byte_last : std_logic;

    -- Internal MII TX signals (used by state machine + debug taps)
    signal mii_txd_int   : std_logic_vector(3 downto 0);
    signal mii_tx_en_int : std_logic;

    -- Dedicated IOB output registers - fanout=1, drives pad only
    signal mii_txd_iob   : std_logic_vector(3 downto 0);
    signal mii_tx_en_iob : std_logic;
    attribute IOB of mii_txd_iob   : signal is "TRUE";
    attribute IOB of mii_tx_en_iob : signal is "TRUE";
    signal tx_start_delay : unsigned(5 downto 0);

    -- =========================================================================
    -- MII TX byte capture (mii_tx_clk domain)
    -- =========================================================================
    signal mii_cap           : byte64_t;           -- captured bytes from TX data FIFO
    signal mii_cap_idx       : unsigned(5 downto 0);
    signal mii_cap_frame_len : unsigned(11 downto 0);   -- frame length counted during TX readout
    signal mii_cap_active    : std_logic;          -- currently capturing
    signal mii_cap_done      : std_logic;          -- capture complete for the latest frame

    -- CDC: sync mii_cap_done to sys_clk domain
    signal mii_cap_done_s1, mii_cap_done_s2 : std_logic;
    attribute ASYNC_REG of mii_cap_done_s1 : signal is "TRUE";
    attribute ASYNC_REG of mii_cap_done_s2 : signal is "TRUE";

begin

    mii_tx_clk_out <= mii_tx_clk;

    process (mii_rx_clk, rst_n)
    begin
        if rst_n = '0' then
            rx_rst_n_s2 <= '0';
            rx_rst_n_s1 <= '0';
        elsif rising_edge(mii_rx_clk) then
            rx_rst_n_s2 <= rx_rst_n_s1;
            rx_rst_n_s1 <= '1';
        end if;
    end process;

    process (mii_tx_clk, rst_n)
    begin
        if rst_n = '0' then
            tx_rst_n_s2 <= '0';
            tx_rst_n_s1 <= '0';
        elsif rising_edge(mii_tx_clk) then
            tx_rst_n_s2 <= tx_rst_n_s1;
            tx_rst_n_s1 <= '1';
        end if;
    end process;

    -- =========================================================================
    -- RX path: MII -> store-and-forward FIFO -> GMII
    -- =========================================================================
    g_rx_pack : for rwi in 0 to 15 generate
        rx_mii_word_rxclk(rwi) <= rx_mii_cap_rxclk(rwi*4+0) & rx_mii_cap_rxclk(rwi*4+1) &
                                  rx_mii_cap_rxclk(rwi*4+2) & rx_mii_cap_rxclk(rwi*4+3);
    end generate g_rx_pack;

    rx_full_write <= rx_wr_en and rx_wr_full;
    rx_wr_accept  <= rx_wr_en and (not rx_wr_full) and (not rx_wr_rst_busy);

    process (mii_rx_clk, rx_rst_n_s2)
    begin
        if rx_rst_n_s2 = '0' then
            mii_rxd_iob   <= (others => '0');
            mii_rx_dv_iob <= '0';
            mii_rx_er_iob <= '0';
        elsif rising_edge(mii_rx_clk) then
            mii_rxd_iob   <= mii_rxd;
            mii_rx_dv_iob <= mii_rx_dv;
            mii_rx_er_iob <= mii_rx_er;
        end if;
    end process;

    mii_rxd_q   <= mii_rxd_iob;
    mii_rx_dv_q <= mii_rx_dv_iob;
    mii_rx_er_q <= mii_rx_er_iob;

    process (mii_rx_clk, rx_rst_n_s2)
    begin
        if rx_rst_n_s2 = '0' then
            rx_nib_sel <= '0';
            rx_nib_low <= (others => '0');
            rx_er_low  <= '0';
            rx_dv_d1   <= '0';
            rx_wr_data <= (others => '0');
            rx_wr_en   <= '0';
            rx_fifo_full_seen <= '0';
            if MII_DEBUG /= 0 then
                rx_fifo_full_frame_toggle  <= '0';
                rx_fifo_full_write_toggle  <= '0';
                rx_fifo_overflow_toggle    <= '0';
                rx_fifo_wr_level_max_rxclk <= (others => '0');
                rx_mii_frame_toggle        <= '0';
                rx_mii_byte_count_rxclk    <= (others => '0');
                rx_mii_last_len_rxclk      <= (others => '0');
                for rxi in 0 to 63 loop
                    rx_mii_cap_rxclk(rxi) <= (others => '0');
                end loop;
            end if;
        elsif rising_edge(mii_rx_clk) then
            rx_wr_en <= '0';
            rx_dv_d1 <= mii_rx_dv_iob;
            if (MII_DEBUG /= 0) and (unsigned(rx_wr_data_count) > rx_fifo_wr_level_max_rxclk) then
                rx_fifo_wr_level_max_rxclk <= unsigned(rx_wr_data_count);
            end if;

            if rx_full_write = '1' then
                rx_fifo_full_seen <= '1';
                if MII_DEBUG /= 0 then
                    rx_fifo_full_write_toggle <= not rx_fifo_full_write_toggle;
                end if;
            end if;
            if (MII_DEBUG /= 0) and (rx_fifo_overflow = '1') then
                rx_fifo_overflow_toggle <= not rx_fifo_overflow_toggle;
            end if;

            if mii_rx_dv_iob = '1' then
                if rx_nib_sel = '0' then
                    rx_nib_low <= mii_rxd_iob;
                    rx_er_low  <= mii_rx_er_iob;
                    rx_nib_sel <= '1';
                else
                    rx_wr_data <= '0' & (rx_er_low or mii_rx_er_iob or
                                         rx_fifo_full_seen or rx_full_write) &
                                  mii_rxd_iob & rx_nib_low;
                    rx_wr_en   <= '1';
                    rx_nib_sel <= '0';
                    if MII_DEBUG /= 0 then
                        -- First-64-byte capture (no wrap). byte_count is the
                        -- index of the byte we are committing this cycle.
                        if rx_mii_byte_count_rxclk(15 downto 6) = 0 then
                            rx_mii_cap_rxclk(to_integer(rx_mii_byte_count_rxclk(5 downto 0)))
                                <= mii_rxd_iob & rx_nib_low;
                        end if;
                        rx_mii_byte_count_rxclk <= rx_mii_byte_count_rxclk + 1;
                    end if;
                end if;
            else
                rx_nib_sel <= '0';
                if rx_dv_d1 = '1' then
                    rx_wr_data <= '1' & rx_fifo_full_seen & x"00";
                    rx_wr_en   <= '1';
                    if MII_DEBUG /= 0 then
                        rx_mii_last_len_rxclk   <= rx_mii_byte_count_rxclk;
                        rx_mii_frame_toggle     <= not rx_mii_frame_toggle;
                        rx_mii_byte_count_rxclk <= (others => '0');
                        if rx_fifo_full_seen = '1' then
                            rx_fifo_full_frame_toggle <= not rx_fifo_full_frame_toggle;
                        end if;
                    end if;
                    rx_fifo_full_seen <= '0';
                end if;
            end if;
        end if;
    end process;

    process (mii_rx_clk, rx_rst_n_s2)
    begin
        if rx_rst_n_s2 = '0' then
            rx_frame_wr_count_bin  <= (others => '0');
            rx_frame_wr_count_gray <= (others => '0');
        elsif rising_edge(mii_rx_clk) then
            if (rx_wr_accept = '1') and (rx_wr_data(9) = '1') then
                rx_frame_wr_count_bin  <= rx_frame_wr_count_bin + 1;
                rx_frame_wr_count_gray <= std_logic_vector((rx_frame_wr_count_bin + 1) xor
                                                           shift_right(rx_frame_wr_count_bin + 1, 1));
            end if;
        end if;
    end process;

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            rx_frame_wr_count_s1  <= (others => '0');
            rx_frame_wr_count_s2  <= (others => '0');
            rx_frame_wr_count_s3  <= (others => '0');
            rx_frame_rd_count_bin <= (others => '0');
        elsif rising_edge(clk) then
            rx_frame_wr_count_s1 <= rx_frame_wr_count_gray;
            rx_frame_wr_count_s2 <= rx_frame_wr_count_s1;
            rx_frame_wr_count_s3 <= rx_frame_wr_count_s2;
            if rx_frame_done_pulse = '1' then
                rx_frame_rd_count_bin <= rx_frame_rd_count_bin + 1;
            end if;
        end if;
    end process;

    rx_frame_wr_count_sys <= gray4_to_bin(rx_frame_wr_count_s3);
    rx_frame_pending_sys  <= '1' when rx_frame_wr_count_sys /= rx_frame_rd_count_bin else '0';

    -- RX FIFO. The labels `u` / `rx_fifo` (and `u_rx` / `fifo` on the other
    -- target) give the instance the flattened name u_rx_fifo, the same as the
    -- Verilog's module-level u_rx_fifo, so the equivalence proof pairs the FIFO
    -- state by name (see sim/parity/mii_if). VHDL-93 has no `else generate`,
    -- so the two targets are two generates with different labels.
    u : if EMZ_TARGET = "XILINX_7SERIES" generate
        xpm_rx_rd_en <= rx_rd_en and (not rx_rd_rst_busy);
        xpm_rx_rst   <= not rx_rst_n_s2;

        rx_fifo : xpm_fifo_async
            generic map (
                FIFO_WRITE_DEPTH    => 4096,
                WRITE_DATA_WIDTH    => 10,
                READ_DATA_WIDTH     => 10,
                READ_MODE           => "FWFT",
                FIFO_READ_LATENCY   => 0,
                CDC_SYNC_STAGES     => 3,
                DOUT_RESET_VALUE    => "0",
                FULL_RESET_VALUE    => 0,
                PROG_EMPTY_THRESH   => 64,
                PROG_FULL_THRESH    => 10,
                RD_DATA_COUNT_WIDTH => 13,
                WR_DATA_COUNT_WIDTH => 13,
                USE_ADV_FEATURES    => RX_FIFO_ADV_FEATURES,
                WAKEUP_TIME         => 0
            )
            port map (
                wr_clk        => mii_rx_clk,
                wr_en         => rx_wr_accept,
                din           => rx_wr_data,
                full          => rx_wr_full,
                wr_rst_busy   => rx_wr_rst_busy,
                rd_clk        => clk,
                rd_en         => xpm_rx_rd_en,
                dout          => rx_rd_data,
                empty         => rx_rd_empty,
                rd_rst_busy   => rx_rd_rst_busy,
                rst           => xpm_rx_rst,
                sleep         => '0',
                injectsbiterr => '0',
                injectdbiterr => '0',
                sbiterr       => open,
                dbiterr       => open,
                overflow      => rx_fifo_overflow,
                underflow     => open,
                prog_full     => open,
                prog_empty    => rx_prog_empty,
                almost_full   => open,
                almost_empty  => open,
                wr_data_count => rx_wr_data_count,
                rd_data_count => rx_rd_data_count,
                data_valid    => rx_rd_valid,
                wr_ack        => open
            );
    end generate u;

    u_rx : if EMZ_TARGET /= "XILINX_7SERIES" generate
        rx_prog_empty    <= '1';
        rx_wr_rst_busy   <= '0';
        rx_rd_rst_busy   <= '0';
        rx_fifo_overflow <= rx_full_write;
        rx_wr_data_count <= (others => '0');
        rx_rd_data_count <= (others => '0') when rx_rd_empty = '1' else (others => '1');
        rx_rd_valid      <= not rx_rd_empty;

        fifo : entity work.async_fifo
            generic map (DATA_WIDTH => 10, ADDR_WIDTH => 11)
            port map (
                wr_clk        => mii_rx_clk,
                wr_rst_n      => rx_rst_n_s2,
                wr_data       => rx_wr_data,
                wr_en         => rx_wr_accept,
                wr_full       => rx_wr_full,
                rd_clk        => clk,
                rd_rst_n      => rst_n,
                rd_data       => rx_rd_data,
                rd_en         => rx_rd_en,
                rd_empty      => rx_rd_empty,
                wr_data_count => open
            );
    end generate u_rx;

    -- In FWFT mode, empty can remain deasserted while the previous word is
    -- still present after rd_en. Use data_valid so replay only consumes a word
    -- when the FIFO has presented fresh data; otherwise bytes can be duplicated
    -- inside the reconstructed GMII frame and FCS will fail.
    rx_rd_word_valid <= rx_rd_valid and (not rx_rd_rst_busy);

    rx_frame_ready <= rx_frame_pending_sys and (not rx_rd_rst_busy);

    dbg_rx_fifo_full_frames     <= std_logic_vector(rx_fifo_full_frames_sys)     when MII_DEBUG /= 0 else (others => '0');
    dbg_rx_fifo_full_writes     <= std_logic_vector(rx_fifo_full_writes_sys)     when MII_DEBUG /= 0 else (others => '0');
    dbg_rx_fifo_overflow_pulses <= std_logic_vector(rx_fifo_overflow_pulses_sys) when MII_DEBUG /= 0 else (others => '0');
    dbg_rx_fifo_wr_level_max    <= std_logic_vector(rx_fifo_wr_level_max_sys)    when MII_DEBUG /= 0 else (others => '0');
    dbg_rx_replay_gap_frames    <= std_logic_vector(rx_replay_gap_frames_sys)    when MII_DEBUG /= 0 else (others => '0');
    dbg_rx_replay_gap_cycles    <= std_logic_vector(rx_replay_gap_cycles_sys)    when MII_DEBUG /= 0 else (others => '0');
    dbg_rx_replay_gap_byte_max  <= std_logic_vector(rx_replay_gap_byte_max_sys)  when MII_DEBUG /= 0 else (others => '0');
    dbg_rx_mii_last_len         <= std_logic_vector(rx_mii_last_len_sys)         when MII_DEBUG /= 0 else (others => '0');
    dbg_rx_mii_word0  <= rx_mii_word_sys( 0) when MII_DEBUG /= 0 else (others => '0');
    dbg_rx_mii_word1  <= rx_mii_word_sys( 1) when MII_DEBUG /= 0 else (others => '0');
    dbg_rx_mii_word2  <= rx_mii_word_sys( 2) when MII_DEBUG /= 0 else (others => '0');
    dbg_rx_mii_word3  <= rx_mii_word_sys( 3) when MII_DEBUG /= 0 else (others => '0');
    dbg_rx_mii_word4  <= rx_mii_word_sys( 4) when MII_DEBUG /= 0 else (others => '0');
    dbg_rx_mii_word5  <= rx_mii_word_sys( 5) when MII_DEBUG /= 0 else (others => '0');
    dbg_rx_mii_word6  <= rx_mii_word_sys( 6) when MII_DEBUG /= 0 else (others => '0');
    dbg_rx_mii_word7  <= rx_mii_word_sys( 7) when MII_DEBUG /= 0 else (others => '0');
    dbg_rx_mii_word8  <= rx_mii_word_sys( 8) when MII_DEBUG /= 0 else (others => '0');
    dbg_rx_mii_word9  <= rx_mii_word_sys( 9) when MII_DEBUG /= 0 else (others => '0');
    dbg_rx_mii_word10 <= rx_mii_word_sys(10) when MII_DEBUG /= 0 else (others => '0');
    dbg_rx_mii_word11 <= rx_mii_word_sys(11) when MII_DEBUG /= 0 else (others => '0');
    dbg_rx_mii_word12 <= rx_mii_word_sys(12) when MII_DEBUG /= 0 else (others => '0');
    dbg_rx_mii_word13 <= rx_mii_word_sys(13) when MII_DEBUG /= 0 else (others => '0');
    dbg_rx_mii_word14 <= rx_mii_word_sys(14) when MII_DEBUG /= 0 else (others => '0');
    dbg_rx_mii_word15 <= rx_mii_word_sys(15) when MII_DEBUG /= 0 else (others => '0');
    dbg_rx_replay_last_len  <= std_logic_vector(rx_replay_last_len_sys)  when MII_DEBUG /= 0 else (others => '0');
    dbg_rx_replay_word0     <= rx_replay_word0_sys                       when MII_DEBUG /= 0 else (others => '0');
    dbg_rx_replay_word1     <= rx_replay_word1_sys                       when MII_DEBUG /= 0 else (others => '0');
    dbg_rx_replay_word2     <= rx_replay_word2_sys                       when MII_DEBUG /= 0 else (others => '0');
    dbg_rx_replay_word3     <= rx_replay_word3_sys                       when MII_DEBUG /= 0 else (others => '0');
    dbg_rx_replay_eof_count <= std_logic_vector(rx_replay_eof_count_sys) when MII_DEBUG /= 0 else (others => '0');

    rx_mem_rd_en <= '1' when (rx_replay_state = RX_REPLAY_PRIME) or
                             ((rx_replay_state = RX_REPLAY_WAIT) and
                              (rx_replay_len > 1)) or
                             ((rx_replay_state = RX_REPLAY_SEND) and
                              ((rx_replay_index + 2) < rx_replay_len))
                    else '0';
    rx_mem_rd_addr_reg <=
        x"000" when rx_replay_state = RX_REPLAY_PRIME else
        x"001" when rx_replay_state = RX_REPLAY_WAIT  else
        std_logic_vector(rx_mem_rd_addr(11 downto 0));

    -- RX frame buffer. The labels `u_rx_frame` / `mem` give the XPM instance
    -- the flattened name u_rx_frame_mem, as in the Verilog (see u above).
    u_rx_frame : if EMZ_TARGET = "XILINX_7SERIES" generate
        mem : xpm_memory_sdpram
            generic map (
                ADDR_WIDTH_A            => 12,
                ADDR_WIDTH_B            => 12,
                AUTO_SLEEP_TIME         => 0,
                BYTE_WRITE_WIDTH_A      => 9,
                CASCADE_HEIGHT          => 0,
                CLOCKING_MODE           => "common_clock",
                ECC_MODE                => "no_ecc",
                MEMORY_INIT_FILE        => "none",
                MEMORY_INIT_PARAM       => "0",
                MEMORY_OPTIMIZATION     => "true",
                MEMORY_PRIMITIVE        => "block",
                MEMORY_SIZE             => 9 * 4096,
                MESSAGE_CONTROL         => 0,
                READ_DATA_WIDTH_B       => 9,
                READ_LATENCY_B          => 1,
                READ_RESET_VALUE_B      => "0",
                RST_MODE_A              => "SYNC",
                RST_MODE_B              => "SYNC",
                USE_EMBEDDED_CONSTRAINT => 0,
                USE_MEM_INIT            => 0,
                WAKEUP_TIME             => "disable_sleep",
                WRITE_DATA_WIDTH_A      => 9,
                WRITE_MODE_B            => "read_first"
            )
            port map (
                sleep          => '0',
                clka           => clk,
                ena            => rx_mem_wr_en,
                wea            => "1",
                addra          => std_logic_vector(rx_mem_wr_addr),
                dina           => rx_mem_wr_data,
                injectsbiterra => '0',
                injectdbiterra => '0',
                clkb           => clk,
                rstb           => '0',
                enb            => rx_mem_rd_en,
                regceb         => '1',
                addrb          => rx_mem_rd_addr_reg,
                doutb          => rx_frame_mem_dout,
                sbiterrb       => open,
                dbiterrb       => open
            );
    end generate u_rx_frame;

    u_rx_frame_inferred : if EMZ_TARGET /= "XILINX_7SERIES" generate
        rx_frame_mem_dout <= rx_frame_mem_dout_r;

        process (clk)
        begin
            if rising_edge(clk) then
                if rx_mem_wr_en = '1' then
                    rx_frame_mem(to_integer(rx_mem_wr_addr(2 downto 0)))     <= rx_mem_wr_data;
                    rx_frame_mem_tag(to_integer(rx_mem_wr_addr(2 downto 0))) <=
                        std_logic_vector(rx_mem_wr_addr(11 downto 3));
                end if;
                if rx_mem_rd_en = '1' then
                    rx_frame_mem_dout_r <=
                        rx_frame_mem(to_integer(unsigned(rx_mem_rd_addr_reg(2 downto 0)))) xor
                        rx_frame_mem_tag(to_integer(unsigned(rx_mem_rd_addr_reg(2 downto 0)))) xor
                        rx_mem_rd_addr_reg(11 downto 3);
                end if;
            end if;
        end process;
    end generate u_rx_frame_inferred;

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            if MII_DEBUG /= 0 then
                rx_full_frame_s1 <= '0';
                rx_full_frame_s2 <= '0';
                rx_full_frame_s3 <= '0';
                rx_full_write_s1 <= '0';
                rx_full_write_s2 <= '0';
                rx_full_write_s3 <= '0';
                rx_overflow_s1 <= '0';
                rx_overflow_s2 <= '0';
                rx_overflow_s3 <= '0';
                rx_mii_frame_s1 <= '0';
                rx_mii_frame_s2 <= '0';
                rx_mii_frame_s3 <= '0';
                rx_wr_level_max_s1 <= (others => '0');
                rx_wr_level_max_s2 <= (others => '0');
                rx_fifo_full_frames_sys <= (others => '0');
                rx_fifo_full_writes_sys <= (others => '0');
                rx_fifo_overflow_pulses_sys <= (others => '0');
                rx_fifo_wr_level_max_sys <= (others => '0');
                rx_mii_last_len_sys <= (others => '0');
                for rxsi in 0 to 15 loop
                    rx_mii_word_sys(rxsi) <= (others => '0');
                end loop;
            end if;
        elsif rising_edge(clk) then
            if MII_DEBUG /= 0 then
                rx_full_frame_s1 <= rx_fifo_full_frame_toggle;
                rx_full_frame_s2 <= rx_full_frame_s1;
                rx_full_frame_s3 <= rx_full_frame_s2;
                rx_full_write_s1 <= rx_fifo_full_write_toggle;
                rx_full_write_s2 <= rx_full_write_s1;
                rx_full_write_s3 <= rx_full_write_s2;
                rx_overflow_s1 <= rx_fifo_overflow_toggle;
                rx_overflow_s2 <= rx_overflow_s1;
                rx_overflow_s3 <= rx_overflow_s2;
                rx_mii_frame_s1 <= rx_mii_frame_toggle;
                rx_mii_frame_s2 <= rx_mii_frame_s1;
                rx_mii_frame_s3 <= rx_mii_frame_s2;
                rx_wr_level_max_s1 <= rx_fifo_wr_level_max_rxclk;
                rx_wr_level_max_s2 <= rx_wr_level_max_s1;

                if rx_full_frame_s2 /= rx_full_frame_s3 then
                    rx_fifo_full_frames_sys <= rx_fifo_full_frames_sys + 1;
                end if;
                if rx_full_write_s2 /= rx_full_write_s3 then
                    rx_fifo_full_writes_sys <= rx_fifo_full_writes_sys + 1;
                end if;
                if rx_overflow_s2 /= rx_overflow_s3 then
                    rx_fifo_overflow_pulses_sys <= rx_fifo_overflow_pulses_sys + 1;
                end if;
                if rx_wr_level_max_s2 > rx_fifo_wr_level_max_sys(12 downto 0) then
                    rx_fifo_wr_level_max_sys <= resize(rx_wr_level_max_s2, 32);
                end if;
                if rx_mii_frame_s2 /= rx_mii_frame_s3 then
                    rx_mii_last_len_sys <= resize(rx_mii_last_len_rxclk, 32);
                    for rxsi in 0 to 15 loop
                        rx_mii_word_sys(rxsi) <= rx_mii_word_rxclk(rxsi);
                    end loop;
                end if;
            end if;
        end if;
    end process;

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            gmii_rxd            <= (others => '0');
            gmii_rx_dv          <= '0';
            gmii_rx_er          <= '0';
            rx_rd_en            <= '0';
            rx_mem_wr_en        <= '0';
            rx_mem_wr_addr      <= (others => '0');
            rx_mem_wr_data      <= (others => '0');
            rx_replay_state     <= RX_REPLAY_IDLE;
            rx_load_wait        <= '0';
            rx_load_count       <= (others => '0');
            rx_replay_len       <= (others => '0');
            rx_replay_index     <= (others => '0');
            rx_mem_rd_addr      <= (others => '0');
            rx_mem_rd_data      <= (others => '0');
            rx_frame_done_pulse <= '0';
            if MII_DEBUG /= 0 then
                rx_replay_gap_frames_sys   <= (others => '0');
                rx_replay_gap_cycles_sys   <= (others => '0');
                rx_replay_gap_byte_max_sys <= (others => '0');
                rx_replay_byte_count       <= (others => '0');
                rx_replay_gap_seen         <= '0';
                rx_replay_last_len_sys     <= (others => '0');
                rx_replay_word0_sys        <= (others => '0');
                rx_replay_word1_sys        <= (others => '0');
                rx_replay_word2_sys        <= (others => '0');
                rx_replay_word3_sys        <= (others => '0');
                rx_replay_eof_count_sys    <= (others => '0');
            end if;
        elsif rising_edge(clk) then
            rx_rd_en            <= '0';
            rx_mem_wr_en        <= '0';
            gmii_rx_dv          <= '0';
            gmii_rx_er          <= '0';
            rx_frame_done_pulse <= '0';

            case rx_replay_state is
                when RX_REPLAY_IDLE =>
                    rx_load_wait  <= '0';
                    rx_load_count <= (others => '0');
                    if MII_DEBUG /= 0 then
                        rx_replay_byte_count <= (others => '0');
                        rx_replay_gap_seen   <= '0';
                    end if;
                    if (rx_frame_ready = '1') and (rx_rd_word_valid = '1') then
                        rx_replay_state <= RX_REPLAY_LOAD;
                    end if;

                when RX_REPLAY_LOAD =>
                    if rx_load_wait = '1' then
                        rx_load_wait <= '0';
                    elsif rx_rd_word_valid = '1' then
                        rx_rd_en     <= '1';
                        rx_load_wait <= '1';
                        if rx_rd_data(9) = '1' then
                            rx_frame_done_pulse <= '1';
                            rx_replay_len       <= rx_load_count;
                            if MII_DEBUG /= 0 then
                                rx_replay_last_len_sys  <= resize(rx_load_count, 32);
                                rx_replay_eof_count_sys <= rx_replay_eof_count_sys + 1;
                                rx_replay_byte_count    <= (others => '0');
                                rx_replay_gap_seen      <= '0';
                            end if;
                            rx_mem_rd_addr  <= (others => '0');
                            rx_replay_index <= (others => '0');
                            if rx_load_count /= 0 then
                                rx_replay_state <= RX_REPLAY_PRIME;
                            else
                                rx_replay_state <= RX_REPLAY_IDLE;
                            end if;
                        else
                            rx_mem_wr_en   <= '1';
                            rx_mem_wr_addr <= rx_load_count(11 downto 0);
                            rx_mem_wr_data <= rx_rd_data(8) & rx_rd_data(7 downto 0);
                            rx_load_count  <= rx_load_count + 1;
                        end if;
                    else
                        if MII_DEBUG /= 0 then
                            rx_replay_gap_cycles_sys <= rx_replay_gap_cycles_sys + 1;
                            if rx_replay_gap_seen = '0' then
                                rx_replay_gap_frames_sys <= rx_replay_gap_frames_sys + 1;
                                rx_replay_gap_seen       <= '1';
                            end if;
                            if resize(rx_load_count, 32) > rx_replay_gap_byte_max_sys then
                                rx_replay_gap_byte_max_sys <= resize(rx_load_count, 32);
                            end if;
                        end if;
                    end if;

                when RX_REPLAY_PRIME =>
                    rx_mem_rd_addr  <= to_unsigned(1, 16);
                    rx_replay_index <= (others => '0');
                    rx_replay_state <= RX_REPLAY_WAIT;

                when RX_REPLAY_WAIT =>
                    rx_mem_rd_data <= rx_frame_mem_dout;
                    if rx_replay_len > 1 then
                        rx_mem_rd_addr <= to_unsigned(2, 16);
                    end if;
                    rx_replay_state <= RX_REPLAY_SEND;

                when RX_REPLAY_SEND =>
                    gmii_rxd   <= rx_mem_rd_data(7 downto 0);
                    gmii_rx_er <= rx_mem_rd_data(8);
                    gmii_rx_dv <= '1';
                    if MII_DEBUG /= 0 then
                        case to_integer(rx_replay_byte_count(3 downto 0)) is
                            when  0 => rx_replay_word0_sys(31 downto 24) <= rx_mem_rd_data(7 downto 0);
                            when  1 => rx_replay_word0_sys(23 downto 16) <= rx_mem_rd_data(7 downto 0);
                            when  2 => rx_replay_word0_sys(15 downto 8)  <= rx_mem_rd_data(7 downto 0);
                            when  3 => rx_replay_word0_sys(7 downto 0)   <= rx_mem_rd_data(7 downto 0);
                            when  4 => rx_replay_word1_sys(31 downto 24) <= rx_mem_rd_data(7 downto 0);
                            when  5 => rx_replay_word1_sys(23 downto 16) <= rx_mem_rd_data(7 downto 0);
                            when  6 => rx_replay_word1_sys(15 downto 8)  <= rx_mem_rd_data(7 downto 0);
                            when  7 => rx_replay_word1_sys(7 downto 0)   <= rx_mem_rd_data(7 downto 0);
                            when  8 => rx_replay_word2_sys(31 downto 24) <= rx_mem_rd_data(7 downto 0);
                            when  9 => rx_replay_word2_sys(23 downto 16) <= rx_mem_rd_data(7 downto 0);
                            when 10 => rx_replay_word2_sys(15 downto 8)  <= rx_mem_rd_data(7 downto 0);
                            when 11 => rx_replay_word2_sys(7 downto 0)   <= rx_mem_rd_data(7 downto 0);
                            when 12 => rx_replay_word3_sys(31 downto 24) <= rx_mem_rd_data(7 downto 0);
                            when 13 => rx_replay_word3_sys(23 downto 16) <= rx_mem_rd_data(7 downto 0);
                            when 14 => rx_replay_word3_sys(15 downto 8)  <= rx_mem_rd_data(7 downto 0);
                            when others => rx_replay_word3_sys(7 downto 0) <= rx_mem_rd_data(7 downto 0);
                        end case;
                        rx_replay_byte_count <= rx_replay_byte_count + 1;
                    end if;

                    if (rx_replay_index + 1) >= rx_replay_len then
                        rx_replay_state <= RX_REPLAY_IDLE;
                    else
                        rx_mem_rd_data <= rx_frame_mem_dout;
                        if (rx_replay_index + 2) < rx_replay_len then
                            rx_mem_rd_addr <= rx_mem_rd_addr + 1;
                        end if;
                        rx_replay_index <= rx_replay_index + 1;
                    end if;

                when others =>
                    rx_replay_state <= RX_REPLAY_IDLE;
            end case;
        end if;
    end process;

    -- =========================================================================
    -- TX path: GMII -> data FIFO with EOF sideband -> MII
    -- =========================================================================
    process (clk, rst_n)
    begin
        if rst_n = '0' then
            tx_en_d1 <= '0';
            tx_er_d1 <= '0';
        elsif rising_edge(clk) then
            tx_en_d1 <= gmii_tx_en;
            tx_er_d1 <= gmii_tx_er;
        end if;
    end process;
    tx_en_fall <= tx_en_d1 and (not gmii_tx_en);
    tx_er_rise <= gmii_tx_er and (not tx_er_d1);

    -- gmii_tx_er visibility. The MII output stage discards gmii_tx_er today -
    -- these counters surface that fact without changing TX semantics so a
    -- store-and-forward upstream (or a later mii_if-side discard) can be
    -- validated against hardware.
    process (clk, rst_n)
    begin
        if rst_n = '0' then
            if MII_DEBUG /= 0 then
                tx_er_pulses_r        <= (others => '0');
                tx_er_frames_r        <= (others => '0');
                tx_er_seen_this_frame <= '0';
            end if;
        elsif rising_edge(clk) then
            if MII_DEBUG /= 0 then
                if (tx_er_rise = '1') and (gmii_tx_en = '1') then
                    tx_er_pulses_r <= tx_er_pulses_r + 1;
                end if;
                if (gmii_tx_en = '1') and (gmii_tx_er = '1') then
                    tx_er_seen_this_frame <= '1';
                end if;
                if tx_en_fall = '1' then
                    if tx_er_seen_this_frame = '1' then
                        tx_er_frames_r <= tx_er_frames_r + 1;
                    end if;
                    tx_er_seen_this_frame <= '0';
                end if;
            end if;
        end if;
    end process;
    dbg_tx_er_pulses <= std_logic_vector(tx_er_pulses_r) when MII_DEBUG /= 0 else (others => '0');
    dbg_tx_er_frames <= std_logic_vector(tx_er_frames_r) when MII_DEBUG /= 0 else (others => '0');

    tx_wr_data       <= tx_en_fall & tx_data_d1;
    tx_wr_en         <= tx_wr_valid_d1;
    tx_wr_accept     <= tx_wr_en and (not tx_wr_rst_busy) and (not tx_wr_full);
    tx_eof_wr_accept <= tx_wr_accept and tx_wr_data(8);

    tx_rd_pulse_sys <= tx_rd_sync2 xor tx_rd_sync3;

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            tx_frame_len_wr <= (others => '0');
            tx_len_wr_data  <= (others => '0');
            tx_len_wr_en    <= '0';
            tx_data_d1      <= (others => '0');
            tx_wr_valid_d1  <= '0';
            if EMZ_TARGET /= "XILINX_7SERIES" then
                -- The Verilog resets tx_fifo_count on every target, but under
                -- XILINX_7SERIES nothing updates or reads it (the XPM's
                -- wr_data_count is used instead). A reset-only signal is a
                -- latch to GHDL, so it is reset here only where it is used.
                tx_fifo_count <= (others => '0');
                tx_rd_sync1 <= '0';
                tx_rd_sync2 <= '0';
                tx_rd_sync3 <= '0';
            end if;
        elsif rising_edge(clk) then
            tx_len_wr_en   <= '0';
            tx_data_d1     <= gmii_txd;
            tx_wr_valid_d1 <= gmii_tx_en;
            if EMZ_TARGET /= "XILINX_7SERIES" then
                tx_rd_sync1 <= tx_rd_toggle;
                tx_rd_sync2 <= tx_rd_sync1;
                tx_rd_sync3 <= tx_rd_sync2;
            end if;

            if (gmii_tx_en = '1') and (tx_wr_full = '0') then
                tx_frame_len_wr <= tx_frame_len_wr + 1;
            end if;

            if tx_en_fall = '1' then
                tx_len_wr_data  <= std_logic_vector(tx_frame_len_wr);
                tx_len_wr_en    <= '1';
                tx_frame_len_wr <= (others => '0');
            end if;

            if EMZ_TARGET /= "XILINX_7SERIES" then
                if (tx_wr_accept = '1') and (tx_rd_pulse_sys = '0') then
                    if tx_fifo_count < TX_FIFO_DEPTH then
                        tx_fifo_count <= tx_fifo_count + 1;
                    end if;
                elsif (tx_wr_accept = '0') and (tx_rd_pulse_sys = '1') then
                    if tx_fifo_count > 0 then
                        tx_fifo_count <= tx_fifo_count - 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    gen_tx_level : if EMZ_TARGET = "XILINX_7SERIES" generate
        tx_fifo_level <= tx_wr_data_count;
        tx_busy       <= '1' when (tx_frames_pending_r >= 2) or
                                  (unsigned(tx_wr_data_count) > TX_START_LIMIT) else '0';
    end generate gen_tx_level;

    gen_tx_level_cnt : if EMZ_TARGET /= "XILINX_7SERIES" generate
        tx_fifo_level <= std_logic_vector(tx_fifo_count);
        tx_busy       <= '1' when (tx_frames_pending_r >= 2) or
                                  (tx_fifo_count > TX_START_LIMIT) else '0';
    end generate gen_tx_level_cnt;

    -- Debug output assigns
    dbg_tx_wr_en           <= (tx_wr_en and (not tx_wr_full)) when MII_DEBUG /= 0 else '0';
    dbg_tx_len_wr_en       <= tx_len_wr_en                    when MII_DEBUG /= 0 else '0';
    dbg_tx_wr_full         <= tx_wr_full                      when MII_DEBUG /= 0 else '0';
    dbg_tx_wr_rst_busy_out <= tx_wr_rst_busy                  when MII_DEBUG /= 0 else '0';
    dbg_tx_rd_en           <= tx_rd_en                        when MII_DEBUG /= 0 else '0';
    dbg_tx_frame_loaded    <= tx_frame_loaded                 when MII_DEBUG /= 0 else '0';
    dbg_last_tx_len_wr     <= tx_len_wr_data                  when MII_DEBUG /= 0 else (others => '0');

    drain_pulse     <= drain_sync2 xor drain_sync3;
    tx_len_write_ok <= tx_eof_wr_accept;

    dbg_tx_frames_queued  <= std_logic_vector(tx_frames_queued_r)  when MII_DEBUG /= 0 else (others => '0');
    dbg_tx_frames_drained <= std_logic_vector(tx_frames_drained_r) when MII_DEBUG /= 0 else (others => '0');

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            tx_frames_queued_r     <= (others => '0');
            tx_frames_drained_r    <= (others => '0');
            tx_frames_pending_r    <= (others => '0');
            tx_frame_wr_count_bin  <= (others => '0');
            tx_frame_wr_count_gray <= (others => '0');
            drain_sync1 <= '0';
            drain_sync2 <= '0';
            drain_sync3 <= '0';
        elsif rising_edge(clk) then
            drain_sync1 <= drain_toggle;
            drain_sync2 <= drain_sync1;
            drain_sync3 <= drain_sync2;
            if tx_len_write_ok = '1' then
                tx_frames_queued_r     <= tx_frames_queued_r + 1;
                tx_frame_wr_count_bin  <= tx_frame_wr_count_bin + 1;
                tx_frame_wr_count_gray <= std_logic_vector((tx_frame_wr_count_bin + 1) xor
                                                           shift_right(tx_frame_wr_count_bin + 1, 1));
            end if;
            if drain_pulse = '1' then
                tx_frames_drained_r <= tx_frames_drained_r + 1;
            end if;

            if (tx_len_write_ok = '1') and (drain_pulse = '0') then
                if tx_frames_pending_r /= 7 then
                    tx_frames_pending_r <= tx_frames_pending_r + 1;
                end if;
            elsif (tx_len_write_ok = '0') and (drain_pulse = '1') then
                if tx_frames_pending_r /= 0 then
                    tx_frames_pending_r <= tx_frames_pending_r - 1;
                end if;
            end if;
        end if;
    end process;

    process (mii_tx_clk, tx_rst_n_s2)
    begin
        if tx_rst_n_s2 = '0' then
            tx_frame_wr_count_s1 <= (others => '0');
            tx_frame_wr_count_s2 <= (others => '0');
            tx_frame_wr_count_s3 <= (others => '0');
        elsif rising_edge(mii_tx_clk) then
            tx_frame_wr_count_s1 <= tx_frame_wr_count_gray;
            tx_frame_wr_count_s2 <= tx_frame_wr_count_s1;
            tx_frame_wr_count_s3 <= tx_frame_wr_count_s2;
        end if;
    end process;

    tx_frame_wr_count_mii <= gray4_to_bin(tx_frame_wr_count_s3);
    tx_frame_pending_mii  <= '1' when tx_frame_wr_count_mii /= tx_frame_rd_count_bin else '0';

    dbg_tx_fifo_empty     <= tx_rd_empty   when MII_DEBUG /= 0 else '0';
    dbg_rx_prog_empty     <= rx_prog_empty when MII_DEBUG /= 0 else '0';
    dbg_rx_rd_empty       <= rx_rd_empty   when MII_DEBUG /= 0 else '0';
    dbg_rx_reading        <= '1' when (MII_DEBUG /= 0) and (rx_replay_state /= RX_REPLAY_IDLE) else '0';
    dbg_rx_frames_pending <= ('0' & rx_frame_ready) when MII_DEBUG /= 0 else "00";

    -- TX data FIFO. Guarded by TX_ENABLE so the store-and-forward MII path
    -- (mii_tx_saf drives the pins) can omit this FIFO's BRAM. Only this
    -- instance is guarded - the framer, IOB stage and debug taps below stay at
    -- module level and self-drive to idle when the FIFO is tied empty, so no
    -- module output ports go undriven and no hierarchical names shift.
    -- Three generates (the Verilog's gen_tx_fifo with the vendor `ifdef
    -- inside, plus gen_no_tx_fifo). The labels gen_tx_fifo / u_tx_fifo and
    -- gen_tx_fifo_u / tx_fifo both flatten to gen_tx_fifo_u_tx_fifo, the
    -- Verilog's gen_tx_fifo.u_tx_fifo, on either target.
    gen_tx_fifo : if (TX_ENABLE /= 0) and (EMZ_TARGET = "XILINX_7SERIES") generate
        xpm_tx_rd_en <= tx_rd_en and (not tx_rd_rst_busy);
        xpm_tx_rst   <= not rst_n;

        u_tx_fifo : xpm_fifo_async
            generic map (
                FIFO_WRITE_DEPTH    => 4096,
                WRITE_DATA_WIDTH    => 9,
                READ_DATA_WIDTH     => 9,
                READ_MODE           => "FWFT",
                FIFO_READ_LATENCY   => 0,
                CDC_SYNC_STAGES     => 3,
                DOUT_RESET_VALUE    => "0",
                FULL_RESET_VALUE    => 0,
                PROG_EMPTY_THRESH   => 10,
                PROG_FULL_THRESH    => 10,
                RD_DATA_COUNT_WIDTH => 1,
                WR_DATA_COUNT_WIDTH => 13,
                USE_ADV_FEATURES    => "0004",
                WAKEUP_TIME         => 0
            )
            port map (
                wr_clk        => clk,
                wr_en         => tx_wr_accept,
                din           => tx_wr_data,
                full          => tx_wr_full,
                wr_rst_busy   => tx_wr_rst_busy,
                rd_clk        => mii_tx_clk,
                rd_en         => xpm_tx_rd_en,
                dout          => tx_rd_data,
                empty         => tx_rd_empty,
                rd_rst_busy   => tx_rd_rst_busy,
                rst           => xpm_tx_rst,
                sleep         => '0',
                injectsbiterr => '0',
                injectdbiterr => '0',
                sbiterr       => open,
                dbiterr       => open,
                overflow      => open,
                underflow     => open,
                prog_full     => open,
                prog_empty    => open,
                almost_full   => open,
                almost_empty  => open,
                wr_data_count => tx_wr_data_count,
                rd_data_count => open,
                data_valid    => tx_rd_valid,
                wr_ack        => open
            );
        tx_rd_word_valid <= (not tx_rd_empty) and (not tx_rd_rst_busy);
    end generate gen_tx_fifo;

    gen_tx_fifo_u : if (TX_ENABLE /= 0) and (EMZ_TARGET /= "XILINX_7SERIES") generate
        tx_wr_rst_busy   <= '0';
        tx_rd_rst_busy   <= '0';
        tx_wr_data_count <= std_logic_vector(tx_fifo_count);
        tx_rd_valid      <= not tx_rd_empty;
        tx_rd_word_valid <= not tx_rd_empty;
        tx_fifo : entity work.async_fifo
            generic map (DATA_WIDTH => 9, ADDR_WIDTH => 12)
            port map (
                wr_clk        => clk,
                wr_rst_n      => rst_n,
                wr_data       => tx_wr_data,
                wr_en         => tx_wr_accept,
                wr_full       => tx_wr_full,
                rd_clk        => mii_tx_clk,
                rd_rst_n      => tx_rst_n_s2,
                rd_data       => tx_rd_data,
                rd_en         => tx_rd_en,
                rd_empty      => tx_rd_empty,
                wr_data_count => open
            );
    end generate gen_tx_fifo_u;

    gen_no_tx_fifo : if TX_ENABLE = 0 generate
        -- TX disabled (Verilog: gen_no_tx_fifo): present a permanently-empty
        -- FIFO so no RAMB is inferred. gmii_tx_en is expected tied low
        -- upstream, so nothing is ever written; the framer below reads
        -- rd_empty=1 and keeps the MII TX pins idle.
        tx_wr_full       <= '0';
        tx_wr_rst_busy   <= '0';
        tx_rd_rst_busy   <= '0';
        tx_rd_data       <= (others => '0');
        tx_rd_empty      <= '1';
        tx_wr_data_count <= (others => '0');
        tx_rd_valid      <= '0';
        tx_rd_word_valid <= '0';
    end generate gen_no_tx_fifo;

    mii_txd               <= mii_txd_iob;
    mii_tx_en             <= mii_tx_en_iob;
    dbg_mii_txd_pre_iob   <= mii_txd_int   when MII_DEBUG /= 0 else (others => '0');
    dbg_mii_tx_en_pre_iob <= mii_tx_en_int when MII_DEBUG /= 0 else '0';

    -- IOB register stage: copies internal to pad on every mii_tx_clk
    -- (synchronous reset, as in the Verilog).
    process (mii_tx_clk)
    begin
        if rising_edge(mii_tx_clk) then
            if tx_rst_n_s2 = '0' then
                mii_txd_iob   <= (others => '0');
                mii_tx_en_iob <= '0';
            else
                mii_txd_iob   <= mii_txd_int;
                mii_tx_en_iob <= mii_tx_en_int;
            end if;
        end if;
    end process;

    process (mii_tx_clk)
    begin
        if rising_edge(mii_tx_clk) then
            if tx_rst_n_s2 = '0' then
                tx_st                 <= TX_IDLE;
                tx_byte               <= (others => '0');
                mii_txd_int           <= (others => '0');
                mii_tx_en_int         <= '0';
                tx_rd_en              <= '0';
                tx_byte_last          <= '0';
                tx_start_delay        <= (others => '0');
                tx_frame_loaded       <= '0';
                tx_frame_rd_count_bin <= (others => '0');
                drain_toggle          <= '0';
                if EMZ_TARGET /= "XILINX_7SERIES" then
                    tx_rd_toggle <= '0';
                end if;
            else
                tx_rd_en <= '0';

                case tx_st is
                    when TX_IDLE =>
                        mii_tx_en_int <= '0';
                        mii_txd_int   <= (others => '0');
                        if (tx_frame_loaded = '0') and (tx_frame_pending_mii = '1') then
                            tx_start_delay  <= to_unsigned(40, 6);
                            tx_frame_loaded <= '1';
                        elsif tx_frame_loaded = '1' then
                            if tx_start_delay /= 0 then
                                tx_start_delay <= tx_start_delay - 1;
                            elsif tx_rd_word_valid = '1' then
                                tx_byte      <= tx_rd_data(7 downto 0);
                                tx_byte_last <= tx_rd_data(8);
                                tx_rd_en     <= '1';
                                tx_st        <= TX_LOW;
                                if EMZ_TARGET /= "XILINX_7SERIES" then
                                    tx_rd_toggle <= not tx_rd_toggle;
                                end if;
                            end if;
                        end if;

                    when TX_LOW =>
                        mii_txd_int   <= tx_byte(3 downto 0);
                        mii_tx_en_int <= '1';
                        tx_st         <= TX_HIGH;

                    when TX_HIGH =>
                        mii_txd_int   <= tx_byte(7 downto 4);
                        mii_tx_en_int <= '1';
                        if tx_byte_last = '1' then
                            tx_frame_loaded       <= '0';
                            tx_st                 <= TX_IDLE;
                            tx_frame_rd_count_bin <= tx_frame_rd_count_bin + 1;
                            drain_toggle          <= not drain_toggle;
                        elsif tx_rd_word_valid = '1' then
                            tx_byte      <= tx_rd_data(7 downto 0);
                            tx_byte_last <= tx_rd_data(8);
                            tx_rd_en     <= '1';
                            tx_st        <= TX_LOW;
                            if EMZ_TARGET /= "XILINX_7SERIES" then
                                tx_rd_toggle <= not tx_rd_toggle;
                            end if;
                        end if;

                    when others =>
                        tx_st <= TX_IDLE;
                end case;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- MII TX byte capture (mii_tx_clk domain)
    -- Captures the first 64 bytes of every transmitted frame, overwriting on
    -- each new frame so software always sees the most recent. Software should
    -- poll dbg_mii_cap_done and read while it stays high.
    -- =========================================================================
    process (mii_tx_clk)
    begin
        if rising_edge(mii_tx_clk) then
            if tx_rst_n_s2 = '0' then
                if MII_DEBUG /= 0 then
                    mii_cap_idx       <= (others => '0');
                    mii_cap_frame_len <= (others => '0');
                    mii_cap_active    <= '0';
                    mii_cap_done      <= '0';
                    for mi in 0 to 63 loop
                        mii_cap(mi) <= (others => '0');
                    end loop;
                end if;
            else
                if MII_DEBUG /= 0 then
                    -- Capture bytes as they're read from data FIFO.
                    if tx_rd_en = '1' then
                        if mii_cap_active = '0' then
                            mii_cap_active    <= '1';
                            mii_cap_done      <= '0';
                            mii_cap_idx       <= (others => '0');
                            mii_cap_frame_len <= to_unsigned(1, 12);
                            mii_cap(0)        <= tx_rd_data(7 downto 0);
                        else
                            mii_cap_frame_len <= mii_cap_frame_len + 1;
                            if mii_cap_idx < 63 then
                                mii_cap(to_integer(mii_cap_idx + 1)) <= tx_rd_data(7 downto 0);
                            end if;
                            mii_cap_idx <= mii_cap_idx + 1;
                        end if;
                        if tx_rd_data(8) = '1' then
                            mii_cap_active <= '0';
                            mii_cap_done   <= '1';
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- CDC: sync mii_cap_done to sys_clk domain
    process (clk, rst_n)
    begin
        if rst_n = '0' then
            if MII_DEBUG /= 0 then
                mii_cap_done_s1 <= '0';
                mii_cap_done_s2 <= '0';
            end if;
        elsif rising_edge(clk) then
            if MII_DEBUG /= 0 then
                mii_cap_done_s1 <= mii_cap_done;
                mii_cap_done_s2 <= mii_cap_done_s1;
            end if;
        end if;
    end process;

    -- Debug assigns for MII capture (stable after mii_cap_done_s2)
    dbg_mii_cap_done      <= mii_cap_done_s2 when MII_DEBUG /= 0 else '0';
    dbg_mii_cap_frame_len <= std_logic_vector(mii_cap_frame_len) when MII_DEBUG /= 0 else (others => '0');
    dbg_mii_cap_word0     <= (mii_cap( 0) & mii_cap( 1) & mii_cap( 2) & mii_cap( 3)) when MII_DEBUG /= 0 else (others => '0');
    dbg_mii_cap_word1     <= (mii_cap( 4) & mii_cap( 5) & mii_cap( 6) & mii_cap( 7)) when MII_DEBUG /= 0 else (others => '0');
    dbg_mii_cap_word2     <= (mii_cap( 8) & mii_cap( 9) & mii_cap(10) & mii_cap(11)) when MII_DEBUG /= 0 else (others => '0');
    dbg_mii_cap_word3     <= (mii_cap(12) & mii_cap(13) & mii_cap(14) & mii_cap(15)) when MII_DEBUG /= 0 else (others => '0');
    dbg_mii_cap_word4     <= (mii_cap(16) & mii_cap(17) & mii_cap(18) & mii_cap(19)) when MII_DEBUG /= 0 else (others => '0');
    dbg_mii_cap_word5     <= (mii_cap(20) & mii_cap(21) & mii_cap(22) & mii_cap(23)) when MII_DEBUG /= 0 else (others => '0');
    dbg_mii_cap_word6     <= (mii_cap(24) & mii_cap(25) & mii_cap(26) & mii_cap(27)) when MII_DEBUG /= 0 else (others => '0');
    dbg_mii_cap_word7     <= (mii_cap(28) & mii_cap(29) & mii_cap(30) & mii_cap(31)) when MII_DEBUG /= 0 else (others => '0');
    dbg_mii_cap_word8     <= (mii_cap(32) & mii_cap(33) & mii_cap(34) & mii_cap(35)) when MII_DEBUG /= 0 else (others => '0');
    dbg_mii_cap_word9     <= (mii_cap(36) & mii_cap(37) & mii_cap(38) & mii_cap(39)) when MII_DEBUG /= 0 else (others => '0');
    dbg_mii_cap_word10    <= (mii_cap(40) & mii_cap(41) & mii_cap(42) & mii_cap(43)) when MII_DEBUG /= 0 else (others => '0');
    dbg_mii_cap_word11    <= (mii_cap(44) & mii_cap(45) & mii_cap(46) & mii_cap(47)) when MII_DEBUG /= 0 else (others => '0');
    dbg_mii_cap_word12    <= (mii_cap(48) & mii_cap(49) & mii_cap(50) & mii_cap(51)) when MII_DEBUG /= 0 else (others => '0');
    dbg_mii_cap_word13    <= (mii_cap(52) & mii_cap(53) & mii_cap(54) & mii_cap(55)) when MII_DEBUG /= 0 else (others => '0');
    dbg_mii_cap_word14    <= (mii_cap(56) & mii_cap(57) & mii_cap(58) & mii_cap(59)) when MII_DEBUG /= 0 else (others => '0');
    dbg_mii_cap_word15    <= (mii_cap(60) & mii_cap(61) & mii_cap(62) & mii_cap(63)) when MII_DEBUG /= 0 else (others => '0');

end architecture rtl;
