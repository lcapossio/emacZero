-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- test_sequencer.vhd - Hardware test FSM for emacZero on Arty A7
-- Drives AXI4-Lite CSR reads/writes, MDIO commands, sends a gratuitous ARP,
-- and reports results over UART.
-- VHDL port of fpga/arty_a7/rtl/test_sequencer.v (formally proven equivalent;
-- see sim/parity/).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity test_sequencer is
    generic (
        CLK_FREQ : integer := 100000000
    );
    port (
        clk            : in  std_logic;
        rst_n          : in  std_logic;
        phy_rst_done   : in  std_logic;                      -- PHY reset sequence complete

        -- ---- AXI4-Lite master ----
        m_axi_awaddr   : out std_logic_vector(7 downto 0);
        m_axi_awvalid  : out std_logic;
        m_axi_awready  : in  std_logic;
        m_axi_wdata    : out std_logic_vector(31 downto 0);
        m_axi_wstrb    : out std_logic_vector(3 downto 0);
        m_axi_wvalid   : out std_logic;
        m_axi_wready   : in  std_logic;
        m_axi_bvalid   : in  std_logic;
        m_axi_bready   : out std_logic;
        m_axi_araddr   : out std_logic_vector(7 downto 0);
        m_axi_arvalid  : out std_logic;
        m_axi_arready  : in  std_logic;
        m_axi_rdata    : in  std_logic_vector(31 downto 0);
        m_axi_rvalid   : in  std_logic;
        m_axi_rready   : out std_logic;

        -- ---- AXI4-Stream TX (for gratuitous ARP) ----
        tx_tdata       : out std_logic_vector(7 downto 0);
        tx_tvalid      : out std_logic;
        tx_tready      : in  std_logic;
        tx_tlast       : out std_logic;

        -- ---- UART TX ----
        uart_data      : out std_logic_vector(7 downto 0);
        uart_valid     : out std_logic;
        uart_busy      : in  std_logic;

        -- ---- Status outputs ----
        link_up        : out std_logic;
        phy_id_ok      : out std_logic;
        tx_done        : out std_logic;
        rx_done        : out std_logic;
        arp_tx_active  : out std_logic                       -- high while sequencer owns TX bus
    );
end entity test_sequencer;

architecture rtl of test_sequencer is

    -- =========================================================================
    -- CSR register offsets
    -- =========================================================================
    constant A_VERSION     : std_logic_vector(7 downto 0) := x"00";
    constant A_CTRL        : std_logic_vector(7 downto 0) := x"04";
    constant A_STATUS      : std_logic_vector(7 downto 0) := x"08";
    constant A_MDIO_CMD    : std_logic_vector(7 downto 0) := x"14";
    constant A_MDIO_WDATA  : std_logic_vector(7 downto 0) := x"18";
    constant A_MDIO_RDATA  : std_logic_vector(7 downto 0) := x"1C";
    constant A_TX_FRAME    : std_logic_vector(7 downto 0) := x"28";
    constant A_RX_FRAME    : std_logic_vector(7 downto 0) := x"30";
    constant A_RX_BYTE     : std_logic_vector(7 downto 0) := x"34";
    constant A_RX_ERR      : std_logic_vector(7 downto 0) := x"38";
    constant A_SCRATCH     : std_logic_vector(7 downto 0) := x"3C";
    constant A_RX_OVERFLOW : std_logic_vector(7 downto 0) := x"50";

    -- MDIO command encoding: [11] go, [10] write, [9:5] phy, [4:0] reg
    -- PHY addr = 1 for DP83848 on Arty
    constant MDIO_RD_PHYIDR1 : std_logic_vector(11 downto 0) := '1' & '0' & "00001" & "00010";  -- reg 2
    constant MDIO_RD_PHYIDR2 : std_logic_vector(11 downto 0) := '1' & '0' & "00001" & "00011";  -- reg 3
    constant MDIO_RD_BMSR    : std_logic_vector(11 downto 0) := '1' & '0' & "00001" & "00001";  -- reg 1
    -- BMCR (reg 0): enable/restart auto-negotiation. The DP83848 default
    -- advertisement includes 100BASE-TX full-duplex, which avoids host-side
    -- parallel-detect falling back to half-duplex.
    constant MDIO_WR_BMCR    : std_logic_vector(11 downto 0) := '1' & '1' & "00001" & "00000";  -- write, phy=1, reg=0
    constant MDIO_RD_BMCR    : std_logic_vector(11 downto 0) := '1' & '0' & "00001" & "00000";  -- read,  phy=1, reg=0
    constant BMCR_VALUE      : std_logic_vector(15 downto 0) := x"1200";  -- auto-neg enable + restart

    -- =========================================================================
    -- Main FSM
    -- =========================================================================
    constant S_WAIT_PHY         : std_logic_vector(5 downto 0) := "000000";  -- 0
    constant S_RD_VER           : std_logic_vector(5 downto 0) := "000001";  -- 1
    constant S_RD_VER_W         : std_logic_vector(5 downto 0) := "000010";  -- 2
    constant S_PRINT_VER        : std_logic_vector(5 downto 0) := "000011";  -- 3
    constant S_WR_SCR           : std_logic_vector(5 downto 0) := "000100";  -- 4
    constant S_WR_SCR_W         : std_logic_vector(5 downto 0) := "000101";  -- 5
    constant S_RD_SCR           : std_logic_vector(5 downto 0) := "000110";  -- 6
    constant S_RD_SCR_W         : std_logic_vector(5 downto 0) := "000111";  -- 7
    constant S_PRINT_SCR        : std_logic_vector(5 downto 0) := "001000";  -- 8
    constant S_MDIO_PHY1        : std_logic_vector(5 downto 0) := "001001";  -- 9
    constant S_MDIO_PHY1_W      : std_logic_vector(5 downto 0) := "001010";  -- 10
    constant S_MDIO_PHY1_P      : std_logic_vector(5 downto 0) := "001011";  -- 11
    constant S_MDIO_PHY1_R      : std_logic_vector(5 downto 0) := "001100";  -- 12
    constant S_MDIO_PHY1_RW     : std_logic_vector(5 downto 0) := "001101";  -- 13
    constant S_PRINT_PHY1       : std_logic_vector(5 downto 0) := "001110";  -- 14
    constant S_MDIO_PHY2        : std_logic_vector(5 downto 0) := "001111";  -- 15
    constant S_MDIO_PHY2_W      : std_logic_vector(5 downto 0) := "010000";  -- 16
    constant S_MDIO_PHY2_P      : std_logic_vector(5 downto 0) := "010001";  -- 17
    constant S_MDIO_PHY2_R      : std_logic_vector(5 downto 0) := "010010";  -- 18
    constant S_MDIO_PHY2_RW     : std_logic_vector(5 downto 0) := "010011";  -- 19
    constant S_PRINT_PHY2       : std_logic_vector(5 downto 0) := "010100";  -- 20
    constant S_MDIO_BMSR        : std_logic_vector(5 downto 0) := "010101";  -- 21
    constant S_MDIO_BMSR_W      : std_logic_vector(5 downto 0) := "010110";  -- 22
    constant S_MDIO_BMSR_P      : std_logic_vector(5 downto 0) := "010111";  -- 23
    constant S_MDIO_BMSR_R      : std_logic_vector(5 downto 0) := "011000";  -- 24
    constant S_MDIO_BMSR_RW     : std_logic_vector(5 downto 0) := "011001";  -- 25
    constant S_PRINT_LINK       : std_logic_vector(5 downto 0) := "011010";  -- 26
    constant S_EN_MAC           : std_logic_vector(5 downto 0) := "011011";  -- 27
    constant S_EN_MAC_W         : std_logic_vector(5 downto 0) := "011100";  -- 28
    constant S_SEND_ARP         : std_logic_vector(5 downto 0) := "011101";  -- 29
    constant S_SEND_ARP_D       : std_logic_vector(5 downto 0) := "011110";  -- 30
    constant S_CHK_TX           : std_logic_vector(5 downto 0) := "011111";  -- 31
    constant S_CHK_TX_W         : std_logic_vector(5 downto 0) := "100000";  -- 32
    constant S_PRINT_TX         : std_logic_vector(5 downto 0) := "100001";  -- 33
    constant S_WAIT_RX          : std_logic_vector(5 downto 0) := "100010";  -- 34
    constant S_CHK_RX           : std_logic_vector(5 downto 0) := "100011";  -- 35
    constant S_CHK_RX_W         : std_logic_vector(5 downto 0) := "100100";  -- 36
    constant S_PRINT_RX         : std_logic_vector(5 downto 0) := "100101";  -- 37
    constant S_PRINT_DONE       : std_logic_vector(5 downto 0) := "100110";  -- 38
    constant S_IDLE             : std_logic_vector(5 downto 0) := "100111";  -- 39
    -- BMCR write+readback test (MDIO write verification)
    constant S_MDIO_WR_BMCR     : std_logic_vector(5 downto 0) := "101000";  -- 40 write MDIO_WDATA then MDIO_CMD (write op)
    constant S_MDIO_WR_BMCR_W   : std_logic_vector(5 downto 0) := "101001";  -- 41 wait AXI write done
    constant S_MDIO_WR_BMCR_P   : std_logic_vector(5 downto 0) := "101010";  -- 42 poll STATUS until mdio_busy=0
    constant S_MDIO_WR_BMCR_R   : std_logic_vector(5 downto 0) := "101011";  -- 43 read STATUS
    constant S_MDIO_RD_BMCR     : std_logic_vector(5 downto 0) := "101100";  -- 44 trigger BMCR readback
    constant S_MDIO_RD_BMCR_W   : std_logic_vector(5 downto 0) := "101101";  -- 45
    constant S_MDIO_RD_BMCR_P   : std_logic_vector(5 downto 0) := "101110";  -- 46
    constant S_MDIO_RD_BMCR_R   : std_logic_vector(5 downto 0) := "101111";  -- 47
    constant S_MDIO_RD_BMCR_RW  : std_logic_vector(5 downto 0) := "110000";  -- 48
    constant S_PRINT_BMCR       : std_logic_vector(5 downto 0) := "110001";  -- 49
    -- Periodic stats dump (after DONE): every ~1s emit RXF/RXB/RXE/OVF
    -- lines for host-side throughput measurement.
    constant S_STAT_WAIT        : std_logic_vector(5 downto 0) := "110010";  -- 50
    constant S_STAT_RD_RXF      : std_logic_vector(5 downto 0) := "110011";  -- 51
    constant S_STAT_RD_RXF_W    : std_logic_vector(5 downto 0) := "110100";  -- 52
    constant S_STAT_PRINT_RXF   : std_logic_vector(5 downto 0) := "110101";  -- 53
    constant S_STAT_RD_RXB      : std_logic_vector(5 downto 0) := "110110";  -- 54
    constant S_STAT_RD_RXB_W    : std_logic_vector(5 downto 0) := "110111";  -- 55
    constant S_STAT_PRINT_RXB   : std_logic_vector(5 downto 0) := "111000";  -- 56
    constant S_STAT_RD_RXE      : std_logic_vector(5 downto 0) := "111001";  -- 57
    constant S_STAT_RD_RXE_W    : std_logic_vector(5 downto 0) := "111010";  -- 58
    constant S_STAT_PRINT_RXE   : std_logic_vector(5 downto 0) := "111011";  -- 59
    constant S_STAT_RD_OVF      : std_logic_vector(5 downto 0) := "111100";  -- 60
    constant S_STAT_RD_OVF_W    : std_logic_vector(5 downto 0) := "111101";  -- 61
    constant S_STAT_PRINT_OVF   : std_logic_vector(5 downto 0) := "111110";  -- 62

    signal state     : std_logic_vector(5 downto 0);
    signal rd_data_r : std_logic_vector(31 downto 0);
    signal phy1_id_r : std_logic_vector(15 downto 0);   -- explicit latch for PHY1 result used in phy_id_ok check
    signal wait_cnt  : unsigned(31 downto 0);
    signal arp_idx   : unsigned(7 downto 0);

    -- ARP frame: 42 bytes (Ethernet header + ARP payload)
    -- Gratuitous ARP: sender = target, broadcast destination
    -- MAC: 02:00:00:00:00:01, IP: 192.168.137.200 (0xC0A889C8)
    -- (The Verilog fills a reg array from an `initial` block and never writes
    -- it, so it is a ROM: a constant here.)
    type arp_frame_t is array (integer range 0 to 41) of std_logic_vector(7 downto 0);
    constant arp_frame : arp_frame_t := (
        -- Dst MAC: FF:FF:FF:FF:FF:FF (broadcast)
        x"FF", x"FF", x"FF", x"FF", x"FF", x"FF",
        -- Src MAC: 02:00:00:00:00:01
        x"02", x"00", x"00", x"00", x"00", x"01",
        -- EtherType: 0x0806 (ARP)
        x"08", x"06",
        -- ARP: HTYPE=1(Ethernet), PTYPE=0x0800(IPv4), HLEN=6, PLEN=4
        x"00", x"01",
        x"08", x"00",
        x"06", x"04",
        -- ARP opcode: 1 (request) - gratuitous: sender=target
        x"00", x"01",
        -- Sender MAC: 02:00:00:00:00:01
        x"02", x"00", x"00", x"00", x"00", x"01",
        -- Sender IP: 192.168.137.200
        x"C0", x"A8", x"89", x"C8",
        -- Target MAC: 00:00:00:00:00:00
        x"00", x"00", x"00", x"00", x"00", x"00",
        -- Target IP: 192.168.137.200 (gratuitous)
        x"C0", x"A8", x"89", x"C8"
    );

    -- Verilog `arp_frame[arp_idx]`. arp_idx only counts 0..41, so in operation
    -- this is a plain lookup. An index past word 41 is unreachable and reads x
    -- in Verilog; here it reads 0, one legal value of that x. The parity proof
    -- uses a golden with the same 0 (sim/parity/test_sequencer/gen_golden.py).
    function arp_byte(idx : unsigned(7 downto 0)) return std_logic_vector is
    begin
        if idx < 42 then
            return arp_frame(to_integer(idx));
        end if;
        return x"00";
    end function arp_byte;

    -- =========================================================================
    -- String printing
    -- =========================================================================
    signal print_buf        : std_logic_vector(255 downto 0);
    signal print_len        : unsigned(4 downto 0);
    signal print_idx        : unsigned(4 downto 0);
    signal printing         : std_logic;
    signal print_next_state : std_logic_vector(5 downto 0);

    -- Hex digit to ASCII
    function hex_char(nib : std_logic_vector(3 downto 0)) return std_logic_vector is
    begin
        if unsigned(nib) < 10 then
            return std_logic_vector(to_unsigned(16#30#, 8) + resize(unsigned(nib), 8));
        else
            return std_logic_vector(to_unsigned(16#41#, 8) + resize(unsigned(nib), 8)
                                    - to_unsigned(10, 8));
        end if;
    end function hex_char;

    -- =========================================================================
    -- AXI-Lite helper flags
    -- =========================================================================
    signal wr_done : std_logic;
    signal rd_done : std_logic;

    -- =========================================================================
    -- MDIO poll counter (wait for busy to clear)
    -- =========================================================================
    signal mdio_poll_cnt : unsigned(15 downto 0);
    constant MDIO_POLL_LIMIT : unsigned(15 downto 0) := to_unsigned(10000, 16); -- ~100us at 100MHz

    -- Outputs the FSM reads back
    signal uart_valid_i : std_logic;
    signal link_up_i    : std_logic;

begin

    wr_done <= m_axi_bvalid;
    rd_done <= m_axi_rvalid;

    uart_valid <= uart_valid_i;
    link_up    <= link_up_i;

    -- =========================================================================
    -- Main state machine
    -- =========================================================================
    process (clk, rst_n)

        -- Pack a 32-bit hex value + CRLF into print_buf (10 chars: XXXXXXXX\r\n)
        procedure setup_print_hex32(val : std_logic_vector(31 downto 0);
                                    nxt : std_logic_vector(5 downto 0)) is
        begin
            print_buf(255 downto 248) <= hex_char(val(31 downto 28));
            print_buf(247 downto 240) <= hex_char(val(27 downto 24));
            print_buf(239 downto 232) <= hex_char(val(23 downto 20));
            print_buf(231 downto 224) <= hex_char(val(19 downto 16));
            print_buf(223 downto 216) <= hex_char(val(15 downto 12));
            print_buf(215 downto 208) <= hex_char(val(11 downto 8));
            print_buf(207 downto 200) <= hex_char(val(7 downto 4));
            print_buf(199 downto 192) <= hex_char(val(3 downto 0));
            print_buf(191 downto 184) <= x"0D";
            print_buf(183 downto 176) <= x"0A";
            print_len <= to_unsigned(10, 5);
            print_idx <= to_unsigned(0, 5);
            printing  <= '1';
            print_next_state <= nxt;
        end procedure setup_print_hex32;

        -- Pack a 16-bit hex value + CRLF into print_buf (6 chars: XXXX\r\n)
        procedure setup_print_hex16(val : std_logic_vector(15 downto 0);
                                    nxt : std_logic_vector(5 downto 0)) is
        begin
            print_buf(255 downto 248) <= hex_char(val(15 downto 12));
            print_buf(247 downto 240) <= hex_char(val(11 downto 8));
            print_buf(239 downto 232) <= hex_char(val(7 downto 4));
            print_buf(231 downto 224) <= hex_char(val(3 downto 0));
            print_buf(223 downto 216) <= x"0D";  -- CR
            print_buf(215 downto 208) <= x"0A";  -- LF
            print_len <= to_unsigned(6, 5);
            print_idx <= to_unsigned(0, 5);
            printing  <= '1';
            print_next_state <= nxt;
        end procedure setup_print_hex16;

    begin
        if rst_n = '0' then
            state          <= S_WAIT_PHY;
            m_axi_awaddr   <= x"00";
            m_axi_awvalid  <= '0';
            m_axi_wdata    <= x"00000000";
            m_axi_wstrb    <= x"F";
            m_axi_wvalid   <= '0';
            m_axi_bready   <= '0';
            m_axi_araddr   <= x"00";
            m_axi_arvalid  <= '0';
            m_axi_rready   <= '0';
            tx_tdata       <= x"00";
            tx_tvalid      <= '0';
            tx_tlast       <= '0';
            uart_data      <= x"00";
            uart_valid_i   <= '0';
            link_up_i      <= '0';
            phy_id_ok      <= '0';
            tx_done        <= '0';
            rx_done        <= '0';
            arp_tx_active  <= '1';
            rd_data_r      <= x"00000000";
            phy1_id_r      <= x"0000";
            wait_cnt       <= (others => '0');
            arp_idx        <= (others => '0');
            printing       <= '0';
            print_buf      <= (others => '0');
            print_len      <= (others => '0');
            print_idx      <= (others => '0');
            print_next_state <= S_IDLE;
            mdio_poll_cnt  <= (others => '0');
        elsif rising_edge(clk) then
            -- Default deassert handshakes
            uart_valid_i <= '0';

            -- String printer
            if printing = '1' then
                if uart_busy = '0' and uart_valid_i = '0' then
                    uart_data    <= print_buf(255 downto 248);
                    uart_valid_i <= '1';
                    print_buf    <= print_buf(247 downto 0) & x"00";
                    print_idx    <= print_idx + 1;
                    if print_idx = print_len - 1 then
                        printing <= '0';
                        state    <= print_next_state;
                    end if;
                end if;
            else

            case state is
                -- =============================================================
                when S_WAIT_PHY =>
                    if phy_rst_done = '1' then
                        -- Print "VER: "
                        print_buf(255 downto 248) <= x"56"; -- V
                        print_buf(247 downto 240) <= x"45"; -- E
                        print_buf(239 downto 232) <= x"52"; -- R
                        print_buf(231 downto 224) <= x"3A"; -- :
                        print_buf(223 downto 216) <= x"20"; -- space
                        print_len <= to_unsigned(5, 5);
                        print_idx <= to_unsigned(0, 5);
                        printing  <= '1';
                        print_next_state <= S_RD_VER;
                    end if;

                -- --- VERSION read ---
                when S_RD_VER =>
                    m_axi_araddr  <= A_VERSION;
                    m_axi_arvalid <= '1';
                    m_axi_rready  <= '1';
                    state <= S_RD_VER_W;
                when S_RD_VER_W =>
                    if m_axi_arready = '1' then m_axi_arvalid <= '0'; end if;
                    if rd_done = '1' then
                        rd_data_r     <= m_axi_rdata;
                        m_axi_rready  <= '0';
                        state <= S_PRINT_VER;
                    end if;
                when S_PRINT_VER =>
                    -- Print hex32 as 8 chars + CRLF
                    print_buf(255 downto 248) <= hex_char(rd_data_r(31 downto 28));
                    print_buf(247 downto 240) <= hex_char(rd_data_r(27 downto 24));
                    print_buf(239 downto 232) <= hex_char(rd_data_r(23 downto 20));
                    print_buf(231 downto 224) <= hex_char(rd_data_r(19 downto 16));
                    print_buf(223 downto 216) <= hex_char(rd_data_r(15 downto 12));
                    print_buf(215 downto 208) <= hex_char(rd_data_r(11 downto 8));
                    print_buf(207 downto 200) <= hex_char(rd_data_r(7 downto 4));
                    print_buf(199 downto 192) <= hex_char(rd_data_r(3 downto 0));
                    print_buf(191 downto 184) <= x"0D";
                    print_buf(183 downto 176) <= x"0A";
                    print_len <= to_unsigned(10, 5);
                    print_idx <= to_unsigned(0, 5);
                    printing  <= '1';
                    print_next_state <= S_WR_SCR;

                -- --- SCRATCH write ---
                when S_WR_SCR =>
                    m_axi_awaddr  <= A_SCRATCH;
                    m_axi_awvalid <= '1';
                    m_axi_wdata   <= x"DEADBEEF";
                    m_axi_wstrb   <= x"F";
                    m_axi_wvalid  <= '1';
                    m_axi_bready  <= '1';
                    state <= S_WR_SCR_W;
                when S_WR_SCR_W =>
                    if m_axi_awready = '1' then m_axi_awvalid <= '0'; end if;
                    if m_axi_wready = '1'  then m_axi_wvalid  <= '0'; end if;
                    if wr_done = '1' then
                        m_axi_bready <= '0';
                        state <= S_RD_SCR;
                    end if;
                when S_RD_SCR =>
                    m_axi_araddr  <= A_SCRATCH;
                    m_axi_arvalid <= '1';
                    m_axi_rready  <= '1';
                    state <= S_RD_SCR_W;
                when S_RD_SCR_W =>
                    if m_axi_arready = '1' then m_axi_arvalid <= '0'; end if;
                    if rd_done = '1' then
                        rd_data_r    <= m_axi_rdata;
                        m_axi_rready <= '0';
                        -- Print "SCR: "
                        print_buf(255 downto 248) <= x"53"; -- S
                        print_buf(247 downto 240) <= x"43"; -- C
                        print_buf(239 downto 232) <= x"52"; -- R
                        print_buf(231 downto 224) <= x"3A"; -- :
                        print_buf(223 downto 216) <= x"20"; -- space
                        print_len <= to_unsigned(5, 5);
                        print_idx <= to_unsigned(0, 5);
                        printing  <= '1';
                        print_next_state <= S_PRINT_SCR;
                    end if;
                when S_PRINT_SCR =>
                    print_buf(255 downto 248) <= hex_char(rd_data_r(31 downto 28));
                    print_buf(247 downto 240) <= hex_char(rd_data_r(27 downto 24));
                    print_buf(239 downto 232) <= hex_char(rd_data_r(23 downto 20));
                    print_buf(231 downto 224) <= hex_char(rd_data_r(19 downto 16));
                    print_buf(223 downto 216) <= hex_char(rd_data_r(15 downto 12));
                    print_buf(215 downto 208) <= hex_char(rd_data_r(11 downto 8));
                    print_buf(207 downto 200) <= hex_char(rd_data_r(7 downto 4));
                    print_buf(199 downto 192) <= hex_char(rd_data_r(3 downto 0));
                    print_buf(191 downto 184) <= x"0D";
                    print_buf(183 downto 176) <= x"0A";
                    print_len <= to_unsigned(10, 5);
                    print_idx <= to_unsigned(0, 5);
                    printing  <= '1';
                    print_next_state <= S_MDIO_PHY1;

                -- --- MDIO read PHY ID1 (reg 2) ---
                when S_MDIO_PHY1 =>
                    m_axi_awaddr  <= A_MDIO_CMD;
                    m_axi_awvalid <= '1';
                    m_axi_wdata   <= x"00000" & MDIO_RD_PHYIDR1;
                    m_axi_wstrb   <= x"F";
                    m_axi_wvalid  <= '1';
                    m_axi_bready  <= '1';
                    state <= S_MDIO_PHY1_W;
                when S_MDIO_PHY1_W =>
                    if m_axi_awready = '1' then m_axi_awvalid <= '0'; end if;
                    if m_axi_wready = '1'  then m_axi_wvalid  <= '0'; end if;
                    if wr_done = '1' then
                        m_axi_bready  <= '0';
                        mdio_poll_cnt <= (others => '0');
                        state <= S_MDIO_PHY1_P;
                    end if;
                when S_MDIO_PHY1_P =>
                    -- Poll STATUS register for mdio_busy (bit 2) to clear
                    mdio_poll_cnt <= mdio_poll_cnt + 1;
                    if mdio_poll_cnt(9 downto 0) = 0 then -- every 1024 cycles
                        m_axi_araddr  <= A_STATUS;
                        m_axi_arvalid <= '1';
                        m_axi_rready  <= '1';
                        state <= S_MDIO_PHY1_R;
                    end if;
                when S_MDIO_PHY1_R =>
                    if m_axi_arready = '1' then m_axi_arvalid <= '0'; end if;
                    if rd_done = '1' then
                        m_axi_rready <= '0';
                        if m_axi_rdata(2) = '0' then
                            -- MDIO done, read result
                            m_axi_araddr  <= A_MDIO_RDATA;
                            m_axi_arvalid <= '1';
                            m_axi_rready  <= '1';
                            state <= S_MDIO_PHY1_RW;
                        else
                            state <= S_MDIO_PHY1_P;
                        end if;
                    end if;
                when S_MDIO_PHY1_RW =>
                    if m_axi_arready = '1' then m_axi_arvalid <= '0'; end if;
                    if rd_done = '1' then
                        rd_data_r    <= m_axi_rdata;
                        phy1_id_r    <= m_axi_rdata(15 downto 0);
                        m_axi_rready <= '0';
                        -- Print "PHY1: "
                        print_buf(255 downto 248) <= x"50"; -- P
                        print_buf(247 downto 240) <= x"48"; -- H
                        print_buf(239 downto 232) <= x"59"; -- Y
                        print_buf(231 downto 224) <= x"31"; -- 1
                        print_buf(223 downto 216) <= x"3A"; -- :
                        print_buf(215 downto 208) <= x"20"; -- space
                        print_len <= to_unsigned(6, 5);
                        print_idx <= to_unsigned(0, 5);
                        printing  <= '1';
                        print_next_state <= S_PRINT_PHY1;
                    end if;
                when S_PRINT_PHY1 =>
                    setup_print_hex16(rd_data_r(15 downto 0), S_MDIO_PHY2);

                -- --- MDIO read PHY ID2 (reg 3) - same pattern ---
                when S_MDIO_PHY2 =>
                    m_axi_awaddr  <= A_MDIO_CMD;
                    m_axi_awvalid <= '1';
                    m_axi_wdata   <= x"00000" & MDIO_RD_PHYIDR2;
                    m_axi_wstrb   <= x"F";
                    m_axi_wvalid  <= '1';
                    m_axi_bready  <= '1';
                    state <= S_MDIO_PHY2_W;
                when S_MDIO_PHY2_W =>
                    if m_axi_awready = '1' then m_axi_awvalid <= '0'; end if;
                    if m_axi_wready = '1'  then m_axi_wvalid  <= '0'; end if;
                    if wr_done = '1' then
                        m_axi_bready  <= '0';
                        mdio_poll_cnt <= (others => '0');
                        state <= S_MDIO_PHY2_P;
                    end if;
                when S_MDIO_PHY2_P =>
                    mdio_poll_cnt <= mdio_poll_cnt + 1;
                    if mdio_poll_cnt(9 downto 0) = 0 then
                        m_axi_araddr  <= A_STATUS;
                        m_axi_arvalid <= '1';
                        m_axi_rready  <= '1';
                        state <= S_MDIO_PHY2_R;
                    end if;
                when S_MDIO_PHY2_R =>
                    if m_axi_arready = '1' then m_axi_arvalid <= '0'; end if;
                    if rd_done = '1' then
                        m_axi_rready <= '0';
                        if m_axi_rdata(2) = '0' then
                            m_axi_araddr  <= A_MDIO_RDATA;
                            m_axi_arvalid <= '1';
                            m_axi_rready  <= '1';
                            state <= S_MDIO_PHY2_RW;
                        else
                            state <= S_MDIO_PHY2_P;
                        end if;
                    end if;
                when S_MDIO_PHY2_RW =>
                    if m_axi_arready = '1' then m_axi_arvalid <= '0'; end if;
                    if rd_done = '1' then
                        rd_data_r    <= m_axi_rdata;
                        m_axi_rready <= '0';
                        -- Check PHY ID: PHYIDR1 should have been 0x2000
                        -- phy1_id_r was latched when PHY1 completed; compare both here
                        if phy1_id_r = x"2000" and
                           m_axi_rdata(15 downto 4) = x"5C9" then
                            phy_id_ok <= '1';
                        else
                            phy_id_ok <= '0';
                        end if;
                        print_buf(255 downto 248) <= x"50"; -- P
                        print_buf(247 downto 240) <= x"48"; -- H
                        print_buf(239 downto 232) <= x"59"; -- Y
                        print_buf(231 downto 224) <= x"32"; -- 2
                        print_buf(223 downto 216) <= x"3A"; -- :
                        print_buf(215 downto 208) <= x"20";
                        print_len <= to_unsigned(6, 5);
                        print_idx <= to_unsigned(0, 5);
                        printing  <= '1';
                        print_next_state <= S_PRINT_PHY2;
                    end if;
                when S_PRINT_PHY2 =>
                    setup_print_hex16(rd_data_r(15 downto 0), S_MDIO_WR_BMCR);

                -- --- MDIO read BMSR (reg 1) for link status ---
                when S_MDIO_BMSR =>
                    m_axi_awaddr  <= A_MDIO_CMD;
                    m_axi_awvalid <= '1';
                    m_axi_wdata   <= x"00000" & MDIO_RD_BMSR;
                    m_axi_wstrb   <= x"F";
                    m_axi_wvalid  <= '1';
                    m_axi_bready  <= '1';
                    state <= S_MDIO_BMSR_W;
                when S_MDIO_BMSR_W =>
                    if m_axi_awready = '1' then m_axi_awvalid <= '0'; end if;
                    if m_axi_wready = '1'  then m_axi_wvalid  <= '0'; end if;
                    if wr_done = '1' then
                        m_axi_bready  <= '0';
                        mdio_poll_cnt <= (others => '0');
                        state <= S_MDIO_BMSR_P;
                    end if;
                when S_MDIO_BMSR_P =>
                    wait_cnt      <= wait_cnt + 1;
                    mdio_poll_cnt <= mdio_poll_cnt + 1;
                    if mdio_poll_cnt(9 downto 0) = 0 then
                        m_axi_araddr  <= A_STATUS;
                        m_axi_arvalid <= '1';
                        m_axi_rready  <= '1';
                        state <= S_MDIO_BMSR_R;
                    end if;
                when S_MDIO_BMSR_R =>
                    wait_cnt <= wait_cnt + 1;
                    if m_axi_arready = '1' then m_axi_arvalid <= '0'; end if;
                    if rd_done = '1' then
                        m_axi_rready <= '0';
                        if m_axi_rdata(2) = '0' then
                            m_axi_araddr  <= A_MDIO_RDATA;
                            m_axi_arvalid <= '1';
                            m_axi_rready  <= '1';
                            state <= S_MDIO_BMSR_RW;
                        else
                            state <= S_MDIO_BMSR_P;
                        end if;
                    end if;
                when S_MDIO_BMSR_RW =>
                    if m_axi_arready = '1' then m_axi_arvalid <= '0'; end if;
                    if rd_done = '1' then
                        rd_data_r    <= m_axi_rdata;
                        m_axi_rready <= '0';
                        if m_axi_rdata(2) = '1' then
                            -- Link is up
                            link_up_i <= '1';
                            state     <= S_PRINT_LINK;
                        elsif wait_cnt < 300000000 then
                            -- No link yet, retry after brief delay (3s total timeout)
                            state <= S_MDIO_BMSR;
                        else
                            -- Timeout - no link
                            link_up_i <= '0';
                            state     <= S_PRINT_LINK;
                        end if;
                    end if;
                when S_PRINT_LINK =>
                    if link_up_i = '1' then
                        -- "LINK: UP\r\n"
                        print_buf(255 downto 248) <= x"4C"; print_buf(247 downto 240) <= x"49";
                        print_buf(239 downto 232) <= x"4E"; print_buf(231 downto 224) <= x"4B";
                        print_buf(223 downto 216) <= x"3A"; print_buf(215 downto 208) <= x"20";
                        print_buf(207 downto 200) <= x"55"; print_buf(199 downto 192) <= x"50";
                        print_buf(191 downto 184) <= x"0D"; print_buf(183 downto 176) <= x"0A";
                        print_len <= to_unsigned(10, 5);
                    else
                        -- "LINK: DN\r\n"
                        print_buf(255 downto 248) <= x"4C"; print_buf(247 downto 240) <= x"49";
                        print_buf(239 downto 232) <= x"4E"; print_buf(231 downto 224) <= x"4B";
                        print_buf(223 downto 216) <= x"3A"; print_buf(215 downto 208) <= x"20";
                        print_buf(207 downto 200) <= x"44"; print_buf(199 downto 192) <= x"4E";
                        print_buf(191 downto 184) <= x"0D"; print_buf(183 downto 176) <= x"0A";
                        print_len <= to_unsigned(10, 5);
                    end if;
                    print_idx <= to_unsigned(0, 5);
                    printing  <= '1';
                    print_next_state <= S_EN_MAC;

                -- --- Enable MAC (tx+rx+promisc) ---
                when S_EN_MAC =>
                    m_axi_awaddr  <= A_CTRL;
                    m_axi_awvalid <= '1';
                    m_axi_wdata   <= x"00000007";
                    m_axi_wstrb   <= x"F";
                    m_axi_wvalid  <= '1';
                    m_axi_bready  <= '1';
                    state <= S_EN_MAC_W;
                when S_EN_MAC_W =>
                    if m_axi_awready = '1' then m_axi_awvalid <= '0'; end if;
                    if m_axi_wready = '1'  then m_axi_wvalid  <= '0'; end if;
                    if wr_done = '1' then
                        m_axi_bready <= '0';
                        if link_up_i = '1' then
                            arp_idx <= (others => '0');
                            state   <= S_SEND_ARP;
                        else
                            state <= S_PRINT_DONE;
                        end if;
                    end if;

                -- --- Send gratuitous ARP ---
                when S_SEND_ARP =>
                    tx_tdata  <= arp_byte(arp_idx);
                    tx_tvalid <= '1';
                    if arp_idx = 41 then
                        tx_tlast <= '1';
                    else
                        tx_tlast <= '0';
                    end if;
                    state <= S_SEND_ARP_D;
                when S_SEND_ARP_D =>
                    if tx_tready = '1' then
                        if arp_idx = 41 then
                            tx_tvalid <= '0';
                            tx_tlast  <= '0';
                            -- Wait for frame to go through
                            wait_cnt <= (others => '0');
                            state    <= S_CHK_TX;
                        else
                            arp_idx <= arp_idx + 1;
                            state   <= S_SEND_ARP;
                        end if;
                    end if;

                -- --- Check TX counter ---
                when S_CHK_TX =>
                    wait_cnt <= wait_cnt + 1;
                    if wait_cnt > 500000 then -- 5ms wait
                        m_axi_araddr  <= A_TX_FRAME;
                        m_axi_arvalid <= '1';
                        m_axi_rready  <= '1';
                        state <= S_CHK_TX_W;
                    end if;
                when S_CHK_TX_W =>
                    if m_axi_arready = '1' then m_axi_arvalid <= '0'; end if;
                    if rd_done = '1' then
                        rd_data_r    <= m_axi_rdata;
                        m_axi_rready <= '0';
                        if unsigned(m_axi_rdata) /= 0 then
                            tx_done <= '1';
                        else
                            tx_done <= '0';
                        end if;
                        arp_tx_active <= '0'; -- hand TX to arp_responder
                        -- "TX: "
                        print_buf(255 downto 248) <= x"54"; print_buf(247 downto 240) <= x"58";
                        print_buf(239 downto 232) <= x"3A"; print_buf(231 downto 224) <= x"20";
                        print_len <= to_unsigned(4, 5);
                        print_idx <= to_unsigned(0, 5);
                        printing  <= '1';
                        print_next_state <= S_PRINT_TX;
                    end if;
                when S_PRINT_TX =>
                    wait_cnt <= (others => '0');  -- reset for RX wait timeout
                    setup_print_hex16(rd_data_r(15 downto 0), S_WAIT_RX);

                -- --- Wait for RX frame ---
                when S_WAIT_RX =>
                    wait_cnt <= wait_cnt + 1;
                    if wait_cnt > 200000000 then -- 2s timeout
                        m_axi_araddr  <= A_RX_FRAME;
                        m_axi_arvalid <= '1';
                        m_axi_rready  <= '1';
                        state <= S_CHK_RX;
                    elsif wait_cnt(19 downto 0) = 0 then
                        -- Poll every ~10ms
                        m_axi_araddr  <= A_RX_FRAME;
                        m_axi_arvalid <= '1';
                        m_axi_rready  <= '1';
                        state <= S_CHK_RX;
                    end if;
                when S_CHK_RX =>
                    if m_axi_arready = '1' then m_axi_arvalid <= '0'; end if;
                    if rd_done = '1' then
                        rd_data_r    <= m_axi_rdata;
                        m_axi_rready <= '0';
                        if unsigned(m_axi_rdata) /= 0 then
                            rx_done <= '1';
                            -- "RX: "
                            print_buf(255 downto 248) <= x"52"; print_buf(247 downto 240) <= x"58";
                            print_buf(239 downto 232) <= x"3A"; print_buf(231 downto 224) <= x"20";
                            print_len <= to_unsigned(4, 5);
                            print_idx <= to_unsigned(0, 5);
                            printing  <= '1';
                            print_next_state <= S_PRINT_RX;
                        elsif wait_cnt > 200000000 then
                            -- Timeout
                            print_buf(255 downto 248) <= x"52"; print_buf(247 downto 240) <= x"58";
                            print_buf(239 downto 232) <= x"3A"; print_buf(231 downto 224) <= x"20";
                            print_buf(223 downto 216) <= x"54"; print_buf(215 downto 208) <= x"4F";  -- TO
                            print_buf(207 downto 200) <= x"0D"; print_buf(199 downto 192) <= x"0A";
                            print_len <= to_unsigned(8, 5);
                            print_idx <= to_unsigned(0, 5);
                            printing  <= '1';
                            print_next_state <= S_PRINT_DONE;
                        else
                            state <= S_WAIT_RX;
                        end if;
                    end if;
                when S_PRINT_RX =>
                    setup_print_hex16(rd_data_r(15 downto 0), S_PRINT_DONE);

                -- --- MDIO write verification: write BMCR loopback, read back ---
                when S_MDIO_WR_BMCR =>
                    -- First write WDATA, then CMD in same AXI write (CMD triggers go)
                    m_axi_awaddr  <= A_MDIO_WDATA;
                    m_axi_awvalid <= '1';
                    m_axi_wdata   <= x"0000" & BMCR_VALUE;
                    m_axi_wstrb   <= x"F";
                    m_axi_wvalid  <= '1';
                    m_axi_bready  <= '1';
                    state <= S_MDIO_WR_BMCR_W;
                when S_MDIO_WR_BMCR_W =>
                    if m_axi_awready = '1' then m_axi_awvalid <= '0'; end if;
                    if m_axi_wready = '1'  then m_axi_wvalid  <= '0'; end if;
                    if wr_done = '1' then
                        m_axi_bready  <= '0';
                        -- Now send the CMD (write=1, phy=1, reg=0, go=1)
                        m_axi_awaddr  <= A_MDIO_CMD;
                        m_axi_awvalid <= '1';
                        m_axi_wdata   <= x"00000" & MDIO_WR_BMCR;
                        m_axi_wstrb   <= x"F";
                        m_axi_wvalid  <= '1';
                        m_axi_bready  <= '1';
                        mdio_poll_cnt <= to_unsigned(1, 16);  -- start at 1 so first poll waits for CMD write to complete
                        state <= S_MDIO_WR_BMCR_P;
                    end if;
                when S_MDIO_WR_BMCR_P =>
                    if m_axi_awready = '1' then m_axi_awvalid <= '0'; end if;
                    if m_axi_wready = '1'  then m_axi_wvalid  <= '0'; end if;
                    if wr_done = '1'       then m_axi_bready  <= '0'; end if;
                    mdio_poll_cnt <= mdio_poll_cnt + 1;
                    if mdio_poll_cnt(9 downto 0) = 0 then
                        m_axi_araddr  <= A_STATUS;
                        m_axi_arvalid <= '1';
                        m_axi_rready  <= '1';
                        state <= S_MDIO_WR_BMCR_R;
                    end if;
                when S_MDIO_WR_BMCR_R =>
                    if m_axi_arready = '1' then m_axi_arvalid <= '0'; end if;
                    if rd_done = '1' then
                        m_axi_rready <= '0';
                        if m_axi_rdata(2) = '0' then
                            state <= S_MDIO_RD_BMCR;
                        else
                            state <= S_MDIO_WR_BMCR_P;
                        end if;
                    end if;
                -- Read BMCR back to verify write
                when S_MDIO_RD_BMCR =>
                    m_axi_awaddr  <= A_MDIO_CMD;
                    m_axi_awvalid <= '1';
                    m_axi_wdata   <= x"00000" & MDIO_RD_BMCR;
                    m_axi_wstrb   <= x"F";
                    m_axi_wvalid  <= '1';
                    m_axi_bready  <= '1';
                    state <= S_MDIO_RD_BMCR_W;
                when S_MDIO_RD_BMCR_W =>
                    if m_axi_awready = '1' then m_axi_awvalid <= '0'; end if;
                    if m_axi_wready = '1'  then m_axi_wvalid  <= '0'; end if;
                    if wr_done = '1' then
                        m_axi_bready  <= '0';
                        mdio_poll_cnt <= (others => '0');
                        state <= S_MDIO_RD_BMCR_P;
                    end if;
                when S_MDIO_RD_BMCR_P =>
                    mdio_poll_cnt <= mdio_poll_cnt + 1;
                    if mdio_poll_cnt(9 downto 0) = 0 then
                        m_axi_araddr  <= A_STATUS;
                        m_axi_arvalid <= '1';
                        m_axi_rready  <= '1';
                        state <= S_MDIO_RD_BMCR_R;
                    end if;
                when S_MDIO_RD_BMCR_R =>
                    if m_axi_arready = '1' then m_axi_arvalid <= '0'; end if;
                    if rd_done = '1' then
                        m_axi_rready <= '0';
                        if m_axi_rdata(2) = '0' then
                            m_axi_araddr  <= A_MDIO_RDATA;
                            m_axi_arvalid <= '1';
                            m_axi_rready  <= '1';
                            state <= S_MDIO_RD_BMCR_RW;
                        else
                            state <= S_MDIO_RD_BMCR_P;
                        end if;
                    end if;
                when S_MDIO_RD_BMCR_RW =>
                    if m_axi_arready = '1' then m_axi_arvalid <= '0'; end if;
                    if rd_done = '1' then
                        rd_data_r    <= m_axi_rdata;
                        m_axi_rready <= '0';
                        -- Print "BMCR: "
                        print_buf(255 downto 248) <= x"42"; -- B
                        print_buf(247 downto 240) <= x"4D"; -- M
                        print_buf(239 downto 232) <= x"43"; -- C
                        print_buf(231 downto 224) <= x"52"; -- R
                        print_buf(223 downto 216) <= x"3A"; -- :
                        print_buf(215 downto 208) <= x"20"; -- space
                        print_len <= to_unsigned(6, 5);
                        print_idx <= to_unsigned(0, 5);
                        printing  <= '1';
                        print_next_state <= S_PRINT_BMCR;
                    end if;
                when S_PRINT_BMCR =>
                    wait_cnt <= (others => '0');  -- reset link-up timeout counter
                    setup_print_hex16(rd_data_r(15 downto 0), S_MDIO_BMSR);

                -- --- Done ---
                when S_PRINT_DONE =>
                    -- "DONE\r\n"
                    print_buf(255 downto 248) <= x"44"; print_buf(247 downto 240) <= x"4F";
                    print_buf(239 downto 232) <= x"4E"; print_buf(231 downto 224) <= x"45";
                    print_buf(223 downto 216) <= x"0D"; print_buf(215 downto 208) <= x"0A";
                    print_len <= to_unsigned(6, 5);
                    print_idx <= to_unsigned(0, 5);
                    printing  <= '1';
                    print_next_state <= S_STAT_WAIT;
                    wait_cnt <= (others => '0');

                -- ========== Periodic stats dump (~1s cadence) ==========
                -- Lines: "RXF: XXXXXXXX", "RXB: XXXXXXXX", "RXE: XXXXXXXX",
                --        "OVF: XXXXXXXX". Host udp_throughput.py parses and
                --        computes Mbps / pps / loss across windows.
                when S_STAT_WAIT =>
                    wait_cnt <= wait_cnt + 1;
                    if wait_cnt >= 100000000 then
                        wait_cnt <= (others => '0');
                        state    <= S_STAT_RD_RXF;
                    end if;

                when S_STAT_RD_RXF =>
                    m_axi_araddr  <= A_RX_FRAME;
                    m_axi_arvalid <= '1';
                    m_axi_rready  <= '1';
                    state         <= S_STAT_RD_RXF_W;
                when S_STAT_RD_RXF_W =>
                    if m_axi_arready = '1' then m_axi_arvalid <= '0'; end if;
                    if rd_done = '1' then
                        rd_data_r    <= m_axi_rdata;
                        m_axi_rready <= '0';
                        -- "RXF: " (5 chars)
                        print_buf(255 downto 248) <= x"52"; print_buf(247 downto 240) <= x"58";
                        print_buf(239 downto 232) <= x"46"; print_buf(231 downto 224) <= x"3A";
                        print_buf(223 downto 216) <= x"20";
                        print_len <= to_unsigned(5, 5);
                        print_idx <= to_unsigned(0, 5);
                        printing  <= '1';
                        print_next_state <= S_STAT_PRINT_RXF;
                    end if;
                when S_STAT_PRINT_RXF => setup_print_hex32(rd_data_r, S_STAT_RD_RXB);

                when S_STAT_RD_RXB =>
                    m_axi_araddr  <= A_RX_BYTE;
                    m_axi_arvalid <= '1';
                    m_axi_rready  <= '1';
                    state         <= S_STAT_RD_RXB_W;
                when S_STAT_RD_RXB_W =>
                    if m_axi_arready = '1' then m_axi_arvalid <= '0'; end if;
                    if rd_done = '1' then
                        rd_data_r    <= m_axi_rdata;
                        m_axi_rready <= '0';
                        -- "RXB: "
                        print_buf(255 downto 248) <= x"52"; print_buf(247 downto 240) <= x"58";
                        print_buf(239 downto 232) <= x"42"; print_buf(231 downto 224) <= x"3A";
                        print_buf(223 downto 216) <= x"20";
                        print_len <= to_unsigned(5, 5);
                        print_idx <= to_unsigned(0, 5);
                        printing  <= '1';
                        print_next_state <= S_STAT_PRINT_RXB;
                    end if;
                when S_STAT_PRINT_RXB => setup_print_hex32(rd_data_r, S_STAT_RD_RXE);

                when S_STAT_RD_RXE =>
                    m_axi_araddr  <= A_RX_ERR;
                    m_axi_arvalid <= '1';
                    m_axi_rready  <= '1';
                    state         <= S_STAT_RD_RXE_W;
                when S_STAT_RD_RXE_W =>
                    if m_axi_arready = '1' then m_axi_arvalid <= '0'; end if;
                    if rd_done = '1' then
                        rd_data_r    <= m_axi_rdata;
                        m_axi_rready <= '0';
                        -- "RXE: "
                        print_buf(255 downto 248) <= x"52"; print_buf(247 downto 240) <= x"58";
                        print_buf(239 downto 232) <= x"45"; print_buf(231 downto 224) <= x"3A";
                        print_buf(223 downto 216) <= x"20";
                        print_len <= to_unsigned(5, 5);
                        print_idx <= to_unsigned(0, 5);
                        printing  <= '1';
                        print_next_state <= S_STAT_PRINT_RXE;
                    end if;
                when S_STAT_PRINT_RXE => setup_print_hex32(rd_data_r, S_STAT_RD_OVF);

                when S_STAT_RD_OVF =>
                    m_axi_araddr  <= A_RX_OVERFLOW;
                    m_axi_arvalid <= '1';
                    m_axi_rready  <= '1';
                    state         <= S_STAT_RD_OVF_W;
                when S_STAT_RD_OVF_W =>
                    if m_axi_arready = '1' then m_axi_arvalid <= '0'; end if;
                    if rd_done = '1' then
                        rd_data_r    <= m_axi_rdata;
                        m_axi_rready <= '0';
                        -- "OVF: "
                        print_buf(255 downto 248) <= x"4F"; print_buf(247 downto 240) <= x"56";
                        print_buf(239 downto 232) <= x"46"; print_buf(231 downto 224) <= x"3A";
                        print_buf(223 downto 216) <= x"20";
                        print_len <= to_unsigned(5, 5);
                        print_idx <= to_unsigned(0, 5);
                        printing  <= '1';
                        print_next_state <= S_STAT_PRINT_OVF;
                    end if;
                when S_STAT_PRINT_OVF => setup_print_hex32(rd_data_r, S_STAT_WAIT);

                when S_IDLE =>
                    -- Reachable only via the default branch; identical to
                    -- S_STAT_WAIT semantics so we never get stuck.
                    state <= S_STAT_WAIT;

                when others => state <= S_IDLE;
            end case;

            end if; -- !printing
        end if;
    end process;

end architecture rtl;
