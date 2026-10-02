param(
    [ValidateSet('start','stop','status','add','remove')]
    [string]$Action = 'status',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.@-]*$')]
    [string]$HostAlias,
    [ValidateRange(1,65535)]
    [int]$RemotePort = 18340
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'bridge-config.ps1')
$directory = "$env:LOCALAPPDATA\clipaste"
$config = Join-Path $directory 'bridge-hosts.json'
switch ($Action) {
    'add' {
        if (-not $HostAlias) { throw 'Usage: clipaste-bridge add SSH_ALIAS' }
        & (Join-Path $PSScriptRoot 'setup-windows.ps1') -HostAlias $HostAlias
    }
    'remove' {
        if (-not $HostAlias) { throw 'Usage: clipaste-bridge remove SSH_ALIAS' }
        Set-BridgeHost $config $HostAlias -Remove
        Write-Output "Removed $HostAlias. Other hosts and remote hook files are unchanged."
    }
    'start' {
        if (Test-Path -LiteralPath (Join-Path $directory 'ClipasteTray.exe')) {
            Start-Process (Join-Path $directory 'ClipasteTray.exe') -ArgumentList '--background' -WindowStyle Hidden
            return
        }
        $exe = (Get-Command pwsh -ErrorAction Stop).Source
        Start-Process $exe -WindowStyle Hidden -ArgumentList "-NoProfile -WindowStyle Hidden -File `"$directory\windows-bridge.ps1`""
    }
    'stop' {
        if (Test-Path -LiteralPath (Join-Path $directory 'ClipasteTray.exe')) {
            Start-Process (Join-Path $directory 'ClipasteTray.exe') -ArgumentList '--shutdown' -WindowStyle Hidden -Wait
        } else { New-Item -ItemType File -Force -Path (Join-Path $directory 'bridge.stop') | Out-Null }
    }
    'status' {
        $statusPath = Join-Path $directory 'bridge-status.json'
        if (-not (Test-Path -LiteralPath $statusPath)) { Write-Output 'Bridge stopped.'; return }
        $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
        if (-not (Get-Process -Id $status.supervisorPid -ErrorAction SilentlyContinue) -or
            ((Get-Date) - [datetime]$status.updatedAt).TotalSeconds -gt 30) {
            Write-Output 'Bridge stopped or unresponsive (stale status).'; return
        }
        if ($status.configError) { Write-Warning $status.configError }
        $status.hosts | Select-Object alias,remotePort,state,pid,error,log
    }
}
