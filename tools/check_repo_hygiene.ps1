# Copyright 2026 LogiMentor Srl
# SPDX-License-Identifier: Apache-2.0

[CmdletBinding()]
param(
  [ValidateSet("Full", "Staged", "Tracked", "CommitMessage", "History")]
  [string]$Mode = "Full",
  [string]$CommitMessageFile,
  [string]$RevisionRange = "HEAD"
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$failures = [System.Collections.Generic.List[string]]::new()
$tempRoot = Join-Path (
  [IO.Path]::GetTempPath()
) ("lm_i2c-hygiene-" + [guid]::NewGuid().ToString("N"))

$pathPattern = '(?i)(^|/)(reference|private|AGENTS\.md)(/|$)|(^|/)(#[^/]+#|[^/]+~|[^/]+\.(swp|swo|tmp|temp|bak|orig|rej)|~\$[^/]+|\.DS_Store)$|\.(ghw|vcd|fst|wlf|vpd|fsdb|jou|log|exe|o)$|(^|/)(build|dist|out|work|work-ghdl[^/]*|coverage|synth)(/|$)' # hygiene-pattern-definition
$absolutePathPattern = '(?i)([A-Za-z]:[\\/](Users|Documents and Settings)[\\/]|/(home|Users)/[^/\s]+/|file:///([A-Za-z]:|home/|Users/))' # hygiene-pattern-definition
$legacyIdentifierPattern = '(?i)(^|[^A-Za-z0-9_])ces_[A-Za-z0-9_]*' # hygiene-pattern-definition
$legacyOrganizationPattern = '(?i)Campera\s+Electronic\s+Systems(\s+Srl)?|([A-Za-z0-9-]+\.)?campera-es\.com' # hygiene-pattern-definition
$trailerPattern = '(?i)^\s*(co-authored-by|generated-by|assisted-by)\s*:' # hygiene-pattern-definition
$attributionPattern = '(?i)(^|[^A-Za-z0-9_])((generated|created|written|authored|assisted|produced)\s+(by|with|using)\s+(an?\s+)?(ai|llm|language[ -]model|chatgpt|codex|copilot|claude|gemini)|(ai|llm|language[ -]model)[ -](generated|assisted|authored))([^A-Za-z0-9_]|$)' # hygiene-pattern-definition
$promptPattern = '(?i)(^|[^A-Za-z0-9_])((system\s+prompt|developer\s+message|user\s+prompt|task\s+instructions)\s*:|begin\s+prompt|end\s+prompt|my\s+request\s+for\s+codex)([^A-Za-z0-9_]|$)' # hygiene-pattern-definition

function Add-Failure {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Location,
    [Parameter(Mandatory = $true)]
    [string]$Problem
  )

  $failures.Add("[HYG] ${Location}: $Problem")
}

function Invoke-Git {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  $output = @(& git -C $repoRoot @Arguments 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "Git failed: git $($Arguments -join ' ')"
  }
  return $output
}

function Test-TextPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
  if (@(
    ".cfg", ".conf", ".ini", ".json", ".md", ".ps1", ".sh", ".tcl",
    ".toml", ".txt", ".vhd", ".vhdl", ".yaml", ".yml"
  ) -contains $extension) {
    return $true
  }

  return @(
    ".editorconfig", ".gitattributes", ".gitignore", "license", "notice"
  ) -contains [IO.Path]::GetFileName($Path).ToLowerInvariant()
}

function Test-PathPolicy {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $normalized = $Path.Replace("\", "/")
  if ($normalized -match $pathPattern) {
    Add-Failure $normalized "blocked public path"
  }
}

function Test-Text {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Text,
    [Parameter(Mandatory = $true)]
    [string]$Location,
    [bool]$CheckFinalNewline = $true
  )

  if ($Text.Contains("`r")) {
    Add-Failure $Location "carriage return"
  }
  if ($CheckFinalNewline -and $Text.Length -gt 0 -and
      -not $Text.EndsWith("`n")) {
    Add-Failure $Location "missing final newline"
  }

  $lines = $Text.Split([char]"`n")
  for ($index = 0; $index -lt $lines.Count; $index++) {
    $line = $lines[$index]
    $lineLocation = "${Location}:$($index + 1)"
    if ($line -match "[`t ]$") {
      $markdownBreak = $Location.EndsWith(
        ".md",
        [StringComparison]::OrdinalIgnoreCase
      ) -and $line -match "\S {2}$"
      if (-not $markdownBreak) {
        Add-Failure $lineLocation "trailing whitespace"
      }
    }
    if ($line -match '^(<<<<<<<|=======|>>>>>>>)(\s|$)') {
      Add-Failure $lineLocation "merge-conflict marker"
    }
    $normalizedLocation = $Location.Replace("\", "/")
    if (
      $normalizedLocation.EndsWith(
        "tools/check_repo_hygiene.sh",
        [StringComparison]::OrdinalIgnoreCase
      ) -or
      $normalizedLocation.EndsWith(
        "tools/check_repo_hygiene.ps1",
        [StringComparison]::OrdinalIgnoreCase
      ) -or
      $line.Contains("hygiene-pattern-definition")
    ) {
      continue
    }
    if ($line -match $absolutePathPattern) {
      Add-Failure $lineLocation "absolute local user path"
    }
    if ($line -match $legacyIdentifierPattern) {
      Add-Failure $lineLocation "legacy public identifier"
    }
    if ($line -match $legacyOrganizationPattern) {
      Add-Failure $lineLocation "legacy organization marker"
    }
    if ($line -match $trailerPattern) {
      Add-Failure $lineLocation "prohibited authorship trailer"
    }
    if ($line -match $attributionPattern) {
      Add-Failure $lineLocation "prohibited attribution marker"
    }
    if ($line -match $promptPattern) {
      Add-Failure $lineLocation "prompt or task transcript"
    }
  }
}

function Test-WorkingFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  Test-PathPolicy $Path
  if (-not (Test-TextPath $Path)) {
    return
  }

  $fullPath = Join-Path $repoRoot $Path
  try {
    $bytes = [IO.File]::ReadAllBytes($fullPath)
    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $text = $strictUtf8.GetString($bytes)
    if ([Array]::IndexOf($bytes, [byte]0) -ge 0) {
      Add-Failure $Path "text contains a NUL byte"
      return
    }
    Test-Text $text $Path
  }
  catch {
    Add-Failure $Path "unable to read valid UTF-8 text"
  }
}

function Test-GitFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Revision,
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$Location
  )

  Test-PathPolicy $Path
  if (-not (Test-TextPath $Path)) {
    return
  }
  if ($Revision -eq ":") {
    $objectSpec = ":$Path"
  }
  else {
    $objectSpec = "${Revision}:$Path"
  }
  $text = (Invoke-Git @(
    "show", "--no-textconv", $objectSpec
  )) -join "`n"
  if ($text.Length -gt 0) {
    $text += "`n"
  }
  Test-Text $text $Location
}

New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

Push-Location $repoRoot
try {
  switch ($Mode) {
    "Full" {
      $paths = @(
        Invoke-Git @("ls-files", "--cached", "--others", "--exclude-standard")
      ) | Sort-Object -Unique
      foreach ($path in $paths) {
        if (Test-Path -LiteralPath (Join-Path $repoRoot "$path") -PathType Leaf) {
          Test-WorkingFile "$path"
        }
      }
    }
    "Staged" {
      $paths = @(Invoke-Git @(
        "diff", "--cached", "--name-only", "--diff-filter=ACMR"
      ))
      foreach ($path in $paths) {
        Test-GitFile ":" "$path" "$path"
      }
    }
    "Tracked" {
      foreach ($path in @(Invoke-Git @("ls-files"))) {
        Test-PathPolicy "$path"
      }
    }
    "CommitMessage" {
      if (-not $CommitMessageFile -or
          -not (Test-Path -LiteralPath $CommitMessageFile -PathType Leaf)) {
        throw "-CommitMessageFile is required in CommitMessage mode."
      }
      $message = [IO.File]::ReadAllText(
        [IO.Path]::GetFullPath($CommitMessageFile)
      )
      Test-Text $message $CommitMessageFile $false
    }
    "History" {
      foreach ($commit in @(Invoke-Git @("rev-list", $RevisionRange))) {
        $message = (Invoke-Git @(
          "show", "-s", "--format=%B", $commit
        )) -join "`n"
        Test-Text $message "${commit}:message" $false
        foreach ($path in @(Invoke-Git @(
          "ls-tree", "-r", "--name-only", $commit
        ))) {
          Test-GitFile $commit "$path" "${commit}:$path"
        }
      }
    }
  }
}
finally {
  Pop-Location
  if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
}

if ($failures.Count -ne 0) {
  $failures | ForEach-Object { [Console]::Error.WriteLine($_) }
  [Console]::Error.WriteLine(
    "Repository hygiene failed with $($failures.Count) violation(s)."
  )
  exit 1
}

Write-Host "Repository hygiene passed ($Mode mode)."
exit 0
