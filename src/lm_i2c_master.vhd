--=============================================================================
-- Module Name : lm_i2c_master
-- Library     : -
-- Project     : lm_i2c
-- Company     : LogiMentor Srl
-------------------------------------------------------------------------------
-- Description:
--  Dependency-free byte-command I2C controller.
--  All logic is synchronous to clk_i with an active-low synchronous reset.
--  The bus interface exposes active-high drive-low controls for open-drain
--  integration. The sampled inputs must reflect the resolved bus levels.
-------------------------------------------------------------------------------
-- Copyright 2026 LogiMentor Srl
-- SPDX-License-Identifier: Apache-2.0
--=============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity lm_i2c_master is
  generic (
    -- System clock frequency.
    g_clk_freq_hz    : positive := 50_000_000;
    -- Requested SCL frequency, up to I2C fast-mode plus (1 MHz).
    g_i2c_freq_hz    : positive := 100_000;
    -- Maximum clk_i cycles spent waiting for released SCL to become high.
    -- Zero disables the clock-stretch timeout.
    g_timeout_cycles : natural  := 0
  );
  port (
    -- Clock and reset
    clk_i   : in std_logic;
    rst_n_i : in std_logic;

    -- Byte-command interface
    cmd_valid_i : in  std_logic;
    cmd_ready_o : out std_logic;
    start_i     : in  std_logic;
    stop_i      : in  std_logic;
    read_i      : in  std_logic;
    write_i     : in  std_logic;
    ack_i       : in  std_logic;
    data_i      : in  std_logic_vector(7 downto 0);

    -- Response and status interface
    rsp_valid_o : out std_logic;
    data_o      : out std_logic_vector(7 downto 0);
    nack_o      : out std_logic;
    busy_o      : out std_logic;
    bus_busy_o  : out std_logic;
    arb_lost_o  : out std_logic;
    timeout_o   : out std_logic;
    cmd_error_o : out std_logic;

    -- Resolved I2C bus inputs and active-high open-drain controls
    scl_i           : in  std_logic;
    sda_i           : in  std_logic;
    scl_drive_low_o : out std_logic;
    sda_drive_low_o : out std_logic
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

  function f_max_one (
    a : natural
  ) return positive is
  begin
    if a = 0 then
      return 1;
    else
      return a;
    end if;
  end function f_max_one;

  constant C_PERIOD_CYCLES : positive :=
    f_div_ceil(g_clk_freq_hz, g_i2c_freq_hz);
  constant C_LOW_CYCLES : positive :=
    f_scale_ceil(C_PERIOD_CYCLES, 13, 25);
  constant C_HIGH_CYCLES : natural :=
    C_PERIOD_CYCLES - C_LOW_CYCLES;
  constant C_TIMEOUT_MAX : positive :=
    f_max_one(g_timeout_cycles);

  type t_state is (
    st_idle,
    st_start_wait,
    st_start_high,
    st_start_hold,
    st_write_low,
    st_write_wait,
    st_write_high,
    st_write_ack_low,
    st_write_ack_wait,
    st_write_ack_high,
    st_read_low,
    st_read_wait,
    st_read_high,
    st_read_ack_low,
    st_read_ack_wait,
    st_read_ack_high,
    st_stop_low,
    st_stop_wait,
    st_stop_high,
    st_stop_hold,
    st_complete
  );

  signal s_state : t_state;

  signal s_cmd_stop  : std_logic;
  signal s_cmd_read  : std_logic;
  signal s_cmd_write : std_logic;
  signal s_cmd_ack   : std_logic;
  signal s_shift     : std_logic_vector(7 downto 0);
  signal s_bit_index : natural range 0 to 7;

  signal s_timer       : natural range 0 to C_PERIOD_CYCLES;
  signal s_stretch_cnt : natural range 0 to C_TIMEOUT_MAX - 1;

  signal s_scl_meta : std_logic;
  signal s_scl_sync : std_logic;
  signal s_sda_meta : std_logic;
  signal s_sda_sync : std_logic;
  signal s_sda_prev : std_logic;

  signal s_scl_low : std_logic;
  signal s_sda_low : std_logic;

begin

  assert g_i2c_freq_hz <= 1_000_000
    report "g_i2c_freq_hz must not exceed 1 MHz"
    severity failure;

  assert (g_clk_freq_hz / g_i2c_freq_hz) >= 8
    report "g_clk_freq_hz must be at least eight times g_i2c_freq_hz"
    severity failure;

  assert C_HIGH_CYCLES > 0
    report "derived I2C high time must be at least one clk_i cycle"
    severity failure;

  cmd_ready_o <= '1' when s_state = st_idle else '0';
  busy_o      <= '0' when s_state = st_idle else '1';

  scl_drive_low_o <= s_scl_low;
  sda_drive_low_o <= s_sda_low;

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
        s_sda_prev <= '1';
        bus_busy_o <= '0';
      else
        if s_scl_sync = '1' then
          if s_sda_prev = '1' and s_sda_sync = '0' then
            bus_busy_o <= '1';
          elsif s_sda_prev = '0' and s_sda_sync = '1' then
            bus_busy_o <= '0';
          end if;
        end if;
        s_sda_prev <= s_sda_sync;
      end if;
    end if;
  end process proc_bus_status;

  proc_controller : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if rst_n_i = '0' then
        s_state       <= st_idle;
        s_cmd_stop    <= '0';
        s_cmd_read    <= '0';
        s_cmd_write   <= '0';
        s_cmd_ack     <= '1';
        s_shift       <= (others => '0');
        s_bit_index   <= 7;
        s_timer       <= 0;
        s_stretch_cnt <= 0;
        s_scl_low     <= '0';
        s_sda_low     <= '0';
        rsp_valid_o   <= '0';
        data_o        <= (others => '0');
        nack_o        <= '0';
        arb_lost_o    <= '0';
        timeout_o     <= '0';
        cmd_error_o   <= '0';
      else
        rsp_valid_o <= '0';

        case s_state is
          when st_idle =>
            if cmd_valid_i = '1' then
              s_cmd_stop    <= stop_i;
              s_cmd_read    <= read_i;
              s_cmd_write   <= write_i;
              s_cmd_ack     <= ack_i;
              s_shift       <= data_i;
              s_bit_index   <= 7;
              s_stretch_cnt <= 0;
              nack_o        <= '0';
              arb_lost_o    <= '0';
              timeout_o     <= '0';
              cmd_error_o   <= '0';

              if (read_i = '1' and write_i = '1') or
                 (start_i = '0' and stop_i = '0' and
                  read_i = '0' and write_i = '0') then
                cmd_error_o <= '1';
                s_state     <= st_complete;
              elsif start_i = '1' then
                s_state   <= st_start_wait;
                s_scl_low <= '0';
                s_sda_low <= '0';
              elsif write_i = '1' then
                s_state   <= st_write_low;
                s_scl_low <= '1';
                if data_i(7) = '0' then
                  s_sda_low <= '1';
                else
                  s_sda_low <= '0';
                end if;
                s_timer <= C_LOW_CYCLES - 1;
              elsif read_i = '1' then
                s_state   <= st_read_low;
                s_scl_low <= '1';
                s_sda_low <= '0';
                s_timer   <= C_LOW_CYCLES - 1;
              else
                s_state   <= st_stop_low;
                s_scl_low <= '1';
                s_sda_low <= '1';
                s_timer   <= C_LOW_CYCLES - 1;
              end if;
            end if;

          when st_start_wait =>
            if s_scl_sync = '1' then
              s_stretch_cnt <= 0;
              s_timer       <= C_LOW_CYCLES - 1;
              s_state       <= st_start_high;
            elsif g_timeout_cycles /= 0 then
              if s_stretch_cnt = g_timeout_cycles - 1 then
                timeout_o <= '1';
                s_scl_low <= '0';
                s_sda_low <= '0';
                s_state   <= st_complete;
              else
                s_stretch_cnt <= s_stretch_cnt + 1;
              end if;
            end if;

          when st_start_high =>
            if s_timer = 0 then
              if s_sda_sync = '0' then
                arb_lost_o <= '1';
                s_scl_low  <= '0';
                s_sda_low  <= '0';
                s_state    <= st_complete;
              else
                s_sda_low <= '1';
                s_timer   <= C_HIGH_CYCLES - 1;
                s_state   <= st_start_hold;
              end if;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_start_hold =>
            if s_timer = 0 then
              s_scl_low <= '1';
              if s_cmd_write = '1' then
                if s_shift(7) = '0' then
                  s_sda_low <= '1';
                else
                  s_sda_low <= '0';
                end if;
                s_timer <= C_LOW_CYCLES - 1;
                s_state <= st_write_low;
              elsif s_cmd_read = '1' then
                s_sda_low <= '0';
                s_timer   <= C_LOW_CYCLES - 1;
                s_state   <= st_read_low;
              elsif s_cmd_stop = '1' then
                s_sda_low <= '1';
                s_timer   <= C_LOW_CYCLES - 1;
                s_state   <= st_stop_low;
              else
                s_state <= st_complete;
              end if;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_write_low =>
            if s_timer = 0 then
              s_scl_low     <= '0';
              s_stretch_cnt <= 0;
              s_state       <= st_write_wait;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_write_wait =>
            if s_scl_sync = '1' then
              s_stretch_cnt <= 0;
              s_timer       <= C_HIGH_CYCLES - 1;
              s_state       <= st_write_high;
            elsif g_timeout_cycles /= 0 then
              if s_stretch_cnt = g_timeout_cycles - 1 then
                timeout_o <= '1';
                s_scl_low <= '0';
                s_sda_low <= '0';
                s_state   <= st_complete;
              else
                s_stretch_cnt <= s_stretch_cnt + 1;
              end if;
            end if;

          when st_write_high =>
            if s_shift(s_bit_index) = '1' and s_sda_sync = '0' then
              arb_lost_o <= '1';
              s_scl_low  <= '0';
              s_sda_low  <= '0';
              s_state    <= st_complete;
            elsif s_timer = 0 then
              s_scl_low <= '1';
              if s_bit_index = 0 then
                s_sda_low <= '0';
                s_timer   <= C_LOW_CYCLES - 1;
                s_state   <= st_write_ack_low;
              else
                s_bit_index <= s_bit_index - 1;
                if s_shift(s_bit_index - 1) = '0' then
                  s_sda_low <= '1';
                else
                  s_sda_low <= '0';
                end if;
                s_timer <= C_LOW_CYCLES - 1;
                s_state <= st_write_low;
              end if;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_write_ack_low =>
            if s_timer = 0 then
              s_scl_low     <= '0';
              s_stretch_cnt <= 0;
              s_state       <= st_write_ack_wait;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_write_ack_wait =>
            if s_scl_sync = '1' then
              s_stretch_cnt <= 0;
              s_timer       <= C_HIGH_CYCLES - 1;
              s_state       <= st_write_ack_high;
            elsif g_timeout_cycles /= 0 then
              if s_stretch_cnt = g_timeout_cycles - 1 then
                timeout_o <= '1';
                s_scl_low <= '0';
                s_sda_low <= '0';
                s_state   <= st_complete;
              else
                s_stretch_cnt <= s_stretch_cnt + 1;
              end if;
            end if;

          when st_write_ack_high =>
            if s_timer = 0 then
              nack_o    <= s_sda_sync;
              s_scl_low <= '1';
              s_sda_low <= '0';
              if s_cmd_stop = '1' then
                s_sda_low <= '1';
                s_timer   <= C_LOW_CYCLES - 1;
                s_state   <= st_stop_low;
              else
                s_state <= st_complete;
              end if;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_read_low =>
            if s_timer = 0 then
              s_scl_low     <= '0';
              s_stretch_cnt <= 0;
              s_state       <= st_read_wait;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_read_wait =>
            if s_scl_sync = '1' then
              s_stretch_cnt <= 0;
              s_timer       <= C_HIGH_CYCLES - 1;
              s_state       <= st_read_high;
            elsif g_timeout_cycles /= 0 then
              if s_stretch_cnt = g_timeout_cycles - 1 then
                timeout_o <= '1';
                s_scl_low <= '0';
                s_sda_low <= '0';
                s_state   <= st_complete;
              else
                s_stretch_cnt <= s_stretch_cnt + 1;
              end if;
            end if;

          when st_read_high =>
            if s_timer = 0 then
              s_shift(s_bit_index) <= s_sda_sync;
              s_scl_low            <= '1';
              if s_bit_index = 0 then
                data_o <= s_shift(7 downto 1) & s_sda_sync;
                if s_cmd_ack = '0' then
                  s_sda_low <= '1';
                else
                  s_sda_low <= '0';
                end if;
                s_timer <= C_LOW_CYCLES - 1;
                s_state <= st_read_ack_low;
              else
                s_bit_index <= s_bit_index - 1;
                s_timer     <= C_LOW_CYCLES - 1;
                s_state     <= st_read_low;
              end if;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_read_ack_low =>
            if s_timer = 0 then
              s_scl_low     <= '0';
              s_stretch_cnt <= 0;
              s_state       <= st_read_ack_wait;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_read_ack_wait =>
            if s_scl_sync = '1' then
              s_stretch_cnt <= 0;
              s_timer       <= C_HIGH_CYCLES - 1;
              s_state       <= st_read_ack_high;
            elsif g_timeout_cycles /= 0 then
              if s_stretch_cnt = g_timeout_cycles - 1 then
                timeout_o <= '1';
                s_scl_low <= '0';
                s_sda_low <= '0';
                s_state   <= st_complete;
              else
                s_stretch_cnt <= s_stretch_cnt + 1;
              end if;
            end if;

          when st_read_ack_high =>
            if s_cmd_ack = '1' and s_sda_sync = '0' then
              arb_lost_o <= '1';
              s_scl_low  <= '0';
              s_sda_low  <= '0';
              s_state    <= st_complete;
            elsif s_timer = 0 then
              s_scl_low <= '1';
              s_sda_low <= '0';
              if s_cmd_stop = '1' then
                s_sda_low <= '1';
                s_timer   <= C_LOW_CYCLES - 1;
                s_state   <= st_stop_low;
              else
                s_state <= st_complete;
              end if;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_stop_low =>
            if s_timer = 0 then
              s_scl_low     <= '0';
              s_stretch_cnt <= 0;
              s_state       <= st_stop_wait;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_stop_wait =>
            if s_scl_sync = '1' then
              s_stretch_cnt <= 0;
              s_timer       <= C_HIGH_CYCLES - 1;
              s_state       <= st_stop_high;
            elsif g_timeout_cycles /= 0 then
              if s_stretch_cnt = g_timeout_cycles - 1 then
                timeout_o <= '1';
                s_scl_low <= '0';
                s_sda_low <= '0';
                s_state   <= st_complete;
              else
                s_stretch_cnt <= s_stretch_cnt + 1;
              end if;
            end if;

          when st_stop_high =>
            if s_timer = 0 then
              s_sda_low <= '0';
              s_timer   <= C_LOW_CYCLES - 1;
              s_state   <= st_stop_hold;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_stop_hold =>
            if s_timer = 0 then
              s_state <= st_complete;
            else
              s_timer <= s_timer - 1;
            end if;

          when st_complete =>
            rsp_valid_o <= '1';
            s_state     <= st_idle;

          when others =>
            s_scl_low   <= '0';
            s_sda_low   <= '0';
            cmd_error_o <= '1';
            s_state     <= st_complete;
        end case;
      end if;
    end if;
  end process proc_controller;

end architecture a_rtl;
