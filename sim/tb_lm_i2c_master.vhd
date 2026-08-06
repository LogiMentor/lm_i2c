--=============================================================================
-- Module Name : tb_lm_i2c_master
-- Library     : -
-- Project     : lm_i2c
-- Company     : LogiMentor Srl
-------------------------------------------------------------------------------
-- Description:
--  Self-checking behavioral verification for lm_i2c_master.
--  The scripted bus peer in this file is simulation-only and is not a
--  synthesizable I2C slave implementation.
-------------------------------------------------------------------------------
-- Copyright 2026 LogiMentor Srl
-- SPDX-License-Identifier: Apache-2.0
--=============================================================================

library ieee;
use ieee.std_logic_1164.all;

library std;
use std.env.all;

entity tb_lm_i2c_master is
  generic (
    g_clk_freq_hz : positive := 10_000_000;
    g_i2c_freq_hz : positive := 400_000
  );
end entity tb_lm_i2c_master;

architecture a_tb of tb_lm_i2c_master is

  constant C_CLK_PERIOD     : time     := 1 sec / g_clk_freq_hz;
  constant C_TIMEOUT_CYCLES : positive := 32;
  constant C_STRETCH_CYCLES : positive := 10;

  signal s_clk   : std_logic := '0';
  signal s_rst_n : std_logic := '0';

  signal s_cmd_valid : std_logic := '0';
  signal s_cmd_ready : std_logic;
  signal s_start     : std_logic := '0';
  signal s_stop      : std_logic := '0';
  signal s_read      : std_logic := '0';
  signal s_write     : std_logic := '0';
  signal s_ack       : std_logic := '1';
  signal s_data_in   : std_logic_vector(7 downto 0) := (others => '0');

  signal s_rsp_valid : std_logic;
  signal s_data_out  : std_logic_vector(7 downto 0);
  signal s_nack      : std_logic;
  signal s_busy      : std_logic;
  signal s_bus_busy  : std_logic;
  signal s_arb_lost  : std_logic;
  signal s_timeout   : std_logic;
  signal s_cmd_error : std_logic;

  signal s_scl_master_low : std_logic;
  signal s_sda_master_low : std_logic;
  signal s_scl_slave_low  : std_logic := '0';
  signal s_sda_slave_low  : std_logic := '0';
  signal s_scl            : std_logic;
  signal s_sda            : std_logic;

  signal s_phase : natural range 0 to 8 := 0;

  procedure p_wait_start (
    signal scl : in std_logic;
    signal sda : in std_logic
  ) is
  begin
    wait until sda'event and sda = '0' and scl = '1';
  end procedure p_wait_start;

  procedure p_wait_stop (
    signal scl : in std_logic;
    signal sda : in std_logic
  ) is
  begin
    wait until sda'event and sda = '1' and scl = '1';
  end procedure p_wait_stop;

  procedure p_receive_byte (
    signal clk            : in  std_logic;
    signal scl            : in  std_logic;
    signal sda            : in  std_logic;
    signal master_scl_low : in  std_logic;
    signal slave_scl_low  : out std_logic;
    signal slave_sda_low  : out std_logic;
    constant expected     : in  std_logic_vector(7 downto 0);
    constant drive_ack    : in  boolean;
    constant stretch_bit  : in  integer := -1
  ) is
  begin
    for v_bit in 7 downto 0 loop
      if v_bit = stretch_bit then
        if master_scl_low /= '1' then
          wait until master_scl_low = '1';
        end if;
        slave_scl_low <= '1';
        wait until master_scl_low = '0';
        for v_cycle in 1 to C_STRETCH_CYCLES loop
          wait until rising_edge(clk);
        end loop;
        slave_scl_low <= '0';
      end if;

      wait until rising_edge(scl);
      assert sda = expected(v_bit)
        report "received I2C byte differs at bit " & integer'image(v_bit)
        severity failure;
      wait until falling_edge(scl);
    end loop;

    if drive_ack then
      slave_sda_low <= '1';
    else
      slave_sda_low <= '0';
    end if;

    wait until rising_edge(scl);
    if drive_ack then
      assert sda = '0'
        report "scripted slave failed to drive ACK"
        severity failure;
    else
      assert sda = '1'
        report "scripted slave failed to leave NACK high"
        severity failure;
    end if;
    wait until falling_edge(scl);
    slave_sda_low <= '0';
  end procedure p_receive_byte;

  procedure p_send_byte (
    signal scl           : in  std_logic;
    signal sda           : in  std_logic;
    signal slave_sda_low : out std_logic;
    constant value       : in  std_logic_vector(7 downto 0);
    constant expect_ack  : in  boolean
  ) is
  begin
    for v_bit in 7 downto 0 loop
      if value(v_bit) = '0' then
        slave_sda_low <= '1';
      else
        slave_sda_low <= '0';
      end if;
      wait until rising_edge(scl);
      wait until falling_edge(scl);
    end loop;

    slave_sda_low <= '0';
    wait until rising_edge(scl);
    if expect_ack then
      assert sda = '0'
        report "master did not ACK the received byte"
        severity failure;
    else
      assert sda = '1'
        report "master did not NACK the final received byte"
        severity failure;
    end if;
    wait until falling_edge(scl);
  end procedure p_send_byte;

begin

  s_scl <= '0' when s_scl_master_low = '1' or s_scl_slave_low = '1' else '1';
  s_sda <= '0' when s_sda_master_low = '1' or s_sda_slave_low = '1' else '1';

  inst_dut : entity work.lm_i2c_master
    generic map (
      g_clk_freq_hz    => g_clk_freq_hz,
      g_i2c_freq_hz    => g_i2c_freq_hz,
      g_timeout_cycles => C_TIMEOUT_CYCLES
    )
    port map (
      clk_i           => s_clk,
      rst_n_i         => s_rst_n,
      cmd_valid_i     => s_cmd_valid,
      cmd_ready_o     => s_cmd_ready,
      start_i         => s_start,
      stop_i          => s_stop,
      read_i          => s_read,
      write_i         => s_write,
      ack_i           => s_ack,
      data_i          => s_data_in,
      rsp_valid_o     => s_rsp_valid,
      data_o          => s_data_out,
      nack_o          => s_nack,
      busy_o          => s_busy,
      bus_busy_o      => s_bus_busy,
      arb_lost_o      => s_arb_lost,
      timeout_o       => s_timeout,
      cmd_error_o     => s_cmd_error,
      scl_i           => s_scl,
      sda_i           => s_sda,
      scl_drive_low_o => s_scl_master_low,
      sda_drive_low_o => s_sda_master_low
    );

  proc_clock : process
  begin
    s_clk <= '0';
    wait for C_CLK_PERIOD / 2;
    s_clk <= '1';
    wait for C_CLK_PERIOD / 2;
  end process proc_clock;

  proc_slave_model : process
  begin
    wait until s_phase = 1;
    p_wait_start(s_scl, s_sda);
    p_receive_byte(
      s_clk, s_scl, s_sda, s_scl_master_low,
      s_scl_slave_low, s_sda_slave_low, x"A0", true, 4
    );
    p_receive_byte(
      s_clk, s_scl, s_sda, s_scl_master_low,
      s_scl_slave_low, s_sda_slave_low, x"A5", true
    );
    p_wait_stop(s_scl, s_sda);

    wait until s_phase = 2;
    p_wait_start(s_scl, s_sda);
    p_receive_byte(
      s_clk, s_scl, s_sda, s_scl_master_low,
      s_scl_slave_low, s_sda_slave_low, x"A0", true
    );
    p_receive_byte(
      s_clk, s_scl, s_sda, s_scl_master_low,
      s_scl_slave_low, s_sda_slave_low, x"12", true
    );
    p_wait_start(s_scl, s_sda);
    p_receive_byte(
      s_clk, s_scl, s_sda, s_scl_master_low,
      s_scl_slave_low, s_sda_slave_low, x"A1", true
    );
    p_send_byte(s_scl, s_sda, s_sda_slave_low, x"3C", true);
    p_send_byte(s_scl, s_sda, s_sda_slave_low, x"C7", false);
    p_wait_stop(s_scl, s_sda);

    wait until s_phase = 3;
    p_wait_start(s_scl, s_sda);
    p_receive_byte(
      s_clk, s_scl, s_sda, s_scl_master_low,
      s_scl_slave_low, s_sda_slave_low, x"A0", false
    );
    p_wait_stop(s_scl, s_sda);

    wait until s_phase = 4;
    p_wait_start(s_scl, s_sda);
    if s_scl_master_low /= '1' then
      wait until s_scl_master_low = '1';
    end if;
    s_sda_slave_low <= '1';
    wait until rising_edge(s_scl);
    for v_cycle in 1 to 8 loop
      wait until rising_edge(s_clk);
    end loop;
    s_sda_slave_low <= '0';

    wait until s_phase = 5;
    s_scl_slave_low <= '1';
    for v_cycle in 1 to C_TIMEOUT_CYCLES + 10 loop
      wait until rising_edge(s_clk);
    end loop;
    s_scl_slave_low <= '0';

    wait;
  end process proc_slave_model;

  proc_stimulus : process

    procedure p_command (
      constant command_start : in boolean;
      constant command_stop  : in boolean;
      constant command_read  : in boolean;
      constant command_write : in boolean;
      constant command_ack   : in std_logic;
      constant command_data  : in std_logic_vector(7 downto 0);
      constant expect_nack   : in std_logic;
      constant expect_arb    : in std_logic;
      constant expect_to     : in std_logic;
      constant expect_error  : in std_logic;
      constant check_data    : in boolean := false;
      constant expected_data : in std_logic_vector(7 downto 0) := x"00"
    ) is
      variable v_cycles : natural;
    begin
      wait until rising_edge(s_clk) and s_cmd_ready = '1';
      if command_start then
        s_start <= '1';
      else
        s_start <= '0';
      end if;
      if command_stop then
        s_stop <= '1';
      else
        s_stop <= '0';
      end if;
      if command_read then
        s_read <= '1';
      else
        s_read <= '0';
      end if;
      if command_write then
        s_write <= '1';
      else
        s_write <= '0';
      end if;
      s_ack       <= command_ack;
      s_data_in   <= command_data;
      s_cmd_valid <= '1';

      wait until rising_edge(s_clk);
      s_cmd_valid <= '0';
      s_start     <= '0';
      s_stop      <= '0';
      s_read      <= '0';
      s_write     <= '0';

      v_cycles := 0;
      loop
        wait until rising_edge(s_clk);
        exit when s_rsp_valid = '1';
        v_cycles := v_cycles + 1;
        assert v_cycles < 10_000
          report "command response timeout in testbench"
          severity failure;
      end loop;

      assert s_nack = expect_nack
        report "unexpected NACK status"
        severity failure;
      assert s_arb_lost = expect_arb
        report "unexpected arbitration-lost status"
        severity failure;
      assert s_timeout = expect_to
        report "unexpected clock-stretch timeout status"
        severity failure;
      assert s_cmd_error = expect_error
        report "unexpected command-error status"
        severity failure;
      if check_data then
        assert s_data_out = expected_data
          report "read response data differs from expected value"
          severity failure;
      end if;
    end procedure p_command;

    procedure p_wait_bus_busy (
      constant expected : in std_logic
    ) is
      variable v_cycles : natural;
    begin
      v_cycles := 0;
      while s_bus_busy /= expected loop
        wait until rising_edge(s_clk);
        v_cycles := v_cycles + 1;
        assert v_cycles < 20
          report "bus_busy_o did not reach its expected state"
          severity failure;
      end loop;
    end procedure p_wait_bus_busy;

  begin
    s_rst_n <= '0';
    for v_cycle in 1 to 4 loop
      wait until rising_edge(s_clk);
    end loop;
    s_rst_n <= '1';
    for v_cycle in 1 to 4 loop
      wait until rising_edge(s_clk);
    end loop;

    assert s_cmd_ready = '1' and s_busy = '0'
      report "controller did not become idle after reset"
      severity failure;
    assert s_scl_master_low = '0' and s_sda_master_low = '0'
      report "reset did not release the I2C bus"
      severity failure;

    -- Write transaction with slave clock stretching.
    s_phase <= 1;
    p_command(true, false, false, true, '1', x"A0", '0', '0', '0', '0');
    p_command(false, true, false, true, '1', x"A5", '0', '0', '0', '0');

    -- Register-style write followed by a repeated START and two-byte read.
    s_phase <= 2;
    p_command(true, false, false, true, '1', x"A0", '0', '0', '0', '0');
    p_command(false, false, false, true, '1', x"12", '0', '0', '0', '0');
    p_command(true, false, false, true, '1', x"A1", '0', '0', '0', '0');
    p_command(false, false, true, false, '0', x"00", '0', '0', '0', '0', true, x"3C");
    p_command(false, true, true, false, '1', x"00", '0', '0', '0', '0', true, x"C7");

    -- A released acknowledge slot is reported as NACK.
    s_phase <= 3;
    p_command(true, true, false, true, '1', x"A0", '1', '0', '0', '0');

    -- Contention while transmitting a one releases the bus and reports loss.
    s_phase <= 4;
    p_command(true, false, false, true, '1', x"A0", '0', '1', '0', '0');
    if s_sda /= '1' then
      wait until s_sda = '1';
    end if;

    -- A slave holding SCL low beyond the configured limit reports timeout.
    s_phase <= 5;
    if s_scl /= '0' then
      wait until s_scl = '0';
    end if;
    p_command(true, false, false, false, '1', x"00", '0', '0', '1', '0');
    if s_scl /= '1' then
      wait until s_scl = '1';
    end if;

    -- START-only and STOP-only commands support explicit bus ownership.
    s_phase <= 6;
    p_command(true, false, false, false, '1', x"00", '0', '0', '0', '0');
    p_wait_bus_busy('1');
    p_command(false, true, false, false, '1', x"00", '0', '0', '0', '0');
    p_wait_bus_busy('0');

    -- Mutually asserted read and write controls are rejected without bus I/O.
    s_phase <= 7;
    p_command(false, false, true, true, '1', x"00", '0', '0', '0', '1');
    assert s_scl = '1' and s_sda = '1'
      report "invalid command changed the released bus"
      severity failure;

    -- Reset while active cancels the command and releases both bus lines.
    s_phase <= 8;
    wait until rising_edge(s_clk) and s_cmd_ready = '1';
    s_start     <= '1';
    s_write     <= '1';
    s_data_in   <= x"A0";
    s_cmd_valid <= '1';
    wait until rising_edge(s_clk);
    s_cmd_valid <= '0';
    s_start     <= '0';
    s_write     <= '0';
    wait until rising_edge(s_clk);
    assert s_busy = '1'
      report "controller did not enter busy state"
      severity failure;
    s_rst_n <= '0';
    wait until rising_edge(s_clk);
    wait until rising_edge(s_clk);
    assert s_busy = '0' and s_cmd_ready = '1'
      report "reset did not cancel the active command"
      severity failure;
    assert s_scl_master_low = '0' and s_sda_master_low = '0'
      report "reset did not release active open-drain controls"
      severity failure;
    assert s_rsp_valid = '0'
      report "reset produced a spurious response"
      severity failure;

    report "lm_i2c_master self-check passed" severity note;
    stop;
    wait;
  end process proc_stimulus;

end architecture a_tb;
