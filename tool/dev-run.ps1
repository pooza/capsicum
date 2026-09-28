#Requires -Version 5.1
<#
.SYNOPSIS
  Run capsicum in debug (#1179): read secrets.env, run build_runner, then
  flutter run in packages/capsicum. Windows counterpart of tool/dev-run.sh.

.DESCRIPTION
  - Always passes --dart-define=RELAY_SECRET. Loading secrets.env alone does
    not reach Dart; without the define, push registration fails with 401 and
    the relay logs nothing (#994).
  - Runs flutter in packages/capsicum (the workspace root has no platform dirs).
  - Does NOT stop when secrets.env is unreadable or RELAY_SECRET is empty
    (#1180). Only maintainers can have the secret, so stopping would leave
    outside contributors unable to run the app at all. Warns and runs without
    the define instead: everything works except push notifications.
    secrets.env is a symlink into Google Drive (G:), which can stay unmounted
    after a failed restart, so the warning still matters to maintainers.
  - Does NOT pass SENTRY_DSN (dev exceptions would go to the production project).
  - build_runner runs directly in each package that depends on it instead of
    "melos run build_runner", which fails on Windows when the Pub Cache bin is
    not on PATH (docs/dev-environment.md).

  Keep this file ASCII only: PowerShell 5.1 reads BOM-less UTF-8 as the ANSI
  code page and non-ASCII text turns into a silent parse error.

  Options (exact match; everything else goes to flutter run as-is):
    -SkipBuildRunner  skip build_runner
    -DryRun           print the commands instead of running them (secret masked)

  No param() block on purpose: PowerShell binds abbreviated parameter names,
  so "-d windows" would be taken as -DryRun and never reach flutter.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tool\dev-run.ps1 -d windows

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tool\dev-run.ps1 -SkipBuildRunner -d windows
#>

$SkipBuildRunner = $false
$DryRun = $false
$FlutterArgs = @()
foreach ($a in $args) {
  switch -CaseSensitive ($a) {
    '-SkipBuildRunner' { $SkipBuildRunner = $true }
    '-DryRun' { $DryRun = $true }
    default { $FlutterArgs += [string]$a }
  }
}

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$secrets = if ($env:CAPSICUM_SECRETS) { $env:CAPSICUM_SECRETS } else {
  Join-Path $env:USERPROFILE '.config\capsicum\secrets.env'
}

$relaySecret = $null
if (Test-Path -LiteralPath $secrets) {
  # secrets.env is written for sh: "export KEY=value", optionally quoted.
  foreach ($line in Get-Content -LiteralPath $secrets) {
    if ($line -match '^\s*(?:export\s+)?RELAY_SECRET=(.*)$') {
      $relaySecret = $Matches[1].Trim().Trim('"').Trim("'")
    }
  }
} else {
  Write-Warning "cannot read $secrets (maintainers: is Google Drive / G: mounted?)"
}
if ([string]::IsNullOrEmpty($relaySecret)) {
  Write-Warning "RELAY_SECRET not found; push notifications will not work (registration fails with 401). Everything else runs."
}

function Invoke-Step([string]$dir, [string]$exe, [string[]]$argv) {
  if ($DryRun) {
    $shown = $argv -join ' '
    # Replacing an empty string would insert the marker between every char.
    if (-not [string]::IsNullOrEmpty($relaySecret)) {
      $shown = $shown.Replace($relaySecret, '<RELAY_SECRET>')
    }
    Write-Output "(in $dir) $exe $shown"
    return
  }
  Push-Location $dir
  try {
    & $exe @argv
    if ($LASTEXITCODE -ne 0) { throw "$exe exited with $LASTEXITCODE" }
  } finally {
    Pop-Location
  }
}

if (-not $SkipBuildRunner) {
  $targets = Get-ChildItem -Path (Join-Path $repoRoot 'packages') -Directory |
    Where-Object {
      $pubspec = Join-Path $_.FullName 'pubspec.yaml'
      (Test-Path $pubspec) -and (Select-String -Path $pubspec -Pattern '^\s+build_runner:' -Quiet)
    }
  foreach ($pkg in $targets) {
    Invoke-Step $pkg.FullName 'dart' @('run', 'build_runner', 'build', '--delete-conflicting-outputs')
  }
}

# Drop the define entirely when there is no secret: baking in an empty value
# makes the relay fail on the signature instead of saying the value is missing.
$runArgs = if ([string]::IsNullOrEmpty($relaySecret)) {
  @('run') + $FlutterArgs
} else {
  @('run', "--dart-define=RELAY_SECRET=$relaySecret") + $FlutterArgs
}
Invoke-Step (Join-Path $repoRoot 'packages\capsicum') 'flutter' $runArgs
