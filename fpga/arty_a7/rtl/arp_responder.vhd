-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- arp_responder.vhd - Minimal ARP reply engine
-- Captures incoming Ethernet frames, detects ARP requests for our IP,
-- and sends ARP replies. Makes the board pingable on the network.
-- VHDL port of fpga/arty_a7/rtl/arp_responder.v (formally proven equivalent;
-- see sim/parity/).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity arp_responder is
    port (
        clk            : in  std_logic;
        rst_n          : in  std_logic;
        enable         : in  std_logic;

        -- ---- RX from MAC (AXI4-Stream master) ----
        rx_tdata       : in  std_logic_vector(7 downto 0);
        rx_tvalid      : in  std_logic;
        rx_tlast       : in  std_logic;
        rx_terror      : in  std_logic;
        rx_tsof        : in  std_logic;

        -- ---- TX to MAC (AXI4-Stream slave) ----
        tx_tdata       : out std_logic_vector(7 downto 0);
        tx_tvalid      : out std_logic;
        tx_tready      : in  std_logic;
        tx_tlast       : out std_logic;

        -- ---- Configuration ----
        our_mac        : in  std_logic_vector(47 downto 0);  -- e.g., 48'h020000000001
        our_ip         : in  std_logic_vector(31 downto 0);  -- e.g., 32'hC0A801C8 = 192.168.1.200

        -- ---- Status ----
        arp_reply_sent : out std_logic
    );
end entity arp_responder;

architecture rtl of arp_responder is

    type byte_array_t is array (integer range 0 to 41) of std_logic_vector(7 downto 0);

    -- Verilog `reply[tx_idx]`. An out-of-range index (tx_idx > 41, unreachable:
    -- tx_idx only counts 0..41) yields x in Verilog, which Yosys synthesizes as
    -- 0; return 0 there so the two sides agree in that state too (the proof
    -- starts from arbitrary state) and the VHDL never indexes out of range.
    function byte_at(a : byte_array_t; idx : unsigned(5 downto 0))
        return std_logic_vector is
    begin
        if idx <= 41 then
            return a(to_integer(idx));
        else
            return "00000000";
        end if;
    end function byte_at;

    -- Capture first 42 bytes of each frame:
    -- [0:5]   dst MAC
    -- [6:11]  src MAC
    -- [12:13] EtherType
    -- [14:41] ARP payload (28 bytes)
    signal cap         : byte_array_t;
    signal cap_idx     : unsigned(5 downto 0);
    signal capturing   : std_logic;
    signal frame_valid : std_logic;

    -- TX state
    signal reply       : byte_array_t;
    signal tx_idx      : unsigned(5 downto 0);

    constant RX_IDLE : std_logic_vector(2 downto 0) := "000";  -- 3'd0
    constant RX_CAP  : std_logic_vector(2 downto 0) := "001";  -- 3'd1
    constant RX_SKIP : std_logic_vector(2 downto 0) := "010";  -- 3'd2
    constant TX_SEND : std_logic_vector(2 downto 0) := "011";  -- 3'd3
    constant TX_WAIT : std_logic_vector(2 downto 0) := "100";  -- 3'd4

    signal state : std_logic_vector(2 downto 0);

    signal is_arp_request : std_logic;

    -- tx_tvalid is read back by the TX state machine.
    signal tx_tvalid_i : std_logic;

begin

    -- Drive tx_tdata and tx_tlast combinationally from the current index.
    -- A registered tx_tdata <= reply[tx_idx] would lag tx_idx by one cycle
    -- (reply[0] sent twice, reply[41] dropped); a registered tx_tlast was
    -- also clobbered to 0 in the same cycle the inner if-clause fired.
    tx_tdata  <= byte_at(reply, tx_idx);
    tx_tlast  <= '1' when tx_tvalid_i = '1' and tx_idx = 41 else '0';
    tx_tvalid <= tx_tvalid_i;

    -- capturing and frame_valid are only ever assigned by the Verilog reset
    -- (to 0) and are never read. GHDL rejects a register assigned only under
    -- reset (it infers a latch), so they are tied to the only value they can
    -- hold; they are not observable either way.
    capturing   <= '0';
    frame_valid <= '0';

    -- Check if captured frame is an ARP request for our IP
    is_arp_request <=
        '1' when (cap(12) = x"08") and (cap(13) = x"06") and  -- EtherType = ARP
                 (cap(20) = x"00") and (cap(21) = x"01") and  -- Opcode = request
                 (cap(38) = our_ip(31 downto 24)) and (cap(39) = our_ip(23 downto 16)) and
                 (cap(40) = our_ip(15 downto 8))  and (cap(41) = our_ip(7 downto 0))  -- Target IP = ours
        else '0';

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            state          <= RX_IDLE;
            cap_idx        <= (others => '0');
            tx_tvalid_i    <= '0';
            tx_idx         <= (others => '0');
            arp_reply_sent <= '0';
            for ri in integer range 0 to 41 loop
                cap(ri)   <= (others => '0');
                reply(ri) <= (others => '0');
            end loop;
        elsif rising_edge(clk) then
            case state is
                when RX_IDLE =>
                    tx_tvalid_i <= '0';
                    if enable = '1' and rx_tvalid = '1' and rx_tsof = '1' then
                        cap(0)  <= rx_tdata;
                        cap_idx <= to_unsigned(1, 6);
                        state   <= RX_CAP;
                    end if;

                when RX_CAP =>
                    if rx_tvalid = '1' then
                        if cap_idx < 42 then
                            cap(to_integer(cap_idx)) <= rx_tdata;
                        end if;
                        cap_idx <= cap_idx + 1;

                        if rx_tlast = '1' then
                            if rx_terror = '0' and cap_idx >= 41 then
                                -- Frame complete, check if ARP request
                                state <= TX_WAIT;
                            else
                                state <= RX_IDLE;
                            end if;
                        end if;
                    end if;

                when TX_WAIT =>
                    -- One-cycle delay to let is_arp_request evaluate
                    if is_arp_request = '1' then
                        -- Build ARP reply in reply buffer
                        -- Dst MAC = sender MAC from request
                        reply(0)  <= cap(22); reply(1)  <= cap(23);
                        reply(2)  <= cap(24); reply(3)  <= cap(25);
                        reply(4)  <= cap(26); reply(5)  <= cap(27);
                        -- Src MAC = our MAC
                        reply(6)  <= our_mac(47 downto 40); reply(7)  <= our_mac(39 downto 32);
                        reply(8)  <= our_mac(31 downto 24); reply(9)  <= our_mac(23 downto 16);
                        reply(10) <= our_mac(15 downto 8);  reply(11) <= our_mac(7 downto 0);
                        -- EtherType = ARP
                        reply(12) <= x"08"; reply(13) <= x"06";
                        -- ARP header (same as request)
                        reply(14) <= x"00"; reply(15) <= x"01";  -- HTYPE
                        reply(16) <= x"08"; reply(17) <= x"00";  -- PTYPE
                        reply(18) <= x"06"; reply(19) <= x"04";  -- HLEN, PLEN
                        -- Opcode = 2 (reply)
                        reply(20) <= x"00"; reply(21) <= x"02";
                        -- Sender MAC = our MAC
                        reply(22) <= our_mac(47 downto 40); reply(23) <= our_mac(39 downto 32);
                        reply(24) <= our_mac(31 downto 24); reply(25) <= our_mac(23 downto 16);
                        reply(26) <= our_mac(15 downto 8);  reply(27) <= our_mac(7 downto 0);
                        -- Sender IP = our IP
                        reply(28) <= our_ip(31 downto 24); reply(29) <= our_ip(23 downto 16);
                        reply(30) <= our_ip(15 downto 8);  reply(31) <= our_ip(7 downto 0);
                        -- Target MAC = sender MAC from request
                        reply(32) <= cap(22); reply(33) <= cap(23);
                        reply(34) <= cap(24); reply(35) <= cap(25);
                        reply(36) <= cap(26); reply(37) <= cap(27);
                        -- Target IP = sender IP from request
                        reply(38) <= cap(28); reply(39) <= cap(29);
                        reply(40) <= cap(30); reply(41) <= cap(31);

                        tx_idx <= (others => '0');
                        state  <= TX_SEND;
                    else
                        state <= RX_IDLE;
                    end if;

                when TX_SEND =>
                    tx_tvalid_i <= '1';
                    if tx_tready = '1' and tx_tvalid_i = '1' then
                        if tx_idx = 41 then
                            tx_tvalid_i    <= '0';
                            arp_reply_sent <= '1';
                            state          <= RX_IDLE;
                        else
                            tx_idx <= tx_idx + 1;
                        end if;
                    end if;

                when others =>
                    state <= RX_IDLE;
            end case;

            -- Drain RX if we're not capturing (don't block MAC)
            if state = RX_IDLE and rx_tvalid = '1' and rx_tsof = '0' then
                null;  -- skip
            end if;
        end if;
    end process;

end architecture rtl;
