-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 Leonardo Capossio - bard0 design
-- =============================================================================
-- i2c_init.vhd - Power-up I2C register writer
-- Plays a fixed list of I2C write transactions out of a ROM, then asserts
-- done. Each ROM entry is one transaction of 2 or 3 bytes (address+W byte
-- first), e.g. a mux channel select or a {reg, value} register write. Any
-- NACK aborts the pass; the whole list is retried after RETRY_DELAY with the
-- `alt` ROM input toggled, which lets the ROM try a second device address.
--
-- The ROM is the rom_entry() function in zcu106_si5328_rom_pkg.vhd (the
-- mirror of zcu106_si5328_rom.vh, which i2c_init.v includes), which also
-- defines ROM_LEN. Entry format: {last[1:0], b0, b1, b2}, where `last` is the
-- index of the final byte (1 = two-byte write, 2 = three-byte write).
--
-- SCL/SDA are open drain: *_t = 1 releases the line (pull-up), 0 drives low.
-- No clock stretching (the Si5328 and TCA9548A never stretch).
-- VHDL port of fpga/zcu106/rtl/i2c_init.v (formally proven equivalent; see
-- sim/parity/).
-- =============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.zcu106_si5328_rom_pkg.all;

entity i2c_init is
    generic (
        CLK_HZ      : integer := 50_000_000;
        I2C_HZ      : integer := 100_000;
        START_DELAY : integer := 50_000_000 / 10;  -- cycles before the first pass
        RETRY_DELAY : integer := 50_000_000 / 10;  -- cycles between failed passes
        DONE_DELAY  : integer := 50_000_000 / 2    -- cycles after the last write
    );
    port (
        clk        : in  std_logic;
        rst_n      : in  std_logic;

        scl_t      : out std_logic;
        sda_t      : out std_logic;
        sda_i      : in  std_logic;

        done       : out std_logic;     -- list written and DONE_DELAY elapsed
        busy       : out std_logic;
        nack_count : out std_logic_vector(7 downto 0)
    );
end entity i2c_init;

architecture rtl of i2c_init is

    -- SDA is sampled in the middle of SCL high, a quarter bit after the rise,
    -- so two synchronizer cycles of latency are harmless.
    signal sda_sync : std_logic_vector(1 downto 0);
    signal sda_s    : std_logic;

    attribute ASYNC_REG : string;
    attribute ASYNC_REG of sda_sync : signal is "TRUE";

    -- Quarter-bit tick: SCL low/high phases are each two quarters.
    constant QTR   : integer := CLK_HZ / (I2C_HZ * 4);
    constant DLY_W : integer := 32;

    signal qcnt  : unsigned(15 downto 0);
    signal qtick : std_logic;

    constant S_WAIT  : std_logic_vector(3 downto 0) := "0000";
    constant S_LOAD  : std_logic_vector(3 downto 0) := "0001";
    constant S_START : std_logic_vector(3 downto 0) := "0010";
    constant S_BIT   : std_logic_vector(3 downto 0) := "0011";
    constant S_ACK   : std_logic_vector(3 downto 0) := "0100";
    constant S_STOP  : std_logic_vector(3 downto 0) := "0101";
    constant S_NEXT  : std_logic_vector(3 downto 0) := "0110";
    constant S_DONE  : std_logic_vector(3 downto 0) := "0111";

    signal state   : std_logic_vector(3 downto 0);
    signal delay   : unsigned(DLY_W-1 downto 0);
    signal idx     : unsigned(15 downto 0);         -- ROM entry
    signal entry   : std_logic_vector(25 downto 0); -- {last[1:0], b0, b1, b2}
    signal byte_i  : unsigned(1 downto 0);          -- byte within the transaction
    signal shreg   : std_logic_vector(7 downto 0);
    signal bit_i   : unsigned(2 downto 0);
    signal phase   : unsigned(1 downto 0);          -- quarter within the bit
    signal nacked  : std_logic;
    signal alt     : std_logic;                     -- toggles on every retry

    signal nack_count_i : unsigned(7 downto 0);

    signal entry_last : unsigned(1 downto 0);
    signal entry_byte : std_logic_vector(7 downto 0);

begin

    process (clk)
    begin
        if rising_edge(clk) then
            sda_sync <= sda_sync(0) & sda_i;
        end if;
    end process;
    sda_s <= sda_sync(1);

    qtick <= '1' when qcnt = to_unsigned(0, 16) else '0';

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            qcnt <= to_unsigned((QTR - 1) mod 65536, 16);
        elsif rising_edge(clk) then
            if qtick = '1' then
                qcnt <= to_unsigned((QTR - 1) mod 65536, 16);
            else
                qcnt <= qcnt - 1;
            end if;
        end if;
    end process;

    entry_last <= unsigned(entry(25 downto 24));
    entry_byte <= entry(23 downto 16) when byte_i = "00" else
                  entry(15 downto 8)  when byte_i = "01" else
                  entry(7 downto 0);

    nack_count <= std_logic_vector(nack_count_i);

    process (clk, rst_n)
    begin
        if rst_n = '0' then
            state        <= S_WAIT;
            delay        <= to_unsigned(START_DELAY, DLY_W);
            idx          <= (others => '0');
            entry        <= (others => '0');
            byte_i       <= "00";
            shreg        <= (others => '0');
            bit_i        <= "000";
            phase        <= "00";
            nacked       <= '0';
            alt          <= '0';
            scl_t        <= '1';
            sda_t        <= '1';
            done         <= '0';
            busy         <= '0';
            nack_count_i <= (others => '0');
        elsif rising_edge(clk) then
            case state is
            when S_WAIT =>
                scl_t <= '1';
                sda_t <= '1';
                if delay /= 0 then
                    delay <= delay - 1;
                else
                    idx    <= (others => '0');
                    nacked <= '0';
                    busy   <= '1';
                    state  <= S_LOAD;
                end if;

            when S_LOAD =>
                entry  <= rom_entry(std_logic_vector(idx), alt);
                byte_i <= "00";
                phase  <= "00";
                state  <= S_START;

            -- START: SDA falls while SCL is high, then SCL falls.
            when S_START =>
                if qtick = '1' then
                    phase <= phase + 1;
                    case phase is
                        when "00" => scl_t <= '1'; sda_t <= '1';
                        when "01" => sda_t <= '0';
                        when "10" => scl_t <= '0';
                        when others =>
                            shreg <= entry_byte;
                            bit_i <= "111";
                            state <= S_BIT;
                    end case;
                end if;

            -- Data bit: set SDA with SCL low, pulse SCL high for two quarters.
            when S_BIT =>
                if qtick = '1' then
                    phase <= phase + 1;
                    case phase is
                        when "00" => sda_t <= shreg(7);
                        when "01" => scl_t <= '1';
                        when "10" => null;
                        when others =>
                            scl_t <= '0';
                            shreg <= shreg(6 downto 0) & '0';
                            if bit_i = "000" then
                                state <= S_ACK;
                            else
                                bit_i <= bit_i - 1;
                            end if;
                    end case;
                end if;

            -- ACK: release SDA, sample it mid SCL-high.
            when S_ACK =>
                if qtick = '1' then
                    phase <= phase + 1;
                    case phase is
                        when "00" => sda_t <= '1';
                        when "01" => scl_t <= '1';
                        when "10" =>
                            if sda_s = '1' then
                                nacked <= '1';
                            end if;
                        when others =>
                            scl_t <= '0';
                            if nacked = '1' or byte_i = entry_last then
                                state <= S_STOP;
                            else
                                byte_i <= byte_i + 1;
                                state  <= S_NEXT;
                            end if;
                    end case;
                end if;

            when S_NEXT =>
                shreg <= entry_byte;
                bit_i <= "111";
                state <= S_BIT;

            -- STOP: SDA rises while SCL is high.
            when S_STOP =>
                if qtick = '1' then
                    phase <= phase + 1;
                    case phase is
                        when "00" => sda_t <= '0';
                        when "01" => scl_t <= '1';
                        when "10" => sda_t <= '1';
                        when others =>
                            if nacked = '1' then
                                if nack_count_i = x"FF" then
                                    nack_count_i <= x"FF";
                                else
                                    nack_count_i <= nack_count_i + 1;
                                end if;
                                alt   <= not alt;
                                busy  <= '0';
                                delay <= to_unsigned(RETRY_DELAY, DLY_W);
                                state <= S_WAIT;
                            elsif to_integer(idx) = ROM_LEN - 1 then
                                busy  <= '0';
                                delay <= to_unsigned(DONE_DELAY, DLY_W);
                                state <= S_DONE;
                            else
                                idx   <= idx + 1;
                                state <= S_LOAD;
                            end if;
                    end case;
                end if;

            when S_DONE =>
                if delay /= 0 then
                    delay <= delay - 1;
                else
                    done  <= '1';
                end if;

            when others =>
                state <= S_WAIT;
            end case;
        end if;
    end process;

end architecture rtl;
