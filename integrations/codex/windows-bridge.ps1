param([string]$HostAlias, [string]$InstallDirectory = "$env:LOCALAPPDATA\clipaste")
$ErrorActionPreference = 'Stop'
$native = Join-Path $InstallDirectory 'ClipasteTray.exe'
if (-not (Test-Path -LiteralPath $native)) { throw 'Install the Windows desktop setup wizard first. The unauthenticated TCP bridge is no longer supported.' }
if ($HostAlias) { & (Join-Path $InstallDirectory 'setup-windows.ps1') -HostAlias $HostAlias }
else { Start-Process $native -ArgumentList '--background' -WindowStyle Hidden }
