param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.@-]*$')]
    [string]$HostAlias,
    [string]$InstallDirectory = "$env:LOCALAPPDATA\clipaste"
)

$ErrorActionPreference = 'Stop'
$mutex = New-Object System.Threading.Mutex($false, 'Local\clipaste-codex-bridge')
if (-not $mutex.WaitOne(0)) { $mutex.Dispose(); exit 0 }
$bridgeProcess = $null
$daemonProcess = $null
$logPath = Join-Path $InstallDirectory 'bridge.log'
$stopPath = Join-Path $InstallDirectory 'bridge.stop'

function Write-BridgeLog([string]$Message) {
    if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 1048576) {
        Move-Item -LiteralPath $logPath -Destination "$logPath.previous" -Force
    }
    Add-Content -LiteralPath $logPath -Value "$(Get-Date -Format o) $Message"
}

try {
    $daemonPath = Join-Path $InstallDirectory 'clipaste.exe'
    if (-not (Test-Path -LiteralPath $daemonPath)) { throw "Missing $daemonPath" }
    if (Test-Path -LiteralPath $stopPath) { Remove-Item -LiteralPath $stopPath }
    # This process and its children only: GUI applications retain their normal image clipboard.
    $env:CLIPASTE_SERVER_ONLY = '1'
    Write-BridgeLog "Starting clipboard bridge for $HostAlias"
    while (-not (Test-Path -LiteralPath $stopPath)) {
        if ($null -eq $daemonProcess -or $daemonProcess.HasExited) {
            $health = $null
            try { $health = Invoke-RestMethod 'http://127.0.0.1:18340/health' -TimeoutSec 2 } catch {}
            if ($null -eq $health) {
                $daemonProcess = Start-Process -FilePath $daemonPath -WindowStyle Hidden -PassThru `
                    -RedirectStandardOutput (Join-Path $InstallDirectory 'daemon.stdout.log') `
                    -RedirectStandardError (Join-Path $InstallDirectory 'daemon.stderr.log')
                Write-BridgeLog "Started Windows clipboard daemon (PID $($daemonProcess.Id))"
            } elseif ($health.mode -ne 'server-only') {
                throw 'An existing clipboard daemon is not in server-only mode. Stop it before starting this bridge.'
            }
        }
        if ($null -eq $bridgeProcess -or $bridgeProcess.HasExited) {
            if ($null -ne $bridgeProcess) {
                Write-BridgeLog "SSH disconnected (exit $($bridgeProcess.ExitCode)); reconnecting"
                $bridgeProcess.Dispose()
            }
            $bridgeProcess = Start-Process -FilePath "$env:WINDIR\System32\OpenSSH\ssh.exe" `
                -WindowStyle Hidden -PassThru -ArgumentList @(
                    '-N', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
                    '-o', 'ExitOnForwardFailure=yes', '-o', 'ServerAliveInterval=15',
                    '-o', 'ServerAliveCountMax=2', '-o', 'ControlMaster=no', '-o', 'ControlPath=none',
                    '-R', '127.0.0.1:18340:127.0.0.1:18340', $HostAlias
                ) -RedirectStandardOutput (Join-Path $InstallDirectory 'ssh.stdout.log') `
                  -RedirectStandardError (Join-Path $InstallDirectory 'ssh.stderr.log')
            Write-BridgeLog "Started SSH tunnel (PID $($bridgeProcess.Id))"
        }
        Start-Sleep -Seconds 5
    }
} catch {
    Write-BridgeLog $_.Exception.Message
    throw
} finally {
    if ($null -ne $bridgeProcess -and -not $bridgeProcess.HasExited) {
        $bridgeProcess.Kill()
    }
    # Keep the clipboard daemon available to other integrations after the tunnel stops.
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
