-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- csum_calc.vhd - IPv4 / IPv6 / TCP / UDP / ICMP checksum engine (byte stream)
-- VHDL port of rtl/net/csum_calc.v (formally proven equivalent; see sim/parity/).
-- =============================================================================
-- Watches one Ethernet frame as a byte stream (frame byte 0 = first dst-MAC
-- byte, no preamble) and computes the Internet checksums it carries. Shared by
-- the TX inserter (tx_csum_off) and the RX checker (eth_mac_rx):
--
--   zero_fields = 1 (TX): the IPv4 header checksum and L4 checksum fields are
--     summed as zero, so ~ip_sum / ~l4_sum are the values to insert.
--   zero_fields = 0 (RX): the fields are summed as received, so a correct
--     header / segment folds to 16'hFFFF.
--
-- Recognised frames:
--   - Ethernet II, optionally with one 802.1Q (0x8100) or 802.1ad (0x88A8) tag.
--   - IPv4 with any IHL (options included): header checksum.
--   - IPv6 fixed header (no header checksum exists).
--   - L4 checksum for TCP (6), UDP (17) and ICMP (1) over IPv4, and TCP, UDP
--     and ICMPv6 (58) over IPv6, with the pseudo-header for all but ICMPv4.
--
-- Not covered (done = 1, l4_ok = 0, so callers leave the L4 field alone):
--   - IPv4 fragments (MF set or offset != 0): the L4 checksum spans the whole
--     reassembled datagram.
--   - IPv4 with a loose or strict source route option (LSRR 0x83, SSRR 0x89)
--     or a malformed option (length < 2): the pseudo-header destination may
--     be the route's final hop, not the header's destination field.
--   - UDP whose Length field is below 8 or beyond the IP payload.
--   - IPv6 with extension headers (next header not 6/17/58 directly).
--   - Other L4 protocols.
-- Frames that are not IP, are malformed (IHL < 5, total length shorter than
-- the header) or carry a second VLAN tag never raise done.
--
-- Sums cover the IP datagram only: [l3, l3_end), where l3_end comes from the
-- IPv4 total length or IPv6 payload length. Ethernet padding and the FCS are
-- ignored. UDP covers only its Length field's bytes (RFC 768), which may be
-- fewer than the IP payload, and that length goes in its pseudo-header; the
-- other protocols use the IP-derived L4 length. Every header start (14 or 18,
-- plus IHL*4 or 40) is even, so a byte's weight in the 16-bit sum follows the
-- parity of its frame offset.
--
-- Timing:
--   - ip4 / ip_sum are final 2 cycles after the IPv4 header's last byte, at
--     frame offset hdr_end - 1, whether or not the rest of the datagram
--     arrives. A caller that also feeds trailing bytes (RX feeds the FCS)
--     must check that hdr_end is inside the real data.
--   - Everything else is final, and done rises, 3 cycles after the
--     datagram's last byte. done stays high until the next frame
--     (in_idx == 0). An incomplete datagram never raises done.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity csum_calc is
    port (
        clk         : in  std_logic;
        rst_n       : in  std_logic;

        in_valid    : in  std_logic;                      -- one frame byte this cycle
        in_idx      : in  std_logic_vector(13 downto 0);  -- its frame offset; 0 starts a new frame
        in_data     : in  std_logic_vector(7 downto 0);
        zero_fields : in  std_logic;                      -- 1 = sum checksum fields as zero (TX)

        done        : out std_logic;                      -- results below are valid
        l3_end      : out std_logic_vector(13 downto 0);  -- frame offset one past the datagram
        ip4         : out std_logic;                      -- IPv4 header checksum applies (see Timing)
        ip_sum      : out std_logic_vector(15 downto 0);  -- folded IPv4 header sum
        hdr_end     : out std_logic_vector(13 downto 0);  -- frame offset one past the IPv4 header
        ip_csum_pos : out std_logic_vector(13 downto 0);  -- frame offset of the IPv4 csum MSB
        l4_ok       : out std_logic;                      -- L4 checksum applies
        l4_udp      : out std_logic;                      -- ... and the L4 protocol is UDP
        l4_sum      : out std_logic_vector(15 downto 0);  -- folded L4 sum incl. pseudo-header
        l4_csum_pos : out std_logic_vector(13 downto 0);  -- frame offset of the L4 csum MSB
        l4_field    : out std_logic_vector(15 downto 0)   -- L4 checksum field as received
    );
end entity csum_calc;

architecture rtl of csum_calc is

    -- ---- Per-frame parse state ---------------------------------------------
    signal etype_hi    : std_logic_vector(7 downto 0);  -- byte 12 (or 16 after a tag)
    signal vlan        : std_logic;                     -- one tag seen; real EtherType at 16-17
    signal l3_known    : std_logic;                     -- l3_off valid
    signal l3_off      : unsigned(4 downto 0);          -- 14 or 18
    signal fam4        : std_logic;                     -- EtherType 0x0800 and version 4
    signal fam6        : std_logic;                     -- EtherType 0x86DD and version 6
    signal hdr_len     : unsigned(5 downto 0);          -- IPv4: IHL*4 (20 until byte 0 is seen)
    signal ip_len      : unsigned(15 downto 0);         -- IPv4 total length / IPv6 payload length
    signal frag        : std_logic;                     -- IPv4 MF or fragment offset != 0
    signal proto       : std_logic_vector(7 downto 0);  -- IPv4 protocol / IPv6 next header
    signal len_ok      : std_logic;                     -- l3_end computed and within 14 bits
    signal l4_start    : unsigned(13 downto 0);         -- also one past the IPv4 header
    signal l4_len      : unsigned(15 downto 0);         -- IP payload length
    signal l4_end      : unsigned(13 downto 0);         -- one past the L4 bytes summed
    signal udp_len_hi  : std_logic_vector(7 downto 0);
    signal udp_len     : unsigned(15 downto 0);         -- UDP Length field

    -- IPv4 option walk (RFC 791): EOL ends the list, NOP is one byte, every
    -- other option is type, length, data.
    signal opt_pos     : unsigned(8 downto 0);          -- header offset of the next option type
    signal opt_len_nx  : std_logic;                     -- this byte is an option's length
    signal opt_end     : std_logic;                     -- EOL or malformed: stop walking
    signal opt_skip    : std_logic;                     -- source route or malformed: no L4 checksum

    signal ip_acc      : unsigned(23 downto 0);         -- IPv4 header
    signal ph_acc      : unsigned(23 downto 0);         -- pseudo-header addresses
    signal l4_acc      : unsigned(31 downto 0);         -- L4 header + payload

    -- Output registers read back internally
    signal l3_end_i      : unsigned(13 downto 0);
    signal l4_csum_pos_i : unsigned(13 downto 0);

    -- Offset of this byte within the L3 header (valid once l3_known)
    signal r : unsigned(13 downto 0);

    -- 16-bit word weight of this byte: even frame offsets are the MSB
    signal w : unsigned(15 downto 0);

    -- L4 checksum field offset within the L4 header for this protocol
    signal l4_off      : unsigned(4 downto 0);
    signal l4_proto_ok : std_logic;

    signal in_l3       : std_logic;
    signal in_ip4h     : std_logic;
    signal in_ph       : std_logic;
    signal in_l4       : std_logic;
    signal is_ipf      : std_logic;
    signal is_l4f      : std_logic;
    signal last        : std_logic;
    signal hdr_last    : std_logic;
    signal in_opt      : std_logic;
    signal is_udp      : std_logic;
    signal udp_len_now : unsigned(15 downto 0);

    -- ---- IPv4 header sum pipeline (2 stages after the header's last byte) --
    signal h1, h2      : std_logic;
    signal ip_f1_r     : unsigned(16 downto 0);

    -- ---- Final sum pipeline (3 stages after the last datagram byte) --------
    signal p1, p2, p3  : std_logic;
    signal l4_tot_r    : unsigned(31 downto 0);
    signal l4_f1_r     : unsigned(16 downto 0);
    signal struct_ok_r : std_logic;                     -- datagram structure valid at p1
    signal l4_ok_r     : std_logic;

    signal ip_f1       : unsigned(16 downto 0);
    signal use_ph      : std_logic;

    signal struct4     : std_logic;
    signal struct_ok   : std_logic;
    signal udp_ok      : std_logic;
    signal ph_len      : unsigned(15 downto 0);
    signal l4_able     : std_logic;

    signal idx         : unsigned(13 downto 0);         -- in_idx as unsigned

begin

    idx <= unsigned(in_idx);

    r <= idx - resize(l3_off, 14);

    w <= unsigned(x"00" & in_data) when in_idx(0) = '1' else
         unsigned(in_data & x"00");

    process (proto, fam4, fam6)
    begin
        l4_proto_ok <= '1';
        case proto is
            when x"06" =>                                   -- TCP
                l4_off <= to_unsigned(16, 5);
            when x"11" =>                                   -- UDP
                l4_off <= to_unsigned(6, 5);
            when x"01" =>                                   -- ICMP (IPv4 only)
                l4_off      <= to_unsigned(2, 5);
                l4_proto_ok <= fam4;
            when x"3A" =>                                   -- ICMPv6 (IPv6 only)
                l4_off      <= to_unsigned(2, 5);
                l4_proto_ok <= fam6;
            when others =>
                l4_off      <= to_unsigned(0, 5);
                l4_proto_ok <= '0';
        end case;
    end process;

    in_l3   <= l3_known and (fam4 or fam6);
    in_ip4h <= '1' when in_l3 = '1' and fam4 = '1' and r < resize(hdr_len, 14) else '0';
    in_ph   <= '1' when in_l3 = '1' and
                        ((fam4 = '1' and r >= 12 and r < 20) or
                         (fam4 = '0' and r >= 8 and r < 40)) else '0';
    in_l4   <= '1' when in_l3 = '1' and len_ok = '1' and idx >= l4_start and
                        idx < l4_end and idx < l3_end_i else '0';
    is_ipf  <= '1' when fam4 = '1' and (r = 10 or r = 11) else '0';
    is_l4f  <= '1' when idx = l4_csum_pos_i or idx = l4_csum_pos_i + 1 else '0';
    last    <= '1' when in_l3 = '1' and len_ok = '1' and idx = l3_end_i - 1 else '0';
    hdr_last <= '1' when in_ip4h = '1' and r = resize(hdr_len, 14) - 1 else '0';
    in_opt  <= '1' when in_ip4h = '1' and r >= 20 and opt_end = '0' else '0';
    is_udp  <= '1' when proto = x"11" else '0';
    udp_len_now <= unsigned(udp_len_hi & in_data);

    hdr_end <= std_logic_vector(l4_start);

    ip_f1  <= ('0' & ip_acc(15 downto 0)) + resize(ip_acc(23 downto 16), 17);
    use_ph <= '1' when fam6 = '1' or proto /= x"01" else '0';

    struct4   <= '1' when fam4 = '1' and hdr_len >= 20 and ip_len >= resize(hdr_len, 16) else '0';
    struct_ok <= len_ok and (struct4 or fam6);
    udp_ok    <= '1' when udp_len >= 8 and udp_len <= l4_len else '0';
    ph_len    <= udp_len when is_udp = '1' else l4_len;
    l4_able   <= '1' when struct_ok = '1' and l4_proto_ok = '1' and
                          not (fam4 = '1' and (frag = '1' or opt_skip = '1')) and
                          l4_len >= resize(l4_off, 16) + 2 and
                          (is_udp = '0' or udp_ok = '1') else '0';

    process (clk, rst_n)
        variable end_off : unsigned(16 downto 0);
        variable l4s     : unsigned(16 downto 0);
    begin
        if rst_n = '0' then
            etype_hi      <= (others => '0');
            vlan          <= '0';
            l3_known      <= '0';
            l3_off        <= to_unsigned(14, 5);
            fam4          <= '0';
            fam6          <= '0';
            hdr_len       <= to_unsigned(20, 6);
            ip_len        <= (others => '0');
            frag          <= '0';
            proto         <= (others => '0');
            len_ok        <= '0';
            l4_start      <= (others => '0');
            l4_len        <= (others => '0');
            l4_end        <= (others => '0');
            udp_len_hi    <= (others => '0');
            udp_len       <= (others => '0');
            opt_pos       <= to_unsigned(20, 9);
            opt_len_nx    <= '0';
            opt_end       <= '0';
            opt_skip      <= '0';
            l3_end_i      <= (others => '0');
            ip_csum_pos   <= (others => '0');
            l4_csum_pos_i <= (others => '1');
            l4_field      <= (others => '0');
            ip_acc        <= (others => '0');
            ph_acc        <= (others => '0');
            l4_acc        <= (others => '0');
            h1            <= '0';
            h2            <= '0';
            p1            <= '0';
            p2            <= '0';
            p3            <= '0';
            l4_tot_r      <= (others => '0');
            l4_f1_r       <= (others => '0');
            ip_f1_r       <= (others => '0');
            struct_ok_r   <= '0';
            l4_ok_r       <= '0';
            done          <= '0';
            ip4           <= '0';
            ip_sum        <= (others => '0');
            l4_ok         <= '0';
            l4_udp        <= '0';
            l4_sum        <= (others => '0');
        elsif rising_edge(clk) then
            h1 <= '0';
            h2 <= '0';
            p1 <= '0';
            p2 <= '0';

            if in_valid = '1' and idx = 0 then
                -- New frame: clear everything (byte 0 is a dst-MAC byte)
                vlan          <= '0';
                l3_known      <= '0';
                l3_off        <= to_unsigned(14, 5);
                fam4          <= '0';
                fam6          <= '0';
                hdr_len       <= to_unsigned(20, 6);
                ip_len        <= (others => '0');
                frag          <= '0';
                proto         <= (others => '0');
                len_ok        <= '0';
                l4_start      <= (others => '0');
                l4_len        <= (others => '0');
                l4_end        <= (others => '0');
                udp_len       <= (others => '0');
                opt_pos       <= to_unsigned(20, 9);
                opt_len_nx    <= '0';
                opt_end       <= '0';
                opt_skip      <= '0';
                l3_end_i      <= (others => '0');
                l4_csum_pos_i <= (others => '1');
                l4_field      <= (others => '0');
                ip_acc        <= (others => '0');
                ph_acc        <= (others => '0');
                l4_acc        <= (others => '0');
                done          <= '0';
                ip4           <= '0';
                l4_ok         <= '0';
                l4_udp        <= '0';
            elsif in_valid = '1' then
                -- ---- EtherType / VLAN ----------------------------------------
                if l3_known = '0' then
                    if idx = 12 or (vlan = '1' and idx = 16) then
                        etype_hi <= in_data;
                    end if;
                    if idx = 13 or (vlan = '1' and idx = 17) then
                        if vlan = '0' and ((etype_hi & in_data) = x"8100" or
                                           (etype_hi & in_data) = x"88A8") then
                            vlan <= '1';
                        else
                            l3_known <= '1';
                            if vlan = '1' then
                                l3_off <= to_unsigned(18, 5);
                            else
                                l3_off <= to_unsigned(14, 5);
                            end if;
                            if (etype_hi & in_data) = x"0800" then fam4 <= '1'; else fam4 <= '0'; end if;
                            if (etype_hi & in_data) = x"86DD" then fam6 <= '1'; else fam6 <= '0'; end if;
                        end if;
                    end if;
                end if;

                -- ---- L3 header fields ----------------------------------------
                if in_l3 = '1' then
                    if r = 0 then
                        if fam4 = '1' then
                            hdr_len <= unsigned(in_data(3 downto 0)) & "00";
                            if in_data(7 downto 4) /= "0100" then fam4 <= '0'; end if;
                        end if;
                        if fam6 = '1' and in_data(7 downto 4) /= "0110" then fam6 <= '0'; end if;
                    end if;
                    if fam4 = '1' then
                        if r = 2 then ip_len(15 downto 8) <= unsigned(in_data); end if;
                        if r = 3 then ip_len(7 downto 0)  <= unsigned(in_data); end if;
                        if r = 6 then
                            if in_data(5) = '1' or in_data(4 downto 0) /= "00000" then
                                frag <= '1';
                            else
                                frag <= '0';
                            end if;
                        end if;
                        if r = 7 and in_data /= x"00" then frag <= '1'; end if;
                        if r = 9 then proto <= in_data; end if;
                    else
                        if r = 4 then ip_len(15 downto 8) <= unsigned(in_data); end if;
                        if r = 5 then ip_len(7 downto 0)  <= unsigned(in_data); end if;
                        if r = 6 then proto <= in_data; end if;
                    end if;

                    -- Once the length is in, work out where things end. IPv4:
                    -- total length covers the header; IPv6: payload length
                    -- follows the fixed 40-byte header.
                    if (fam4 = '1' and r = 4) or (fam6 = '1' and r = 6) then
                        if fam4 = '1' then
                            end_off := resize(l3_off, 17) + resize(ip_len, 17);
                            l4s     := resize(l3_off, 17) + resize(hdr_len, 17);
                        else
                            end_off := resize(l3_off, 17) + 40 + resize(ip_len, 17);
                            l4s     := resize(l3_off, 17) + 40;
                        end if;
                        if end_off <= 16#3FFF# then len_ok <= '1'; else len_ok <= '0'; end if;
                        l3_end_i <= end_off(13 downto 0);
                        l4_end   <= end_off(13 downto 0);
                        l4_start <= l4s(13 downto 0);
                        if fam4 = '1' then
                            l4_len <= ip_len - resize(hdr_len, 16);
                        else
                            l4_len <= ip_len;
                        end if;
                        ip_csum_pos <= std_logic_vector(resize(l3_off, 14) + 10);
                    end if;
                    -- Protocol is known by IPv4 byte 9 / IPv6 byte 6.
                    if (fam4 = '1' and r = 10) or (fam6 = '1' and r = 7) then
                        l4_csum_pos_i <= l4_start + resize(l4_off, 14);
                    end if;

                    -- IPv4 options: look for a source route (or a length
                    -- that cannot be walked past).
                    if fam4 = '1' and in_opt = '1' then
                        if opt_len_nx = '1' then
                            opt_len_nx <= '0';
                            if unsigned(in_data) < 2 then
                                opt_end  <= '1';
                                opt_skip <= '1';
                            else
                                opt_pos <= opt_pos + resize(unsigned(in_data), 9);
                            end if;
                        elsif r = resize(opt_pos, 14) then
                            case in_data is
                                when x"00" =>                       -- EOL
                                    opt_end <= '1';
                                when x"01" =>                       -- NOP
                                    opt_pos <= opt_pos + 1;
                                when others =>
                                    opt_len_nx <= '1';
                                    if in_data = x"83" or in_data = x"89" then
                                        opt_skip <= '1';            -- LSRR / SSRR
                                    end if;
                            end case;
                        end if;
                    end if;

                    -- UDP Length (L4 bytes 4-5). Bytes 0-5 are always
                    -- covered, so the end only needs to move from byte 6 on.
                    if is_udp = '1' and len_ok = '1' and idx = l4_start + 4 then
                        udp_len_hi <= in_data;
                    end if;
                    if is_udp = '1' and len_ok = '1' and idx = l4_start + 5 then
                        udp_len <= udp_len_now;
                        if udp_len_now >= 8 and udp_len_now <= l4_len then
                            l4_end <= l4_start + udp_len_now(13 downto 0);
                        end if;
                    end if;
                end if;

                -- ---- Sums ----------------------------------------------------
                if in_ip4h = '1' and not (zero_fields = '1' and is_ipf = '1') then
                    ip_acc <= ip_acc + resize(w, 24);
                end if;
                if in_ph = '1' then
                    ph_acc <= ph_acc + resize(w, 24);
                end if;
                if in_l4 = '1' then
                    if not (zero_fields = '1' and is_l4f = '1') then
                        l4_acc <= l4_acc + resize(w, 32);
                    end if;
                    if idx = l4_csum_pos_i     then l4_field(15 downto 8) <= in_data; end if;
                    if idx = l4_csum_pos_i + 1 then l4_field(7 downto 0)  <= in_data; end if;
                end if;

                if hdr_last = '1' then
                    h1 <= '1';
                end if;
                if last = '1' then
                    p1 <= '1';
                end if;
            end if;

            -- IPv4 header: two folds; valid whether or not the datagram ends
            if h1 = '1' then
                h2      <= '1';
                ip_f1_r <= ip_f1;
            end if;
            if h2 = '1' then
                ip_sum <= std_logic_vector(ip_f1_r(15 downto 0) + resize(ip_f1_r(16 downto 16), 16));
                ip4    <= struct4;
            end if;

            -- Stage 1: add the pseudo-header
            if p1 = '1' then
                p2          <= '1';
                struct_ok_r <= struct_ok;
                l4_ok_r     <= l4_able;
                l4_udp      <= is_udp;
                if use_ph = '1' then
                    l4_tot_r <= l4_acc + (resize(ph_acc, 32) + resize(unsigned(proto), 32) +
                                          resize(ph_len, 32));
                else
                    l4_tot_r <= l4_acc;
                end if;
            end if;

            -- Stage 2: first fold of the L4 sum
            if p2 = '1' then
                l4_f1_r <= ('0' & l4_tot_r(15 downto 0)) + ('0' & l4_tot_r(31 downto 16));
            end if;

            -- Stage 3: final fold of the L4 sum; results valid
            p3 <= p2;
            if p3 = '1' then
                l4_sum <= std_logic_vector(l4_f1_r(15 downto 0) + resize(l4_f1_r(16 downto 16), 16));
                done   <= struct_ok_r;
                l4_ok  <= struct_ok_r and l4_ok_r;
            end if;
        end if;
    end process;

    l3_end      <= std_logic_vector(l3_end_i);
    l4_csum_pos <= std_logic_vector(l4_csum_pos_i);

end architecture rtl;
