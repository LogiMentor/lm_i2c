--=============================================================================
-- Module Name : tb_lm_i2c_master_invalid
-- Library     : -
-- Project     : lm_i2c
-- Company     : LogiMentor Srl
-------------------------------------------------------------------------------
-- Description:
--  Minimal harness used to verify rejection of invalid generic values.
-------------------------------------------------------------------------------
-- Copyright 2026 LogiMentor Srl
-- SPDX-License-Identifier: Apache-2.0
--=============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity tb_lm_i2c_master_invalid is
  generic (
    g_clk_freq_hz : positive := 4_000_000;
    g_i2c_freq_hz : positive := 1_000_000
  );
end entity tb_lm_i2c_master_invalid;

architecture a_tb of tb_lm_i2c_master_invalid is
  signal s_clk         : std_logic := '0';
  signal s_scl_low     : std_logic;
  signal s_sda_low     : std_logic;
  signal s_unused_data : std_logic_vector(7 downto 0);
  signal s_unused      : std_logic_vector(8 downto 0);
begin

  s_clk <= not s_clk after 5 ns;

  inst_dut : entity work.lm_i2c_master
    generic map (
      g_clk_freq_hz    => g_clk_freq_hz,
      g_i2c_freq_hz    => g_i2c_freq_hz,
      g_timeout_cycles => 0
    )
    port map (
      clk_i           => s_clk,
      rst_n_i         => '0',
      cmd_valid_i     => '0',
      cmd_ready_o     => s_unused(0),
      start_i         => '0',
      stop_i          => '0',
      read_i          => '0',
      write_i         => '0',
      ack_i           => '1',
      data_i          => (others => '0'),
      rsp_valid_o     => s_unused(1),
      data_o          => s_unused_data,
      nack_o          => s_unused(2),
      busy_o          => s_unused(3),
      bus_busy_o      => s_unused(4),
      arb_lost_o      => s_unused(5),
      timeout_o       => s_unused(6),
      cmd_error_o     => s_unused(7),
      scl_i           => '1',
      sda_i           => '1',
      scl_drive_low_o => s_scl_low,
      sda_drive_low_o => s_sda_low
    );

  proc_guard : process
  begin
    wait for 100 ns;
    assert false
      report "invalid generic configuration was accepted"
      severity failure;
  end process proc_guard;

end architecture a_tb;
