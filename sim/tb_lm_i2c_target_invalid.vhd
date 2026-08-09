--=============================================================================
-- Module Name : tb_lm_i2c_target_invalid
-- Library     : -
-- Project     : lm_i2c
-- Company     : LogiMentor Srl
-------------------------------------------------------------------------------
-- Description:
--  Elaboration harness for lm_i2c_target invalid-generic assertions.
-------------------------------------------------------------------------------
-- Copyright 2026 LogiMentor Srl
-- SPDX-License-Identifier: Apache-2.0
--=============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity tb_lm_i2c_target_invalid is
  generic (
    g_clk_freq_hz : positive := 10_000_000;
    g_i2c_freq_hz : positive := 400_001
  );
end entity tb_lm_i2c_target_invalid;

architecture a_tb of tb_lm_i2c_target_invalid is

  signal s_clk : std_logic := '0';

begin

  s_clk <= not s_clk after 50 ns;

  inst_dut : entity work.lm_i2c_target
    generic map (
      g_clk_freq_hz => g_clk_freq_hz,
      g_i2c_freq_hz => g_i2c_freq_hz
    )
    port map (
      clk_i       => s_clk,
      rst_n_i     => '0',
      enable_i    => '0',
      address_i   => (others => '0'),
      active_o    => open,
      read_o      => open,
      addressed_o => open,
      stop_o      => open,
      rx_valid_o  => open,
      rx_ready_i  => '0',
      rx_data_o   => open,
      rx_nack_i   => '0',
      tx_valid_i  => '0',
      tx_ready_o  => open,
      tx_data_i   => (others => '0'),
      scl_i       => '1',
      sda_i       => '1',
      scl_low_o   => open,
      sda_low_o   => open
    );

end architecture a_tb;
