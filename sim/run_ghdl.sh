#!/usr/bin/env bash
# Copyright 2026 LogiMentor Srl
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

ghdl_bin=${GHDL:-ghdl}
stop_time=20ms

usage() {
  printf '%s\n' "Usage: run_ghdl.sh [--stop-time <GHDL time>]" >&2
}

while (($# > 0)); do
  case "$1" in
    --stop-time)
      if (($# < 2)); then
        usage
        exit 2
      fi
      stop_time=$2
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
work_root=$(mktemp -d "${TMPDIR:-/tmp}/lm_i2c-ghdl.XXXXXX")
rtl_work="$work_root/rtl-93"
sim_work="$work_root/sim-08"

cleanup() {
  rm -rf -- "$work_root"
}
trap cleanup EXIT

mkdir -p -- "$rtl_work" "$sim_work"

master_rtl="$repo_root/src/lm_i2c_master.vhd"
target_rtl="$repo_root/src/lm_i2c_target.vhd"
master_tb="$script_dir/tb_lm_i2c_master.vhd"
master_reset_tb="$script_dir/tb_lm_i2c_master_reset.vhd"
master_invalid_tb="$script_dir/tb_lm_i2c_master_invalid.vhd"
target_tb="$script_dir/tb_lm_i2c_target.vhd"
target_reset_tb="$script_dir/tb_lm_i2c_target_reset.vhd"
target_invalid_tb="$script_dir/tb_lm_i2c_target_invalid.vhd"
master_marker="lm_i2c_master self-check passed"
target_marker="lm_i2c_target functional self-check passed"

cd -- "$work_root"

run_with_marker() {
  marker=$1
  output_file=$2
  shift 2

  set +e
  "$@" >"$output_file" 2>&1
  simulator_status=$?
  set -e
  cat -- "$output_file"

  if ((simulator_status != 0)); then
    return "$simulator_status"
  fi

  marker_count=$(grep -F -c -- "$marker" "$output_file" || true)
  if [[ "$marker_count" != "1" ]]; then
    printf 'Expected exactly one success marker: %s\n' "$marker" >&2
    return 1
  fi
}

run_expected_failure() {
  expected=$1
  output_file=$2
  shift 2

  set +e
  "$@" >"$output_file" 2>&1
  simulator_status=$?
  set -e
  cat -- "$output_file"

  if ((simulator_status == 0)); then
    printf '%s\n' "Invalid generic configuration was unexpectedly accepted." >&2
    return 1
  fi
  if ! grep -F -- "$expected" "$output_file" >/dev/null; then
    printf '%s\n' "Invalid generic check failed for an unexpected reason." >&2
    return 1
  fi
}

"$ghdl_bin" -a --std=93 --workdir="$rtl_work" \
  "$master_rtl" "$target_rtl"
"$ghdl_bin" --synth --std=93 --workdir="$rtl_work" \
  -gg_clk_freq_hz=50000000 \
  -gg_i2c_freq_hz=400000 \
  lm_i2c_master \
  >"$work_root/master-synthesis.txt"
"$ghdl_bin" --synth --std=93 --workdir="$rtl_work" \
  -gg_clk_freq_hz=50000000 \
  -gg_i2c_freq_hz=400000 \
  lm_i2c_target \
  >"$work_root/target-synthesis.txt"

"$ghdl_bin" -a --std=08 --workdir="$sim_work" \
  "$master_rtl" "$target_rtl" \
  "$master_tb" "$master_reset_tb" "$master_invalid_tb" \
  "$target_tb" "$target_reset_tb" "$target_invalid_tb"
"$ghdl_bin" -e --std=08 --workdir="$sim_work" tb_lm_i2c_master
"$ghdl_bin" -e --std=08 --workdir="$sim_work" tb_lm_i2c_master_reset
"$ghdl_bin" -e --std=08 --workdir="$sim_work" tb_lm_i2c_master_invalid
"$ghdl_bin" -e --std=08 --workdir="$sim_work" tb_lm_i2c_target
"$ghdl_bin" -e --std=08 --workdir="$sim_work" tb_lm_i2c_target_reset
"$ghdl_bin" -e --std=08 --workdir="$sim_work" tb_lm_i2c_target_invalid

config_index=0
for config in \
  "10000000 50000" \
  "10000000 100000" \
  "12000000 100000" \
  "10000000 137000" \
  "10000000 200000" \
  "10000000 333000" \
  "10000000 400000" \
  "50000000 400000"; do
  read -r clock_hz bus_hz <<<"$config"
  printf 'Running clk=%s Hz, scl=%s Hz\n' "$clock_hz" "$bus_hz"
  output_file="$work_root/main-$config_index.txt"
  run_with_marker "$master_marker" "$output_file" \
    "$ghdl_bin" -r --std=08 --workdir="$sim_work" tb_lm_i2c_master \
    -gg_clk_freq_hz="$clock_hz" \
    -gg_i2c_freq_hz="$bus_hz" \
    --assert-level=error \
    --stop-time="$stop_time"
  config_index=$((config_index + 1))
done

for reset_case in {0..14}; do
  reset_marker="lm_i2c_master reset case passed: $reset_case"
  printf 'Running reset case %s\n' "$reset_case"
  run_with_marker "$reset_marker" "$work_root/reset-$reset_case.txt" \
    "$ghdl_bin" -r --std=08 --workdir="$sim_work" \
    tb_lm_i2c_master_reset \
    -gg_reset_case="$reset_case" \
    --assert-level=error \
    --stop-time="$stop_time"
done

config_index=0
for config in \
  "10000000 100000 100000" \
  "10000000 400000 400000" \
  "800000 100000 100000" \
  "3200000 400000 400000" \
  "10000000 400000 50000"; do
  read -r clock_hz maximum_hz actual_hz <<<"$config"
  printf 'Running target clk=%s Hz, maximum=%s Hz, actual=%s Hz\n' \
    "$clock_hz" "$maximum_hz" "$actual_hz"
  output_file="$work_root/target-main-$config_index.txt"
  run_with_marker "$target_marker" "$output_file" \
    "$ghdl_bin" -r --std=08 --workdir="$sim_work" tb_lm_i2c_target \
    -gg_clk_freq_hz="$clock_hz" \
    -gg_i2c_freq_hz="$maximum_hz" \
    -gg_actual_i2c_freq_hz="$actual_hz" \
    --assert-level=error \
    --stop-time="$stop_time"
  config_index=$((config_index + 1))
done

for reset_case in {0..7}; do
  reset_marker="lm_i2c_target reset case passed: $reset_case"
  printf 'Running target reset case %s\n' "$reset_case"
  run_with_marker "$reset_marker" "$work_root/target-reset-$reset_case.txt" \
    "$ghdl_bin" -r --std=08 --workdir="$sim_work" \
    tb_lm_i2c_target_reset \
    -gg_reset_case="$reset_case" \
    --assert-level=error \
    --stop-time="$stop_time"
done

run_expected_failure \
  "g_i2c_freq_hz must not exceed 400 kHz" \
  "$work_root/invalid-frequency.txt" \
  "$ghdl_bin" -r --std=08 --workdir="$sim_work" \
  tb_lm_i2c_master_invalid \
  -gg_clk_freq_hz=10000000 \
  -gg_i2c_freq_hz=400001 \
  --assert-level=error

run_expected_failure \
  "g_clk_freq_hz must be at least eight times g_i2c_freq_hz" \
  "$work_root/invalid-ratio.txt" \
  "$ghdl_bin" -r --std=08 --workdir="$sim_work" \
  tb_lm_i2c_master_invalid \
  -gg_clk_freq_hz=700000 \
  -gg_i2c_freq_hz=100000 \
  --assert-level=error

run_expected_failure \
  "g_i2c_freq_hz must not exceed 400 kHz" \
  "$work_root/target-invalid-frequency.txt" \
  "$ghdl_bin" -r --std=08 --workdir="$sim_work" \
  tb_lm_i2c_target_invalid \
  -gg_clk_freq_hz=10000000 \
  -gg_i2c_freq_hz=400001 \
  --assert-level=error

run_expected_failure \
  "g_clk_freq_hz must be at least eight times g_i2c_freq_hz" \
  "$work_root/target-invalid-ratio.txt" \
  "$ghdl_bin" -r --std=08 --workdir="$sim_work" \
  tb_lm_i2c_target_invalid \
  -gg_clk_freq_hz=700000 \
  -gg_i2c_freq_hz=100000 \
  --assert-level=error

run_expected_failure \
  "system clock is too slow for synchronized SCL LOW takeover" \
  "$work_root/target-invalid-takeover.txt" \
  "$ghdl_bin" -r --std=08 --workdir="$sim_work" \
  tb_lm_i2c_target_invalid \
  -gg_clk_freq_hz=1096000 \
  -gg_i2c_freq_hz=137000 \
  --assert-level=error

printf '%s\n' \
  "All I2C controller and target regressions, VHDL-93 analysis, and synthesis checks passed."
