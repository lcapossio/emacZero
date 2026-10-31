-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- axilite_regs.vhd - AXI4-Lite slave register block for Ethernet MAC
-- 32-bit registers at byte addresses 0x00-0x98.
-- VHDL port of rtl/axilite_regs.v (formally proven equivalent; see sim/parity/).
-- =============================================================================
--
-- Register Map:
--   0x00 VERSION    RO    {MAJOR[7:0], MINOR[7:0], ID[15:0]}; values come from
--                         rtl/version.vh (single source of truth, validated
--                         against sw/emaczero/emaczero.h and emaczero.core by
--                         build_and_test.py). VHDL: emz_version_pkg.
--   0x04 CTRL       RW    [0] tx_en  [1] rx_en  [2] promisc
--                         [4:3] speed (00=1G, 01=100M, 10=10M, 11=reserved)
--                         [5] full_duplex (RW; default 1) - INFORMATIONAL ONLY.
--                              The MAC implements full-duplex operation; there
--                              is no half-duplex CSMA/CD logic. Software may
--                              reflect the auto-negotiated mode here for
--                              status, but the bit has no functional effect.
--                         [6] jumbo_en  (allow >1518-byte frames)
--                         [7] tx_csum_off (insert IPv4 header / TCP / UDP /
--                              ICMP / ICMPv6 checksums on TX; needs
--                              TX_CSUM_OFFLOAD=1)
--                         [8] passthrough (sniffer mode: bypass MAC filter and
--                              deliver frames with FCS / size errors anyway,
--                              still tagged via m_axis_terror)
--                         [9] rx_csum_off (verify those checksums on RX and
--                              flag frames that fail with m_axis_terror;
--                              needs RX_CSUM_OFFLOAD=1)
--   0x08 STATUS     RO    [0] tx_active  [1] tx_fifo_busy  [2] mdio_busy
--                         [3] mdio_cmd_dropped (sticky: an MDIO GO was written
--                              while the master was busy and was ignored;
--                              cleared by the next successfully-issued GO)
--   0x0C MAC_LO     RW    our_mac[31:0]
--   0x10 MAC_HI     RW    our_mac[47:32]  (upper 16 bits read as 0)
--   0x14 MDIO_CMD   RW    [4:0] reg  [9:5] phy  [10] write  [11] go (self-clear)
--                          [12] c45_en   (0=clause-22, 1=clause-45)
--                          [14:13] c45_op (when c45_en=1; 00=ADDR 01=WRITE
--                          10=READ-INC 11=READ; ignored in C22)
--   0x18 MDIO_WDATA RW    [15:0] write data
--   0x1C MDIO_RDATA RO    [15:0] read data
--   0x20 IRQ_EN     RW    [0] tx_done  [1] rx_frame  [2] mdio_done
--   0x24 IRQ_STATUS W1C   [0] tx_done  [1] rx_frame  [2] mdio_done
--   0x28 TX_FRAME   RO/WC write-any-to-clear
--   0x2C TX_BYTE    RO/WC write-any-to-clear
--   0x30 RX_FRAME   RO/WC write-any-to-clear
--   0x34 RX_BYTE    RO/WC write-any-to-clear
--   0x38 RX_ERR     RO/WC write-any-to-clear
--   0x3C SCRATCH    RW
--   0x40 IP_ADDR    RW    cfg_ip_addr[31:0] - IPv4 address for the demo L3
--                          stack (arp/icmp/udp responders in the board top).
--                          Default 0xC0A889C8 = 192.168.137.200. Not a MAC-layer
--                          concept; provided so the hardware L3 IP can be set at
--                          runtime over AXI (e.g. via the EJTAG-AXI bridge)
--                          instead of only at build time.
--   --- Only present when MCAST_HASH_FILTER == 1 ---
--   0x44 MCAST_LO   RW    mcast_hash_table[31:0]
--   0x48 MCAST_HI   RW    mcast_hash_table[63:32]
--   --- 802.3x PAUSE flow control (always present) ---
--   0x84 PAUSE_CTRL  RW    [0] tx_send (W1S, hardware self-clears once frame
--                              has been emitted)
--                          [1] rx_en   (honor incoming PAUSE frames)
--   0x88 PAUSE_QUANTA RW   [15:0] quanta to load into the next emitted frame
--   0x8C PAUSE_RX_CNT RO/WC count of received PAUSE frames
--   0x90 PAUSE_TX_CNT RO/WC count of transmitted PAUSE frames
--   --- RX statistics breakdown (always present) ---
--   0x4C RX_ERR_ALIGN    RO/WC  rx_er asserted during frame
--   0x50 RX_ERR_OVERFLOW RO/WC  RX FIFO overflow during frame
--   0x54 RX_ERR_OVERSIZE RO/WC  frame longer than current MAX (std/jumbo)
--   0x58 RX_BCAST        RO/WC  bcast frames received (dst = FF:FF:FF:FF:FF:FF)
--   0x5C RX_MCAST        RO/WC  mcast frames received (I/G bit set, !bcast)
--   0x60 RX_SIZE_64        RO/WC  frames exactly 64 bytes (incl FCS)
--   0x64 RX_SIZE_65_127    RO/WC
--   0x68 RX_SIZE_128_255   RO/WC
--   0x6C RX_SIZE_256_511   RO/WC
--   0x70 RX_SIZE_512_1023  RO/WC
--   0x74 RX_SIZE_1024_1518 RO/WC
--   0x78 RX_SIZE_JUMBO     RO/WC  > 1518 bytes
--   0x7C RX_DROP           RO/WC  frames for us dropped whole: no RX FIFO
--                                 room at their start, so never delivered and
--                                 in no other RX counter. Reads 0 on cores
--                                 that predate it (unmapped CSRs read 0).
--   0x80 RX_ERR_CSUM       RO/WC  frames flagged for a wrong IP / L4 checksum
--                                 (CTRL[9]); otherwise sound frames only
--   --- Build capabilities (always present; unmapped, so 0, on older cores) ---
--   0x98 CAPS       RO    [0] MCAST_HASH_FILTER  [1] TX_CSUM_OFFLOAD
--                         [2] RX_CSUM_OFFLOAD  [15:3] reserved (0)
--                         [31:16] MAX_FRAME (bytes; never 0, so a nonzero
--                         read means the core has CAPS)
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.emz_version_pkg.all;

entity axilite_regs is
    generic (
        ADDR_WIDTH        : integer := 8;    -- 8 bits gives 256-byte CSR space
        MCAST_HASH_FILTER : integer := 0;
        -- Reported in CAPS only; the logic they select lives in eth_mac_sys.
        TX_CSUM_OFFLOAD   : integer := 0;
        RX_CSUM_OFFLOAD   : integer := 0;
        MAX_FRAME         : integer := 9018;
        -- 1 = CTRL leaves reset with tx_en and rx_en set; 0 = both clear.
        -- eth_mac_sys resets its TX/RX enable gates from the same generic.
        TXRX_EN_AT_RESET  : integer := 1
    );
    port (
        s_axi_aclk    : in  std_logic;
        s_axi_aresetn : in  std_logic;

        -- ---- AXI4-Lite Write Address ----
        s_axi_awaddr  : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        s_axi_awvalid : in  std_logic;
        s_axi_awready : out std_logic;

        -- ---- AXI4-Lite Write Data ----
        s_axi_wdata   : in  std_logic_vector(31 downto 0);
        s_axi_wstrb   : in  std_logic_vector(3 downto 0);
        s_axi_wvalid  : in  std_logic;
        s_axi_wready  : out std_logic;

        -- ---- AXI4-Lite Write Response ----
        s_axi_bresp   : out std_logic_vector(1 downto 0);
        s_axi_bvalid  : out std_logic;
        s_axi_bready  : in  std_logic;

        -- ---- AXI4-Lite Read Address ----
        s_axi_araddr  : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
        s_axi_arvalid : in  std_logic;
        s_axi_arready : out std_logic;

        -- ---- AXI4-Lite Read Data ----
        s_axi_rdata   : out std_logic_vector(31 downto 0);
        s_axi_rresp   : out std_logic_vector(1 downto 0);
        s_axi_rvalid  : out std_logic;
        s_axi_rready  : in  std_logic;

        -- ---- Configuration outputs ----
        cfg_tx_en       : out std_logic;
        cfg_rx_en       : out std_logic;
        cfg_promisc     : out std_logic;
        cfg_speed       : out std_logic_vector(1 downto 0);   -- 00=1G, 01=100M, 10=10M
        cfg_full_duplex : out std_logic;
        cfg_jumbo_en    : out std_logic;
        cfg_tx_csum_off : out std_logic;
        cfg_passthrough : out std_logic;
        cfg_rx_csum_off : out std_logic;
        cfg_mac_addr    : out std_logic_vector(47 downto 0);
        cfg_ip_addr     : out std_logic_vector(31 downto 0);  -- demo L3 stack IPv4 (0x40 IP_ADDR)
        dbg_saf         : in  std_logic_vector(15 downto 0);  -- mii_tx_saf read-side debug (0x94, RO)
        cfg_mcast_hash_table : out std_logic_vector(63 downto 0);

        -- ---- PAUSE controls ----
        cfg_pause_rx_en     : out std_logic;
        cfg_pause_tx_send   : out std_logic;                     -- single-cycle pulse
        cfg_pause_tx_quanta : out std_logic_vector(15 downto 0);
        stat_pause_rx_cnt   : in  std_logic_vector(31 downto 0);
        stat_pause_tx_cnt   : in  std_logic_vector(31 downto 0);
        stat_clr_pause      : out std_logic;

        -- ---- MDIO interface ----
        mdio_go       : out std_logic;
        mdio_write    : out std_logic;
        mdio_phy_addr : out std_logic_vector(4 downto 0);
        mdio_reg_addr : out std_logic_vector(4 downto 0);
        mdio_wdata    : out std_logic_vector(15 downto 0);
        mdio_c45_en   : out std_logic;
        mdio_c45_op   : out std_logic_vector(1 downto 0);
        mdio_rdata    : in  std_logic_vector(15 downto 0);
        mdio_done     : in  std_logic;
        mdio_busy     : in  std_logic;

        -- ---- Statistics inputs ----
        stat_tx_frame_cnt          : in  std_logic_vector(31 downto 0);
        stat_tx_byte_cnt           : in  std_logic_vector(31 downto 0);
        stat_rx_frame_cnt          : in  std_logic_vector(31 downto 0);
        stat_rx_byte_cnt           : in  std_logic_vector(31 downto 0);
        stat_rx_err_cnt            : in  std_logic_vector(31 downto 0);   -- legacy: rx_crc_err_cnt
        stat_rx_err_align_cnt      : in  std_logic_vector(31 downto 0);
        stat_rx_err_overflow_cnt   : in  std_logic_vector(31 downto 0);
        stat_rx_err_oversize_cnt   : in  std_logic_vector(31 downto 0);
        stat_rx_bcast_cnt          : in  std_logic_vector(31 downto 0);
        stat_rx_mcast_cnt          : in  std_logic_vector(31 downto 0);
        stat_rx_size_64_cnt        : in  std_logic_vector(31 downto 0);
        stat_rx_size_65_127_cnt    : in  std_logic_vector(31 downto 0);
        stat_rx_size_128_255_cnt   : in  std_logic_vector(31 downto 0);
        stat_rx_size_256_511_cnt   : in  std_logic_vector(31 downto 0);
        stat_rx_size_512_1023_cnt  : in  std_logic_vector(31 downto 0);
        stat_rx_size_1024_1518_cnt : in  std_logic_vector(31 downto 0);
        stat_rx_size_jumbo_cnt     : in  std_logic_vector(31 downto 0);
        stat_rx_drop_cnt           : in  std_logic_vector(31 downto 0);
        stat_rx_err_csum_cnt       : in  std_logic_vector(31 downto 0);
        stat_clr_tx                : out std_logic;
        stat_clr_rx                : out std_logic;

        -- ---- Status inputs ----
        sts_tx_active    : in  std_logic;
        sts_tx_fifo_busy : in  std_logic;

        -- ---- Interrupt event inputs (single-cycle pulses) ----
        evt_tx_done  : in  std_logic;
        evt_rx_frame : in  std_logic;

        -- ---- Interrupt output ----
        irq : out std_logic
    );
end entity axilite_regs;

architecture rtl of axilite_regs is

    -- =========================================================================
    -- Constants
    -- =========================================================================
    constant VERSION : std_logic_vector(31 downto 0) :=
        EMZ_VERSION_MAJOR & EMZ_VERSION_MINOR & EMZ_VERSION_ID;

    function cap_bit(p : integer) return std_logic is
    begin
        if p /= 0 then
            return '1';
        end if;
        return '0';
    end function;

    -- MAX_FRAME's low 16 bits, as the Verilog [15:0] localparam truncates it
    constant CAPS : std_logic_vector(31 downto 0) :=
        std_logic_vector(to_unsigned(MAX_FRAME mod 65536, 16)) &
        "0000000000000" & cap_bit(RX_CSUM_OFFLOAD) &
        cap_bit(TX_CSUM_OFFLOAD) & cap_bit(MCAST_HASH_FILTER);

    -- Register address offsets (word-aligned, using bits [ADDR_WIDTH-1:2]).
    -- Verilog compares the ADDR_WIDTH-2 bit index against these 6-bit codes
    -- with zero extension of the narrower side, i.e. numerically; the case
    -- statements below compare the index as an integer for the same result
    -- at every ADDR_WIDTH.
    constant A_VERSION    : integer := 16#00#;  -- 0x00
    constant A_CTRL       : integer := 16#01#;  -- 0x04
    constant A_STATUS     : integer := 16#02#;  -- 0x08
    constant A_MAC_LO     : integer := 16#03#;  -- 0x0C
    constant A_MAC_HI     : integer := 16#04#;  -- 0x10
    constant A_MDIO_CMD   : integer := 16#05#;  -- 0x14
    constant A_MDIO_WDATA : integer := 16#06#;  -- 0x18
    constant A_MDIO_RDATA : integer := 16#07#;  -- 0x1C
    constant A_IRQ_EN     : integer := 16#08#;  -- 0x20
    constant A_IRQ_STATUS : integer := 16#09#;  -- 0x24
    constant A_TX_FRAME   : integer := 16#0A#;  -- 0x28
    constant A_TX_BYTE    : integer := 16#0B#;  -- 0x2C
    constant A_RX_FRAME   : integer := 16#0C#;  -- 0x30
    constant A_RX_BYTE    : integer := 16#0D#;  -- 0x34
    constant A_RX_ERR     : integer := 16#0E#;  -- 0x38
    constant A_SCRATCH    : integer := 16#0F#;  -- 0x3C
    constant A_IP_ADDR    : integer := 16#10#;  -- 0x40 (demo L3 stack IPv4)
    -- MCAST registers (only active when MCAST_HASH_FILTER == 1)
    constant A_MCAST_LO   : integer := 16#11#;  -- 0x44
    constant A_MCAST_HI   : integer := 16#12#;  -- 0x48
    -- RX statistics breakdown
    constant A_RX_ERR_ALIGN      : integer := 16#13#;  -- 0x4C
    constant A_RX_ERR_OVERFLOW   : integer := 16#14#;  -- 0x50
    constant A_RX_ERR_OVERSIZE   : integer := 16#15#;  -- 0x54
    constant A_RX_BCAST          : integer := 16#16#;  -- 0x58
    constant A_RX_MCAST          : integer := 16#17#;  -- 0x5C
    constant A_RX_SIZE_64        : integer := 16#18#;  -- 0x60
    constant A_RX_SIZE_65_127    : integer := 16#19#;  -- 0x64
    constant A_RX_SIZE_128_255   : integer := 16#1A#;  -- 0x68
    constant A_RX_SIZE_256_511   : integer := 16#1B#;  -- 0x6C
    constant A_RX_SIZE_512_1023  : integer := 16#1C#;  -- 0x70
    constant A_RX_SIZE_1024_1518 : integer := 16#1D#;  -- 0x74
    constant A_RX_SIZE_JUMBO     : integer := 16#1E#;  -- 0x78
    constant A_RX_DROP           : integer := 16#1F#;  -- 0x7C
    constant A_RX_ERR_CSUM       : integer := 16#20#;  -- 0x80
    -- PAUSE registers (require ADDR_WIDTH >= 8)
    constant A_PAUSE_CTRL   : integer := 16#21#;  -- 0x84
    constant A_PAUSE_QUANTA : integer := 16#22#;  -- 0x88
    constant A_PAUSE_RX_CNT : integer := 16#23#;  -- 0x8C
    constant A_PAUSE_TX_CNT : integer := 16#24#;  -- 0x90
    constant A_SAF_DBG      : integer := 16#25#;  -- 0x94 (RO, mii_tx_saf debug)
    constant A_CAPS         : integer := 16#26#;  -- 0x98 (RO, build capabilities)

    -- =========================================================================
    -- Registers
    -- =========================================================================
    -- [0] tx_en, [1] rx_en, [2] promisc, [4:3] speed, [5] full_duplex,
    -- [6] jumbo_en, [7] tx_csum_off, [8] passthrough
    -- CTRL reset value: full_duplex=1, speed=00 (1G), everything else off,
    -- plus tx_en and rx_en when TXRX_EN_AT_RESET is set.
    function ctrl_reset_val(en : integer) return std_logic_vector is
    begin
        if en /= 0 then
            return "0000100011";
        else
            return "0000100000";
        end if;
    end function;
    constant CTRL_RESET     : std_logic_vector(9 downto 0) := ctrl_reset_val(TXRX_EN_AT_RESET);
    signal reg_ctrl         : std_logic_vector(9 downto 0);
    signal reg_mac_lo       : std_logic_vector(31 downto 0);
    signal reg_mac_hi       : std_logic_vector(15 downto 0);
    signal reg_ip_addr      : std_logic_vector(31 downto 0);
    -- Storage mirrors user bit positions exactly. Bit 11 (go) self-clears and
    -- is captured separately via mdio_go, so bit 11 of this register reads 0.
    signal reg_mdio_cmd     : std_logic_vector(14 downto 0);  -- [4:0] reg/devad, [9:5] phy, [10] write,
                                                              -- [11] reads-as-0, [12] c45_en, [14:13] c45_op
    signal reg_mdio_wdata   : std_logic_vector(15 downto 0);
    signal mdio_cmd_dropped : std_logic;   -- sticky: an MDIO GO arrived while busy
    signal reg_irq_en       : std_logic_vector(2 downto 0);
    signal reg_irq_status   : std_logic_vector(2 downto 0);
    signal reg_scratch      : std_logic_vector(31 downto 0);
    signal reg_mcast_lo     : std_logic_vector(31 downto 0);  -- mcast_hash_table[31:0]
    signal reg_mcast_hi     : std_logic_vector(31 downto 0);  -- mcast_hash_table[63:32]
    -- PAUSE
    signal reg_pause_rx_en  : std_logic;
    signal reg_pause_quanta : std_logic_vector(15 downto 0);

    -- =========================================================================
    -- Write channel state
    -- =========================================================================
    signal aw_ready_r : std_logic;
    signal w_ready_r  : std_logic;
    signal aw_latched : std_logic;   -- AW received, waiting for W
    signal w_latched  : std_logic;   -- W received, waiting for AW
    signal aw_addr    : std_logic_vector(ADDR_WIDTH-1 downto 0);
    signal w_data     : std_logic_vector(31 downto 0);
    signal w_strb     : std_logic_vector(3 downto 0);

    signal wr_fire : std_logic;
    signal wr_idx  : std_logic_vector(ADDR_WIDTH-3 downto 0);

    -- Outputs read back internally
    signal s_axi_bvalid_i  : std_logic;
    signal s_axi_arready_i : std_logic;
    signal s_axi_rvalid_i  : std_logic;

    -- WSTRB byte-lane merge helper
    function strb_merge(old_val : std_logic_vector(31 downto 0);
                        new_val : std_logic_vector(31 downto 0);
                        strb    : std_logic_vector(3 downto 0))
        return std_logic_vector is
        variable r : std_logic_vector(31 downto 0);
    begin
        r := old_val;
        if strb(3) = '1' then r(31 downto 24) := new_val(31 downto 24); end if;
        if strb(2) = '1' then r(23 downto 16) := new_val(23 downto 16); end if;
        if strb(1) = '1' then r(15 downto 8)  := new_val(15 downto 8);  end if;
        if strb(0) = '1' then r(7 downto 0)   := new_val(7 downto 0);   end if;
        return r;
    end function strb_merge;

begin

    -- =========================================================================
    -- Responses always OKAY
    -- =========================================================================
    s_axi_bresp <= "00";
    s_axi_rresp <= "00";

    s_axi_bvalid  <= s_axi_bvalid_i;
    s_axi_arready <= s_axi_arready_i;
    s_axi_rvalid  <= s_axi_rvalid_i;

    -- =========================================================================
    -- Configuration outputs
    -- =========================================================================
    cfg_tx_en       <= reg_ctrl(0);
    cfg_rx_en       <= reg_ctrl(1);
    cfg_promisc     <= reg_ctrl(2);
    cfg_speed       <= reg_ctrl(4 downto 3);
    cfg_full_duplex <= reg_ctrl(5);
    cfg_jumbo_en    <= reg_ctrl(6);
    cfg_tx_csum_off <= reg_ctrl(7);
    cfg_passthrough <= reg_ctrl(8);
    cfg_rx_csum_off <= reg_ctrl(9);
    cfg_mac_addr    <= reg_mac_hi & reg_mac_lo;
    cfg_ip_addr     <= reg_ip_addr;
    cfg_mcast_hash_table <= reg_mcast_hi & reg_mcast_lo when MCAST_HASH_FILTER /= 0
                            else (others => '0');
    cfg_pause_rx_en     <= reg_pause_rx_en;
    cfg_pause_tx_quanta <= reg_pause_quanta;

    -- =========================================================================
    -- MDIO outputs
    -- =========================================================================
    mdio_reg_addr <= reg_mdio_cmd(4 downto 0);
    mdio_phy_addr <= reg_mdio_cmd(9 downto 5);
    mdio_write    <= reg_mdio_cmd(10);
    mdio_c45_en   <= reg_mdio_cmd(12);
    mdio_c45_op   <= reg_mdio_cmd(14 downto 13);
    mdio_wdata    <= reg_mdio_wdata;

    -- =========================================================================
    -- Interrupt logic
    -- =========================================================================
    irq <= '1' when (reg_irq_status and reg_irq_en) /= "000" else '0';

    -- =========================================================================
    -- Write channel - AW and W accepted independently per AXI4-Lite spec
    -- =========================================================================
    s_axi_awready <= aw_ready_r;
    s_axi_wready  <= w_ready_r;

    -- Write fires when both AW and W have been received
    wr_fire <= aw_latched and w_latched;
    wr_idx  <= aw_addr(ADDR_WIDTH-1 downto 2);

    process (s_axi_aclk, s_axi_aresetn)
        variable merged : std_logic_vector(31 downto 0);
    begin
        if s_axi_aresetn = '0' then
            aw_ready_r     <= '1';
            w_ready_r      <= '1';
            s_axi_bvalid_i <= '0';
            aw_latched     <= '0';
            w_latched      <= '0';
            aw_addr        <= (others => '0');
            w_data         <= (others => '0');
            w_strb         <= (others => '0');

            reg_ctrl       <= CTRL_RESET;
            reg_mac_lo     <= x"00000001";
            reg_mac_hi     <= x"0200";      -- locally administered
            reg_ip_addr    <= x"C0A889C8";  -- 192.168.137.200
            reg_mdio_cmd   <= (others => '0');
            reg_mdio_wdata <= (others => '0');
            reg_irq_en     <= (others => '0');
            reg_irq_status <= (others => '0');
            reg_scratch    <= (others => '0');
            -- reg_mcast_lo / reg_mcast_hi: see gen_mcast below
            mdio_go        <= '0';
            mdio_cmd_dropped <= '0';
            stat_clr_tx    <= '0';
            stat_clr_rx    <= '0';
            stat_clr_pause <= '0';
            cfg_pause_tx_send <= '0';
            reg_pause_rx_en  <= '0';
            reg_pause_quanta <= (others => '0');
        elsif rising_edge(s_axi_aclk) then
            -- Self-clearing pulses default to 0
            mdio_go        <= '0';
            stat_clr_tx    <= '0';
            stat_clr_rx    <= '0';
            stat_clr_pause <= '0';
            cfg_pause_tx_send <= '0';

            -- IRQ event capture (set bits from event pulses)
            if evt_tx_done = '1'  then reg_irq_status(0) <= '1'; end if;
            if evt_rx_frame = '1' then reg_irq_status(1) <= '1'; end if;
            if mdio_done = '1'    then reg_irq_status(2) <= '1'; end if;

            -- --- AW handshake (independent of W) ---
            if s_axi_awvalid = '1' and aw_ready_r = '1' then
                aw_addr    <= s_axi_awaddr;
                aw_latched <= '1';
                aw_ready_r <= '0';
            end if;

            -- --- W handshake (independent of AW) ---
            if s_axi_wvalid = '1' and w_ready_r = '1' then
                w_data    <= s_axi_wdata;
                w_strb    <= s_axi_wstrb;
                w_latched <= '1';
                w_ready_r <= '0';
            end if;

            -- --- Both received: execute write + issue B ---
            if wr_fire = '1' and s_axi_bvalid_i = '0' then
                s_axi_bvalid_i <= '1';
                aw_latched     <= '0';
                w_latched      <= '0';

                case to_integer(unsigned(wr_idx)) is
                    when A_CTRL =>
                        merged := strb_merge(x"00000" & "00" & reg_ctrl, w_data, w_strb);
                        reg_ctrl <= merged(9 downto 0);
                    when A_MAC_LO =>
                        reg_mac_lo <= strb_merge(reg_mac_lo, w_data, w_strb);
                    when A_MAC_HI =>
                        merged := strb_merge(x"0000" & reg_mac_hi, w_data, w_strb);
                        reg_mac_hi <= merged(15 downto 0);
                    when A_IP_ADDR =>
                        reg_ip_addr <= strb_merge(reg_ip_addr, w_data, w_strb);
                    when A_MDIO_CMD =>
                        -- Mask bit 11 (go) to 0 so it never persists in storage
                        merged := strb_merge(x"0000" & '0' & reg_mdio_cmd, w_data, w_strb);
                        reg_mdio_cmd <= merged(14 downto 0) and "111011111111111";
                        -- GO while the master is busy cannot start a transaction.
                        -- Surface that via a sticky STATUS bit instead of failing
                        -- silently; the next successfully-issued GO clears it.
                        if w_strb(1) = '1' and w_data(11) = '1' then
                            if mdio_busy = '0' then
                                mdio_go          <= '1';
                                mdio_cmd_dropped <= '0';
                            else
                                mdio_cmd_dropped <= '1';
                            end if;
                        end if;
                    when A_MDIO_WDATA =>
                        merged := strb_merge(x"0000" & reg_mdio_wdata, w_data, w_strb);
                        reg_mdio_wdata <= merged(15 downto 0);
                    when A_IRQ_EN =>
                        merged := strb_merge(x"0000000" & '0' & reg_irq_en, w_data, w_strb);
                        reg_irq_en <= merged(2 downto 0);
                    when A_IRQ_STATUS =>
                        reg_irq_status <= reg_irq_status and not w_data(2 downto 0);  -- W1C
                    when A_TX_FRAME =>   stat_clr_tx <= '1';
                    when A_TX_BYTE =>    stat_clr_tx <= '1';
                    when A_RX_FRAME =>   stat_clr_rx <= '1';
                    when A_RX_BYTE =>    stat_clr_rx <= '1';
                    when A_RX_ERR =>     stat_clr_rx <= '1';
                    when A_SCRATCH =>
                        reg_scratch <= strb_merge(reg_scratch, w_data, w_strb);
                    when A_MCAST_LO | A_MCAST_HI =>
                        null;  -- written in gen_mcast below (MCAST_HASH_FILTER only)
                    -- Extended RX stat counters: any write clears (W1C-style,
                    -- grouped under stat_clr_rx since they all live in eth_stats RX block)
                    when A_RX_ERR_ALIGN
                       | A_RX_ERR_OVERFLOW
                       | A_RX_ERR_OVERSIZE
                       | A_RX_BCAST
                       | A_RX_MCAST
                       | A_RX_SIZE_64
                       | A_RX_SIZE_65_127
                       | A_RX_SIZE_128_255
                       | A_RX_SIZE_256_511
                       | A_RX_SIZE_512_1023
                       | A_RX_SIZE_1024_1518
                       | A_RX_SIZE_JUMBO
                       | A_RX_DROP =>
                        stat_clr_rx <= '1';
                    when A_RX_ERR_CSUM =>
                        stat_clr_rx <= '1';
                    when A_PAUSE_CTRL =>
                        if w_strb(0) = '1' then
                            -- [0] tx_send (W1S, self-clearing pulse to eth_pause)
                            -- [1] rx_en   (level-sensitive)
                            if w_data(0) = '1' then
                                cfg_pause_tx_send <= '1';
                            end if;
                            reg_pause_rx_en <= w_data(1);
                        end if;
                    when A_PAUSE_QUANTA =>
                        if w_strb(0) = '1' then reg_pause_quanta(7 downto 0)  <= w_data(7 downto 0);  end if;
                        if w_strb(1) = '1' then reg_pause_quanta(15 downto 8) <= w_data(15 downto 8); end if;
                    when A_PAUSE_RX_CNT
                       | A_PAUSE_TX_CNT =>
                        stat_clr_pause <= '1';
                    when others =>
                        null;  -- STATUS, MDIO_RDATA, VERSION: read-only
                end case;
            end if;

            -- --- B handshake ---
            if s_axi_bvalid_i = '1' and s_axi_bready = '1' then
                s_axi_bvalid_i <= '0';
                aw_ready_r     <= '1';
                w_ready_r      <= '1';
            end if;
        end if;
    end process;

    -- MCAST hash registers. Same reset and write conditions as the Verilog,
    -- which keeps them in the write process above; here they get their own
    -- process because with MCAST_HASH_FILTER = 0 they are never written, and
    -- GHDL rejects a register assigned only under reset (it infers a latch).
    -- With the filter off they are not observable (cfg_mcast_hash_table and
    -- the MCAST reads are forced to 0 below), so they are tied to 0.
    gen_mcast : if MCAST_HASH_FILTER /= 0 generate
        process (s_axi_aclk, s_axi_aresetn)
        begin
            if s_axi_aresetn = '0' then
                reg_mcast_lo <= (others => '0');
                reg_mcast_hi <= (others => '0');
            elsif rising_edge(s_axi_aclk) then
                if wr_fire = '1' and s_axi_bvalid_i = '0' then
                    case to_integer(unsigned(wr_idx)) is
                        when A_MCAST_LO =>
                            reg_mcast_lo <= strb_merge(reg_mcast_lo, w_data, w_strb);
                        when A_MCAST_HI =>
                            reg_mcast_hi <= strb_merge(reg_mcast_hi, w_data, w_strb);
                        when others =>
                            null;
                    end case;
                end if;
            end if;
        end process;
    end generate gen_mcast;

    gen_no_mcast : if MCAST_HASH_FILTER = 0 generate
        reg_mcast_lo <= (others => '0');
        reg_mcast_hi <= (others => '0');
    end generate gen_no_mcast;

    -- =========================================================================
    -- Read channel
    -- =========================================================================
    process (s_axi_aclk, s_axi_aresetn)
    begin
        if s_axi_aresetn = '0' then
            s_axi_arready_i <= '0';
            s_axi_rvalid_i  <= '0';
            s_axi_rdata     <= (others => '0');
        elsif rising_edge(s_axi_aclk) then
            if s_axi_arvalid = '1' and s_axi_rvalid_i = '0' and s_axi_arready_i = '0' then
                s_axi_arready_i <= '1';
                s_axi_rvalid_i  <= '1';

                case to_integer(unsigned(s_axi_araddr(ADDR_WIDTH-1 downto 2))) is  -- ADDR_WIDTH-2 bit index
                    when A_CTRL =>       s_axi_rdata <= x"00000" & "00" & reg_ctrl;
                    when A_STATUS =>     s_axi_rdata <= x"0000000" & mdio_cmd_dropped & mdio_busy
                                                        & sts_tx_fifo_busy & sts_tx_active;
                    when A_MAC_LO =>     s_axi_rdata <= reg_mac_lo;
                    when A_MAC_HI =>     s_axi_rdata <= x"0000" & reg_mac_hi;
                    when A_IP_ADDR =>    s_axi_rdata <= reg_ip_addr;
                    when A_SAF_DBG =>    s_axi_rdata <= x"0000" & dbg_saf;
                    when A_MDIO_CMD =>   s_axi_rdata <= x"0000" & '0' & reg_mdio_cmd;  -- bit 11 (go) reads 0 by storage
                    when A_MDIO_WDATA => s_axi_rdata <= x"0000" & reg_mdio_wdata;
                    when A_MDIO_RDATA => s_axi_rdata <= x"0000" & mdio_rdata;
                    when A_IRQ_EN =>     s_axi_rdata <= x"0000000" & '0' & reg_irq_en;
                    when A_IRQ_STATUS => s_axi_rdata <= x"0000000" & '0' & reg_irq_status;
                    when A_TX_FRAME =>   s_axi_rdata <= stat_tx_frame_cnt;
                    when A_TX_BYTE =>    s_axi_rdata <= stat_tx_byte_cnt;
                    when A_RX_FRAME =>   s_axi_rdata <= stat_rx_frame_cnt;
                    when A_RX_BYTE =>    s_axi_rdata <= stat_rx_byte_cnt;
                    when A_RX_ERR =>     s_axi_rdata <= stat_rx_err_cnt;
                    when A_SCRATCH =>    s_axi_rdata <= reg_scratch;
                    when A_VERSION =>    s_axi_rdata <= VERSION;
                    when A_CAPS =>       s_axi_rdata <= CAPS;
                    when A_MCAST_LO =>
                        if MCAST_HASH_FILTER /= 0 then
                            s_axi_rdata <= reg_mcast_lo;
                        else
                            s_axi_rdata <= (others => '0');
                        end if;
                    when A_MCAST_HI =>
                        if MCAST_HASH_FILTER /= 0 then
                            s_axi_rdata <= reg_mcast_hi;
                        else
                            s_axi_rdata <= (others => '0');
                        end if;
                    when A_RX_ERR_ALIGN =>      s_axi_rdata <= stat_rx_err_align_cnt;
                    when A_RX_ERR_OVERFLOW =>   s_axi_rdata <= stat_rx_err_overflow_cnt;
                    when A_RX_ERR_OVERSIZE =>   s_axi_rdata <= stat_rx_err_oversize_cnt;
                    when A_RX_BCAST =>          s_axi_rdata <= stat_rx_bcast_cnt;
                    when A_RX_MCAST =>          s_axi_rdata <= stat_rx_mcast_cnt;
                    when A_RX_SIZE_64 =>        s_axi_rdata <= stat_rx_size_64_cnt;
                    when A_RX_SIZE_65_127 =>    s_axi_rdata <= stat_rx_size_65_127_cnt;
                    when A_RX_SIZE_128_255 =>   s_axi_rdata <= stat_rx_size_128_255_cnt;
                    when A_RX_SIZE_256_511 =>   s_axi_rdata <= stat_rx_size_256_511_cnt;
                    when A_RX_SIZE_512_1023 =>  s_axi_rdata <= stat_rx_size_512_1023_cnt;
                    when A_RX_SIZE_1024_1518 => s_axi_rdata <= stat_rx_size_1024_1518_cnt;
                    when A_RX_SIZE_JUMBO =>     s_axi_rdata <= stat_rx_size_jumbo_cnt;
                    when A_RX_DROP =>           s_axi_rdata <= stat_rx_drop_cnt;
                    when A_RX_ERR_CSUM =>       s_axi_rdata <= stat_rx_err_csum_cnt;
                    when A_PAUSE_CTRL =>        s_axi_rdata <= x"0000000" & "00" & reg_pause_rx_en & '0';
                    when A_PAUSE_QUANTA =>      s_axi_rdata <= x"0000" & reg_pause_quanta;
                    when A_PAUSE_RX_CNT =>      s_axi_rdata <= stat_pause_rx_cnt;
                    when A_PAUSE_TX_CNT =>      s_axi_rdata <= stat_pause_tx_cnt;
                    when others =>              s_axi_rdata <= (others => '0');
                end case;
            else
                s_axi_arready_i <= '0';
            end if;

            if s_axi_rvalid_i = '1' and s_axi_rready = '1' then
                s_axi_rvalid_i <= '0';
            end if;
        end if;
    end process;

end architecture rtl;
