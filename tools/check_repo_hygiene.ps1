# Copyright 2026 LogiMentor Srl
# SPDX-License-Identifier: Apache-2.0

[CmdletBinding()]
param(
  [ValidateSet("Full", "Staged", "Tracked")]
  [string]$Mode = "Full"
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$problems = [System.Collections.Generic.List[string]]::new()

Push-Location $repoRoot
try {
  if ($Mode -eq "Staged") {
    $paths = @(git diff --cached --name-only --diff-filter=ACMR)
  }
  elseif ($Mode -eq "Tracked") {
    $paths = @(git ls-files)
  }
  else {
    $paths = @(
      git ls-files
      git ls-files --others --exclude-standard
    ) | Sort-Object -Unique
  }

  if ($LASTEXITCODE -ne 0) {
    throw "Git could not enumerate repository files."
  }

  $blockedPathPatterns = @(
    '(^|/)(reference|private)(/|$)',
    '(^|/)ces_[^/]*$',
    '(^|/)(work-obj[^/]*\.cf|modelsim\.ini|transcript)$',
    '\.(ghw|vcd|fst|wlf|vpd|fsdb|jou|log|tmp|exe|o)$'
  )
  $textExtensions = @(
    ".cfg", ".conf", ".ini", ".json", ".md", ".ps1", ".sh", ".tcl",
    ".toml", ".txt", ".vhd", ".vhdl", ".yaml", ".yml"
  )
  $textNames = @(".editorconfig", ".gitattributes", ".gitignore", "LICENSE", "NOTICE")

  foreach ($path in $paths) {
    $normalized = $path -replace '\\', '/'
    foreach ($pattern in $blockedPathPatterns) {
      if ($normalized -match $pattern) {
        $problems.Add("blocked path: $normalized")
        break
      }
    }

    $extension = [System.IO.Path]::GetExtension($normalized).ToLowerInvariant()
    $name = [System.IO.Path]::GetFileName($normalized)
    if ($Mode -ne "Tracked" -and
        ($textExtensions -contains $extension -or $textNames -contains $name)) {
      $fullPath = Join-Path $repoRoot $path
      if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
        $bytes = [System.IO.File]::ReadAllBytes($fullPath)
        if ($bytes -contains 13) {
          $problems.Add("CRLF or CR line ending: $normalized")
        }
      }
    }
  }

  if ($problems.Count -ne 0) {
    $problems | ForEach-Object { Write-Error $_ }
    exit 1
  }

  Write-Host "Repository hygiene check passed ($Mode mode, $($paths.Count) paths)."
}
finally {
  Pop-Location
}
