-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- tx_csum_off.vhd - TX checksum offload: IPv4 header, TCP, UDP, ICMP, ICMPv6
-- VHDL port of rtl/net/tx_csum_off.v (formally proven equivalent; see sim/parity/).
-- =============================================================================
-- Inline AXI4-Stream stage between the network stack and the MAC TX. For each
-- frame with `enable` high (sampled at the frame's first byte) it computes and
-- writes:
--   - the IPv4 header checksum (any IHL), and
--   - the TCP / UDP / ICMP checksum over IPv4, or the TCP / UDP / ICMPv6
--     checksum over IPv6 (pseudo-header included where the protocol uses it),
-- with an optional single 802.1Q / 802.1ad tag. Whatever software left in
-- those fields is ignored. A UDP checksum that computes to 0 is sent as
-- 0xFFFF. Scope and limits are those of csum_calc.v: IPv4 fragments,
-- source-routed IPv4, UDP with an out-of-range Length and IPv6 packets with
-- extension headers get no L4 checksum (the IPv4 header checksum is still
-- written), and other frames pass unchanged. With `enable` low a
-- frame passes unchanged.
--
-- The checksum fields precede the bytes they cover, so the stage stores each
-- frame before sending it: a circular byte buffer (sync_fifo) holds frames,
-- and a small metadata FIFO holds each committed frame's patch values and
-- positions. The next frame is taken in while the previous one drains, so a
-- buffer one MAX_FRAME deep sustains 1 byte/clk; the per-frame cost is a
-- 5-cycle pause in s_axis_tready after each TLAST while the sums settle.
--
-- A frame longer than MAX_FRAME bytes is cut at MAX_FRAME (TLAST forced on the
-- last kept byte, the rest discarded up to the real TLAST) and sent unpatched,
-- so an oversized or unterminated frame can never fill the buffer and
-- deadlock. BUF_ADDR_WIDTH must give a buffer deeper than MAX_FRAME.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.emz_util_pkg.all;

entity tx_csum_off is
    generic (
        MAX_FRAME       : integer := 9018;
        -- Byte buffer depth 2^BUF_ADDR_WIDTH; must exceed MAX_FRAME. One
        -- MAX_FRAME is enough for full rate (one frame drains while the next fills).
        BUF_ADDR_WIDTH  : integer := 0;     -- 0 = clog2(MAX_FRAME + 8), as the Verilog default
        META_ADDR_WIDTH : integer := 4      -- committed frames held: 2^N
    );
    port (
        clk           : in  std_logic;
        rst_n         : in  std_logic;
        enable        : in  std_logic;

        -- Ingress (from network stack)
        s_axis_tdata  : in  std_logic_vector(7 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;
        s_axis_tlast  : in  std_logic;

        -- Egress (to MAC TX)
        m_axis_tdata  : out std_logic_vector(7 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic;
        m_axis_tlast  : out std_logic
    );
end entity tx_csum_off;

architecture rtl of tx_csum_off is
    -- BUF_ADDR_WIDTH resolved (its Verilog default depends on MAX_FRAME, which
    -- a VHDL-93 generic default cannot; see emz_util_pkg.auto_or).
    constant BUF_AW : integer := auto_or(BUF_ADDR_WIDTH, clog2(MAX_FRAME + 8));

    constant META_DEPTH : integer := 2 ** META_ADDR_WIDTH;
    -- csum_calc results are final 3 cycles after the last byte; commit on the
    -- 4th.
    constant FLUSH_CYC : unsigned(2 downto 0) := to_unsigned(4, 3);

    -- =========================================================================
    -- Ingest
    -- =========================================================================
    constant IN_DATA  : std_logic_vector(1 downto 0) := "00";  -- accepting frame bytes
    constant IN_FLUSH : std_logic_vector(1 downto 0) := "01";  -- frame stored; sums settling, then commit
    constant IN_DROP  : std_logic_vector(1 downto 0) := "10";  -- discarding a cut frame's tail

    signal in_state  : std_logic_vector(1 downto 0);
    signal in_cnt    : unsigned(13 downto 0);  -- bytes of the current frame accepted so far
    signal en_frame  : std_logic;              -- `enable` latched at the frame's first byte
    signal cut       : std_logic;              -- frame was cut at MAX_FRAME
    signal flush_cnt : unsigned(2 downto 0);

    signal buf_full  : std_logic;
    signal meta_full : std_logic;

    signal s_axis_tready_i : std_logic;
    signal in_hs           : std_logic;
    signal at_max          : std_logic;
    signal in_last         : std_logic;  -- TLAST as written to the buffer

    -- Checksum engine on the accepted bytes
    signal c_done, c_ip4, c_l4_ok, c_l4_udp : std_logic;
    signal c_l3_end, c_ip_pos, c_l4_pos     : std_logic_vector(13 downto 0);
    signal c_ip_sum, c_l4_sum, c_l4_field   : std_logic_vector(15 downto 0);

    signal ip_csum   : std_logic_vector(15 downto 0);
    signal l4_csum_c : std_logic_vector(15 downto 0);
    signal l4_csum   : std_logic_vector(15 downto 0);
    signal patch_ok  : std_logic;

    -- Metadata word: {ip_patch, ip_csum, ip_pos, l4_patch, l4_csum, l4_pos}
    constant META_W : integer := 1 + 16 + 14 + 1 + 16 + 14;
    signal meta_in  : std_logic_vector(META_W-1 downto 0);

    signal commit   : std_logic;

    -- =========================================================================
    -- Storage
    -- =========================================================================
    signal buf_wr_data  : std_logic_vector(8 downto 0);
    signal buf_rd_data  : std_logic_vector(8 downto 0);
    signal buf_rd_valid : std_logic;
    signal buf_pop      : std_logic;

    type meta_mem_t is array (0 to META_DEPTH-1) of std_logic_vector(META_W-1 downto 0);
    signal meta_mem   : meta_mem_t;
    signal meta_wr    : unsigned(META_ADDR_WIDTH downto 0);
    signal meta_rd    : unsigned(META_ADDR_WIDTH downto 0);
    signal meta_valid : std_logic;
    signal meta_pop   : std_logic;

    -- =========================================================================
    -- Egress
    -- =========================================================================
    signal meta_q     : std_logic_vector(META_W-1 downto 0);
    signal q_ip_patch : std_logic;
    signal q_ip_csum  : std_logic_vector(15 downto 0);
    signal q_ip_pos   : unsigned(13 downto 0);
    signal q_l4_patch : std_logic;
    signal q_l4_csum  : std_logic_vector(15 downto 0);
    signal q_l4_pos   : unsigned(13 downto 0);

    signal eg_pos          : unsigned(13 downto 0);  -- offset of the head byte within its frame
    signal m_axis_tvalid_i : std_logic;

begin

    s_axis_tready_i <= '1' when (in_state = IN_DATA and buf_full = '0') or
                                (in_state = IN_DROP) else '0';

    in_hs   <= '1' when s_axis_tvalid = '1' and s_axis_tready_i = '1' and in_state = IN_DATA else '0';
    at_max  <= '1' when in_cnt = MAX_FRAME - 1 else '0';
    in_last <= s_axis_tlast or at_max;

    u_calc : entity work.csum_calc
        port map (
            clk         => clk,
            rst_n       => rst_n,
            in_valid    => in_hs,
            in_idx      => std_logic_vector(in_cnt),
            in_data     => s_axis_tdata,
            zero_fields => '1',
            done        => c_done,
            l3_end      => c_l3_end,
            ip4         => c_ip4,
            ip_sum      => c_ip_sum,
            hdr_end     => open,
            ip_csum_pos => c_ip_pos,
            l4_ok       => c_l4_ok,
            l4_udp      => c_l4_udp,
            l4_sum      => c_l4_sum,
            l4_csum_pos => c_l4_pos,
            l4_field    => c_l4_field
        );

    ip_csum   <= not c_ip_sum;
    l4_csum_c <= not c_l4_sum;
    l4_csum   <= x"FFFF" when c_l4_udp = '1' and l4_csum_c = x"0000" else l4_csum_c;
    patch_ok  <= en_frame and (not cut) and c_done;

    meta_in <= (patch_ok and c_ip4) & ip_csum & c_ip_pos &
               (patch_ok and c_l4_ok) & l4_csum & c_l4_pos;

    commit <= '1' when in_state = IN_FLUSH and flush_cnt = 0 and meta_full = '0' else '0';

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            in_state  <= IN_DATA;
            in_cnt    <= (others => '0');
            en_frame  <= '0';
            cut       <= '0';
            flush_cnt <= (others => '0');
        elsif rising_edge(clk) then
            case in_state is
                when IN_DATA =>
                    if in_hs = '1' then
                        if in_cnt = 0 then
                            en_frame <= enable;
                        end if;
                        if in_last = '1' then
                            in_state  <= IN_FLUSH;
                            flush_cnt <= FLUSH_CYC - 1;
                            cut       <= at_max and (not s_axis_tlast);
                        else
                            in_cnt <= in_cnt + 1;
                        end if;
                    end if;

                when IN_FLUSH =>
                    if flush_cnt /= 0 then
                        flush_cnt <= flush_cnt - 1;
                    end if;
                    if commit = '1' then
                        in_cnt <= (others => '0');
                        if cut = '1' then
                            in_state <= IN_DROP;
                        else
                            in_state <= IN_DATA;
                        end if;
                        cut <= '0';
                    end if;

                when IN_DROP =>
                    if s_axis_tvalid = '1' and s_axis_tlast = '1' then
                        in_state <= IN_DATA;
                    end if;

                when others =>
                    in_state <= IN_DATA;
            end case;
        end if;
    end process;

    -- =========================================================================
    -- Storage: frame bytes {tlast, data}; per-frame patch metadata
    -- =========================================================================
    buf_wr_data <= in_last & s_axis_tdata;

    u_buf : entity work.sync_fifo
        generic map (
            DATA_WIDTH => 9,
            ADDR_WIDTH => BUF_AW
        )
        port map (
            clk         => clk,
            rst_n       => rst_n,
            wr_data     => buf_wr_data,
            wr_en       => in_hs,
            wr_full     => buf_full,
            rd_data     => buf_rd_data,
            rd_valid    => buf_rd_valid,
            rd_en       => buf_pop,
            rd_empty    => open,
            count       => open,
            wr_overflow => open
        );

    meta_valid <= '1' when meta_wr /= meta_rd else '0';

    meta_full <= '1' when (meta_wr - meta_rd) = to_unsigned(META_DEPTH, META_ADDR_WIDTH+1) else '0';

    process (clk)
    begin
        if rising_edge(clk) then
            if commit = '1' then
                meta_mem(to_integer(meta_wr(META_ADDR_WIDTH-1 downto 0))) <= meta_in;
            end if;
        end if;
    end process;

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            meta_wr <= (others => '0');
            meta_rd <= (others => '0');
        elsif rising_edge(clk) then
            if commit = '1' then
                meta_wr <= meta_wr + 1;
            end if;
            if meta_pop = '1' then
                meta_rd <= meta_rd + 1;
            end if;
        end if;
    end process;

    -- =========================================================================
    -- Egress: the head frame's bytes, once its metadata is committed
    -- =========================================================================
    meta_q     <= meta_mem(to_integer(meta_rd(META_ADDR_WIDTH-1 downto 0)));
    q_ip_patch <= meta_q(61);
    q_ip_csum  <= meta_q(60 downto 45);
    q_ip_pos   <= unsigned(meta_q(44 downto 31));
    q_l4_patch <= meta_q(30);
    q_l4_csum  <= meta_q(29 downto 14);
    q_l4_pos   <= unsigned(meta_q(13 downto 0));

    m_axis_tvalid_i <= buf_rd_valid and meta_valid;
    m_axis_tlast    <= buf_rd_data(8);
    buf_pop         <= m_axis_tvalid_i and m_axis_tready;
    meta_pop        <= buf_pop and buf_rd_data(8);

    m_axis_tdata <= q_ip_csum(15 downto 8) when q_ip_patch = '1' and eg_pos = q_ip_pos else
                    q_ip_csum(7 downto 0)  when q_ip_patch = '1' and eg_pos = q_ip_pos + 1 else
                    q_l4_csum(15 downto 8) when q_l4_patch = '1' and eg_pos = q_l4_pos else
                    q_l4_csum(7 downto 0)  when q_l4_patch = '1' and eg_pos = q_l4_pos + 1 else
                    buf_rd_data(7 downto 0);

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            eg_pos <= (others => '0');
        elsif rising_edge(clk) then
            if buf_pop = '1' then
                if buf_rd_data(8) = '1' then
                    eg_pos <= (others => '0');
                else
                    eg_pos <= eg_pos + 1;
                end if;
            end if;
        end if;
    end process;

    s_axis_tready <= s_axis_tready_i;
    m_axis_tvalid <= m_axis_tvalid_i;

end architecture rtl;
