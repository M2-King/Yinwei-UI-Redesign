# Build spatial_core.dll and copy next to the Flutter Windows runner.
# Run from anywhere:
#   powershell -ExecutionPolicy Bypass -File yinwei/tools/build_native_windows.ps1
#
# After rebuild: fully quit yinwei_player (do NOT hot restart) so the process
# loads the new DLL. A locked copy is a common cause of missing yinwei_live_* symbols.

$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $Root

function Test-FileLocked([string]$Path) {
  if (-not (Test-Path $Path)) { return $false }
  try {
    $fs = [System.IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
    $fs.Close()
    return $false
  } catch {
    return $true
  }
}

function Find-Dumpbin {
  $cmd = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
  if (-not (Test-Path $vswhere)) { return $null }
  $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
  if (-not $vs) { return $null }
  $bins = Get-ChildItem -Path (Join-Path $vs "VC\Tools\MSVC") -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
  foreach ($b in $bins) {
    $candidate = Join-Path $b.FullName "bin\Hostx64\x64\dumpbin.exe"
    if (Test-Path $candidate) { return $candidate }
  }
  return $null
}

function Test-LiveSymbols([string]$DllPath, [string]$Dumpbin) {
  $required = @(
    "yinwei_live_start",
    "yinwei_live_set_params",
    "yinwei_live_set_eq",
    "yinwei_set_eq",
    "yinwei_live_captured_frames",
    "yinwei_live_energy_frames",
    "yinwei_live_set_output_device",
    "yinwei_live_set_output_hold"
  )
  if (-not $Dumpbin) {
    Write-Host "WARN: dumpbin.exe not found; skip export smoke-check for $DllPath"
    return
  }
  $exports = & $Dumpbin /EXPORTS $DllPath 2>$null | Out-String
  $missing = @()
  foreach ($sym in $required) {
    if ($exports -notmatch [regex]::Escape($sym)) { $missing += $sym }
  }
  if ($missing.Count -gt 0) {
    Write-Error "DLL missing live symbols: $($missing -join ', ')`n  $DllPath`nQuit the player fully and rebuild."
  }
  Write-Host "Live symbols OK -> $DllPath"
}

$Destinations = @(
  (Join-Path $Root "apps\yinwei_player\windows\runner"),
  (Join-Path $Root "apps\yinwei_player\build\windows\x64\runner\Debug"),
  (Join-Path $Root "apps\yinwei_player\build\windows\x64\runner\Release")
)

$locked = @()
foreach ($dest in $Destinations) {
  $path = Join-Path $dest "spatial_core.dll"
  if (Test-FileLocked $path) {
    $locked += $path
  }
}
if ($locked.Count -gt 0) {
  Write-Host "ERROR: spatial_core.dll is locked (player still running):"
  $locked | ForEach-Object { Write-Host "  $_" }
  Write-Host ""
  Write-Host "Fully quit yinwei_player (close the window; do NOT Flutter hot restart),"
  Write-Host "then rerun this script so the new DLL can be copied."
  exit 1
}

Write-Host "==> cargo build -p spatial_core --release"
cargo build -p spatial_core --release
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$Dll = Join-Path $Root "target\release\spatial_core.dll"
if (-not (Test-Path $Dll)) {
  Write-Error "DLL not found: $Dll"
}

$dumpbin = Find-Dumpbin
Test-LiveSymbols $Dll $dumpbin

foreach ($dest in $Destinations) {
  if (-not (Test-Path $dest)) {
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
  }
  $target = Join-Path $dest "spatial_core.dll"
  if (Test-FileLocked $target) {
    Write-Error "Locked during copy: $target`nFully quit the player (not hot restart) and rerun."
  }
  Copy-Item -Force $Dll $target
  Write-Host "Copied -> $target"
  Test-LiveSymbols $target $dumpbin
}

Write-Host ""
Write-Host "Done. Fully quit yinwei_player if it is open, then:"
Write-Host "  cd apps\yinwei_player"
Write-Host "  flutter pub get"
Write-Host "  flutter run -d windows"
Write-Host ""
Write-Host "Do NOT hot restart after a DLL rebuild — the old spatial_core.dll stays mapped."
Write-Host "Status bar should show: Native · spatial_core"
