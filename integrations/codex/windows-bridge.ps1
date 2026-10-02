param(
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.@-]*$')]
    [string]$HostAlias,
    [string]$InstallDirectory = "$env:LOCALAPPDATA\clipaste"
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'bridge-config.ps1')
$configPath = Join-Path $InstallDirectory 'bridge-hosts.json'
# Older launch commands add one host without replacing the configured list.
if ($HostAlias) { Set-BridgeHost $configPath $HostAlias }
$mutex = New-Object Threading.Mutex($false, 'Local\clipaste-codex-bridge')
if (-not $mutex.WaitOne(0)) { $mutex.Dispose(); exit 0 }
$connections = @{}
$daemonProcess = $null
$logPath = Join-Path $InstallDirectory 'bridge.log'
$stopPath = Join-Path $InstallDirectory 'bridge.stop'
$statusPath = Join-Path $InstallDirectory 'bridge-status.json'
$configError = ''
function Write-BridgeLog([string]$Message) {
    if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 1048576) {
        Move-Item -LiteralPath $logPath -Destination "$logPath.previous" -Force
    }
    Add-Content -LiteralPath $logPath -Value "$(Get-Date -Format o) $Message"
}
function Stop-Connection($Connection) {
    if ($null -ne $Connection.process) {
        if (-not $Connection.process.HasExited) { $Connection.process.Kill(); $Connection.process.WaitForExit(3000) | Out-Null }
        $Connection.process.Dispose()
    }
}
try {
    $daemonPath = Join-Path $InstallDirectory 'clipaste.exe'
    if (-not (Test-Path -LiteralPath $daemonPath)) { throw "Missing $daemonPath" }
    if (Test-Path -LiteralPath $stopPath) { Remove-Item -LiteralPath $stopPath }
    $env:CLIPASTE_SERVER_ONLY = '1'
    Write-BridgeLog 'Starting multi-host clipboard bridge'
    while (-not (Test-Path -LiteralPath $stopPath)) {
        if ($null -eq $daemonProcess -or $daemonProcess.HasExited) {
            $health = $null
            try { $health = Invoke-RestMethod 'http://127.0.0.1:18340/health' -TimeoutSec 2 } catch {}
            if ($null -eq $health) {
                $daemonProcess = Start-Process -FilePath $daemonPath -WindowStyle Hidden -PassThru `
                    -RedirectStandardOutput (Join-Path $InstallDirectory 'daemon.stdout.log') `
                    -RedirectStandardError (Join-Path $InstallDirectory 'daemon.stderr.log')
                Write-BridgeLog "Started Windows clipboard daemon (PID $($daemonProcess.Id))"
            } elseif ($health.mode -ne 'server-only') { throw 'Existing daemon is not in server-only mode.' }
        }
        try {
            $desired = @(Read-BridgeConfig $configPath)
            $changes = Get-BridgeChanges $desired $connections
            foreach ($alias in $changes.Stop) {
                Stop-Connection $connections[$alias]
                $connections.Remove($alias)
                Write-BridgeLog "[$alias] Removed tunnel"
            }
            foreach ($entry in $changes.Start) {
                $connections[$entry.alias] = @{
                    alias = $entry.alias; remotePort = $entry.remotePort; process = $null
                    nextAttempt = [datetime]::MinValue; failures = 0; error = ''
                }
            }
            $configError = ''
        } catch {
            # Invalid edits preserve every working connection until the config is repaired.
            if ($configError -ne $_.Exception.Message) { Write-BridgeLog "Config error: $($_.Exception.Message)" }
            $configError = $_.Exception.Message
        }
        foreach ($connection in $connections.Values) {
            $alias = $connection.alias
            if ($null -ne $connection.process) {
                if (-not $connection.process.HasExited) {
                    if (((Get-Date) - $connection.process.StartTime).TotalSeconds -gt 30) { $connection.failures = 0 }
                    continue
                }
                $connection.error = "SSH exited $($connection.process.ExitCode); see host log"
                $connection.process.Dispose(); $connection.process = $null
                $connection.failures++
                $delay = [Math]::Min(60, 5 * [Math]::Pow(2, [Math]::Min(4, $connection.failures - 1)))
                $connection.nextAttempt = (Get-Date).AddSeconds($delay)
                Write-BridgeLog "[$alias] $($connection.error); retry in ${delay}s"
            }
            if ((Get-Date) -lt $connection.nextAttempt) { continue }
            try {
                $key = Get-BridgeHostKey $alias
                $connection.process = Start-Process -FilePath "$env:WINDIR\System32\OpenSSH\ssh.exe" `
                    -WindowStyle Hidden -PassThru -ArgumentList @(
                        '-N', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
                        '-o', 'ExitOnForwardFailure=yes', '-o', 'ServerAliveInterval=15',
                        '-o', 'ServerAliveCountMax=2', '-o', 'ControlMaster=no', '-o', 'ControlPath=none',
                        '-R', "127.0.0.1:$($connection.remotePort):127.0.0.1:18340", $alias
                    ) -RedirectStandardOutput (Join-Path $InstallDirectory "ssh-$key.stdout.log") `
                      -RedirectStandardError (Join-Path $InstallDirectory "ssh-$key.stderr.log")
                $connection.error = ''
                Write-BridgeLog "[$alias] Started SSH tunnel (PID $($connection.process.Id))"
            } catch {
                $connection.error = $_.Exception.Message
                $connection.nextAttempt = (Get-Date).AddSeconds(30)
                Write-BridgeLog "[$alias] $($connection.error)"
            }
        }
        $states = @($connections.Values | ForEach-Object {
            $alive = $null -ne $_.process -and -not $_.process.HasExited
            @{ alias = $_.alias; remotePort = $_.remotePort; state = $(if ($alive) { 'running' } else { 'retrying' })
               pid = $(if ($alive) { $_.process.Id } else { $null }); error = $_.error
               log = "ssh-$(Get-BridgeHostKey $_.alias).stderr.log" }
        })
        @{ version = 2; supervisorPid = $PID; updatedAt = (Get-Date).ToString('o'); configError = $configError; hosts = $states } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$statusPath.tmp" -Encoding utf8
        Move-Item -LiteralPath "$statusPath.tmp" -Destination $statusPath -Force
        Start-Sleep -Seconds 2
    }
} catch { Write-BridgeLog $_.Exception.Message; throw }
finally {
    foreach ($connection in $connections.Values) { Stop-Connection $connection }
    if (Test-Path -LiteralPath $statusPath) { Remove-Item -LiteralPath $statusPath }
    $mutex.ReleaseMutex(); $mutex.Dispose()
}
