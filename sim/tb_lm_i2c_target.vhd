--=============================================================================
-- Module Name : tb_lm_i2c_target
-- Library     : -
-- Project     : lm_i2c
-- Company     : LogiMentor Srl
-------------------------------------------------------------------------------
-- Description:
--  Self-checking functional, timing, and integration regression for
--  lm_i2c_target. Directed resolved-bus stimulus is complemented by transfers
--  from the synthesizable lm_i2c_master.
-------------------------------------------------------------------------------
-- Copyright 2026 LogiMentor Srl
-- SPDX-License-Identifier: Apache-2.0
--=============================================================================

library ieee;
use ieee.std_logic_1164.all;

library std;
use std.env.all;

entity tb_lm_i2c_target is
  generic (
    g_clk_freq_hz        : positive := 10_000_000;
    g_i2c_freq_hz        : positive := 400_000;
    g_actual_i2c_freq_hz : positive := 400_000
  );
end entity tb_lm_i2c_target;

architecture a_tb of tb_lm_i2c_target is

  function f_mode_time (
    standard_time : time;
    fast_time     : time;
    bus_frequency : positive
  ) return time is
  begin
    if bus_frequency <= 100_000 then
      return standard_time;
    else
      return fast_time;
    end if;
  end function f_mode_time;

  function f_max_time (
    a : time;
    b : time
  ) return time is
  begin
    if a > b then
      return a;
    else
      return b;
    end if;
  end function f_max_time;

  constant C_CLK_PERIOD : time :=
    2 * ((1 sec / g_clk_freq_hz + 2 fs) / 2);
  constant C_T_LOW : time :=
    f_mode_time(4.7 us, 1.3 us, g_actual_i2c_freq_hz);
  constant C_T_HIGH : time :=
    f_mode_time(4.0 us, 0.6 us, g_actual_i2c_freq_hz);
  constant C_T_BUF : time :=
    f_mode_time(4.7 us, 1.3 us, g_actual_i2c_freq_hz);
  constant C_T_HD_STA : time :=
    f_mode_time(4.0 us, 0.6 us, g_actual_i2c_freq_hz);
  constant C_T_SU_STA : time :=
    f_mode_time(4.7 us, 0.6 us, g_actual_i2c_freq_hz);
  constant C_T_SU_STO : time :=
    f_mode_time(4.0 us, 0.6 us, g_actual_i2c_freq_hz);
  constant C_T_SU_DAT : time :=
    f_mode_time(250 ns, 100 ns, g_i2c_freq_hz);
  constant C_T_HD_DAT : time := 300 ns;
  constant C_BUS_PERIOD : time := 1 sec / g_actual_i2c_freq_hz;
  constant C_CTRL_HIGH : time :=
    f_max_time(C_T_HIGH, C_BUS_PERIOD - C_T_LOW);
  constant C_WATCHDOG : time := 20 ms;
  constant C_TARGET_ADDRESS : std_logic_vector(6 downto 0) := "1010010";
  constant C_READ_ADDRESS : std_logic_vector(7 downto 0) := x"A5";

  signal s_clk   : std_logic := '0';
  signal s_rst_n : std_logic := '0';

  signal s_enable  : std_logic := '0';
  signal s_address : std_logic_vector(6 downto 0) := C_TARGET_ADDRESS;

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
  signal s_tx_data  : std_logic_vector(7 downto 0) := (others => '0');

  signal s_target_scl_low : std_logic;
  signal s_target_sda_low : std_logic;
  signal s_bfm_scl_low    : std_logic := '0';
  signal s_bfm_sda_low    : std_logic := '0';
  signal s_master_scl_low : std_logic;
  signal s_master_sda_low : std_logic;
  signal s_scl            : std_logic;
  signal s_sda            : std_logic;

  signal s_bus_assume_free : std_logic := '1';
  signal s_cmd_valid       : std_logic := '0';
  signal s_cmd_start       : std_logic := '0';
  signal s_cmd_stop        : std_logic := '0';
  signal s_cmd_stop_only   : std_logic := '0';
  signal s_cmd_read        : std_logic := '0';
  signal s_cmd_data        : std_logic_vector(7 downto 0) := (others => '0');
  signal s_cmd_nack        : std_logic := '1';
  signal s_cmd_ready       : std_logic;
  signal s_rsp_ready       : std_logic := '0';
  signal s_rsp_valid       : std_logic;
  signal s_rsp_data        : std_logic_vector(7 downto 0);
  signal s_rsp_nack        : std_logic;
  signal s_rsp_arb_lost    : std_logic;
  signal s_rsp_cmd_error   : std_logic;
  signal s_master_busy     : std_logic;
  signal s_master_bus_busy : std_logic;

  signal s_monitor_armed   : std_logic := '0';
  signal s_forbid_tx_ready : std_logic := '0';
  signal s_addressed_count : natural := 0;
  signal s_stop_count      : natural := 0;
  signal s_rx_count        : natural := 0;

begin

  assert g_actual_i2c_freq_hz <= g_i2c_freq_hz
    report "actual controller frequency must not exceed target maximum"
    severity failure;

  s_scl <= '0' when
    s_target_scl_low = '1' or
    s_bfm_scl_low = '1' or
    s_master_scl_low = '1'
    else '1';
  s_sda <= '0' when
    s_target_sda_low = '1' or
    s_bfm_sda_low = '1' or
    s_master_sda_low = '1'
    else '1';

  inst_target : entity work.lm_i2c_target
    generic map (
      g_clk_freq_hz => g_clk_freq_hz,
      g_i2c_freq_hz => g_i2c_freq_hz
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

  inst_master : entity work.lm_i2c_master
    generic map (
      g_clk_freq_hz => g_clk_freq_hz,
      g_i2c_freq_hz => g_i2c_freq_hz
    )
    port map (
      clk_i             => s_clk,
      rst_n_i           => s_rst_n,
      bus_assume_free_i => s_bus_assume_free,
      cmd_valid_i       => s_cmd_valid,
      cmd_start_i       => s_cmd_start,
      cmd_stop_i        => s_cmd_stop,
      cmd_stop_only_i   => s_cmd_stop_only,
      cmd_read_i        => s_cmd_read,
      cmd_data_i        => s_cmd_data,
      cmd_nack_i        => s_cmd_nack,
      rsp_ready_i       => s_rsp_ready,
      scl_i             => s_scl,
      sda_i             => s_sda,
      cmd_ready_o       => s_cmd_ready,
      rsp_valid_o       => s_rsp_valid,
      rsp_data_o        => s_rsp_data,
      rsp_nack_o        => s_rsp_nack,
      rsp_arb_lost_o    => s_rsp_arb_lost,
      rsp_cmd_error_o   => s_rsp_cmd_error,
      busy_o            => s_master_busy,
      bus_busy_o        => s_master_bus_busy,
      scl_low_o         => s_master_scl_low,
      sda_low_o         => s_master_sda_low
    );

  proc_clock : process
  begin
    s_clk <= '0';
    wait for C_CLK_PERIOD / 2;
    s_clk <= '1';
    wait for C_CLK_PERIOD / 2;
  end process proc_clock;

  proc_status_monitor : process(s_clk)
    variable v_addressed_previous : std_logic := '0';
    variable v_stop_previous      : std_logic := '0';
  begin
    if rising_edge(s_clk) then
      if s_rst_n = '0' then
        s_addressed_count <= 0;
        s_stop_count      <= 0;
        s_rx_count        <= 0;
        v_addressed_previous := '0';
        v_stop_previous      := '0';
      else
        if s_forbid_tx_ready = '1' then
          assert s_tx_ready = '0'
            report "target requested another TX byte after controller NACK"
            severity failure;
        end if;
        if s_addressed = '1' then
          assert v_addressed_previous = '0'
            report "addressed_o was asserted for more than one clock"
            severity failure;
          s_addressed_count <= s_addressed_count + 1;
        end if;
        if s_stop = '1' then
          assert v_stop_previous = '0'
            report "stop_o was asserted for more than one clock"
            severity failure;
          assert s_scl = '1' and s_sda = '1'
            report "stop_o asserted without a physical STOP condition"
            severity failure;
          s_stop_count <= s_stop_count + 1;
        end if;
        if s_rx_valid = '1' and s_rx_ready = '1' then
          s_rx_count <= s_rx_count + 1;
        end if;
        v_addressed_previous := s_addressed;
        v_stop_previous      := s_stop;
      end if;
    end if;
  end process proc_status_monitor;

  proc_timing_monitor : process(
    s_monitor_armed,
    s_scl,
    s_target_scl_low,
    s_target_sda_low
  )
    variable v_last_fall       : time := 0 ns;
    variable v_last_sda_change : time := 0 ns;
    variable v_have_fall       : boolean := false;
    variable v_have_sda_change : boolean := false;
  begin
    if s_monitor_armed'event and s_monitor_armed = '1' then
      v_last_fall       := now;
      v_last_sda_change := now;
      v_have_fall       := false;
      v_have_sda_change := false;
    elsif s_monitor_armed = '1' and s_rst_n = '1' then
      assert (s_target_scl_low = '0' or s_target_scl_low = '1') and
             (s_target_sda_low = '0' or s_target_sda_low = '1')
        report "target open-drain control contains a non-binary value"
        severity failure;

      if s_scl'event and s_scl = '0' then
        v_last_fall := now;
        v_have_fall := true;
      elsif s_scl'event and s_scl = '1' and v_have_sda_change then
        assert now - v_last_sda_change >= C_T_SU_DAT
          report "target SDA setup before physical SCL rise was too short"
          severity failure;
      end if;

      if s_target_sda_low'event then
        assert s_scl = '0'
          report "target changed SDA while physical SCL was HIGH"
          severity failure;
        assert v_have_fall and now - v_last_fall >= C_T_HD_DAT
          report "target SDA change violated the 300 ns data hold policy"
          severity failure;
        v_last_sda_change := now;
        v_have_sda_change := true;
      end if;

      if s_target_scl_low'event and s_target_scl_low = '1' then
        assert s_scl = '0'
          report "target began stretching outside a physical SCL LOW phase"
          severity failure;
      end if;
    end if;
  end process proc_timing_monitor;

  proc_stimulus : process

    procedure p_wait_clocks (
      constant count : in natural
    ) is
    begin
      for v_cycle in 1 to count loop
        wait until rising_edge(s_clk);
      end loop;
    end procedure p_wait_clocks;

    procedure p_start (
      constant repeated_start : in boolean
    ) is
    begin
      s_bfm_sda_low <= '0';
      if repeated_start then
        s_bfm_scl_low <= '1';
        wait for C_T_LOW;
        s_bfm_scl_low <= '0';
        wait until s_scl = '1';
        wait for C_T_SU_STA;
      else
        s_bfm_scl_low <= '0';
        if s_scl /= '1' or s_sda /= '1' then
          wait until s_scl = '1' and s_sda = '1';
        end if;
        wait for C_T_BUF;
      end if;
      s_bfm_sda_low <= '1';
      wait for C_T_HD_STA;
      s_bfm_scl_low <= '1';
    end procedure p_start;

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
      wait for C_CTRL_HIGH;
      s_bfm_scl_low <= '1';
    end procedure p_controller_bit;

    procedure p_address_byte (
      constant value          : in std_logic_vector(7 downto 0);
      constant expected_ack   : in boolean;
      constant expect_passive : in boolean := false
    ) is
    begin
      for v_bit in 7 downto 0 loop
        p_controller_bit(value(v_bit));
        if expect_passive then
          assert s_target_scl_low = '0' and s_target_sda_low = '0'
            report "passive target drove or stretched the bus"
            severity failure;
        end if;
      end loop;

      wait for C_T_HD_DAT;
      s_bfm_sda_low <= '0';
      wait for C_T_LOW - C_T_HD_DAT;
      s_bfm_scl_low <= '0';
      wait until s_scl = '1';
      wait for C_CTRL_HIGH / 2;
      if expected_ack then
        assert s_sda = '0'
          report "matching target address was not ACKed"
          severity failure;
      else
        assert s_sda = '1'
          report "disabled or mismatched target address was ACKed"
          severity failure;
      end if;
      wait for C_CTRL_HIGH - C_CTRL_HIGH / 2;
      s_bfm_scl_low <= '1';
      wait for C_T_HD_DAT;
      if expect_passive then
        assert s_target_scl_low = '0' and s_target_sda_low = '0'
          report "passive target altered the address ACK slot"
          severity failure;
      end if;
    end procedure p_address_byte;

    procedure p_write_byte (
      constant value               : in std_logic_vector(7 downto 0);
      constant application_nack    : in boolean;
      constant backpressure_cycles : in natural
    ) is
      variable v_expected_rx_count : natural;
      variable v_stretch_start     : time;
    begin
      s_rx_ready <= '0';
      s_rx_nack  <= '0';
      v_expected_rx_count := s_rx_count;

      for v_bit in 7 downto 0 loop
        p_controller_bit(value(v_bit));
      end loop;

      while s_rx_valid /= '1' loop
        wait until rising_edge(s_clk);
      end loop;
      assert s_rx_data = value
        report "received target byte had incorrect value or bit order"
        severity failure;

      wait for C_T_HD_DAT;
      s_bfm_sda_low <= '0';
      wait for C_T_LOW - C_T_HD_DAT;
      s_bfm_scl_low <= '0';
      v_stretch_start := now;

      if backpressure_cycles > 0 then
        p_wait_clocks(backpressure_cycles);
        assert s_scl = '0' and s_target_scl_low = '1'
          report "RX backpressure did not produce observable SCL stretching"
          severity failure;
        assert s_rx_valid = '1' and s_rx_data = value
          report "RX ready/valid payload changed during backpressure"
          severity failure;
      end if;

      if application_nack then
        s_rx_nack <= '1';
      else
        s_rx_nack <= '0';
      end if;
      s_rx_ready <= '1';
      wait until rising_edge(s_clk);
      s_rx_ready <= '0';
      s_rx_nack  <= '0';

      wait until s_scl = '1';
      if backpressure_cycles > 0 then
        assert now - v_stretch_start >= backpressure_cycles * C_CLK_PERIOD
          report "RX stretch ended before application backpressure resolved"
          severity failure;
      end if;
      wait for C_CTRL_HIGH / 2;
      if application_nack then
        assert s_sda = '1'
          report "application-requested RX NACK was not transmitted"
          severity failure;
      else
        assert s_sda = '0'
          report "application-accepted RX byte was not ACKed"
          severity failure;
      end if;
      wait for C_CTRL_HIGH - C_CTRL_HIGH / 2;
      s_bfm_scl_low <= '1';
      wait for C_T_HD_DAT;
      s_bfm_sda_low <= '0';
      if s_rx_count /= v_expected_rx_count + 1 then
        wait until s_rx_count = v_expected_rx_count + 1;
      end if;
    end procedure p_write_byte;

    procedure p_unaccepted_write_byte (
      constant value : in std_logic_vector(7 downto 0)
    ) is
      variable v_rx_before : natural;
    begin
      v_rx_before := s_rx_count;
      for v_bit in 7 downto 0 loop
        p_controller_bit(value(v_bit));
        assert s_target_scl_low = '0' and s_target_sda_low = '0'
          report "rejected transaction accepted or drove another data byte"
          severity failure;
      end loop;
      wait for C_T_HD_DAT;
      s_bfm_sda_low <= '0';
      wait for C_T_LOW - C_T_HD_DAT;
      s_bfm_scl_low <= '0';
      wait until s_scl = '1';
      wait for C_CTRL_HIGH / 2;
      assert s_sda = '1'
        report "target ACKed a byte after application NACK"
        severity failure;
      wait for C_CTRL_HIGH - C_CTRL_HIGH / 2;
      s_bfm_scl_low <= '1';
      wait for C_T_HD_DAT;
      assert s_rx_count = v_rx_before and s_rx_valid = '0'
        report "target emitted RX activity after application NACK"
        severity failure;
    end procedure p_unaccepted_write_byte;

    procedure p_read_byte (
      constant value               : in std_logic_vector(7 downto 0);
      constant controller_ack      : in boolean;
      constant starvation_cycles   : in natural
    ) is
      variable v_bit_value    : std_logic;
      variable v_stretch_time : time;
    begin
      s_tx_valid <= '0';
      while s_tx_ready /= '1' loop
        wait until rising_edge(s_clk);
      end loop;

      s_bfm_sda_low <= '0';
      wait for C_T_LOW;
      s_bfm_scl_low <= '0';
      v_stretch_time := now;

      if starvation_cycles > 0 then
        p_wait_clocks(starvation_cycles);
        assert s_tx_ready = '1'
          report "tx_ready_o dropped before a valid handshake"
          severity failure;
        assert s_scl = '0' and s_target_scl_low = '1'
          report "TX starvation did not produce observable SCL stretching"
          severity failure;
      end if;

      s_tx_data  <= value;
      s_tx_valid <= '1';
      wait until rising_edge(s_clk) and s_tx_ready = '1';
      s_tx_valid <= '0';

      wait until s_scl = '1';
      if starvation_cycles > 0 then
        assert now - v_stretch_time >= starvation_cycles * C_CLK_PERIOD
          report "TX stretch ended before the valid handshake"
          severity failure;
      end if;
      wait for C_CTRL_HIGH / 2;
      v_bit_value := s_sda;
      assert v_bit_value = value(7)
        report "target transmitted incorrect read bit 7"
        severity failure;
      wait for C_CTRL_HIGH - C_CTRL_HIGH / 2;
      s_bfm_scl_low <= '1';

      for v_bit in 6 downto 0 loop
        wait for C_T_LOW;
        s_bfm_scl_low <= '0';
        wait until s_scl = '1';
        wait for C_CTRL_HIGH / 2;
        assert s_sda = value(v_bit)
          report "target transmitted incorrect read bit or bit order"
          severity failure;
        wait for C_CTRL_HIGH - C_CTRL_HIGH / 2;
        s_bfm_scl_low <= '1';
      end loop;

      wait for C_T_HD_DAT;
      if controller_ack then
        s_bfm_sda_low <= '1';
      else
        s_bfm_sda_low <= '0';
        s_forbid_tx_ready <= '1';
      end if;
      wait for C_T_LOW - C_T_HD_DAT;
      s_bfm_scl_low <= '0';
      wait until s_scl = '1';
      wait for C_CTRL_HIGH;
      s_bfm_scl_low <= '1';
      wait for C_T_HD_DAT;
      s_bfm_sda_low <= '0';

      if controller_ack then
        while s_tx_ready /= '1' loop
          wait until rising_edge(s_clk);
        end loop;
      else
        p_wait_clocks(4);
        assert s_tx_ready = '0'
          report "target requested another TX byte after controller NACK"
          severity failure;
        assert s_target_sda_low = '0'
          report "target failed to release SDA after transmitted byte"
          severity failure;
        s_forbid_tx_ready <= '0';
      end if;
    end procedure p_read_byte;

    procedure p_restart_with_pending_rx is
    begin
      s_rx_ready <= '0';
      for v_bit in 7 downto 1 loop
        p_controller_bit('1');
      end loop;

      wait for C_T_HD_DAT;
      s_bfm_sda_low <= '0';
      wait for C_T_LOW - C_T_HD_DAT;
      s_bfm_scl_low <= '0';
      wait until s_scl = '1';
      while s_rx_valid /= '1' loop
        wait until rising_edge(s_clk);
      end loop;
      assert s_rx_data = x"FF"
        report "pending RX restart setup received the wrong byte"
        severity failure;

      s_bfm_sda_low <= '1';
      wait for C_T_HD_STA;
      s_bfm_scl_low <= '1';
      p_wait_clocks(4);
      assert s_rx_valid = '0'
        report "stale rx_valid_o leaked across repeated START"
        severity failure;
      p_address_byte(x"A4", true);
    end procedure p_restart_with_pending_rx;

    procedure p_restart_with_pending_tx is
    begin
      p_start(false);
      for v_bit in 7 downto 1 loop
        p_controller_bit(C_READ_ADDRESS(v_bit));
      end loop;

      wait for C_T_HD_DAT;
      s_bfm_sda_low <= '0';
      wait for C_T_LOW - C_T_HD_DAT;
      s_bfm_scl_low <= '0';
      wait until s_scl = '1';
      while s_tx_ready /= '1' loop
        wait until rising_edge(s_clk);
      end loop;

      s_bfm_sda_low <= '1';
      wait for C_T_HD_STA;
      s_bfm_scl_low <= '1';
      p_wait_clocks(4);
      assert s_tx_ready = '0'
        report "stale tx_ready_o leaked across repeated START"
        severity failure;
      p_address_byte(x"A4", true);
    end procedure p_restart_with_pending_tx;

    procedure p_master_launch (
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
    end procedure p_master_launch;

    procedure p_master_response (
      constant expected_data : in std_logic_vector(7 downto 0);
      constant expected_nack : in std_logic
    ) is
    begin
      while s_rsp_valid /= '1' loop
        wait until rising_edge(s_clk);
      end loop;
      assert s_rsp_data = expected_data and
             s_rsp_nack = expected_nack and
             s_rsp_arb_lost = '0' and
             s_rsp_cmd_error = '0'
        report "master-target integration response was incorrect"
        severity failure;
      s_rsp_ready <= '1';
      wait until rising_edge(s_clk);
      s_rsp_ready <= '0';
      wait until rising_edge(s_clk);
    end procedure p_master_response;

    variable v_addressed_before : natural;
    variable v_stop_before      : natural;
    variable v_rx_before        : natural;

  begin
    s_rst_n <= '0';
    p_wait_clocks(6);
    wait for 0 ns;
    assert s_target_scl_low = '0' and s_target_sda_low = '0' and
           s_active = '0' and s_read = '0' and
           s_addressed = '0' and s_stop = '0' and
           s_rx_valid = '0' and s_tx_ready = '0'
      report "reset or idle release state was incorrect"
      severity failure;
    s_rst_n <= '1';
    p_wait_clocks(6);
    s_monitor_armed <= '1';

    -- Disabled target and address mismatch remain completely passive.
    s_enable <= '0';
    s_address <= C_TARGET_ADDRESS;
    v_addressed_before := s_addressed_count;
    v_stop_before := s_stop_count;
    p_start(false);
    p_address_byte(x"A4", false, true);
    p_stop;
    assert s_addressed_count = v_addressed_before and
           s_stop_count = v_stop_before and s_active = '0'
      report "disabled target emitted transaction status"
      severity failure;

    s_enable <= '1';
    p_start(false);
    p_address_byte(x"A6", false, true);
    p_stop;
    assert s_addressed_count = v_addressed_before and
           s_stop_count = v_stop_before
      report "address mismatch emitted target transaction status"
      severity failure;

    -- Configuration is sampled at START and remains fixed for the address.
    s_enable  <= '1';
    s_address <= C_TARGET_ADDRESS;
    p_start(false);
    p_wait_clocks(4);
    s_enable  <= '0';
    s_address <= "0110011";
    p_address_byte(x"A4", true);
    p_wait_clocks(2);
    assert s_active = '1' and s_read = '0' and
           s_addressed_count = v_addressed_before + 1
      report "sampled configuration or write status was incorrect"
      severity failure;
    s_enable  <= '1';
    s_address <= C_TARGET_ADDRESS;

    p_write_byte(x"12", false, 0);
    p_write_byte(x"34", false, 8);
    p_write_byte(x"56", true, 0);
    v_rx_before := s_rx_count;
    p_unaccepted_write_byte(x"78");
    assert s_rx_count = v_rx_before
      report "RX byte was accepted after application NACK"
      severity failure;
    v_stop_before := s_stop_count;
    p_stop;
    p_wait_clocks(4);
    assert s_active = '0' and s_read = '0' and
           s_stop_count = v_stop_before + 1
      report "STOP did not end the selected write transaction"
      severity failure;

    -- Read stream starvation, controller ACK continuation, and NACK stop.
    v_addressed_before := s_addressed_count;
    p_start(false);
    p_address_byte(x"A5", true);
    p_wait_clocks(2);
    assert s_active = '1' and s_read = '1' and
           s_addressed_count = v_addressed_before + 1
      report "matching read address status was incorrect"
      severity failure;
    p_read_byte(x"3C", true, 8);
    p_read_byte(x"C7", false, 0);
    p_stop;
    p_wait_clocks(4);
    assert s_active = '0' and s_read = '0'
      report "STOP did not end the selected read transaction"
      severity failure;

    -- Repeated START cancels application handshakes from an interrupted phase.
    p_start(false);
    p_address_byte(x"A4", true);
    p_restart_with_pending_rx;
    p_stop;
    p_restart_with_pending_tx;
    p_stop;

    -- Combined write/repeated-START/read and direction changes.
    p_start(false);
    p_address_byte(x"A4", true);
    p_write_byte(x"09", false, 0);
    v_addressed_before := s_addressed_count;
    p_start(true);
    p_address_byte(x"A5", true);
    assert s_addressed_count = v_addressed_before + 1 and s_read = '1'
      report "write-to-read repeated START was not re-addressed"
      severity failure;
    p_read_byte(x"9A", false, 0);
    p_start(true);
    p_address_byte(x"A4", true);
    assert s_read = '0'
      report "read-to-write repeated START did not change direction"
      severity failure;
    p_write_byte(x"BC", false, 0);

    v_addressed_before := s_addressed_count;
    p_start(true);
    p_address_byte(x"A4", true);
    assert s_addressed_count = v_addressed_before + 1
      report "same-target repeated START did not pulse addressed_o"
      severity failure;
    p_write_byte(x"DE", false, 0);

    p_start(true);
    p_address_byte(x"A6", false, true);
    p_wait_clocks(3);
    assert s_active = '0' and s_rx_valid = '0' and s_tx_ready = '0'
      report "repeated START to another address did not deselect target"
      severity failure;
    p_stop;

    -- Real controller/target integration: write, then combined write/read.
    s_bfm_scl_low <= '0';
    s_bfm_sda_low <= '0';
    while s_master_bus_busy /= '0' loop
      wait until rising_edge(s_clk);
    end loop;

    p_master_launch(true, false, false, x"A4", '1');
    p_master_response(x"00", '0');
    s_rx_ready <= '0';
    p_master_launch(false, true, false, x"5A", '1');
    while s_rx_valid /= '1' loop
      wait until rising_edge(s_clk);
    end loop;
    assert s_rx_data = x"5A"
      report "master-target integrated write data was incorrect"
      severity failure;
    s_rx_nack  <= '0';
    s_rx_ready <= '1';
    wait until rising_edge(s_clk);
    s_rx_ready <= '0';
    p_master_response(x"00", '0');

    p_master_launch(true, false, false, x"A4", '1');
    p_master_response(x"00", '0');
    s_rx_ready <= '0';
    p_master_launch(false, false, false, x"0D", '1');
    while s_rx_valid /= '1' loop
      wait until rising_edge(s_clk);
    end loop;
    assert s_rx_data = x"0D"
      report "integrated combined-transfer write byte was incorrect"
      severity failure;
    s_rx_ready <= '1';
    wait until rising_edge(s_clk);
    s_rx_ready <= '0';
    p_master_response(x"00", '0');

    s_tx_data  <= x"E1";
    s_tx_valid <= '1';
    p_master_launch(true, false, false, x"A5", '1');
    wait until rising_edge(s_clk) and s_tx_ready = '1';
    s_tx_valid <= '0';
    p_master_response(x"00", '0');
    p_master_launch(false, true, true, x"00", '1');
    p_master_response(x"E1", '0');

    p_wait_clocks(8);
    assert s_scl = '1' and s_sda = '1' and
           s_target_scl_low = '0' and s_target_sda_low = '0'
      report "bus was not released after integration regression"
      severity failure;

    report "lm_i2c_target functional self-check passed" severity note;
    stop;
    wait;
  end process proc_stimulus;

  proc_watchdog : process
  begin
    wait for C_WATCHDOG;
    assert false report "target functional regression watchdog expired"
      severity failure;
  end process proc_watchdog;

end architecture a_tb;
