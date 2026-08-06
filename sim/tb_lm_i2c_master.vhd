--=============================================================================
-- Module Name : tb_lm_i2c_master
-- Library     : -
-- Project     : lm_i2c
-- Company     : LogiMentor Srl
-------------------------------------------------------------------------------
-- Description:
--  Self-checking behavioral regression for lm_i2c_master. The target and
--  competing-controller models are simulation-only. A passive monitor checks
--  the resolved SCL and SDA signals against UM10204 Standard/Fast-mode timing.
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

  function f_div_ceil (
    a : positive;
    b : positive
  ) return positive is
  begin
    return ((a - 1) / b) + 1;
  end function f_div_ceil;

  function f_time_cycles (
    required_time : time;
    clock_period  : time
  ) return positive is
  begin
    return (required_time + clock_period - 1 fs) / clock_period;
  end function f_time_cycles;

  function f_max (
    a : positive;
    b : positive
  ) return positive is
  begin
    if a > b then
      return a;
    else
      return b;
    end if;
  end function f_max;

  function f_expected_high_cycles (
    period_cycles : positive;
    low_cycles    : positive;
    minimum       : positive
  ) return positive is
  begin
    if period_cycles > low_cycles then
      return f_max(minimum, period_cycles - low_cycles);
    else
      return minimum;
    end if;
  end function f_expected_high_cycles;

  -- Round the generated simulation clock conservatively above the ideal
  -- period so fractional-femtosecond division cannot create a faster clock.
  constant C_CLK_PERIOD : time :=
    2 * ((1 sec / g_clk_freq_hz + 2 fs) / 2);
  constant C_T_LOW : time :=
    f_mode_time(4.7 us, 1.3 us, g_i2c_freq_hz);
  constant C_T_HIGH : time :=
    f_mode_time(4.0 us, 0.6 us, g_i2c_freq_hz);
  constant C_T_BUF : time :=
    f_mode_time(4.7 us, 1.3 us, g_i2c_freq_hz);
  constant C_T_HD_STA : time :=
    f_mode_time(4.0 us, 0.6 us, g_i2c_freq_hz);
  constant C_T_SU_STA : time :=
    f_mode_time(4.7 us, 0.6 us, g_i2c_freq_hz);
  constant C_T_SU_STO : time :=
    f_mode_time(4.0 us, 0.6 us, g_i2c_freq_hz);
  constant C_T_SU_DAT : time :=
    f_mode_time(250 ns, 100 ns, g_i2c_freq_hz);
  constant C_T_HD_DAT : time := 300 ns;
  constant C_REQ_PERIOD : time := 1 sec / g_i2c_freq_hz;
  constant C_PERIOD_CYCLES : positive :=
    f_div_ceil(g_clk_freq_hz, g_i2c_freq_hz);
  constant C_EXPECT_HOLD_CYCLES : positive :=
    f_time_cycles(C_T_HD_DAT, C_CLK_PERIOD);
  constant C_EXPECT_SETUP_CYCLES : positive :=
    f_time_cycles(C_T_SU_DAT, C_CLK_PERIOD);
  constant C_EXPECT_LOW_CYCLES : positive := f_max(
    f_time_cycles(C_T_LOW, C_CLK_PERIOD),
    C_EXPECT_HOLD_CYCLES + C_EXPECT_SETUP_CYCLES
  );
  constant C_EXPECT_HIGH_CYCLES : positive := f_expected_high_cycles(
    C_PERIOD_CYCLES,
    C_EXPECT_LOW_CYCLES,
    f_time_cycles(C_T_HIGH, C_CLK_PERIOD)
  );
  constant C_EXPECT_LOW : time :=
    C_EXPECT_LOW_CYCLES * C_CLK_PERIOD;
  constant C_EXPECT_HIGH : time :=
    (C_EXPECT_HIGH_CYCLES + 2) * C_CLK_PERIOD;
  constant C_EXPECT_PERIOD : time :=
    C_EXPECT_LOW + C_EXPECT_HIGH;
  constant C_CTRL_HIGH : time :=
    f_max_time(C_T_HIGH, C_REQ_PERIOD - C_T_LOW);
  constant C_ARB_RELEASE_CHECK : time :=
    C_T_SU_STO / 2 + 4 * C_CLK_PERIOD;
  constant C_STRETCH_TIME : time := 3 * C_CTRL_HIGH + 4 * C_CLK_PERIOD;
  constant C_WATCHDOG : time := 20 ms;

  signal s_clk   : std_logic := '0';
  signal s_rst_n : std_logic := '0';
  signal s_bus_assume_free : std_logic := '0';

  signal s_cmd_valid     : std_logic := '0';
  signal s_cmd_start     : std_logic := '0';
  signal s_cmd_stop      : std_logic := '0';
  signal s_cmd_stop_only : std_logic := '0';
  signal s_cmd_read      : std_logic := '0';
  signal s_cmd_data      : std_logic_vector(7 downto 0) := (others => '0');
  signal s_cmd_nack      : std_logic := '1';
  signal s_cmd_ready     : std_logic;

  signal s_rsp_ready     : std_logic := '0';
  signal s_rsp_valid     : std_logic;
  signal s_rsp_data      : std_logic_vector(7 downto 0);
  signal s_rsp_nack      : std_logic;
  signal s_rsp_arb_lost  : std_logic;
  signal s_rsp_cmd_error : std_logic;

  signal s_busy     : std_logic;
  signal s_bus_busy : std_logic;

  signal s_dut_scl_low : std_logic;
  signal s_dut_sda_low : std_logic;
  signal s_tgt_scl_low : std_logic := '0';
  signal s_tgt_sda_low : std_logic := '0';
  signal s_oth_scl_low : std_logic := '0';
  signal s_oth_sda_low : std_logic := '0';
  signal s_scl         : std_logic;
  signal s_sda         : std_logic;

  signal s_target_phase : natural range 0 to 20 := 0;
  signal s_other_phase  : natural range 0 to 20 := 0;
  signal s_allow_winner_stop : natural range 0 to 20 := 0;
  signal s_winner_waiting    : std_logic := '0';

  signal s_monitor_armed : std_logic := '0';
  signal s_measure_dut_timing : std_logic := '0';
  signal s_context_busy  : std_logic := '0';
  signal s_start_limit   : natural := 0;
  signal s_stop_limit    : natural := 0;
  signal s_start_seen    : natural := 0;
  signal s_stop_seen     : natural := 0;
  signal s_min_low       : time := 1 sec;
  signal s_min_high      : time := 1 sec;
  signal s_min_period    : time := 1 sec;
  signal s_min_data_hold : time := 1 sec;
  signal s_rep_low       : time := 0 ns;
  signal s_rep_setup     : time := 0 ns;
  signal s_rep_hold      : time := 0 ns;
  signal s_rep_high      : time := 0 ns;
  signal s_scl_rises     : natural := 0;
  signal s_scl_falls     : natural := 0;

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

  procedure p_stretch_next_high (
    signal dut_scl_low : in  std_logic;
    signal peer_scl_low : out std_logic
  ) is
  begin
    peer_scl_low <= '1';
    if dut_scl_low /= '0' then
      wait until dut_scl_low = '0';
    end if;
    wait for C_STRETCH_TIME;
    peer_scl_low <= '0';
  end procedure p_stretch_next_high;

  procedure p_receive_byte (
    signal scl            : in  std_logic;
    signal sda            : in  std_logic;
    signal dut_scl_low    : in  std_logic;
    signal peer_scl_low   : out std_logic;
    signal peer_sda_low   : out std_logic;
    constant expected     : in  std_logic_vector(7 downto 0);
    constant drive_ack    : in  boolean;
    constant stretch_bit  : in  integer := -1;
    constant stretch_ack  : in  boolean := false;
    constant late_ack     : in  boolean := false
  ) is
  begin
    for v_bit in 7 downto 0 loop
      if v_bit = stretch_bit then
        p_stretch_next_high(dut_scl_low, peer_scl_low);
      end if;
      wait until rising_edge(scl);
      assert sda = expected(v_bit)
        report "target received incorrect write bit " & integer'image(v_bit)
        severity failure;
      wait until falling_edge(scl);
    end loop;

    if stretch_ack or late_ack then
      peer_scl_low <= '1';
    end if;
    wait for C_T_HD_DAT;
    if late_ack then
      if drive_ack then
        peer_sda_low <= '0';
      else
        peer_sda_low <= '1';
      end if;
      if dut_scl_low /= '0' then
        wait until dut_scl_low = '0';
      end if;
      if drive_ack then
        peer_sda_low <= '1';
      else
        peer_sda_low <= '0';
      end if;
      wait for C_T_SU_DAT;
      peer_scl_low <= '0';
    else
      if drive_ack then
        peer_sda_low <= '1';
      else
        peer_sda_low <= '0';
      end if;
      if stretch_ack then
        if dut_scl_low /= '0' then
          wait until dut_scl_low = '0';
        end if;
        wait for C_STRETCH_TIME;
        peer_scl_low <= '0';
      end if;
    end if;

    wait until rising_edge(scl);
    if drive_ack then
      assert sda = '0' report "target ACK was not present" severity failure;
    else
      assert sda = '1' report "target NACK was not present" severity failure;
    end if;
    wait until falling_edge(scl);
    wait for C_T_HD_DAT;
    peer_sda_low <= '0';
  end procedure p_receive_byte;

  procedure p_send_byte (
    signal scl            : in  std_logic;
    signal sda            : in  std_logic;
    signal dut_scl_low    : in  std_logic;
    signal peer_scl_low   : out std_logic;
    signal peer_sda_low   : out std_logic;
    constant value        : in  std_logic_vector(7 downto 0);
    constant expect_ack   : in  boolean;
    constant stretch_bit  : in  integer := -1;
    constant stretch_ack  : in  boolean := false;
    constant late_data    : in  boolean := false
  ) is
  begin
    for v_bit in 7 downto 0 loop
      if late_data then
        peer_scl_low <= '1';
        wait for C_T_HD_DAT;
        if value(v_bit) = '0' then
          peer_sda_low <= '0';
        else
          peer_sda_low <= '1';
        end if;
        if dut_scl_low /= '0' then
          wait until dut_scl_low = '0';
        end if;
        if value(v_bit) = '0' then
          peer_sda_low <= '1';
        else
          peer_sda_low <= '0';
        end if;
        wait for C_T_SU_DAT;
        peer_scl_low <= '0';
      else
        wait for C_T_HD_DAT;
        if value(v_bit) = '0' then
          peer_sda_low <= '1';
        else
          peer_sda_low <= '0';
        end if;
        if v_bit = stretch_bit then
          p_stretch_next_high(dut_scl_low, peer_scl_low);
        end if;
      end if;
      wait until rising_edge(scl);
      wait until falling_edge(scl);
    end loop;

    if stretch_ack then
      peer_scl_low <= '1';
    end if;
    wait for C_T_HD_DAT;
    peer_sda_low <= '0';
    if stretch_ack then
      if dut_scl_low /= '0' then
        wait until dut_scl_low = '0';
      end if;
      wait for C_STRETCH_TIME;
      peer_scl_low <= '0';
    end if;

    wait until rising_edge(scl);
    if expect_ack then
      assert sda = '0' report "controller failed to transmit ACK" severity failure;
    else
      assert sda = '1' report "controller failed to transmit NACK" severity failure;
    end if;
    wait until falling_edge(scl);
    wait for C_T_HD_DAT;
  end procedure p_send_byte;

  procedure p_winning_stop (
    signal scl          : in  std_logic;
    signal peer_scl_low : out std_logic;
    signal peer_sda_low : out std_logic
  ) is
  begin
    peer_scl_low <= '1';
    peer_sda_low <= '1';
    wait for C_T_LOW;
    peer_scl_low <= '0';
    wait until scl = '1';
    wait for C_T_SU_STO;
    peer_sda_low <= '0';
  end procedure p_winning_stop;

begin

  assert C_STRETCH_TIME > 2 * C_CTRL_HIGH
    report "directed stretch must exceed two requested HIGH phases"
    severity failure;

  s_scl <= '0' when
    s_dut_scl_low = '1' or s_tgt_scl_low = '1' or s_oth_scl_low = '1'
    else '1';
  s_sda <= '0' when
    s_dut_sda_low = '1' or s_tgt_sda_low = '1' or s_oth_sda_low = '1'
    else '1';

  inst_dut : entity work.lm_i2c_master
    generic map (
      g_clk_freq_hz => g_clk_freq_hz,
      g_i2c_freq_hz => g_i2c_freq_hz
    )
    port map (
      clk_i           => s_clk,
      rst_n_i         => s_rst_n,
      bus_assume_free_i => s_bus_assume_free,
      cmd_valid_i     => s_cmd_valid,
      cmd_start_i     => s_cmd_start,
      cmd_stop_i      => s_cmd_stop,
      cmd_stop_only_i => s_cmd_stop_only,
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

  proc_bus_edge_counts : process(s_scl)
  begin
    if rising_edge(s_scl) then
      s_scl_rises <= s_scl_rises + 1;
    elsif falling_edge(s_scl) then
      s_scl_falls <= s_scl_falls + 1;
    end if;
  end process proc_bus_edge_counts;

  -- Only resolved-bus and arm events can change this event-driven monitor;
  -- the other read signals are stable controls during each measured phase.
  proc_passive_monitor : process(
    s_monitor_armed, s_scl, s_sda
  )
    variable v_active         : boolean := false;
    variable v_pending_start  : boolean := false;
    variable v_repeat_start   : boolean := false;
    variable v_last_scl_rise  : time := 0 ns;
    variable v_last_scl_fall  : time := 0 ns;
    variable v_last_sda_event : time := 0 ns;
    variable v_last_stop      : time := 0 ns;
    variable v_last_low       : time := 0 ns;
    variable v_have_rise      : boolean := false;
    variable v_have_fall      : boolean := false;
    variable v_have_sda       : boolean := false;
    variable v_have_stop      : boolean := false;
    variable v_starts         : natural := 0;
    variable v_stops          : natural := 0;
    variable v_low            : time;
    variable v_high           : time;
    variable v_period         : time;
    variable v_hold           : time;
  begin
    if s_monitor_armed'event and s_monitor_armed = '1' then
      v_active         := s_context_busy = '1';
      v_pending_start  := false;
      v_repeat_start   := false;
      v_last_scl_rise  := now;
      v_last_scl_fall  := now;
      v_last_sda_event := now;
      v_last_stop      := now;
      v_have_rise      := false;
      v_have_fall      := false;
      v_have_sda       := false;
      v_have_stop      := false;
    elsif s_monitor_armed = '1' then
      assert (s_scl = '0' or s_scl = '1') and
             (s_sda = '0' or s_sda = '1')
        report "resolved I2C bus contains a non-binary level"
        severity failure;

      if s_scl'event and s_scl = '1' then
        if v_have_fall then
          v_low := now - v_last_scl_fall;
          assert v_low >= C_T_LOW
            report "passive monitor detected short tLOW: " & time'image(v_low)
            severity failure;
          if s_measure_dut_timing = '1' then
            assert v_low >= C_EXPECT_LOW
              report "passive monitor detected shortened derived LOW phase: " &
                time'image(v_low) & " expected " & time'image(C_EXPECT_LOW)
              severity failure;
          end if;
          if s_measure_dut_timing = '1' and v_low < s_min_low then
            s_min_low <= v_low;
          end if;
          v_last_low := v_low;
        end if;
        if v_have_sda then
          assert now - v_last_sda_event >= C_T_SU_DAT
            report "passive monitor detected short data setup"
            severity failure;
        end if;
        if v_have_rise then
          v_period := now - v_last_scl_rise;
          assert v_period >= C_REQ_PERIOD
            report "passive monitor detected SCL faster than requested"
            severity failure;
          if s_measure_dut_timing = '1' then
            assert v_period >= C_EXPECT_PERIOD
              report "passive monitor detected shortened derived SCL period: " &
                time'image(v_period) & " expected " &
                time'image(C_EXPECT_PERIOD)
              severity failure;
          end if;
          if s_measure_dut_timing = '1' and v_period < s_min_period then
            s_min_period <= v_period;
          end if;
        end if;
        v_last_scl_rise := now;
        v_have_rise     := true;
      elsif s_scl'event and s_scl = '0' then
        if v_have_rise then
          v_high := now - v_last_scl_rise;
          assert v_high >= C_T_HIGH
            report "passive monitor detected short tHIGH: " & time'image(v_high)
            severity failure;
          if s_measure_dut_timing = '1' and
             (not v_pending_start or v_repeat_start) then
            assert v_high >= C_EXPECT_HIGH
              report "passive monitor detected shortened derived HIGH phase: " &
                time'image(v_high) & " expected " & time'image(C_EXPECT_HIGH)
              severity failure;
          end if;
          if s_measure_dut_timing = '1' and v_high < s_min_high then
            s_min_high <= v_high;
          end if;
        end if;
        if v_pending_start then
          assert now - v_last_sda_event >= C_T_HD_STA
            report "passive monitor detected short START hold"
            severity failure;
          if v_repeat_start then
            assert now - v_last_scl_rise >= C_EXPECT_HIGH
              report "passive monitor detected repeated-START HIGH faster " &
                "than requested"
              severity failure;
            s_rep_hold <= now - v_last_sda_event;
            s_rep_high <= now - v_last_scl_rise;
          end if;
          v_pending_start := false;
          v_repeat_start  := false;
        end if;
        v_last_scl_fall := now;
        v_have_fall     := true;
      end if;

      if s_sda'event then
        if s_scl = '1' then
          if s_sda = '0' then
            assert v_starts < s_start_limit
              report "passive monitor detected unexpected START"
              severity failure;
            if v_active then
              assert v_have_rise and now - v_last_scl_rise >= C_T_SU_STA
                report "passive monitor detected short repeated-START setup"
                severity failure;
              assert v_last_low >= C_T_LOW
                report "passive monitor detected collapsed repeated-START LOW"
                severity failure;
              s_rep_low <= v_last_low;
              s_rep_setup <= now - v_last_scl_rise;
              v_repeat_start := true;
            elsif v_have_stop then
              assert now - v_last_stop >= C_T_BUF
                report "passive monitor detected short bus-free time"
                severity failure;
            end if;
            v_starts         := v_starts + 1;
            s_start_seen     <= v_starts;
            v_active         := true;
            v_pending_start  := true;
          else
            assert v_stops < s_stop_limit
              report "passive monitor detected unexpected STOP"
              severity failure;
            assert v_active
              report "passive monitor detected STOP while bus was free"
              severity failure;
            assert v_have_rise and now - v_last_scl_rise >= C_T_SU_STO
              report "passive monitor detected short STOP setup"
              severity failure;
            v_stops      := v_stops + 1;
            s_stop_seen  <= v_stops;
            v_active     := false;
            v_last_stop  := now;
            v_have_stop  := true;
            -- A STOP terminates the SCL slot sequence; the next rising edge
            -- belongs to a new transfer rather than the preceding period.
            v_have_rise  := false;
          end if;
        elsif v_have_fall then
          v_hold := now - v_last_scl_fall;
          assert v_hold >= C_T_HD_DAT
            report "passive monitor detected short deliberate data hold: " &
              time'image(v_hold)
            severity failure;
          if v_hold < s_min_data_hold then
            s_min_data_hold <= v_hold;
          end if;
        end if;
        v_last_sda_event := now;
        v_have_sda       := true;
      end if;
    end if;
  end process proc_passive_monitor;

  proc_bus_sanity : process(s_clk)
  begin
    if rising_edge(s_clk) and s_monitor_armed = '1' then
      assert (s_dut_scl_low = '0' or s_dut_scl_low = '1') and
             (s_dut_sda_low = '0' or s_dut_sda_low = '1')
        report "DUT open-drain control contains a non-binary value"
        severity failure;
      if s_dut_scl_low = '1' or s_dut_sda_low = '1' then
        assert s_bus_busy = '1'
          report "bus_busy_o was LOW while the DUT drove or claimed the bus"
          severity failure;
      end if;
    end if;
  end process proc_bus_sanity;

  proc_target : process
    constant C_ARB_READ_DATA : std_logic_vector(7 downto 0) := x"F0";
    variable v_rises_before_stop : natural;
    variable v_falls_before_stop : natural;
  begin
    wait until s_target_phase = 1;
    p_wait_start(s_scl, s_sda);
    p_receive_byte(
      s_scl, s_sda, s_dut_scl_low, s_tgt_scl_low, s_tgt_sda_low,
      x"A0", true, 4, true
    );
    p_receive_byte(
      s_scl, s_sda, s_dut_scl_low, s_tgt_scl_low, s_tgt_sda_low,
      x"12", true
    );
    p_receive_byte(
      s_scl, s_sda, s_dut_scl_low, s_tgt_scl_low, s_tgt_sda_low,
      x"34", true
    );
    p_stretch_next_high(s_dut_scl_low, s_tgt_scl_low);
    p_wait_stop(s_scl, s_sda);

    wait until s_target_phase = 2;
    p_wait_start(s_scl, s_sda);
    p_receive_byte(
      s_scl, s_sda, s_dut_scl_low, s_tgt_scl_low, s_tgt_sda_low,
      x"A0", false, -1, true
    );
    s_tgt_scl_low <= '1';
    v_rises_before_stop := s_scl_rises;
    v_falls_before_stop := s_scl_falls;
    if s_dut_scl_low /= '0' then
      wait until s_dut_scl_low = '0';
    end if;
    wait for C_STRETCH_TIME;
    s_tgt_scl_low <= '0';
    p_wait_stop(s_scl, s_sda);
    assert s_scl_rises = v_rises_before_stop + 1 and
           s_scl_falls = v_falls_before_stop
      report "STOP-only after address NACK emitted byte clocks"
      severity failure;

    wait until s_target_phase = 3;
    p_wait_start(s_scl, s_sda);
    p_receive_byte(
      s_scl, s_sda, s_dut_scl_low, s_tgt_scl_low, s_tgt_sda_low,
      x"A0", true
    );
    p_receive_byte(
      s_scl, s_sda, s_dut_scl_low, s_tgt_scl_low, s_tgt_sda_low,
      x"55", true
    );
    s_tgt_scl_low <= '1';
    if s_dut_scl_low /= '0' then
      wait until s_dut_scl_low = '0';
    end if;
    wait for C_STRETCH_TIME;
    s_tgt_scl_low <= '0';
    p_wait_start(s_scl, s_sda);
    p_receive_byte(
      s_scl, s_sda, s_dut_scl_low, s_tgt_scl_low, s_tgt_sda_low,
      x"A1", true
    );
    p_send_byte(
      s_scl, s_sda, s_dut_scl_low, s_tgt_scl_low, s_tgt_sda_low,
      x"3C", true, 3, true
    );
    p_send_byte(
      s_scl, s_sda, s_dut_scl_low, s_tgt_scl_low, s_tgt_sda_low,
      x"C7", false, -1, true
    );
    p_stretch_next_high(s_dut_scl_low, s_tgt_scl_low);
    p_wait_stop(s_scl, s_sda);

    wait until s_target_phase = 4;
    p_wait_start(s_scl, s_sda);
    p_receive_byte(
      s_scl, s_sda, s_dut_scl_low, s_tgt_scl_low, s_tgt_sda_low,
      x"A1", true, -1, false, true
    );
    p_send_byte(
      s_scl, s_sda, s_dut_scl_low, s_tgt_scl_low, s_tgt_sda_low,
      x"5A", false, -1, false, true
    );
    p_wait_stop(s_scl, s_sda);

    wait until s_target_phase = 6;
    p_wait_start(s_scl, s_sda);
    p_receive_byte(
      s_scl, s_sda, s_dut_scl_low, s_tgt_scl_low, s_tgt_sda_low,
      x"A0", true
    );
    p_receive_byte(
      s_scl, s_sda, s_dut_scl_low, s_tgt_scl_low, s_tgt_sda_low,
      x"6D", false
    );
    v_rises_before_stop := s_scl_rises;
    v_falls_before_stop := s_scl_falls;
    p_wait_stop(s_scl, s_sda);
    assert s_scl_rises = v_rises_before_stop + 1 and
           s_scl_falls = v_falls_before_stop
      report "STOP-only after data NACK emitted byte clocks"
      severity failure;

    wait until s_target_phase = 7;
    p_wait_start(s_scl, s_sda);
    p_receive_byte(
      s_scl, s_sda, s_dut_scl_low, s_tgt_scl_low, s_tgt_sda_low,
      x"A0", true
    );
    p_wait_start(s_scl, s_sda);
    p_receive_byte(
      s_scl, s_sda, s_dut_scl_low, s_tgt_scl_low, s_tgt_sda_low,
      x"A2", true
    );
    p_wait_stop(s_scl, s_sda);

    wait until s_target_phase = 5;
    p_wait_start(s_scl, s_sda);
    p_receive_byte(
      s_scl, s_sda, s_dut_scl_low, s_tgt_scl_low, s_tgt_sda_low,
      x"A0", true
    );
    p_wait_stop(s_scl, s_sda);

    wait until s_target_phase = 12;
    p_wait_start(s_scl, s_sda);
    p_receive_byte(
      s_scl, s_sda, s_dut_scl_low, s_tgt_scl_low, s_tgt_sda_low,
      x"A1", true
    );
    for v_bit in 7 downto 0 loop
      wait for C_T_HD_DAT;
      if C_ARB_READ_DATA(v_bit) = '0' then
        s_tgt_sda_low <= '1';
      else
        s_tgt_sda_low <= '0';
      end if;
      wait until rising_edge(s_scl);
      wait until falling_edge(s_scl);
    end loop;
    wait for C_T_HD_DAT;
    s_tgt_sda_low <= '0';
    wait;
  end process proc_target;

  proc_other_controller : process

    procedure p_arbitrate_write (
      constant preceding_bits : in natural;
      constant phase          : in natural
    ) is
    begin
      p_wait_start(s_scl, s_sda);
      for v_bit in 1 to preceding_bits loop
        wait until rising_edge(s_scl);
        wait until falling_edge(s_scl);
      end loop;
      wait for C_T_HD_DAT;
      s_oth_sda_low <= '1';
      wait until rising_edge(s_scl);
      wait for C_ARB_RELEASE_CHECK;
      assert s_dut_scl_low = '0' and s_dut_sda_low = '0'
        report "DUT continued driving after arbitration loss"
        severity failure;
      wait for C_CTRL_HIGH - C_ARB_RELEASE_CHECK;
      s_oth_scl_low <= '1';
      wait for C_T_LOW;
      s_oth_scl_low <= '0';
      wait until s_scl = '1';
      wait for C_CTRL_HIGH;
      s_oth_scl_low <= '1';
      wait for C_T_LOW;
      s_winner_waiting <= '1';
      wait until s_allow_winner_stop = phase;
      s_winner_waiting <= '0';
      p_winning_stop(s_scl, s_oth_scl_low, s_oth_sda_low);
    end procedure p_arbitrate_write;

  begin
    if s_other_phase /= 1 then
      wait until s_other_phase = 1;
    end if;
    s_oth_scl_low <= '1';
    s_oth_sda_low <= '1';
    wait for 6 * C_T_LOW;
    s_oth_scl_low <= '0';
    wait until s_scl = '1';
    wait for C_T_SU_STO;
    s_oth_sda_low <= '0';

    if s_other_phase /= 10 then
      wait until s_other_phase = 10;
    end if;
    p_arbitrate_write(0, 10);

    if s_other_phase /= 11 then
      wait until s_other_phase = 11;
    end if;
    p_arbitrate_write(2, 11);

    if s_other_phase /= 13 then
      wait until s_other_phase = 13;
    end if;
    p_arbitrate_write(5, 13);

    if s_other_phase /= 12 then
      wait until s_other_phase = 12;
    end if;
    p_wait_start(s_scl, s_sda);
    -- Include the START-to-first-bit falling edge, nine address-slot falling
    -- edges, and eight read-data falling edges.
    for v_edge in 1 to 18 loop
      wait until falling_edge(s_scl);
    end loop;
    wait for C_T_HD_DAT;
    s_oth_sda_low <= '1';
    wait until rising_edge(s_scl);
    wait for C_ARB_RELEASE_CHECK;
    assert s_dut_scl_low = '0' and s_dut_sda_low = '0'
      report "DUT continued driving after read-NACK arbitration loss"
      severity failure;
    wait for C_CTRL_HIGH - C_ARB_RELEASE_CHECK;
    s_oth_scl_low <= '1';
    s_winner_waiting <= '1';
    wait until s_allow_winner_stop = 12;
    s_winner_waiting <= '0';
    p_winning_stop(s_scl, s_oth_scl_low, s_oth_sda_low);
    wait;
  end process proc_other_controller;

  proc_stimulus : process

    procedure p_allow_start is
    begin
      s_start_limit <= s_start_limit + 1;
      wait for 0 ns;
    end procedure p_allow_start;

    procedure p_allow_stop is
    begin
      s_stop_limit <= s_stop_limit + 1;
      wait for 0 ns;
    end procedure p_allow_stop;

    procedure p_launch (
      constant start_cmd : in boolean;
      constant stop_cmd  : in boolean;
      constant read_cmd  : in boolean;
      constant data      : in std_logic_vector(7 downto 0);
      constant nack      : in std_logic;
      constant stop_only : in boolean := false
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
      if stop_only then
        s_cmd_stop_only <= '1';
      else
        s_cmd_stop_only <= '0';
      end if;
      s_cmd_data  <= data;
      s_cmd_nack  <= nack;
      s_cmd_valid <= '1';
      wait until rising_edge(s_clk);
      s_cmd_valid <= '0';
      s_cmd_start <= '0';
      s_cmd_stop  <= '0';
      s_cmd_stop_only <= '0';
      s_cmd_read  <= '0';
      wait for 0 ns;
      wait for 0 ns;
    end procedure p_launch;

    procedure p_wait_response (
      constant expected_data  : in std_logic_vector(7 downto 0);
      constant expected_nack  : in std_logic;
      constant expected_arb   : in std_logic;
      constant expected_error : in std_logic;
      constant hold_cycles    : in natural := 0
    ) is
      variable v_cycles : natural := 0;
    begin
      while s_rsp_valid /= '1' loop
        wait until rising_edge(s_clk);
        v_cycles := v_cycles + 1;
        assert v_cycles < 200_000
          report "bounded response wait expired"
          severity failure;
      end loop;
      assert s_rsp_data = expected_data
        report "unexpected response data"
        severity failure;
      assert s_rsp_nack = expected_nack
        report "unexpected response NACK"
        severity failure;
      assert s_rsp_arb_lost = expected_arb
        report "unexpected response arbitration status"
        severity failure;
      assert s_rsp_cmd_error = expected_error
        report "unexpected response command-error status"
        severity failure;

      for v_cycle in 1 to hold_cycles loop
        wait until rising_edge(s_clk);
        assert s_rsp_valid = '1' and
               s_rsp_data = expected_data and
               s_rsp_nack = expected_nack and
               s_rsp_arb_lost = expected_arb and
               s_rsp_cmd_error = expected_error
          report "backpressured response changed"
          severity failure;
        assert s_cmd_ready = '0'
          report "command accepted while response was pending"
          severity failure;
      end loop;

      s_rsp_ready <= '1';
      wait until rising_edge(s_clk);
      s_rsp_ready <= '0';
      wait until rising_edge(s_clk);
      assert s_rsp_valid = '0'
        report "response did not clear after ready handshake"
        severity failure;
    end procedure p_wait_response;

    procedure p_wait_bus_free is
      variable v_cycles : natural := 0;
    begin
      while s_bus_busy /= '0' loop
        wait until rising_edge(s_clk);
        v_cycles := v_cycles + 1;
        assert v_cycles < 200_000
          report "bounded bus-free wait expired"
          severity failure;
      end loop;
    end procedure p_wait_bus_free;

    procedure p_wait_winner is
      variable v_cycles : natural := 0;
    begin
      while s_winner_waiting /= '1' loop
        wait until rising_edge(s_clk);
        v_cycles := v_cycles + 1;
        assert v_cycles < 200_000
          report "bounded winning-controller wait expired"
          severity failure;
      end loop;
    end procedure p_wait_winner;

    variable v_start_before : natural;

  begin
    -- Reset into an externally active transfer. The first command is accepted
    -- but must wait for the winning controller's STOP and a complete tBUF.
    s_other_phase   <= 1;
    s_context_busy  <= '1';
    s_stop_limit    <= 1;
    s_start_limit   <= 1;
    s_rst_n         <= '0';
    wait for 8 * C_CLK_PERIOD;
    wait until rising_edge(s_clk);
    s_rst_n         <= '1';
    s_monitor_armed <= '1';
    s_measure_dut_timing <= '1';
    wait for 4 * C_CLK_PERIOD;
    assert s_bus_busy = '1'
      report "bus was incorrectly qualified free after active reset"
      severity failure;

    s_target_phase <= 1;
    p_launch(true, false, false, x"A0", '1');
    assert s_busy = '1' report "START command did not wait internally" severity failure;

    -- Hold the next byte valid while the first response is backpressured.
    while s_rsp_valid /= '1' loop
      wait until rising_edge(s_clk);
    end loop;
    assert s_rsp_data = x"00" and s_rsp_nack = '0' and
           s_rsp_arb_lost = '0' and s_rsp_cmd_error = '0'
      report "unexpected first response"
      severity failure;
    s_cmd_data  <= x"12";
    s_cmd_valid <= '1';
    for v_cycle in 1 to 6 loop
      wait until rising_edge(s_clk);
      assert s_rsp_valid = '1' and s_cmd_ready = '0'
        report "pending response accepted or changed a queued command"
        severity failure;
    end loop;
    s_rsp_ready <= '1';
    wait until rising_edge(s_clk);
    s_rsp_ready <= '0';
    wait until rising_edge(s_clk);
    s_cmd_valid <= '0';
    wait for 0 ns;
    wait for 0 ns;
    assert s_busy = '1'
      report "queued command was not accepted at the earliest supported cycle"
      severity failure;
    p_wait_response(x"00", '0', '0', '0', 3);

    p_allow_stop;
    p_launch(false, true, false, x"34", '1');
    p_wait_response(x"00", '0', '0', '0');
    p_wait_bus_free;

    -- Write NACK.
    s_target_phase <= 2;
    p_allow_start;
    p_launch(true, false, false, x"A0", '1');
    p_wait_response(x"00", '1', '0', '0');
    assert s_bus_busy = '1'
      report "address NACK unexpectedly cleared controller ownership"
      severity failure;
    p_allow_stop;
    p_launch(true, true, true, x"FF", '0', true);
    p_wait_response(x"00", '0', '0', '0', 5);
    p_wait_bus_free;

    -- Combined register read with repeated START and two read bytes.
    s_target_phase <= 3;
    p_allow_start;
    p_launch(true, false, false, x"A0", '1');
    p_wait_response(x"00", '0', '0', '0');
    p_launch(false, false, false, x"55", '1');
    p_wait_response(x"00", '0', '0', '0');
    p_allow_start;
    p_launch(true, false, false, x"A1", '1');
    assert s_bus_busy = '1'
      report "bus_busy_o fell during repeated-START ownership"
      severity failure;
    p_wait_response(x"00", '0', '0', '0');
    p_launch(false, false, true, x"00", '0');
    p_wait_response(x"3C", '0', '0', '0', 4);
    p_allow_stop;
    p_launch(false, true, true, x"00", '1');
    p_wait_response(x"C7", '0', '0', '0');
    p_wait_bus_free;

    -- One-byte read.
    s_target_phase <= 4;
    p_allow_start;
    p_launch(true, false, false, x"A1", '1');
    p_wait_response(x"00", '0', '0', '0');
    p_allow_stop;
    p_launch(false, true, true, x"00", '1');
    p_wait_response(x"5A", '0', '0', '0');
    p_wait_bus_free;

    -- A data NACK also leaves ownership available for a STOP-only command.
    s_target_phase <= 6;
    p_allow_start;
    p_launch(true, false, false, x"A0", '1');
    p_wait_response(x"00", '0', '0', '0');
    p_launch(false, false, false, x"6D", '1');
    p_wait_response(x"00", '1', '0', '0');
    assert s_bus_busy = '1'
      report "data NACK unexpectedly cleared controller ownership"
      severity failure;
    p_allow_stop;
    p_launch(true, true, true, x"FF", '0', true);
    p_wait_response(x"00", '0', '0', '0', 3);
    p_wait_bus_free;

    -- An unstretched repeated START keeps a full preparation LOW interval.
    s_target_phase <= 7;
    p_allow_start;
    p_launch(true, false, false, x"A0", '1');
    p_wait_response(x"00", '0', '0', '0');
    p_allow_start;
    p_allow_stop;
    p_launch(true, true, false, x"A2", '1');
    p_wait_response(x"00", '0', '0', '0');
    p_wait_bus_free;

    -- STOP-only ignores every byte field but requires local ownership.
    p_launch(true, true, true, x"99", '0', true);
    p_wait_response(x"00", '0', '0', '1', 5);
    assert s_scl = '1' and s_sda = '1'
      report "illegal STOP-only command caused bus activity"
      severity failure;

    -- Reset removes a backpressured response without leaving stale status.
    s_target_phase <= 5;
    p_allow_start;
    p_allow_stop;
    p_launch(true, true, false, x"A0", '1');
    while s_rsp_valid /= '1' loop
      wait until rising_edge(s_clk);
    end loop;
    wait for 5 * C_CLK_PERIOD;
    s_rst_n <= '0';
    wait until rising_edge(s_clk);
    wait until rising_edge(s_clk);
    assert s_rsp_valid = '0' and s_cmd_ready = '1'
      report "reset did not clear a pending response"
      severity failure;
    assert s_dut_scl_low = '0' and s_dut_sda_low = '0'
      report "reset did not release open-drain controls"
      severity failure;
    s_rst_n <= '1';
    s_bus_assume_free <= '1';
    p_wait_bus_free;
    assert s_rsp_valid = '0'
      report "stale response appeared after reset"
      severity failure;

    s_measure_dut_timing <= '0';

    -- Arbitration at address bit 7. The next command is queued while the
    -- winning controller still owns the physical bus.
    s_other_phase <= 10;
    p_allow_start;
    p_launch(true, false, false, x"A0", '1');
    p_wait_response(x"00", '0', '1', '0', 6);
    p_wait_winner;
    assert s_dut_scl_low = '0' and s_dut_sda_low = '0'
      report "arbitration loss did not release the bus"
      severity failure;
    assert s_bus_busy = '1'
      report "bus_busy cleared before the winning controller issued STOP"
      severity failure;

    v_start_before := s_start_seen;
    s_other_phase <= 11;
    p_allow_start;
    p_launch(true, false, false, x"A0", '1');
    for v_cycle in 1 to 5 loop
      wait until rising_edge(s_clk);
      assert s_start_seen = v_start_before and s_bus_busy = '1'
        report "new START occurred before the winning controller released the bus"
        severity failure;
    end loop;
    p_allow_stop;
    s_allow_winner_stop <= 10;

    -- Arbitration at address bit 5 after transmitting zero without false loss.
    p_wait_response(x"00", '0', '1', '0');
    p_wait_winner;
    assert s_start_seen = v_start_before + 1 and s_bus_busy = '1'
      report "queued START or second arbitration ownership was incorrect"
      severity failure;
    p_allow_stop;
    s_allow_winner_stop <= 11;
    p_wait_bus_free;

    -- A third write-data arbitration point.
    s_other_phase <= 13;
    p_allow_start;
    p_launch(true, false, false, x"A4", '1');
    p_wait_response(x"00", '0', '1', '0', 3);
    p_wait_winner;
    assert s_bus_busy = '1'
      report "third arbitration case lost physical bus-busy state"
      severity failure;
    p_allow_stop;
    s_allow_winner_stop <= 13;
    p_wait_bus_free;

    -- Arbitration during the controller NACK phase after a read.
    s_target_phase <= 12;
    s_other_phase  <= 12;
    p_allow_start;
    p_launch(true, false, false, x"A1", '1');
    p_wait_response(x"00", '0', '0', '0');
    p_allow_stop;
    p_launch(false, false, true, x"00", '1');
    p_wait_response(x"F0", '0', '1', '0', 4);
    p_wait_winner;
    assert s_dut_scl_low = '0' and s_dut_sda_low = '0' and
           s_bus_busy = '1'
      report "read-NACK arbitration did not release ownership correctly"
      severity failure;
    s_allow_winner_stop <= 12;
    p_wait_bus_free;

    assert s_start_seen = s_start_limit
      report "expected START count was not observed"
      severity failure;
    assert s_stop_seen = s_stop_limit
      report "expected STOP count was not observed"
      severity failure;
    assert s_rep_low >= 2 * C_EXPECT_LOW
      report "repeated-START LOW measurement was not captured"
      severity failure;
    assert s_rep_setup >= C_T_SU_STA and s_rep_hold >= C_T_HD_STA and
           s_rep_high >= C_EXPECT_HIGH
      report "repeated-START HIGH timing was not fully captured"
      severity failure;

    report "MEASURE min_tLOW=" & time'image(s_min_low) &
      " min_tHIGH=" & time'image(s_min_high) &
      " min_period=" & time'image(s_min_period) &
      " min_data_hold=" & time'image(s_min_data_hold) &
      " repeated_start_low=" & time'image(s_rep_low) &
      " repeated_start_setup=" & time'image(s_rep_setup) &
      " repeated_start_hold=" & time'image(s_rep_hold) &
      " repeated_start_high=" & time'image(s_rep_high)
      severity note;
    report "lm_i2c_master self-check passed" severity note;
    stop;
    wait;
  end process proc_stimulus;

  proc_watchdog : process
  begin
    wait for C_WATCHDOG;
    assert false
      report "global regression watchdog expired"
      severity failure;
  end process proc_watchdog;

end architecture a_tb;
