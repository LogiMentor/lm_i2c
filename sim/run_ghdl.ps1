# Copyright 2026 LogiMentor Srl
# SPDX-License-Identifier: Apache-2.0

param(
  [string]$Ghdl = "ghdl"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$workRoot = Join-Path $PSScriptRoot "work-ghdl"
$rtlWork = Join-Path $workRoot "rtl-93"
$simWork = Join-Path $workRoot "sim-08"

if (Test-Path -LiteralPath $workRoot) {
  Remove-Item -LiteralPath $workRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $rtlWork -Force | Out-Null
New-Item -ItemType Directory -Path $simWork -Force | Out-Null

function Invoke-Ghdl {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  & $Ghdl @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "GHDL failed with exit code $LASTEXITCODE."
  }
}

$rtl = Join-Path $repoRoot "src/lm_i2c_master.vhd"
$tb = Join-Path $PSScriptRoot "tb_lm_i2c_master.vhd"
$invalidTb = Join-Path $PSScriptRoot "tb_lm_i2c_master_invalid.vhd"

Push-Location $workRoot
try {
  Invoke-Ghdl @("-a", "--std=93", "--workdir=$rtlWork", $rtl)
  & $Ghdl "--synth" "--std=93" "--workdir=$rtlWork" "lm_i2c_master" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "GHDL synthesis check failed with exit code $LASTEXITCODE."
  }

  Invoke-Ghdl @("-a", "--std=08", "--workdir=$simWork", $rtl, $tb, $invalidTb)
  Invoke-Ghdl @("-e", "--std=08", "--workdir=$simWork", "tb_lm_i2c_master")
  Invoke-Ghdl @("-e", "--std=08", "--workdir=$simWork", "tb_lm_i2c_master_invalid")

  $testCases = @(
    @{ Clock = 10000000; Bus = 100000 },
    @{ Clock = 10000000; Bus = 400000 },
    @{ Clock = 12000000; Bus = 100000 },
    @{ Clock = 8000000; Bus = 1000000 }
  )

  foreach ($testCase in $testCases) {
    Write-Host ("Running clk={0} Hz, scl={1} Hz" -f $testCase.Clock, $testCase.Bus)
    Invoke-Ghdl @(
      "-r", "--std=08", "--workdir=$simWork", "tb_lm_i2c_master",
      "-gg_clk_freq_hz=$($testCase.Clock)",
      "-gg_i2c_freq_hz=$($testCase.Bus)",
      "--assert-level=error",
      "--stop-time=20ms"
    )
  }

  $invalidCases = @(
    @{
      Clock = 4000000
      Bus = 1000000
      Message = "at least eight times"
    },
    @{
      Clock = 16000000
      Bus = 1000001
      Message = "must not exceed 1 MHz"
    }
  )

  foreach ($invalidCase in $invalidCases) {
    $output = & $Ghdl "-r" "--std=08" "--workdir=$simWork" `
      "tb_lm_i2c_master_invalid" `
      "-gg_clk_freq_hz=$($invalidCase.Clock)" `
      "-gg_i2c_freq_hz=$($invalidCase.Bus)" `
      "--assert-level=error" 2>&1
    if ($LASTEXITCODE -eq 0) {
      throw "Invalid generic configuration was unexpectedly accepted."
    }
    if (($output | Out-String) -notmatch [regex]::Escape($invalidCase.Message)) {
      $output | Write-Error
      throw "Invalid generic check failed for an unexpected reason."
    }
  }

  Write-Host "All I2C master regressions and the VHDL-93 synthesis check passed."
}
finally {
  Pop-Location
}

exit 0
