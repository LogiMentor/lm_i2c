--=============================================================================
-- Module Name : lm_i2c_master
-- Library     : -
-- Project     : lm_i2c
-- Company     : LogiMentor Srl
-------------------------------------------------------------------------------
-- Description:
--  Dependency-free byte-command I2C controller for Standard-mode and
--  Fast-mode. All state is synchronous to clk_i with active-low synchronous
--  reset. Bus outputs are active-high open-drain drive-low controls.
-------------------------------------------------------------------------------
-- Copyright 2026 LogiMentor Srl
-- SPDX-License-Identifier: Apache-2.0
--=============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity lm_i2c_master is
  generic (
    g_clk_freq_hz : positive;
    g_i2c_freq_hz : positive := 100_000
  );
  port (
    -- Clock and reset
    clk_i   : in std_logic;
    rst_n_i : in std_logic;

    -- Byte-command input
    cmd_valid_i : in std_logic;
    cmd_start_i : in std_logic;
    cmd_stop_i  : in std_logic;
    cmd_read_i  : in std_logic;
    cmd_data_i  : in std_logic_vector(7 downto 0);
    cmd_nack_i  : in std_logic;

    -- Response consumption
    rsp_ready_i : in std_logic;

    -- Resolved I2C bus inputs
    scl_i : in std_logic;
    sda_i : in std_logic;

    -- Command and response status
    cmd_ready_o     : out std_logic;
    rsp_valid_o     : out std_logic;
    rsp_data_o      : out std_logic_vector(7 downto 0);
    rsp_nack_o      : out std_logic;
    rsp_arb_lost_o  : out std_logic;
    rsp_cmd_error_o : out std_logic;
    busy_o          : out std_logic;
    bus_busy_o      : out std_logic;

    -- Active-high open-drain controls
    scl_low_o : out std_logic;
    sda_low_o : out std_logic
  );
end entity lm_i2c_master;

architecture a_rtl of lm_i2c_master is

  function f_div_ceil (
    a : positive;
    b : positive
  ) return positive is
  begin
    return ((a - 1) / b) + 1;
  end function f_div_ceil;

  function f_scale_ceil (
    a : positive;
    n : positive;
    d : positive
  ) return positive is
    variable v_quotient  : natural;
    variable v_remainder : natural;
  begin
    v_quotient  := (a / d) * n;
    v_remainder := ((a mod d) * n + d - 1) / d;
    return v_quotient + v_remainder;
  end function f_scale_ceil;

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

  function f_mode_cycles (
    standard_cycles : positive;
    fast_cycles     : positive;
    bus_frequency   : positive
  ) return positive is
  begin
    if bus_frequency <= 100_000 then
      return standard_cycles;
    else
      return fast_cycles;
    end if;
  end function f_mode_cycles;

  function f_high_cycles (
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
  end function f_high_cycles;

  constant C_PERIOD_CYCLES : positive :=
    f_div_ceil(g_clk_freq_hz, g_i2c_freq_hz);
  constant C_LOW_MIN_CYCLES : positive := f_mode_cycles(
    f_scale_ceil(g_clk_freq_hz, 47, 10_000_000),
    f_scale_ceil(g_clk_freq_hz, 13, 10_000_000),
    g_i2c_freq_hz
  );
  constant C_HIGH_MIN_CYCLES : positive := f_mode_cycles(
    f_scale_ceil(g_clk_freq_hz, 4, 1_000_000),
    f_scale_ceil(g_clk_freq_hz, 6, 10_000_000),
    g_i2c_freq_hz
  );
  constant C_BUF_CYCLES : positive := f_mode_cycles(
    f_scale_ceil(g_clk_freq_hz, 47, 10_000_000),
    f_scale_ceil(g_clk_freq_hz, 13, 10_000_000),
    g_i2c_freq_hz
  );
  constant C_START_SETUP : positive := f_mode_cycles(
    f_scale_ceil(g_clk_freq_hz, 47, 10_000_000),
    f_scale_ceil(g_clk_freq_hz, 6, 10_000_000),
    g_i2c_freq_hz
  );
  constant C_START_HOLD : positive := f_mode_cycles(
    f_scale_ceil(g_clk_freq_hz, 4, 1_000_000),
    f_scale_ceil(g_clk_freq_hz, 6, 10_000_000),
    g_i2c_freq_hz
  );
  constant C_STOP_SETUP : positive := f_mode_cycles(
    f_scale_ceil(g_clk_freq_hz, 4, 1_000_000),
    f_scale_ceil(g_clk_freq_hz, 6, 10_000_000),
    g_i2c_freq_hz
  );
  constant C_DATA_SETUP : positive := f_mode_cycles(
    f_scale_ceil(g_clk_freq_hz, 1, 4_000_000),
    f_scale_ceil(g_clk_freq_hz, 1, 10_000_000),
    g_i2c_freq_hz
  );
  constant C_DATA_HOLD : positive :=
    f_scale_ceil(g_clk_freq_hz, 3, 10_000_000);
  constant C_LOW_CYCLES : positive :=
    f_max(C_LOW_MIN_CYCLES, C_DATA_HOLD + C_DATA_SETUP);
  constant C_HIGH_CYCLES : positive :=
    f_high_cycles(C_PERIOD_CYCLES, C_LOW_CYCLES, C_HIGH_MIN_CYCLES);
  constant C_LOW_REMAIN : positive :=
    C_LOW_CYCLES - C_DATA_HOLD;
  constant C_TIMER_MAX : positive :=
    f_max(
      f_max(C_PERIOD_CYCLES, C_BUF_CYCLES),
      f_max(
        f_max(C_START_SETUP, C_START_HOLD),
        f_max(C_STOP_SETUP, C_LOW_CYCLES)
      )
    );

  type t_state is (
    st_idle,
    st_wait_free,
    st_start_hold,
    st_rep_low,
    st_rep_wait,
    st_rep_setup,
    st_rep_hold,
    st_write_hold,
    st_write_setup,
    st_write_wait,
    st_write_high,
    st_wack_hold,
    st_wack_setup,
    st_wack_wait,
    st_wack_high,
    st_wdone_hold,
    st_wdone_setup,
    st_read_hold,
    st_read_setup,
    st_read_wait,
    st_read_high,
    st_rack_hold,
    st_rack_setup,
    st_rack_wait,
    st_rack_high,
    st_rdone_hold,
    st_rdone_setup,
    st_stop_wait,
    st_stop_setup,
    st_response
  );

  signal s_state : t_state;

  signal s_cmd_start : std_logic;
  signal s_cmd_stop  : std_logic;
  signal s_cmd_read  : std_logic;
  signal s_cmd_nack  : std_logic;
  signal s_shift     : std_logic_vector(7 downto 0);
  signal s_bit_index : natural range 0 to 7;
  signal s_timer     : natural range 0 to C_TIMER_MAX;

  signal s_scl_meta : std_logic;
  signal s_scl_sync : std_logic;
  signal s_sda_meta : std_logic;
  signal s_sda_sync : std_logic;
  signal s_sda_prev : std_logic;

  signal s_bus_busy  : std_logic;
  signal s_need_stop : std_logic;
  signal s_free_cnt  : natural range 0 to C_BUF_CYCLES;
  signal s_owned     : std_logic;

  signal s_scl_low : std_logic;
  signal s_sda_low : std_logic;

begin

  assert g_i2c_freq_hz <= 400_000
    report "g_i2c_freq_hz must not exceed 400 kHz"
    severity failure;

  assert g_clk_freq_hz / g_i2c_freq_hz >= 8
    report "g_clk_freq_hz must be at least eight times g_i2c_freq_hz"
    severity failure;

  assert C_DATA_HOLD > 0
    report "derived data-hold interval must be nonzero"
    severity failure;

  assert C_LOW_CYCLES > C_DATA_HOLD
    report "derived SCL LOW interval must exceed the data-hold interval"
    severity failure;

  assert C_LOW_REMAIN >= C_DATA_SETUP
    report "derived SCL LOW interval leaves insufficient data setup time"
    severity failure;

  cmd_ready_o <= '1' when s_state = st_idle else '0';
  busy_o      <= '0' when s_state = st_idle or s_state = st_response else '1';
  bus_busy_o  <= s_bus_busy;
  scl_low_o   <= s_scl_low;
  sda_low_o   <= s_sda_low;

  proc_sync_inputs : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if rst_n_i = '0' then
        s_scl_meta <= '1';
        s_scl_sync <= '1';
        s_sda_meta <= '1';
        s_sda_sync <= '1';
      else
        s_scl_meta <= scl_i;
        s_scl_sync <= s_scl_meta;
        s_sda_meta <= sda_i;
        s_sda_sync <= s_sda_meta;
      end if;
    end if;
  end process proc_sync_inputs;

  proc_bus_status : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if rst_n_i = '0' then
        s_sda_prev  <= '1';
        s_bus_busy  <= '1';
        s_need_stop <= '0';
        s_free_cnt  <= 0;
      else
        if s_owned = '1' then
          s_bus_busy <= '1';
          s_free_cnt <= 0;
        elsif s_scl_sync = '1' and
              s_sda_prev = '1' and s_sda_sync = '0' then
          s_bus_busy  <= '1';
          s_need_stop <= '1';
          s_free_cnt  <= 0;
        elsif s_scl_sync = '1' and
              s_sda_prev = '0' and s_sda_sync = '1' then
          s_bus_busy  <= '1';
          s_need_stop <= '0';
          s_free_cnt  <= 0;
        elsif s_scl_sync = '0' or s_sda_sync = '0' then
          s_bus_busy  <= '1';
          s_need_stop <= '1';
          s_free_cnt  <= 0;
        elsif s_need_stop = '1' then
          s_bus_busy <= '1';
          s_free_cnt <= 0;
        elsif s_free_cnt = C_BUF_CYCLES - 1 then
          s_bus_busy <= '0';
          s_free_cnt <= C_BUF_CYCLES;
        elsif s_free_cnt < C_BUF_CYCLES then
          s_free_cnt <= s_free_cnt + 1;
        end if;
        s_sda_prev <= s_sda_sync;
      end if;
    end if;
  end process proc_bus_status;

  proc_controller : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if rst_n_i = '0' then
        s_state           <= st_idle;
        s_cmd_start       <= '0';
        s_cmd_stop        <= '0';
        s_cmd_read        <= '0';
        s_cmd_nack        <= '1';
        s_shift           <= (others => '0');
        s_bit_index       <= 7;
        s_timer           <= 0;
        s_owned           <= '0';
        s_scl_low         <= '0';
        s_sda_low         <= '0';
        rsp_valid_o       <= '0';
        rsp_data_o        <= (others => '0');
        rsp_nack_o        <= '0';
        rsp_arb_lost_o    <= '0';
        rsp_cmd_error_o   <= '0';
      else
        case s_state is
          when st_idle =>
            if cmd_valid_i = '1' then
              s_cmd_start     <= cmd_start_i;
              s_cmd_stop      <= cmd_stop_i;
              s_cmd_read      <= cmd_read_i;
              s_cmd_nack      <= cmd_nack_i;
              s_shift         <= cmd_data_i;
              s_bit_index     <= 7;
              rsp_data_o      <= (others => '0');
              rsp_nack_o      <= '0';
              rsp_arb_lost_o  <= '0';
              rsp_cmd_error_o <= '0';

              if cmd_start_i = '1' and s_owned = '0' then
                s_scl_low <= '0';
                s_sda_low <= '0';
                s_state   <= st_wait_free;
              elsif cmd_start_i = '1' then
                s_scl_low <= '1';
                s_sda_low <= '0';
                s_timer   <= C_LOW_CYCLES - 1;
                s_state   <= st_rep_low;
              elsif s_owned = '0' then
                rsp_cmd_error_o <= '1';
                rsp_valid_o     <= '1';
                s_state         <= st_response;
              elsif cmd_read_i = '1' then
                s_timer <= C_DATA_HOLD - 1;
                s_state <= st_read_hold;
              else
                s_timer <= C_DATA_HOLD - 1;
                s_state <= st_write_hold;
              end if;
            end if;

          when st_wait_free =>
            if s_bus_busy = '0' then
              s_sda_low <= '1';
              s_owned   <= '1';
              s_timer   <= C_START_HOLD - 1;
              s_state   <= st_start_hold;
            end if;

          when st_start_hold =>
            if s_timer = 0 then
              s_scl_low <= '1';
              if s_cmd_read = '1' then
                s_timer <= C_DATA_HOLD - 1;
                s_state <= st_read_hold;
              else
                s_timer <= C_DATA_HOLD - 1;
                s_state <= st_write_hold;
              end if;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_rep_low =>
            if s_timer = 0 then
              s_scl_low <= '0';
              s_state   <= st_rep_wait;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_rep_wait =>
            if s_scl_sync = '1' then
              s_timer <= C_START_SETUP - 1;
              s_state <= st_rep_setup;
            end if;

          when st_rep_setup =>
            if s_sda_sync = '0' then
              s_scl_low        <= '0';
              s_sda_low        <= '0';
              s_owned          <= '0';
              rsp_arb_lost_o   <= '1';
              rsp_valid_o      <= '1';
              s_state          <= st_response;
            elsif s_timer = 0 then
              s_sda_low <= '1';
              s_timer   <= C_START_HOLD - 1;
              s_state   <= st_rep_hold;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_rep_hold =>
            if s_timer = 0 then
              s_scl_low <= '1';
              if s_cmd_read = '1' then
                s_timer <= C_DATA_HOLD - 1;
                s_state <= st_read_hold;
              else
                s_timer <= C_DATA_HOLD - 1;
                s_state <= st_write_hold;
              end if;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_write_hold =>
            if s_timer = 0 then
              if s_shift(s_bit_index) = '0' then
                s_sda_low <= '1';
              else
                s_sda_low <= '0';
              end if;
              s_timer <= C_LOW_REMAIN - 1;
              s_state <= st_write_setup;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_write_setup =>
            if s_timer = 0 then
              s_scl_low <= '0';
              s_state   <= st_write_wait;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_write_wait =>
            if s_scl_sync = '1' then
              s_timer <= C_HIGH_CYCLES - 1;
              s_state <= st_write_high;
            end if;

          when st_write_high =>
            if s_shift(s_bit_index) = '1' and s_sda_sync = '0' then
              s_scl_low       <= '0';
              s_sda_low       <= '0';
              s_owned         <= '0';
              rsp_arb_lost_o  <= '1';
              rsp_valid_o     <= '1';
              s_state         <= st_response;
            elsif s_timer = 0 then
              s_scl_low <= '1';
              if s_bit_index = 0 then
                s_timer <= C_DATA_HOLD - 1;
                s_state <= st_wack_hold;
              else
                s_bit_index <= s_bit_index - 1;
                s_timer     <= C_DATA_HOLD - 1;
                s_state     <= st_write_hold;
              end if;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_wack_hold =>
            if s_timer = 0 then
              s_sda_low <= '0';
              s_timer   <= C_LOW_REMAIN - 1;
              s_state   <= st_wack_setup;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_wack_setup =>
            if s_timer = 0 then
              s_scl_low <= '0';
              s_state   <= st_wack_wait;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_wack_wait =>
            if s_scl_sync = '1' then
              s_timer <= C_HIGH_CYCLES - 1;
              s_state <= st_wack_high;
            end if;

          when st_wack_high =>
            if s_timer = 0 then
              rsp_nack_o <= s_sda_sync;
              s_scl_low  <= '1';
              s_timer    <= C_DATA_HOLD - 1;
              s_state    <= st_wdone_hold;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_wdone_hold =>
            if s_timer = 0 then
              if s_cmd_stop = '1' then
                s_sda_low <= '1';
              else
                s_sda_low <= '0';
              end if;
              s_timer <= C_LOW_REMAIN - 1;
              s_state <= st_wdone_setup;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_wdone_setup =>
            if s_timer = 0 then
              if s_cmd_stop = '1' then
                s_scl_low <= '0';
                s_state   <= st_stop_wait;
              else
                s_sda_low   <= '0';
                rsp_valid_o <= '1';
                s_state     <= st_response;
              end if;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_read_hold =>
            if s_timer = 0 then
              s_sda_low <= '0';
              s_timer   <= C_LOW_REMAIN - 1;
              s_state   <= st_read_setup;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_read_setup =>
            if s_timer = 0 then
              s_scl_low <= '0';
              s_state   <= st_read_wait;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_read_wait =>
            if s_scl_sync = '1' then
              s_timer <= C_HIGH_CYCLES - 1;
              s_state <= st_read_high;
            end if;

          when st_read_high =>
            if s_timer = 0 then
              s_shift(s_bit_index) <= s_sda_sync;
              s_scl_low            <= '1';
              if s_bit_index = 0 then
                rsp_data_o <= s_shift(7 downto 1) & s_sda_sync;
                s_timer    <= C_DATA_HOLD - 1;
                s_state    <= st_rack_hold;
              else
                s_bit_index <= s_bit_index - 1;
                s_timer     <= C_DATA_HOLD - 1;
                s_state     <= st_read_hold;
              end if;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_rack_hold =>
            if s_timer = 0 then
              if s_cmd_nack = '0' then
                s_sda_low <= '1';
              else
                s_sda_low <= '0';
              end if;
              s_timer <= C_LOW_REMAIN - 1;
              s_state <= st_rack_setup;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_rack_setup =>
            if s_timer = 0 then
              s_scl_low <= '0';
              s_state   <= st_rack_wait;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_rack_wait =>
            if s_scl_sync = '1' then
              s_timer <= C_HIGH_CYCLES - 1;
              s_state <= st_rack_high;
            end if;

          when st_rack_high =>
            if s_cmd_nack = '1' and s_sda_sync = '0' then
              s_scl_low       <= '0';
              s_sda_low       <= '0';
              s_owned         <= '0';
              rsp_arb_lost_o  <= '1';
              rsp_valid_o     <= '1';
              s_state         <= st_response;
            elsif s_timer = 0 then
              s_scl_low <= '1';
              s_timer   <= C_DATA_HOLD - 1;
              s_state   <= st_rdone_hold;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_rdone_hold =>
            if s_timer = 0 then
              if s_cmd_stop = '1' then
                s_sda_low <= '1';
              else
                s_sda_low <= '0';
              end if;
              s_timer <= C_LOW_REMAIN - 1;
              s_state <= st_rdone_setup;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_rdone_setup =>
            if s_timer = 0 then
              if s_cmd_stop = '1' then
                s_scl_low <= '0';
                s_state   <= st_stop_wait;
              else
                s_sda_low   <= '0';
                rsp_valid_o <= '1';
                s_state     <= st_response;
              end if;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_stop_wait =>
            if s_scl_sync = '1' then
              s_timer <= C_STOP_SETUP - 1;
              s_state <= st_stop_setup;
            end if;

          when st_stop_setup =>
            if s_timer = 0 then
              s_sda_low   <= '0';
              s_owned     <= '0';
              rsp_valid_o <= '1';
              s_state     <= st_response;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_response =>
            if rsp_ready_i = '1' then
              rsp_valid_o <= '0';
              s_state     <= st_idle;
            end if;

          when others =>
            s_scl_low        <= '0';
            s_sda_low        <= '0';
            s_owned          <= '0';
            rsp_cmd_error_o  <= '1';
            rsp_valid_o      <= '1';
            s_state          <= st_response;
        end case;
      end if;
    end if;
  end process proc_controller;

end architecture a_rtl;
