# Build spatial_core.dll and copy next to the Flutter Windows runner.
# Run from anywhere:
#   powershell -ExecutionPolicy Bypass -File yinwei/tools/build_native_windows.ps1

$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $Root

Write-Host "==> cargo build -p spatial_core --release"
cargo build -p spatial_core --release
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$Dll = Join-Path $Root "target\release\spatial_core.dll"
if (-not (Test-Path $Dll)) {
  Write-Error "DLL not found: $Dll"
}

$Destinations = @(
  (Join-Path $Root "apps\yinwei_player\windows\runner"),
  (Join-Path $Root "apps\yinwei_player\build\windows\x64\runner\Debug"),
  (Join-Path $Root "apps\yinwei_player\build\windows\x64\runner\Release")
)

foreach ($dest in $Destinations) {
  if (Test-Path $dest) {
    Copy-Item -Force $Dll (Join-Path $dest "spatial_core.dll")
    Write-Host "Copied -> $dest\spatial_core.dll"
  } else {
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item -Force $Dll (Join-Path $dest "spatial_core.dll")
    Write-Host "Created & copied -> $dest\spatial_core.dll"
  }
}

Write-Host ""
Write-Host "Done. Then:"
Write-Host "  cd apps\yinwei_player"
Write-Host "  flutter pub get"
Write-Host "  flutter run -d windows"
Write-Host ""
Write-Host "Status bar should show: Native · spatial_core"
