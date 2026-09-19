# Packages a local Windows Release zip + test manifest for updater checks.
# Does not install, push, or touch audio/spatial code.
param(
  [string]$Version = "0.1.1",
  [string]$Channel = "stable"
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

$dist = Join-Path $root "dist\windows"
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$zipName = "yinwei_player-$Version-windows-x64.zip"
$zipPath = Join-Path $dist $zipName
if (Test-Path $zipPath) {
  Remove-Item $zipPath -Force
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($releaseDir, $zipPath)

$hash = (Get-FileHash -Algorithm SHA256 $zipPath).Hash.ToLowerInvariant()
$size = (Get-Item $zipPath).Length
$manifest = [ordered]@{
  schemaVersion = 1
  platform      = "windows-x64"
  generatedAt   = [DateTime]::UtcNow.ToString("o")
  purpose       = "local-test-only"
  installedHint = @{
    version = "0.1.0"
    channel = "stable"
    platform = "windows-x64"
  }
  releases      = @(
    [ordered]@{
      version   = $Version
      channel   = $Channel
      platform  = "windows-x64"
      fileName  = $zipName
      sha256    = $hash
      sizeBytes = $size
      uri       = ([Uri]$zipPath).AbsoluteUri
      notes     = "Local test package. Manual install only."
    }
    [ordered]@{
      version   = "0.1.2-beta.1"
      channel   = "beta"
      platform  = "windows-x64"
      fileName  = $zipName
      sha256    = $hash
      sizeBytes = $size
      uri       = ([Uri]$zipPath).AbsoluteUri
      notes     = "Same bits as stable 0.1.1, advertised as Beta for channel tests."
    }
    [ordered]@{
      version   = "0.1.3-dev.1"
      channel   = "developer"
      platform  = "windows-x64"
      fileName  = $zipName
      sha256    = $hash
      sizeBytes = $size
      uri       = ([Uri]$zipPath).AbsoluteUri
      notes     = "Same bits as stable 0.1.1, advertised as Developer for channel tests."
    }
  )
}

$manifestPath = Join-Path $dist "local-release-manifest.json"
$manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $manifestPath -Encoding utf8
Write-Output "PACKAGE=$zipPath"
Write-Output "SHA256=$hash"
Write-Output "MANIFEST=$manifestPath"
