#!/usr/bin/env sh
# Copyright 2026 LogiMentor Srl
# SPDX-License-Identifier: Apache-2.0

set -eu

ghdl_bin="${GHDL:-ghdl}"
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
work_root="$script_dir/work-ghdl"
rtl_work="$work_root/rtl-93"
sim_work="$work_root/sim-08"

rm -rf -- "$work_root"
mkdir -p -- "$rtl_work" "$sim_work"

rtl="$repo_root/src/lm_i2c_master.vhd"
tb="$script_dir/tb_lm_i2c_master.vhd"
invalid_tb="$script_dir/tb_lm_i2c_master_invalid.vhd"

cd -- "$work_root"

"$ghdl_bin" -a --std=93 --workdir="$rtl_work" "$rtl"
"$ghdl_bin" --synth --std=93 --workdir="$rtl_work" lm_i2c_master >/dev/null

"$ghdl_bin" -a --std=08 --workdir="$sim_work" "$rtl" "$tb" "$invalid_tb"
"$ghdl_bin" -e --std=08 --workdir="$sim_work" tb_lm_i2c_master
"$ghdl_bin" -e --std=08 --workdir="$sim_work" tb_lm_i2c_master_invalid

for config in "10000000 100000" "10000000 400000" \
              "12000000 100000" "8000000 1000000"; do
  set -- $config
  echo "Running clk=$1 Hz, scl=$2 Hz"
  "$ghdl_bin" -r --std=08 --workdir="$sim_work" tb_lm_i2c_master \
    -gg_clk_freq_hz="$1" \
    -gg_i2c_freq_hz="$2" \
    --assert-level=error \
    --stop-time=20ms
done

check_invalid() {
  clock_hz=$1
  bus_hz=$2
  expected=$3
  output_file="$work_root/invalid-output.txt"

  if "$ghdl_bin" -r --std=08 --workdir="$sim_work" \
      tb_lm_i2c_master_invalid \
      -gg_clk_freq_hz="$clock_hz" \
      -gg_i2c_freq_hz="$bus_hz" \
      --assert-level=error >"$output_file" 2>&1; then
    echo "Invalid generic configuration was unexpectedly accepted." >&2
    return 1
  fi

  if ! grep -F -- "$expected" "$output_file" >/dev/null; then
    cat "$output_file" >&2
    echo "Invalid generic check failed for an unexpected reason." >&2
    return 1
  fi
}

check_invalid 4000000 1000000 "at least eight times"
check_invalid 16000000 1000001 "must not exceed 1 MHz"

echo "All I2C master regressions and the VHDL-93 synthesis check passed."
