param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.@-]*$')]
    [string]$HostAlias
)
$ErrorActionPreference = 'Stop'
$directory = "$env:LOCALAPPDATA\clipaste"
$native = Join-Path $directory 'ClipasteTray.exe'
if (-not (Test-Path -LiteralPath $native)) { throw 'Install the Windows desktop setup wizard first.' }
. (Join-Path $PSScriptRoot 'bridge-config.ps1')
$null = [Reflection.Assembly]::LoadFrom($native)
[ClipasteDesktop.Program]::InstallHook($HostAlias, 18340)
$socket = [ClipasteDesktop.Program]::PrepareSocket($HostAlias)
Set-BridgeHost (Join-Path $directory 'bridge-hosts.json') $HostAlias -RemoteSocket $socket
Start-Process $native -ArgumentList '--background' -WindowStyle Hidden
Write-Host "Private bridge configured for $HostAlias. Images expire after 24 hours. Review /hooks once in remote Codex."
