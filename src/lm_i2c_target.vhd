--=============================================================================
-- Module Name : lm_i2c_target
-- Library     : -
-- Project     : lm_i2c
-- Company     : LogiMentor Srl
-------------------------------------------------------------------------------
-- Description:
--  Dependency-free 7-bit I2C target for Standard-mode and Fast-mode. All
--  protocol decisions use synchronized resolved-bus inputs. The application
--  interfaces are byte-wide ready/valid streams, and active-high bus outputs
--  are open-drain drive-low controls.
-------------------------------------------------------------------------------
-- Copyright 2026 LogiMentor Srl
-- SPDX-License-Identifier: Apache-2.0
--=============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity lm_i2c_target is
  generic (
    g_clk_freq_hz : positive;
    g_i2c_freq_hz : positive := 100_000
  );
  port (
    -- Clock and reset
    clk_i   : in std_logic;
    rst_n_i : in std_logic;

    -- Inputs: synchronous or static configuration
    enable_i  : in std_logic;
    address_i : in std_logic_vector(6 downto 0);

    -- Inputs: controller-to-target stream
    rx_ready_i : in  std_logic;
    rx_nack_i  : in  std_logic;

    -- Inputs: target-to-controller stream
    tx_valid_i : in  std_logic;
    tx_data_i  : in  std_logic_vector(7 downto 0);

    -- Inputs: resolved I2C bus
    scl_i : in std_logic;
    sda_i : in std_logic;

    -- Outputs: transaction status
    active_o    : out std_logic;
    read_o      : out std_logic;
    addressed_o : out std_logic;
    stop_o      : out std_logic;

    -- Outputs: application streams
    rx_valid_o : out std_logic;
    rx_data_o  : out std_logic_vector(7 downto 0);
    tx_ready_o : out std_logic;

    -- Outputs: active-high open-drain controls
    scl_low_o : out std_logic;
    sda_low_o : out std_logic
  );
end entity lm_i2c_target;

architecture a_rtl of lm_i2c_target is

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

  function f_min (
    a : positive;
    b : positive
  ) return positive is
  begin
    if a < b then
      return a;
    else
      return b;
    end if;
  end function f_min;

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

  constant C_DATA_HOLD_CYCLES : positive :=
    f_scale_ceil(g_clk_freq_hz, 3, 10_000_000);
  constant C_STRETCH_SETUP_CYCLES : positive :=
    f_scale_ceil(g_clk_freq_hz, 5, 4_000_000);
  constant C_LOW_MIN_CYCLES : positive := f_mode_cycles(
    f_scale_ceil(g_clk_freq_hz, 47, 10_000_000),
    f_scale_ceil(g_clk_freq_hz, 13, 10_000_000),
    g_i2c_freq_hz
  );
  constant C_START_SETUP_MIN_CYCLES : positive := f_mode_cycles(
    f_scale_ceil(g_clk_freq_hz, 47, 10_000_000),
    f_scale_ceil(g_clk_freq_hz, 6, 10_000_000),
    g_i2c_freq_hz
  );
  constant C_START_HOLD_MIN_CYCLES : positive := f_mode_cycles(
    f_scale_ceil(g_clk_freq_hz, 4, 1_000_000),
    f_scale_ceil(g_clk_freq_hz, 6, 10_000_000),
    g_i2c_freq_hz
  );
  constant C_STOP_SETUP_MIN_CYCLES : positive := f_mode_cycles(
    f_scale_ceil(g_clk_freq_hz, 4, 1_000_000),
    f_scale_ceil(g_clk_freq_hz, 6, 10_000_000),
    g_i2c_freq_hz
  );
  constant C_STABLE_HIGH_MIN_CYCLES : positive := f_min(
    C_START_SETUP_MIN_CYCLES,
    f_min(C_START_HOLD_MIN_CYCLES, C_STOP_SETUP_MIN_CYCLES)
  );
  constant C_SYNC_TAKEOVER_CYCLES : positive := 3;
  constant C_TIMER_MAX : positive :=
    f_max(C_DATA_HOLD_CYCLES, C_STRETCH_SETUP_CYCLES);

  type t_state is (
    st_idle,
    st_address,
    st_passive,
    st_address_wait_fall,
    st_address_ack_hold,
    st_address_ack_setup,
    st_address_ack_wait_rise,
    st_address_ack_wait_fall,
    st_rx_start_hold,
    st_rx_start_setup,
    st_rx_bits,
    st_rx_wait_fall,
    st_rx_ack_hold,
    st_rx_wait_application,
    st_rx_ack_setup,
    st_rx_ack_wait_rise,
    st_rx_ack_wait_fall,
    st_rx_release_hold,
    st_rx_release_setup,
    st_rx_rejected,
    st_tx_start_hold,
    st_tx_wait_application,
    st_tx_bit_setup,
    st_tx_bit_wait_rise,
    st_tx_bit_wait_fall,
    st_tx_release_hold,
    st_tx_release_setup,
    st_tx_ack_wait_rise,
    st_tx_ack_wait_fall,
    st_tx_done
  );

  signal s_state : t_state;

  signal s_scl_meta : std_logic;
  signal s_scl_sync : std_logic;
  signal s_scl_prev : std_logic;
  signal s_sda_meta : std_logic;
  signal s_sda_sync : std_logic;
  signal s_sda_prev : std_logic;
  signal s_sync_ready : natural range 0 to 3;

  signal s_enable_sample  : std_logic;
  signal s_address_sample : std_logic_vector(6 downto 0);
  signal s_address_shift  : std_logic_vector(6 downto 0);
  signal s_bit_index      : natural range 0 to 7;

  signal s_rx_shift          : std_logic_vector(7 downto 0);
  signal s_rx_decision_valid : std_logic;
  signal s_rx_nack           : std_logic;

  signal s_tx_shift          : std_logic_vector(7 downto 0);
  signal s_tx_loaded         : std_logic;
  signal s_controller_ack    : std_logic;

  signal s_timer : natural range 0 to C_TIMER_MAX;

  signal s_active  : std_logic;
  signal s_read    : std_logic;
  signal s_rx_valid : std_logic;
  signal s_tx_ready : std_logic;
  signal s_scl_low : std_logic;
  signal s_sda_low : std_logic;

begin

  assert g_i2c_freq_hz <= 400_000
    report "g_i2c_freq_hz must not exceed 400 kHz"
    severity failure;

  assert g_clk_freq_hz / g_i2c_freq_hz >= 8
    report "g_clk_freq_hz must be at least eight times g_i2c_freq_hz"
    severity failure;

  assert C_STABLE_HIGH_MIN_CYCLES >= 2
    report "system clock is too slow for stable-HIGH START/STOP detection"
    severity failure;

  assert C_LOW_MIN_CYCLES >= C_SYNC_TAKEOVER_CYCLES + 2
    report "system clock is too slow for synchronized target SCL takeover"
    severity failure;

  assert C_DATA_HOLD_CYCLES > 0
    report "derived data-hold interval must be nonzero"
    severity failure;

  assert C_STRETCH_SETUP_CYCLES > 0
    report "derived stretch-release setup interval must be nonzero"
    severity failure;

  active_o  <= s_active;
  read_o    <= s_read;
  rx_valid_o <= s_rx_valid;
  tx_ready_o <= s_tx_ready;
  scl_low_o <= s_scl_low;
  sda_low_o <= s_sda_low;

  proc_sync_inputs : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if rst_n_i = '0' then
        s_scl_meta  <= '1';
        s_scl_sync  <= '1';
        s_scl_prev  <= '1';
        s_sda_meta  <= '1';
        s_sda_sync  <= '1';
        s_sda_prev  <= '1';
        s_sync_ready <= 0;
      else
        s_scl_meta <= scl_i;
        s_scl_sync <= s_scl_meta;
        s_scl_prev <= s_scl_sync;
        s_sda_meta <= sda_i;
        s_sda_sync <= s_sda_meta;
        s_sda_prev <= s_sda_sync;
        if s_sync_ready < 3 then
          s_sync_ready <= s_sync_ready + 1;
        end if;
      end if;
    end if;
  end process proc_sync_inputs;

  proc_target : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if rst_n_i = '0' then
        s_state             <= st_idle;
        s_enable_sample     <= '0';
        s_address_sample    <= (others => '0');
        s_address_shift     <= (others => '0');
        s_bit_index         <= 0;
        s_rx_shift          <= (others => '0');
        s_rx_decision_valid <= '0';
        s_rx_nack           <= '1';
        s_tx_shift          <= (others => '0');
        s_tx_loaded         <= '0';
        s_controller_ack    <= '0';
        s_timer             <= 0;
        s_active            <= '0';
        s_read              <= '0';
        s_scl_low           <= '0';
        s_sda_low           <= '0';
        addressed_o         <= '0';
        stop_o              <= '0';
        s_rx_valid          <= '0';
        rx_data_o           <= (others => '0');
        s_tx_ready          <= '0';
      else
        addressed_o <= '0';
        stop_o      <= '0';

        if s_sync_ready = 3 and
           s_scl_prev = '1' and
           s_scl_sync = '1' and
           s_sda_prev = '1' and s_sda_sync = '0' then
          s_state             <= st_address;
          s_enable_sample     <= enable_i;
          s_address_sample    <= address_i;
          s_address_shift     <= (others => '0');
          s_bit_index         <= 0;
          s_rx_shift          <= (others => '0');
          s_rx_decision_valid <= '0';
          s_rx_nack           <= '1';
          s_tx_shift          <= (others => '0');
          s_tx_loaded         <= '0';
          s_controller_ack    <= '0';
          s_timer             <= 0;
          s_active            <= '0';
          s_read              <= '0';
          s_scl_low           <= '0';
          s_sda_low           <= '0';
          s_rx_valid          <= '0';
          s_tx_ready          <= '0';

        elsif s_sync_ready = 3 and
              s_scl_prev = '1' and
              s_scl_sync = '1' and
              s_sda_prev = '0' and s_sda_sync = '1' then
          s_state             <= st_idle;
          s_rx_decision_valid <= '0';
          s_tx_loaded         <= '0';
          s_controller_ack    <= '0';
          s_timer             <= 0;
          s_scl_low           <= '0';
          s_sda_low           <= '0';
          s_rx_valid          <= '0';
          s_tx_ready          <= '0';
          if s_active = '1' then
            stop_o <= '1';
          end if;
          s_active <= '0';
          s_read   <= '0';

        else
          if s_rx_valid = '1' and rx_ready_i = '1' then
            s_rx_valid          <= '0';
            s_rx_decision_valid <= '1';
            s_rx_nack           <= rx_nack_i;
          end if;

          if s_tx_ready = '1' and tx_valid_i = '1' then
            s_tx_ready  <= '0';
            s_tx_shift  <= tx_data_i;
            s_tx_loaded <= '1';
          end if;

          case s_state is
            when st_idle =>
              s_scl_low <= '0';
              s_sda_low <= '0';

            when st_address =>
              if s_scl_prev = '0' and s_scl_sync = '1' then
                if s_bit_index < 7 then
                  s_address_shift(6 - s_bit_index) <= s_sda_sync;
                  s_bit_index <= s_bit_index + 1;
                else
                  if s_enable_sample = '1' and
                     s_address_shift = s_address_sample then
                    s_active    <= '1';
                    s_read      <= s_sda_sync;
                    addressed_o <= '1';
                    if s_sda_sync = '1' then
                      s_tx_ready <= '1';
                    end if;
                    s_state <= st_address_wait_fall;
                  else
                    s_state <= st_passive;
                  end if;
                end if;
              end if;

            when st_passive =>
              s_scl_low  <= '0';
              s_sda_low  <= '0';
              s_rx_valid <= '0';
              s_tx_ready <= '0';

            when st_address_wait_fall =>
              if s_scl_prev = '1' and s_scl_sync = '0' then
                s_scl_low <= '1';
                s_timer   <= C_DATA_HOLD_CYCLES - 1;
                s_state   <= st_address_ack_hold;
              end if;

            when st_address_ack_hold =>
              if s_timer = 0 then
                s_sda_low <= '1';
                s_timer   <= C_STRETCH_SETUP_CYCLES - 1;
                s_state   <= st_address_ack_setup;
              else
                s_timer <= s_timer - 1;
              end if;

            when st_address_ack_setup =>
              if s_timer = 0 then
                s_scl_low <= '0';
                s_state   <= st_address_ack_wait_rise;
              else
                s_timer <= s_timer - 1;
              end if;

            when st_address_ack_wait_rise =>
              if s_scl_prev = '0' and s_scl_sync = '1' then
                s_state <= st_address_ack_wait_fall;
              end if;

            when st_address_ack_wait_fall =>
              if s_scl_prev = '1' and s_scl_sync = '0' then
                s_scl_low <= '1';
                s_timer   <= C_DATA_HOLD_CYCLES - 1;
                if s_read = '1' then
                  s_bit_index <= 7;
                  s_state     <= st_tx_start_hold;
                else
                  s_bit_index <= 0;
                  s_state     <= st_rx_start_hold;
                end if;
              end if;

            when st_rx_start_hold =>
              if s_timer = 0 then
                s_sda_low <= '0';
                s_timer   <= C_STRETCH_SETUP_CYCLES - 1;
                s_state   <= st_rx_start_setup;
              else
                s_timer <= s_timer - 1;
              end if;

            when st_rx_start_setup =>
              if s_timer = 0 then
                s_scl_low <= '0';
                s_state   <= st_rx_bits;
              else
                s_timer <= s_timer - 1;
              end if;

            when st_rx_bits =>
              if s_scl_prev = '0' and s_scl_sync = '1' then
                s_rx_shift(7 - s_bit_index) <= s_sda_sync;
                if s_bit_index = 7 then
                  rx_data_o           <= s_rx_shift(7 downto 1) & s_sda_sync;
                  s_rx_valid          <= '1';
                  s_rx_decision_valid <= '0';
                  s_bit_index         <= 0;
                  s_state             <= st_rx_wait_fall;
                else
                  s_bit_index <= s_bit_index + 1;
                end if;
              end if;

            when st_rx_wait_fall =>
              if s_scl_prev = '1' and s_scl_sync = '0' then
                s_scl_low <= '1';
                s_timer   <= C_DATA_HOLD_CYCLES - 1;
                s_state   <= st_rx_ack_hold;
              end if;

            when st_rx_ack_hold =>
              if s_timer = 0 then
                if s_rx_decision_valid = '1' then
                  if s_rx_nack = '0' then
                    s_sda_low <= '1';
                  else
                    s_sda_low <= '0';
                  end if;
                  s_timer <= C_STRETCH_SETUP_CYCLES - 1;
                  s_state <= st_rx_ack_setup;
                else
                  s_sda_low <= '0';
                  s_state   <= st_rx_wait_application;
                end if;
              else
                s_timer <= s_timer - 1;
              end if;

            when st_rx_wait_application =>
              if s_rx_decision_valid = '1' then
                if s_rx_nack = '0' then
                  s_sda_low <= '1';
                else
                  s_sda_low <= '0';
                end if;
                s_timer <= C_STRETCH_SETUP_CYCLES - 1;
                s_state <= st_rx_ack_setup;
              end if;

            when st_rx_ack_setup =>
              if s_timer = 0 then
                s_scl_low <= '0';
                s_state   <= st_rx_ack_wait_rise;
              else
                s_timer <= s_timer - 1;
              end if;

            when st_rx_ack_wait_rise =>
              if s_scl_prev = '0' and s_scl_sync = '1' then
                s_state <= st_rx_ack_wait_fall;
              end if;

            when st_rx_ack_wait_fall =>
              if s_scl_prev = '1' and s_scl_sync = '0' then
                s_scl_low <= '1';
                s_timer   <= C_DATA_HOLD_CYCLES - 1;
                s_state   <= st_rx_release_hold;
              end if;

            when st_rx_release_hold =>
              if s_timer = 0 then
                s_sda_low <= '0';
                s_timer   <= C_STRETCH_SETUP_CYCLES - 1;
                s_state   <= st_rx_release_setup;
              else
                s_timer <= s_timer - 1;
              end if;

            when st_rx_release_setup =>
              if s_timer = 0 then
                s_scl_low           <= '0';
                s_rx_decision_valid <= '0';
                if s_rx_nack = '1' then
                  s_state <= st_rx_rejected;
                else
                  s_bit_index <= 0;
                  s_state     <= st_rx_bits;
                end if;
              else
                s_timer <= s_timer - 1;
              end if;

            when st_rx_rejected =>
              s_scl_low  <= '0';
              s_sda_low  <= '0';
              s_rx_valid <= '0';

            when st_tx_start_hold =>
              if s_timer = 0 then
                if s_tx_loaded = '1' then
                  if s_tx_shift(s_bit_index) = '0' then
                    s_sda_low <= '1';
                  else
                    s_sda_low <= '0';
                  end if;
                  s_timer <= C_STRETCH_SETUP_CYCLES - 1;
                  s_state <= st_tx_bit_setup;
                else
                  s_sda_low <= '0';
                  s_state   <= st_tx_wait_application;
                end if;
              else
                s_timer <= s_timer - 1;
              end if;

            when st_tx_wait_application =>
              if s_tx_loaded = '1' then
                if s_tx_shift(s_bit_index) = '0' then
                  s_sda_low <= '1';
                else
                  s_sda_low <= '0';
                end if;
                s_timer <= C_STRETCH_SETUP_CYCLES - 1;
                s_state <= st_tx_bit_setup;
              end if;

            when st_tx_bit_setup =>
              if s_timer = 0 then
                s_scl_low <= '0';
                s_state   <= st_tx_bit_wait_rise;
              else
                s_timer <= s_timer - 1;
              end if;

            when st_tx_bit_wait_rise =>
              if s_scl_prev = '0' and s_scl_sync = '1' then
                s_state <= st_tx_bit_wait_fall;
              end if;

            when st_tx_bit_wait_fall =>
              if s_scl_prev = '1' and s_scl_sync = '0' then
                s_scl_low <= '1';
                s_timer   <= C_DATA_HOLD_CYCLES - 1;
                if s_bit_index = 0 then
                  s_state <= st_tx_release_hold;
                else
                  s_bit_index <= s_bit_index - 1;
                  s_state     <= st_tx_start_hold;
                end if;
              end if;

            when st_tx_release_hold =>
              if s_timer = 0 then
                s_sda_low <= '0';
                s_timer   <= C_STRETCH_SETUP_CYCLES - 1;
                s_state   <= st_tx_release_setup;
              else
                s_timer <= s_timer - 1;
              end if;

            when st_tx_release_setup =>
              if s_timer = 0 then
                s_scl_low <= '0';
                s_state   <= st_tx_ack_wait_rise;
              else
                s_timer <= s_timer - 1;
              end if;

            when st_tx_ack_wait_rise =>
              if s_scl_prev = '0' and s_scl_sync = '1' then
                s_tx_loaded <= '0';
                if s_sda_sync = '0' then
                  s_controller_ack <= '1';
                  s_tx_ready       <= '1';
                else
                  s_controller_ack <= '0';
                  s_tx_ready       <= '0';
                end if;
                s_state <= st_tx_ack_wait_fall;
              end if;

            when st_tx_ack_wait_fall =>
              if s_scl_prev = '1' and s_scl_sync = '0' then
                if s_controller_ack = '1' then
                  s_scl_low   <= '1';
                  s_bit_index <= 7;
                  s_timer     <= C_DATA_HOLD_CYCLES - 1;
                  s_state     <= st_tx_start_hold;
                else
                  s_scl_low <= '0';
                  s_state   <= st_tx_done;
                end if;
              end if;

            when st_tx_done =>
              s_scl_low  <= '0';
              s_sda_low  <= '0';
              s_tx_ready <= '0';

            when others =>
              -- Defensive recovery for an unreachable encoded-state fault.
              s_state             <= st_idle;
              s_bit_index         <= 0;
              s_rx_decision_valid <= '0';
              s_tx_loaded         <= '0';
              s_controller_ack    <= '0';
              s_timer             <= 0;
              s_active            <= '0';
              s_read              <= '0';
              s_rx_valid          <= '0';
              s_tx_ready          <= '0';
              s_scl_low           <= '0';
              s_sda_low           <= '0';
          end case;
        end if;
      end if;
    end if;
  end process proc_target;

end architecture a_rtl;
