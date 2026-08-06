--=============================================================================
-- Module Name : tb_lm_i2c_master_reset
-- Library     : -
-- Project     : lm_i2c
-- Company     : LogiMentor Srl
-------------------------------------------------------------------------------
-- Description:
--  Reset-abort regression for the major I2C controller phases. Each generic
--  case is run in a fresh simulation so no aborted target transaction can
--  affect a later case.
-------------------------------------------------------------------------------
-- Copyright 2026 LogiMentor Srl
-- SPDX-License-Identifier: Apache-2.0
--=============================================================================

library ieee;
use ieee.std_logic_1164.all;

library std;
use std.env.all;

entity tb_lm_i2c_master_reset is
  generic (
    g_reset_case : natural := 0
  );
end entity tb_lm_i2c_master_reset;

architecture a_tb of tb_lm_i2c_master_reset is

  constant C_CLK_FREQ_HZ : positive := 10_000_000;
  constant C_I2C_FREQ_HZ : positive := 400_000;
  constant C_CLK_PERIOD   : time :=
    2 * ((1 sec / C_CLK_FREQ_HZ + 2 fs) / 2);
  constant C_DATA_HOLD    : time := 300 ns;
  constant C_WATCHDOG     : time := 2 ms;

  signal s_clk   : std_logic := '0';
  signal s_rst_n : std_logic := '0';

  signal s_cmd_valid : std_logic := '0';
  signal s_cmd_start : std_logic := '0';
  signal s_cmd_stop  : std_logic := '0';
  signal s_cmd_read  : std_logic := '0';
  signal s_cmd_data  : std_logic_vector(7 downto 0) := (others => '0');
  signal s_cmd_nack  : std_logic := '1';
  signal s_cmd_ready : std_logic;

  signal s_rsp_ready     : std_logic := '0';
  signal s_rsp_valid     : std_logic;
  signal s_rsp_data      : std_logic_vector(7 downto 0);
  signal s_rsp_nack      : std_logic;
  signal s_rsp_arb_lost  : std_logic;
  signal s_rsp_cmd_error : std_logic;

  signal s_busy     : std_logic;
  signal s_bus_busy : std_logic;

  signal s_dut_scl_low  : std_logic;
  signal s_dut_sda_low  : std_logic;
  signal s_peer_scl_low : std_logic := '0';
  signal s_peer_sda_low : std_logic := '0';
  signal s_scl          : std_logic;
  signal s_sda          : std_logic;

  procedure p_wait_start (
    signal scl : in std_logic;
    signal sda : in std_logic
  ) is
  begin
    wait until sda'event and sda = '0' and scl = '1';
  end procedure p_wait_start;

begin

  assert g_reset_case <= 8
    report "g_reset_case must be in the range 0 through 8"
    severity failure;

  s_scl <= '0' when
    s_dut_scl_low = '1' or s_peer_scl_low = '1'
    else '1';
  s_sda <= '0' when
    s_dut_sda_low = '1' or s_peer_sda_low = '1'
    else '1';

  inst_dut : entity work.lm_i2c_master
    generic map (
      g_clk_freq_hz => C_CLK_FREQ_HZ,
      g_i2c_freq_hz => C_I2C_FREQ_HZ
    )
    port map (
      clk_i           => s_clk,
      rst_n_i         => s_rst_n,
      cmd_valid_i     => s_cmd_valid,
      cmd_start_i     => s_cmd_start,
      cmd_stop_i      => s_cmd_stop,
      cmd_read_i      => s_cmd_read,
      cmd_data_i      => s_cmd_data,
      cmd_nack_i      => s_cmd_nack,
      rsp_ready_i     => s_rsp_ready,
      scl_i           => s_scl,
      sda_i           => s_sda,
      cmd_ready_o     => s_cmd_ready,
      rsp_valid_o     => s_rsp_valid,
      rsp_data_o      => s_rsp_data,
      rsp_nack_o      => s_rsp_nack,
      rsp_arb_lost_o  => s_rsp_arb_lost,
      rsp_cmd_error_o => s_rsp_cmd_error,
      busy_o          => s_busy,
      bus_busy_o      => s_bus_busy,
      scl_low_o       => s_dut_scl_low,
      sda_low_o       => s_dut_sda_low
    );

  proc_clock : process
  begin
    s_clk <= '0';
    wait for C_CLK_PERIOD / 2;
    s_clk <= '1';
    wait for C_CLK_PERIOD / 2;
  end process proc_clock;

  proc_stimulus : process

    procedure p_launch (
      constant start_cmd : in boolean;
      constant stop_cmd  : in boolean;
      constant read_cmd  : in boolean;
      constant data      : in std_logic_vector(7 downto 0);
      constant nack      : in std_logic
    ) is
    begin
      wait until rising_edge(s_clk) and s_cmd_ready = '1';
      if start_cmd then
        s_cmd_start <= '1';
      else
        s_cmd_start <= '0';
      end if;
      if stop_cmd then
        s_cmd_stop <= '1';
      else
        s_cmd_stop <= '0';
      end if;
      if read_cmd then
        s_cmd_read <= '1';
      else
        s_cmd_read <= '0';
      end if;
      s_cmd_data  <= data;
      s_cmd_nack  <= nack;
      s_cmd_valid <= '1';
      wait until rising_edge(s_clk);
      s_cmd_valid <= '0';
      s_cmd_start <= '0';
      s_cmd_stop  <= '0';
      s_cmd_read  <= '0';
      wait for 0 ns;
      wait for 0 ns;
    end procedure p_launch;

    procedure p_receive_byte (
      constant expected  : in std_logic_vector(7 downto 0);
      constant drive_ack : in boolean
    ) is
    begin
      for v_bit in 7 downto 0 loop
        wait until rising_edge(s_scl);
        assert s_sda = expected(v_bit)
          report "reset target received an incorrect write bit"
          severity failure;
        wait until falling_edge(s_scl);
      end loop;
      wait for C_DATA_HOLD;
      if drive_ack then
        s_peer_sda_low <= '1';
      else
        s_peer_sda_low <= '0';
      end if;
      wait until rising_edge(s_scl);
      wait until falling_edge(s_scl);
      wait for C_DATA_HOLD;
      s_peer_sda_low <= '0';
    end procedure p_receive_byte;

    procedure p_send_byte (
      constant data : in std_logic_vector(7 downto 0)
    ) is
    begin
      for v_bit in 7 downto 0 loop
        wait for C_DATA_HOLD;
        if data(v_bit) = '0' then
          s_peer_sda_low <= '1';
        else
          s_peer_sda_low <= '0';
        end if;
        wait until rising_edge(s_scl);
        wait until falling_edge(s_scl);
      end loop;
      wait for C_DATA_HOLD;
      s_peer_sda_low <= '0';
    end procedure p_send_byte;

    procedure p_consume_response is
    begin
      while s_rsp_valid /= '1' loop
        wait until rising_edge(s_clk);
      end loop;
      assert s_rsp_arb_lost = '0' and s_rsp_cmd_error = '0'
        report "setup command failed before reset injection"
        severity failure;
      s_rsp_ready <= '1';
      wait until rising_edge(s_clk);
      s_rsp_ready <= '0';
      wait until rising_edge(s_clk);
    end procedure p_consume_response;

    procedure p_wait_bus_free is
    begin
      while s_bus_busy /= '0' loop
        wait until rising_edge(s_clk);
      end loop;
    end procedure p_wait_bus_free;

    procedure p_establish_ownership is
    begin
      p_launch(true, false, false, x"A1", '1');
      p_wait_start(s_scl, s_sda);
      p_receive_byte(x"A1", true);
      p_consume_response;
    end procedure p_establish_ownership;

    procedure p_check_reset_abort is
    begin
      s_rst_n <= '0';
      wait until rising_edge(s_clk);
      wait for 0 ns;
      wait for 0 ns;
      assert s_dut_scl_low = '0' and s_dut_sda_low = '0'
        report "reset did not release both open-drain controls"
        severity failure;
      assert s_rsp_valid = '0' and s_cmd_ready = '1'
        report "reset left stale command or response state"
        severity failure;
      assert s_bus_busy = '1'
        report "reset incorrectly reported a qualified-free bus"
        severity failure;

      s_peer_scl_low <= '0';
      s_peer_sda_low <= '0';
      wait until rising_edge(s_clk);
      s_rst_n <= '1';
      wait until rising_edge(s_clk);
      assert s_bus_busy = '1'
        report "bus was qualified free immediately after reset release"
        severity failure;
      p_wait_bus_free;
      assert s_rsp_valid = '0' and s_dut_scl_low = '0' and
             s_dut_sda_low = '0'
        report "reset-abort state was not clean after bus qualification"
        severity failure;
    end procedure p_check_reset_abort;

  begin
    if g_reset_case = 0 then
      s_peer_scl_low <= '1';
    end if;

    s_rst_n <= '0';
    wait for 8 * C_CLK_PERIOD;
    wait until rising_edge(s_clk);
    s_rst_n <= '1';

    if g_reset_case = 0 then
      p_launch(true, false, false, x"A0", '1');
      wait for 4 * C_CLK_PERIOD;
      assert s_busy = '1' and s_dut_scl_low = '0' and
             s_dut_sda_low = '0'
        report "busy-bus START did not remain in the wait-for-free phase"
        severity failure;
      p_check_reset_abort;
    else
      p_wait_bus_free;

      case g_reset_case is
        when 1 =>
          p_launch(true, false, false, x"A0", '1');
          p_wait_start(s_scl, s_sda);
          wait for C_CLK_PERIOD;
          assert s_scl = '1' and s_sda = '0'
            report "START-hold reset case did not reach START hold"
            severity failure;
          p_check_reset_abort;

        when 2 =>
          p_launch(true, false, false, x"A0", '1');
          p_wait_start(s_scl, s_sda);
          wait until falling_edge(s_scl);
          wait for 2 * C_CLK_PERIOD;
          assert s_dut_scl_low = '1'
            report "write-LOW reset case did not reach SCL LOW"
            severity failure;
          p_check_reset_abort;

        when 3 =>
          p_launch(true, false, false, x"A0", '1');
          p_wait_start(s_scl, s_sda);
          wait until rising_edge(s_scl);
          assert s_dut_scl_low = '0'
            report "write-HIGH reset case did not release SCL"
            severity failure;
          p_check_reset_abort;

        when 4 =>
          p_launch(true, false, false, x"A0", '1');
          p_wait_start(s_scl, s_sda);
          for v_bit in 7 downto 0 loop
            wait until rising_edge(s_scl);
            wait until falling_edge(s_scl);
          end loop;
          s_peer_scl_low <= '1';
          wait for C_DATA_HOLD;
          s_peer_sda_low <= '1';
          if s_dut_scl_low /= '0' then
            wait until s_dut_scl_low = '0';
          end if;
          assert s_scl = '0'
            report "target-ACK reset case did not stretch SCL"
            severity failure;
          p_check_reset_abort;

        when 5 =>
          p_launch(true, false, false, x"A0", '1');
          p_wait_start(s_scl, s_sda);
          p_receive_byte(x"A0", true);
          p_consume_response;
          p_launch(true, false, false, x"A1", '1');
          s_peer_scl_low <= '1';
          if s_dut_scl_low /= '0' then
            wait until s_dut_scl_low = '0';
          end if;
          assert s_scl = '0'
            report "repeated-START reset case did not stretch preparation"
            severity failure;
          p_check_reset_abort;

        when 6 =>
          p_establish_ownership;
          p_launch(false, false, true, x"00", '1');
          wait for C_DATA_HOLD;
          s_peer_sda_low <= '0';
          wait until rising_edge(s_scl);
          assert s_dut_scl_low = '0'
            report "read-data reset case did not reach a read HIGH phase"
            severity failure;
          p_check_reset_abort;

        when 7 =>
          p_establish_ownership;
          p_launch(false, false, true, x"00", '0');
          p_send_byte(x"5A");
          wait until rising_edge(s_scl);
          assert s_sda = '0'
            report "controller-ACK reset case did not transmit ACK"
            severity failure;
          p_check_reset_abort;

        when 8 =>
          p_launch(true, true, false, x"A0", '1');
          p_wait_start(s_scl, s_sda);
          p_receive_byte(x"A0", true);
          wait until s_scl = '1';
          assert s_sda = '0'
            report "STOP reset case did not reach STOP setup"
            severity failure;
          p_check_reset_abort;

        when others =>
          assert false report "unreachable reset case" severity failure;
      end case;
    end if;

    report "lm_i2c_master reset case passed: " &
      integer'image(g_reset_case)
      severity note;
    stop;
    wait;
  end process proc_stimulus;

  proc_watchdog : process
  begin
    wait for C_WATCHDOG;
    assert false report "reset regression watchdog expired" severity failure;
  end process proc_watchdog;

end architecture a_tb;
