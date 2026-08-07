# Copyright 2026 LogiMentor Srl
# SPDX-License-Identifier: Apache-2.0

[CmdletBinding()]
param(
  [string]$Ghdl = "ghdl",
  [string]$StopTime = "20ms"
)

$ErrorActionPreference = "Stop"
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
  $PSNativeCommandUseErrorActionPreference = $false
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$workRoot = Join-Path (
  [IO.Path]::GetTempPath()
) ("lm_i2c-ghdl-" + [guid]::NewGuid().ToString("N"))
$rtlWork = Join-Path $workRoot "rtl-93"
$simWork = Join-Path $workRoot "sim-08"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$locationPushed = $false

function Invoke-GhdlCapture {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  $savedPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    $output = @(& $Ghdl @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $savedPreference
  }

  return [pscustomobject]@{
    ExitCode = $exitCode
    Output = $output
  }
}

function Invoke-Ghdl {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  $result = Invoke-GhdlCapture -Arguments $Arguments
  $result.Output | ForEach-Object { Write-Host $_ }
  if ($result.ExitCode -ne 0) {
    exit $result.ExitCode
  }
}

function Invoke-GhdlWithMarker {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Marker,

    [Parameter(Mandatory = $true)]
    [string]$OutputFile,

    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  $result = Invoke-GhdlCapture -Arguments $Arguments
  $text = ($result.Output | Out-String)
  [IO.File]::WriteAllText($OutputFile, $text, $utf8NoBom)
  $result.Output | ForEach-Object { Write-Host $_ }

  if ($result.ExitCode -ne 0) {
    exit $result.ExitCode
  }

  $markerCount = [regex]::Matches(
    $text,
    [regex]::Escape($Marker)
  ).Count
  if ($markerCount -ne 1) {
    [Console]::Error.WriteLine(
      "Expected exactly one success marker: $Marker"
    )
    exit 1
  }
}

function Invoke-GhdlExpectedFailure {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Expected,

    [Parameter(Mandatory = $true)]
    [string]$OutputFile,

    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  $result = Invoke-GhdlCapture -Arguments $Arguments
  $text = ($result.Output | Out-String)
  [IO.File]::WriteAllText($OutputFile, $text, $utf8NoBom)
  $result.Output | ForEach-Object { Write-Host $_ }

  if ($result.ExitCode -eq 0) {
    [Console]::Error.WriteLine(
      "Invalid generic configuration was unexpectedly accepted."
    )
    exit 1
  }
  if (-not $text.Contains($Expected)) {
    [Console]::Error.WriteLine(
      "Invalid generic check failed for an unexpected reason."
    )
    exit 1
  }
}

New-Item -ItemType Directory -Path $rtlWork -Force | Out-Null
New-Item -ItemType Directory -Path $simWork -Force | Out-Null

try {
  Push-Location $workRoot
  $locationPushed = $true

  $masterRtl = Join-Path $repoRoot "src/lm_i2c_master.vhd"
  $targetRtl = Join-Path $repoRoot "src/lm_i2c_target.vhd"
  $masterTb = Join-Path $PSScriptRoot "tb_lm_i2c_master.vhd"
  $masterResetTb = Join-Path $PSScriptRoot "tb_lm_i2c_master_reset.vhd"
  $masterInvalidTb = Join-Path $PSScriptRoot "tb_lm_i2c_master_invalid.vhd"
  $targetTb = Join-Path $PSScriptRoot "tb_lm_i2c_target.vhd"
  $targetResetTb = Join-Path $PSScriptRoot "tb_lm_i2c_target_reset.vhd"
  $targetInvalidTb = Join-Path $PSScriptRoot "tb_lm_i2c_target_invalid.vhd"
  $masterMarker = "lm_i2c_master self-check passed"
  $targetMarker = "lm_i2c_target functional self-check passed"

  Invoke-Ghdl @(
    "-a",
    "--std=93",
    "--workdir=$rtlWork",
    $masterRtl,
    $targetRtl
  )
  $masterSynthesisResult = Invoke-GhdlCapture -Arguments @(
    "--synth",
    "--std=93",
    "--workdir=$rtlWork",
    "-gg_clk_freq_hz=50000000",
    "-gg_i2c_freq_hz=400000",
    "lm_i2c_master"
  )
  [IO.File]::WriteAllText(
    (Join-Path $workRoot "master-synthesis.txt"),
    ($masterSynthesisResult.Output | Out-String),
    $utf8NoBom
  )
  if ($masterSynthesisResult.ExitCode -ne 0) {
    $masterSynthesisResult.Output | ForEach-Object { Write-Host $_ }
    exit $masterSynthesisResult.ExitCode
  }

  $targetSynthesisResult = Invoke-GhdlCapture -Arguments @(
    "--synth",
    "--std=93",
    "--workdir=$rtlWork",
    "-gg_clk_freq_hz=50000000",
    "-gg_i2c_freq_hz=400000",
    "lm_i2c_target"
  )
  [IO.File]::WriteAllText(
    (Join-Path $workRoot "target-synthesis.txt"),
    ($targetSynthesisResult.Output | Out-String),
    $utf8NoBom
  )
  if ($targetSynthesisResult.ExitCode -ne 0) {
    $targetSynthesisResult.Output | ForEach-Object { Write-Host $_ }
    exit $targetSynthesisResult.ExitCode
  }

  Invoke-Ghdl @(
    "-a",
    "--std=08",
    "--workdir=$simWork",
    $masterRtl,
    $targetRtl,
    $masterTb,
    $masterResetTb,
    $masterInvalidTb,
    $targetTb,
    $targetResetTb,
    $targetInvalidTb
  )
  Invoke-Ghdl @("-e", "--std=08", "--workdir=$simWork", "tb_lm_i2c_master")
  Invoke-Ghdl @(
    "-e",
    "--std=08",
    "--workdir=$simWork",
    "tb_lm_i2c_master_reset"
  )
  Invoke-Ghdl @(
    "-e",
    "--std=08",
    "--workdir=$simWork",
    "tb_lm_i2c_master_invalid"
  )
  Invoke-Ghdl @("-e", "--std=08", "--workdir=$simWork", "tb_lm_i2c_target")
  Invoke-Ghdl @(
    "-e",
    "--std=08",
    "--workdir=$simWork",
    "tb_lm_i2c_target_reset"
  )
  Invoke-Ghdl @(
    "-e",
    "--std=08",
    "--workdir=$simWork",
    "tb_lm_i2c_target_invalid"
  )

  $testCases = @(
    @{ Clock = 10000000; Bus = 50000 },
    @{ Clock = 10000000; Bus = 100000 },
    @{ Clock = 12000000; Bus = 100000 },
    @{ Clock = 10000000; Bus = 137000 },
    @{ Clock = 10000000; Bus = 200000 },
    @{ Clock = 10000000; Bus = 333000 },
    @{ Clock = 10000000; Bus = 400000 },
    @{ Clock = 50000000; Bus = 400000 }
  )

  for ($index = 0; $index -lt $testCases.Count; $index++) {
    $testCase = $testCases[$index]
    Write-Host (
      "Running clk={0} Hz, scl={1} Hz" -f
        $testCase.Clock,
        $testCase.Bus
    )
    Invoke-GhdlWithMarker `
      -Marker $masterMarker `
      -OutputFile (Join-Path $workRoot "main-$index.txt") `
      -Arguments @(
        "-r",
        "--std=08",
        "--workdir=$simWork",
        "tb_lm_i2c_master",
        "-gg_clk_freq_hz=$($testCase.Clock)",
        "-gg_i2c_freq_hz=$($testCase.Bus)",
        "--assert-level=error",
        "--stop-time=$StopTime"
      )
  }

  foreach ($resetCase in 0..14) {
    $resetMarker = "lm_i2c_master reset case passed: $resetCase"
    Write-Host "Running reset case $resetCase"
    Invoke-GhdlWithMarker `
      -Marker $resetMarker `
      -OutputFile (Join-Path $workRoot "reset-$resetCase.txt") `
      -Arguments @(
        "-r",
        "--std=08",
        "--workdir=$simWork",
        "tb_lm_i2c_master_reset",
        "-gg_reset_case=$resetCase",
        "--assert-level=error",
        "--stop-time=$StopTime"
      )
  }

  $targetTestCases = @(
    @{ Clock = 10000000; Maximum = 100000; Actual = 100000 },
    @{ Clock = 10000000; Maximum = 400000; Actual = 400000 },
    @{ Clock = 800000; Maximum = 100000; Actual = 100000 },
    @{ Clock = 3200000; Maximum = 400000; Actual = 400000 },
    @{ Clock = 10000000; Maximum = 400000; Actual = 50000 }
  )

  for ($index = 0; $index -lt $targetTestCases.Count; $index++) {
    $testCase = $targetTestCases[$index]
    Write-Host (
      "Running target clk={0} Hz, maximum={1} Hz, actual={2} Hz" -f
        $testCase.Clock,
        $testCase.Maximum,
        $testCase.Actual
    )
    Invoke-GhdlWithMarker `
      -Marker $targetMarker `
      -OutputFile (Join-Path $workRoot "target-main-$index.txt") `
      -Arguments @(
        "-r",
        "--std=08",
        "--workdir=$simWork",
        "tb_lm_i2c_target",
        "-gg_clk_freq_hz=$($testCase.Clock)",
        "-gg_i2c_freq_hz=$($testCase.Maximum)",
        "-gg_actual_i2c_freq_hz=$($testCase.Actual)",
        "--assert-level=error",
        "--stop-time=$StopTime"
      )
  }

  foreach ($resetCase in 0..7) {
    $resetMarker = "lm_i2c_target reset case passed: $resetCase"
    Write-Host "Running target reset case $resetCase"
    Invoke-GhdlWithMarker `
      -Marker $resetMarker `
      -OutputFile (Join-Path $workRoot "target-reset-$resetCase.txt") `
      -Arguments @(
        "-r",
        "--std=08",
        "--workdir=$simWork",
        "tb_lm_i2c_target_reset",
        "-gg_reset_case=$resetCase",
        "--assert-level=error",
        "--stop-time=$StopTime"
      )
  }

  Invoke-GhdlExpectedFailure `
    -Expected "g_i2c_freq_hz must not exceed 400 kHz" `
    -OutputFile (Join-Path $workRoot "invalid-frequency.txt") `
    -Arguments @(
      "-r",
      "--std=08",
      "--workdir=$simWork",
      "tb_lm_i2c_master_invalid",
      "-gg_clk_freq_hz=10000000",
      "-gg_i2c_freq_hz=400001",
      "--assert-level=error"
    )

  Invoke-GhdlExpectedFailure `
    -Expected "g_clk_freq_hz must be at least eight times g_i2c_freq_hz" `
    -OutputFile (Join-Path $workRoot "invalid-ratio.txt") `
    -Arguments @(
      "-r",
      "--std=08",
      "--workdir=$simWork",
      "tb_lm_i2c_master_invalid",
      "-gg_clk_freq_hz=700000",
      "-gg_i2c_freq_hz=100000",
      "--assert-level=error"
    )

  Invoke-GhdlExpectedFailure `
    -Expected "g_i2c_freq_hz must not exceed 400 kHz" `
    -OutputFile (Join-Path $workRoot "target-invalid-frequency.txt") `
    -Arguments @(
      "-r",
      "--std=08",
      "--workdir=$simWork",
      "tb_lm_i2c_target_invalid",
      "-gg_clk_freq_hz=10000000",
      "-gg_i2c_freq_hz=400001",
      "--assert-level=error"
    )

  Invoke-GhdlExpectedFailure `
    -Expected "g_clk_freq_hz must be at least eight times g_i2c_freq_hz" `
    -OutputFile (Join-Path $workRoot "target-invalid-ratio.txt") `
    -Arguments @(
      "-r",
      "--std=08",
      "--workdir=$simWork",
      "tb_lm_i2c_target_invalid",
      "-gg_clk_freq_hz=700000",
      "-gg_i2c_freq_hz=100000",
      "--assert-level=error"
    )

  Invoke-GhdlExpectedFailure `
    -Expected "system clock is too slow for synchronized SCL LOW takeover" `
    -OutputFile (Join-Path $workRoot "target-invalid-takeover.txt") `
    -Arguments @(
      "-r",
      "--std=08",
      "--workdir=$simWork",
      "tb_lm_i2c_target_invalid",
      "-gg_clk_freq_hz=1096000",
      "-gg_i2c_freq_hz=137000",
      "--assert-level=error"
    )

  Write-Host (
    "All I2C controller and target regressions, VHDL-93 analysis, " +
      "and synthesis checks passed."
  )
}
finally {
  if ($locationPushed) {
    Pop-Location
  }
  if (Test-Path -LiteralPath $workRoot) {
    Remove-Item -LiteralPath $workRoot -Recurse -Force
  }
}

exit 0
