--=============================================================================
-- Module Name : tb_lm_i2c_target_reset
-- Library     : -
-- Project     : lm_i2c
-- Company     : LogiMentor Srl
-------------------------------------------------------------------------------
-- Description:
--  Reset-abort regression for the major I2C target phases. Each generic case
--  runs in a fresh simulation and proves release, stale-handshake removal, and
--  acceptance of a new transaction after reset.
-------------------------------------------------------------------------------
-- Copyright 2026 LogiMentor Srl
-- SPDX-License-Identifier: Apache-2.0
--=============================================================================

library ieee;
use ieee.std_logic_1164.all;

library std;
use std.env.all;

entity tb_lm_i2c_target_reset is
  generic (
    g_reset_case : natural := 0
  );
end entity tb_lm_i2c_target_reset;

architecture a_tb of tb_lm_i2c_target_reset is

  constant C_CLK_FREQ_HZ : positive := 10_000_000;
  constant C_I2C_FREQ_HZ : positive := 400_000;
  constant C_CLK_PERIOD   : time :=
    2 * ((1 sec / C_CLK_FREQ_HZ + 2 fs) / 2);
  constant C_T_LOW        : time := 1.3 us;
  constant C_T_HIGH       : time := 0.6 us;
  constant C_T_BUF        : time := 1.3 us;
  constant C_T_HD_STA     : time := 0.6 us;
  constant C_T_SU_STO     : time := 0.6 us;
  constant C_T_HD_DAT     : time := 300 ns;
  constant C_WATCHDOG     : time := 2 ms;
  constant C_WRITE_ADDRESS : std_logic_vector(7 downto 0) := x"A4";

  signal s_clk   : std_logic := '0';
  signal s_rst_n : std_logic := '0';

  signal s_enable  : std_logic := '1';
  signal s_address : std_logic_vector(6 downto 0) := "1010010";

  signal s_active    : std_logic;
  signal s_read      : std_logic;
  signal s_addressed : std_logic;
  signal s_stop      : std_logic;

  signal s_rx_valid : std_logic;
  signal s_rx_ready : std_logic := '0';
  signal s_rx_data  : std_logic_vector(7 downto 0);
  signal s_rx_nack  : std_logic := '0';
  signal s_tx_valid : std_logic := '0';
  signal s_tx_ready : std_logic;
  signal s_tx_data  : std_logic_vector(7 downto 0) := x"A5";

  signal s_target_scl_low : std_logic;
  signal s_target_sda_low : std_logic;
  signal s_bfm_scl_low    : std_logic := '0';
  signal s_bfm_sda_low    : std_logic := '0';
  signal s_scl            : std_logic;
  signal s_sda            : std_logic;

begin

  assert g_reset_case <= 7
    report "g_reset_case must be in the range 0 through 7"
    severity failure;

  s_scl <= '0' when
    s_target_scl_low = '1' or s_bfm_scl_low = '1'
    else '1';
  s_sda <= '0' when
    s_target_sda_low = '1' or s_bfm_sda_low = '1'
    else '1';

  inst_dut : entity work.lm_i2c_target
    generic map (
      g_clk_freq_hz => C_CLK_FREQ_HZ,
      g_i2c_freq_hz => C_I2C_FREQ_HZ
    )
    port map (
      clk_i       => s_clk,
      rst_n_i     => s_rst_n,
      enable_i    => s_enable,
      address_i   => s_address,
      active_o    => s_active,
      read_o      => s_read,
      addressed_o => s_addressed,
      stop_o      => s_stop,
      rx_valid_o  => s_rx_valid,
      rx_ready_i  => s_rx_ready,
      rx_data_o   => s_rx_data,
      rx_nack_i   => s_rx_nack,
      tx_valid_i  => s_tx_valid,
      tx_ready_o  => s_tx_ready,
      tx_data_i   => s_tx_data,
      scl_i       => s_scl,
      sda_i       => s_sda,
      scl_low_o   => s_target_scl_low,
      sda_low_o   => s_target_sda_low
    );

  proc_clock : process
  begin
    s_clk <= '0';
    wait for C_CLK_PERIOD / 2;
    s_clk <= '1';
    wait for C_CLK_PERIOD / 2;
  end process proc_clock;

  proc_stimulus : process

    procedure p_wait_clocks (
      constant count : in natural
    ) is
    begin
      for v_cycle in 1 to count loop
        wait until rising_edge(s_clk);
      end loop;
    end procedure p_wait_clocks;

    procedure p_start is
    begin
      s_bfm_scl_low <= '0';
      s_bfm_sda_low <= '0';
      if s_scl /= '1' or s_sda /= '1' then
        wait until s_scl = '1' and s_sda = '1';
      end if;
      wait for C_T_BUF;
      s_bfm_sda_low <= '1';
      wait for C_T_HD_STA;
      s_bfm_scl_low <= '1';
    end procedure p_start;

    procedure p_controller_bit (
      constant value : in std_logic
    ) is
    begin
      wait for C_T_HD_DAT;
      if value = '0' then
        s_bfm_sda_low <= '1';
      else
        s_bfm_sda_low <= '0';
      end if;
      wait for C_T_LOW - C_T_HD_DAT;
      s_bfm_scl_low <= '0';
      wait until s_scl = '1';
      wait for C_T_HIGH;
      s_bfm_scl_low <= '1';
    end procedure p_controller_bit;

    procedure p_address (
      constant value : in std_logic_vector(7 downto 0)
    ) is
    begin
      for v_bit in 7 downto 0 loop
        p_controller_bit(value(v_bit));
      end loop;
      wait for C_T_HD_DAT;
      s_bfm_sda_low <= '0';
      wait for C_T_LOW - C_T_HD_DAT;
      s_bfm_scl_low <= '0';
      wait until s_scl = '1';
      wait for C_T_HIGH / 2;
      assert s_sda = '0'
        report "reset setup address was not ACKed"
        severity failure;
      wait for C_T_HIGH - C_T_HIGH / 2;
      s_bfm_scl_low <= '1';
      wait for C_T_HD_DAT;
      s_bfm_sda_low <= '0';
    end procedure p_address;

    procedure p_stop is
    begin
      s_bfm_scl_low <= '1';
      s_bfm_sda_low <= '1';
      wait for C_T_LOW;
      s_bfm_scl_low <= '0';
      wait until s_scl = '1';
      wait for C_T_SU_STO;
      s_bfm_sda_low <= '0';
      wait for C_T_BUF;
    end procedure p_stop;

    procedure p_send_data_bits (
      constant value : in std_logic_vector(7 downto 0);
      constant count : in positive
    ) is
    begin
      for v_bit in 7 downto 8 - count loop
        p_controller_bit(value(v_bit));
      end loop;
    end procedure p_send_data_bits;

    procedure p_load_tx is
    begin
      while s_tx_ready /= '1' loop
        wait until rising_edge(s_clk);
      end loop;
      s_tx_valid <= '1';
      wait until rising_edge(s_clk) and s_tx_ready = '1';
      s_tx_valid <= '0';
    end procedure p_load_tx;

    procedure p_clock_read_bits (
      constant count : in positive
    ) is
    begin
      for v_bit in 7 downto 8 - count loop
        wait for C_T_LOW;
        s_bfm_scl_low <= '0';
        wait until s_scl = '1';
        wait for C_T_HIGH / 2;
        assert s_sda = s_tx_data(v_bit)
          report "reset setup read bit was incorrect"
          severity failure;
        wait for C_T_HIGH - C_T_HIGH / 2;
        s_bfm_scl_low <= '1';
      end loop;
    end procedure p_clock_read_bits;

    procedure p_check_reset_abort is
    begin
      s_rst_n <= '0';
      wait until rising_edge(s_clk);
      wait for 0 ns;
      wait for 0 ns;
      assert s_target_scl_low = '0' and s_target_sda_low = '0'
        report "reset did not release target open-drain controls"
        severity failure;
      assert s_active = '0' and s_read = '0' and
             s_addressed = '0' and s_stop = '0' and
             s_rx_valid = '0' and s_tx_ready = '0'
        report "reset left stale target transaction or handshake state"
        severity failure;

      s_bfm_scl_low <= '0';
      s_bfm_sda_low <= '0';
      p_wait_clocks(3);
      s_rst_n <= '1';
      p_wait_clocks(5);
      assert s_stop = '0' and s_rx_valid = '0' and s_tx_ready = '0'
        report "reset generated STOP or leaked a stale handshake"
        severity failure;

      p_start;
      p_address(x"A4");
      assert s_active = '1' and s_read = '0'
        report "fresh legal transaction failed after reset"
        severity failure;
      p_stop;
      p_wait_clocks(4);
      assert s_active = '0'
        report "post-reset fresh transaction did not terminate"
        severity failure;
    end procedure p_check_reset_abort;

  begin
    s_rst_n <= '0';
    p_wait_clocks(6);
    s_rst_n <= '1';
    p_wait_clocks(6);

    case g_reset_case is
      when 0 =>
        p_start;
        p_send_data_bits(x"A4", 3);
        p_check_reset_abort;

      when 1 =>
        p_start;
        for v_bit in 7 downto 0 loop
          p_controller_bit(C_WRITE_ADDRESS(v_bit));
        end loop;
        wait for C_T_HD_DAT;
        s_bfm_sda_low <= '0';
        wait for C_T_LOW - C_T_HD_DAT;
        s_bfm_scl_low <= '0';
        while s_target_sda_low /= '1' loop
          wait until rising_edge(s_clk);
        end loop;
        p_check_reset_abort;

      when 2 =>
        p_start;
        p_address(x"A4");
        p_send_data_bits(x"5A", 4);
        p_check_reset_abort;

      when 3 =>
        p_start;
        p_address(x"A4");
        s_rx_ready <= '0';
        p_send_data_bits(x"5A", 8);
        wait for C_T_LOW;
        s_bfm_sda_low <= '0';
        s_bfm_scl_low <= '0';
        while s_rx_valid /= '1' or s_target_scl_low /= '1' loop
          wait until rising_edge(s_clk);
        end loop;
        p_check_reset_abort;

      when 4 =>
        p_start;
        p_address(x"A5");
        p_load_tx;
        p_clock_read_bits(4);
        p_check_reset_abort;

      when 5 =>
        p_start;
        p_address(x"A5");
        while s_tx_ready /= '1' loop
          wait until rising_edge(s_clk);
        end loop;
        wait for C_T_LOW;
        s_bfm_scl_low <= '0';
        while s_target_scl_low /= '1' loop
          wait until rising_edge(s_clk);
        end loop;
        p_check_reset_abort;

      when 6 =>
        p_start;
        p_address(x"A5");
        p_load_tx;
        p_clock_read_bits(8);
        wait for C_T_LOW;
        while s_target_sda_low /= '0' loop
          wait until rising_edge(s_clk);
        end loop;
        p_check_reset_abort;

      when 7 =>
        p_start;
        p_address(x"A5");
        p_load_tx;
        p_clock_read_bits(8);
        wait for C_T_LOW;
        s_bfm_sda_low <= '0';
        s_bfm_scl_low <= '0';
        wait until s_scl = '1';
        wait for C_T_HIGH;
        s_bfm_scl_low <= '1';
        p_wait_clocks(4);
        assert s_tx_ready = '0'
          report "controller NACK incorrectly requested another TX byte"
          severity failure;
        p_check_reset_abort;

      when others =>
        assert false report "unreachable reset case" severity failure;
    end case;

    report "lm_i2c_target reset case passed: " &
      integer'image(g_reset_case)
      severity note;
    stop;
    wait;
  end process proc_stimulus;

  proc_watchdog : process
  begin
    wait for C_WATCHDOG;
    assert false report "target reset regression watchdog expired"
      severity failure;
  end process proc_watchdog;

end architecture a_tb;
