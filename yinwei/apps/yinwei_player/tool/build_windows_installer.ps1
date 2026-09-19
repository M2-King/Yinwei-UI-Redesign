# Builds a native Windows installer for the Flutter desktop player.
# Output is YinweiSetup-<version>-windows-x64.exe, not a web/JS package.
param(
  [string]$Version = "0.1.0"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$releaseDir = Join-Path $root "build\windows\x64\runner\Release"
$exe = Join-Path $releaseDir "yinwei_player.exe"
$dll = Join-Path $releaseDir "spatial_core.dll"
if (-not (Test-Path $exe)) {
  throw "Missing Release build: $exe. Run flutter build windows --release first."
}
if (-not (Test-Path $dll)) {
  throw "Missing spatial_core.dll in Release folder."
}

$iscc = Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe"
if (-not (Test-Path $iscc)) {
  $iscc = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
}
if (-not (Test-Path $iscc)) {
  throw "Inno Setup compiler not found. Install JRSoftware.InnoSetup."
}

$dist = Join-Path $root "dist\windows"
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$iss = Join-Path $root "windows\installer\yinwei.iss"

& $iscc `
  "/DMyAppVersion=$Version" `
  "/DSourceDir=$releaseDir" `
  "/DOutputDir=$dist" `
  $iss
if ($LASTEXITCODE -ne 0) {
  throw "ISCC failed with exit $LASTEXITCODE"
}

$setup = Join-Path $dist "YinweiSetup-$Version-windows-x64.exe"
if (-not (Test-Path $setup)) {
  throw "Installer not produced: $setup"
}
$hash = (Get-FileHash -Algorithm SHA256 $setup).Hash.ToLowerInvariant()
Write-Output "INSTALLER=$setup"
Write-Output "SHA256=$hash"
Write-Output "SIZE=$((Get-Item $setup).Length)"
