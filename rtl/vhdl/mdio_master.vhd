-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- mdio_master.vhd - MDIO master supporting clause-22 and clause-45
-- VHDL port of rtl/mdio_master.v (formally proven equivalent; see sim/parity/).
-- -----------------------------------------------------------------------------
-- Clause-22 (cmd_c45_en=0):
--   ST=01, OP={10=read, 01=write}, PRTAD[4:0], REGAD[4:0], TA, DATA[15:0]
--   cmd_reg holds REGAD; cmd_wdata holds DATA on writes; rdata returns DATA.
--
-- Clause-45 (cmd_c45_en=1):
--   ST=00, OP=cmd_c45_op[1:0], PRTAD[4:0], DEVAD[4:0], TA, DATA[15:0]
--   OP encoding (IEEE 802.3 clause 45.2.4):
--     00 = ADDRESS  (cmd_wdata[15:0] is the register-address payload)
--     01 = WRITE    (cmd_wdata[15:0] is the data payload)
--     10 = READ-INC (post-increment internal address; data returns on rdata)
--     11 = READ     (data returns on rdata)
--   The two-step sequence is driven by software: issue an ADDRESS frame to
--   latch the 16-bit register address inside the PHY, then issue a READ or
--   WRITE frame using the same DEVAD.
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mdio_master is
    generic (
        -- clk frequency; MDC runs at ~1 MHz (well under the 2.5 MHz clause-22
        -- limit) from a divide-by-ceil(CLK_FREQ_HZ / 1 MHz), 100 at 100 MHz.
        CLK_FREQ_HZ : integer := 100000000
    );
    port (
        clk            : in  std_logic;                      -- system clock
        rst_n          : in  std_logic;

        -- MDIO pins
        mdc            : out std_logic;
        mdio_i         : in  std_logic;                      -- MDIO input (directly from pad)
        mdio_o         : out std_logic;                      -- MDIO output
        mdio_oe        : out std_logic;                      -- output enable (active high)

        -- Command interface
        cmd_valid      : in  std_logic;                      -- pulse to start operation
        cmd_write      : in  std_logic;                      -- C22 only: 0=read, 1=write
        cmd_phy        : in  std_logic_vector(4 downto 0);   -- PHY address (PRTAD)
        cmd_reg        : in  std_logic_vector(4 downto 0);   -- C22: REGAD; C45: DEVAD
        cmd_wdata      : in  std_logic_vector(15 downto 0);  -- C22 write data, or C45 ADDRESS / WRITE payload
        cmd_c45_en     : in  std_logic;                      -- 1 = clause-45 framing, 0 = clause-22
        cmd_c45_op     : in  std_logic_vector(1 downto 0);   -- C45 OP: 00=ADDR 01=WRITE 10=READ-INC 11=READ
        cmd_rdata      : out std_logic_vector(15 downto 0);  -- read data (C22 read or C45 READ/READ-INC)
        cmd_done       : out std_logic;                      -- pulse when operation complete

        -- Debug: count mdio_i=0 at exact S_DATA read sampling instants
        dbg_rd_low_cnt : out std_logic_vector(4 downto 0);   -- how many bits were 0 during read
        dbg_rd_raw     : out std_logic_vector(15 downto 0)   -- raw captured shift_reg after read
    );
end entity mdio_master;

architecture rtl of mdio_master is

    -- MDC divider: clk/MDC_DIV ~= 1 MHz MDC (clk/100 at 100 MHz)
    function max4(x : integer) return integer is
    begin
        if x < 4 then
            return 4;
        else
            return x;
        end if;
    end function max4;

    -- Verilog `v[4 - bit_cnt]`. An out-of-range select (bit_cnt > 4, unreachable)
    -- yields x in Verilog, which Yosys synthesizes as 0; return '0' there so the
    -- two sides agree in that state too (the proof starts from arbitrary state).
    function msb_first_bit(v : std_logic_vector(4 downto 0); cnt : unsigned(5 downto 0))
        return std_logic is
    begin
        if cnt <= 4 then
            return v(4 - to_integer(cnt));
        else
            return '0';
        end if;
    end function msb_first_bit;

    constant MDC_DIV_RAW : integer := (CLK_FREQ_HZ + 999999) / 1000000;
    -- Verilog localparam MDC_DIV; renamed because VHDL is case-insensitive and
    -- the register mdc_div keeps its Verilog name (the proof pairs it by name).
    constant MDC_DIV_C   : integer := max4(MDC_DIV_RAW);
    -- Verilog `localparam [15:0]`: truncated to 16 bits.
    constant MDC_RISE    : unsigned(15 downto 0) := to_unsigned((MDC_DIV_C / 2 - 1) mod 65536, 16);
    constant MDC_LAST    : unsigned(15 downto 0) := to_unsigned((MDC_DIV_C - 1) mod 65536, 16);

    signal mdc_div     : unsigned(15 downto 0);
    signal mdc_rising  : std_logic;
    signal mdc_falling : std_logic;

    -- State machine - drives data on MDC falling edge (setup for PHY)
    -- PHY samples on rising edge; master samples read data on rising edge
    constant S_IDLE : std_logic_vector(3 downto 0) := "0000";  -- 4'd0
    constant S_PRE  : std_logic_vector(3 downto 0) := "0001";  -- 4'd1
    constant S_ST1  : std_logic_vector(3 downto 0) := "0010";  -- 4'd2
    constant S_ST2  : std_logic_vector(3 downto 0) := "0011";  -- 4'd3
    constant S_OP1  : std_logic_vector(3 downto 0) := "0100";  -- 4'd4
    constant S_OP2  : std_logic_vector(3 downto 0) := "0101";  -- 4'd5
    constant S_PHY  : std_logic_vector(3 downto 0) := "0110";  -- 4'd6
    constant S_REG  : std_logic_vector(3 downto 0) := "0111";  -- 4'd7
    constant S_TA1  : std_logic_vector(3 downto 0) := "1000";  -- 4'd8
    constant S_TA2  : std_logic_vector(3 downto 0) := "1001";  -- 4'd9
    constant S_DATA : std_logic_vector(3 downto 0) := "1010";  -- 4'd10
    constant S_DONE : std_logic_vector(3 downto 0) := "1011";  -- 4'd11

    signal state     : std_logic_vector(3 downto 0);
    signal bit_cnt   : unsigned(5 downto 0);
    signal is_write  : std_logic;                      -- C22 write, or C45 op that drives data on TA/DATA
    signal phy_addr  : std_logic_vector(4 downto 0);
    signal reg_addr  : std_logic_vector(4 downto 0);   -- C22 REGAD or C45 DEVAD
    signal shift_reg : std_logic_vector(15 downto 0);
    signal c45_en    : std_logic;
    signal c45_op    : std_logic_vector(1 downto 0);   -- latched C45 OP code

    signal drive_data : std_logic;

    signal mdio_i_sampled   : std_logic;
    signal dbg_rd_low_cnt_i : unsigned(4 downto 0);

begin

    mdc_rising  <= '1' when mdc_div = MDC_RISE else '0';
    mdc_falling <= '1' when mdc_div = MDC_LAST else '0';

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            mdc_div <= (others => '0');
            mdc     <= '0';
        elsif rising_edge(clk) then
            if mdc_div >= MDC_LAST then
                mdc_div <= (others => '0');
            else
                mdc_div <= mdc_div + 1;
            end if;
            if mdc_div = MDC_RISE then
                mdc <= '1';
            elsif mdc_div = MDC_LAST then
                mdc <= '0';
            end if;
        end if;
    end process;

    -- In C45 mode, ADDRESS (00) and WRITE (01) drive the bus on TA/DATA;
    -- READ (11) and READ-INC (10) tri-state the bus the same way as C22 reads.
    drive_data <= '1' when c45_en = '1' and (c45_op = "00" or c45_op = "01") else
                  '0' when c45_en = '1' else
                  is_write;

    -- Capture MDIO input on MDC rising edge per IEEE 802.3 clause 22.3.4.
    -- PHY changes data on falling edge; we sample on rising edge.
    process (clk, rst_n)
    begin
        if rst_n = '0' then
            mdio_i_sampled <= '1';
        elsif rising_edge(clk) then
            if mdc_rising = '1' then
                mdio_i_sampled <= mdio_i;
            end if;
        end if;
    end process;

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            state            <= S_IDLE;
            bit_cnt          <= (others => '0');
            mdio_o           <= '1';
            mdio_oe          <= '0';
            cmd_rdata        <= (others => '0');
            cmd_done         <= '0';
            is_write         <= '0';
            phy_addr         <= (others => '0');
            reg_addr         <= (others => '0');
            shift_reg        <= (others => '0');
            c45_en           <= '0';
            c45_op           <= (others => '0');
            dbg_rd_low_cnt_i <= (others => '0');
            dbg_rd_raw       <= (others => '0');
        elsif rising_edge(clk) then
            cmd_done <= '0';

            if state = S_IDLE then
                if cmd_valid = '1' then
                    is_write  <= cmd_write;
                    phy_addr  <= cmd_phy;
                    reg_addr  <= cmd_reg;
                    shift_reg <= cmd_wdata;
                    c45_en    <= cmd_c45_en;
                    c45_op    <= cmd_c45_op;
                    state     <= S_PRE;
                    bit_cnt   <= (others => '0');
                    mdio_oe   <= '1';
                    mdio_o    <= '1';
                end if;
            elsif mdc_falling = '1' then
                -- Change data on falling edge (setup time before rising edge)
                case state is
                    when S_PRE =>
                        mdio_o  <= '1';
                        mdio_oe <= '1';
                        bit_cnt <= bit_cnt + 1;
                        if bit_cnt >= 31 then
                            state <= S_ST1;
                        end if;

                    -- ST: C22 = 01, C45 = 00
                    when S_ST1 =>
                        mdio_o <= '0';
                        state  <= S_ST2;
                    when S_ST2 =>
                        mdio_o <= not c45_en;
                        state  <= S_OP1;

                    -- OP: C22 read=10 / write=01; C45 = c45_op[1:0]
                    when S_OP1 =>
                        if c45_en = '1' then
                            mdio_o <= c45_op(1);
                        else
                            mdio_o <= not is_write;
                        end if;
                        state <= S_OP2;
                    when S_OP2 =>
                        if c45_en = '1' then
                            mdio_o <= c45_op(0);
                        else
                            mdio_o <= is_write;
                        end if;
                        state   <= S_PHY;
                        bit_cnt <= (others => '0');

                    when S_PHY =>
                        mdio_o  <= msb_first_bit(phy_addr, bit_cnt);
                        bit_cnt <= bit_cnt + 1;
                        if bit_cnt >= 4 then
                            state   <= S_REG;
                            bit_cnt <= (others => '0');
                        end if;

                    when S_REG =>
                        mdio_o  <= msb_first_bit(reg_addr, bit_cnt);
                        bit_cnt <= bit_cnt + 1;
                        if bit_cnt >= 4 then
                            state <= S_TA1;
                        end if;

                    when S_TA1 =>
                        if drive_data = '1' then
                            mdio_o <= '1';   -- master-driven TA: 10
                        else
                            mdio_oe <= '0';  -- read: release bus, PHY drives 0
                        end if;
                        state <= S_TA2;

                    when S_TA2 =>
                        if drive_data = '1' then
                            mdio_o <= '0';
                        end if;
                        -- For reads: PHY drives 0 here; D[15] only becomes stable on the
                        -- NEXT MDC falling edge.  S_DATA runs 17 iterations for reads
                        -- (bit_cnt 0..16): iteration 0 captures TA[2]=0 into shift_reg[0],
                        -- which is discarded by the final {shift_reg[14:0], mdio_i_sampled}.
                        -- Iterations 1..16 then correctly capture D[15:0].
                        state   <= S_DATA;
                        bit_cnt <= (others => '0');

                    when S_DATA =>
                        if drive_data = '1' then
                            mdio_o    <= shift_reg(15);
                            shift_reg <= shift_reg(14 downto 0) & '0';
                        else
                            -- Read: use rising-edge-captured MDIO sample
                            shift_reg <= shift_reg(14 downto 0) & mdio_i_sampled;
                            if mdio_i_sampled = '0' then
                                dbg_rd_low_cnt_i <= dbg_rd_low_cnt_i + 1;
                            end if;
                        end if;
                        bit_cnt <= bit_cnt + 1;
                        -- Reads run 17 iterations (bit_cnt 0..16): iteration 0 captures
                        -- TA[2]=0 which ends up at shift_reg[15] and is discarded by
                        -- {shift_reg[14:0], mdio_i_sampled}; iterations 1..16 capture
                        -- D[15:0].  Writes run 16 iterations (bit_cnt 0..15) unchanged.
                        if (drive_data = '0' and bit_cnt >= 16) or (drive_data = '1' and bit_cnt >= 15) then
                            if drive_data = '0' then
                                cmd_rdata  <= shift_reg(14 downto 0) & mdio_i_sampled;
                                dbg_rd_raw <= shift_reg(14 downto 0) & mdio_i_sampled;
                            end if;
                            state <= S_DONE;
                        end if;

                    when S_DONE =>
                        mdio_oe  <= '0';
                        cmd_done <= '1';
                        state    <= S_IDLE;

                    when others =>
                        state <= S_IDLE;
                end case;
            end if;
        end if;
    end process;

    dbg_rd_low_cnt <= std_logic_vector(dbg_rd_low_cnt_i);

end architecture rtl;
