param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.@-]*$')]
    [string]$HostAlias,
    [string]$BinaryPath = "$env:LOCALAPPDATA\clipaste\clipaste.exe",
    [ValidateRange(1,65535)]
    [int]$RemotePort = 18340,
    [ValidatePattern('^python3(\.[0-9]+)?$')]
    [string]$RemotePython = 'python3.11'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'bridge-config.ps1')
$installDirectory = Join-Path $env:LOCALAPPDATA 'clipaste'
$daemonPath = Join-Path $installDirectory 'clipaste.exe'
$bridgePath = Join-Path $installDirectory 'windows-bridge.ps1'
$bridgeChanged = (Test-Path -LiteralPath $bridgePath) -and
    (Get-FileHash -LiteralPath $bridgePath).Hash -ne (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'windows-bridge.ps1')).Hash
$pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
$powershellPath = if ($pwsh) { $pwsh.Source } else {
    Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
}
# Prefer the stable Store app alias over a versioned WindowsApps package path.
$pwshAlias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
if ($pwsh -and (Test-Path -LiteralPath $pwshAlias)) { $powershellPath = $pwshAlias }
$policy = & $powershellPath -NoProfile -Command Get-ExecutionPolicy
if ($policy -eq 'Restricted' -or $policy -eq 'AllSigned') {
    throw 'The selected PowerShell host does not permit this unsigned local script. Use an approved PowerShell installation.'
}

if (-not (Test-Path -LiteralPath $BinaryPath -PathType Leaf)) { throw 'Build clipaste.exe first.' }
& ssh -n -o BatchMode=yes -o ConnectTimeout=10 $HostAlias "~/.local/bin/uv run --offline --no-project --python $RemotePython python -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'"
if ($LASTEXITCODE -ne 0) { throw 'Check SSH authentication and the remote Python version.' }

New-Item -ItemType Directory -Force -Path $installDirectory | Out-Null
if (-not (Test-Path -LiteralPath $daemonPath) -or
    (Get-FileHash -LiteralPath $BinaryPath).Hash -ne (Get-FileHash -LiteralPath $daemonPath).Hash) {
    Copy-Item -LiteralPath $BinaryPath -Destination $daemonPath
}
foreach ($file in @('windows-bridge.ps1','bridge-config.ps1','bridge.ps1','setup-windows.ps1','clipboard_hook.py')) {
    $source = Join-Path $PSScriptRoot $file
    $destination = Join-Path $installDirectory $file
    if ([IO.Path]::GetFullPath($source) -ne [IO.Path]::GetFullPath($destination)) { Copy-Item -LiteralPath $source -Destination $destination }
}

& ssh -n -o BatchMode=yes $HostAlias 'mkdir -p ~/.local/share/clipaste-codex'
if ($LASTEXITCODE -ne 0) { throw 'Cannot create the remote integration directory.' }
& scp (Join-Path $PSScriptRoot 'clipboard_hook.py') "${HostAlias}:.local/share/clipaste-codex/clipboard_hook.py"
if ($LASTEXITCODE -ne 0) { throw 'Cannot copy the remote hook.' }
& ssh -n -o BatchMode=yes $HostAlias "~/.local/bin/uv run --offline --no-project --python $RemotePython ~/.local/share/clipaste-codex/clipboard_hook.py install --url http://127.0.0.1:$RemotePort"
if ($LASTEXITCODE -ne 0) { throw 'Cannot install the Codex hook.' }

$configPath = Join-Path $installDirectory 'bridge-hosts.json'
$startup = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startup 'clipaste Codex bridge.lnk'
$shell = New-Object -ComObject WScript.Shell
if (Test-Path -LiteralPath $shortcutPath) {
    $previousArguments = $shell.CreateShortcut($shortcutPath).Arguments
    if ($previousArguments -match '-HostAlias ([A-Za-z0-9][A-Za-z0-9_.@-]*)') {
        $previousAlias = $Matches[1]
        if ($previousAlias -notin @(Read-BridgeConfig $configPath | ForEach-Object alias)) {
            Set-BridgeHost $configPath $previousAlias
        }
    }
}
Set-BridgeHost $configPath $HostAlias $RemotePort
$arguments = "-NoProfile -WindowStyle Hidden -File `"$bridgePath`""
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $powershellPath
$shortcut.Arguments = $arguments
$shortcut.WorkingDirectory = $installDirectory
$shortcut.WindowStyle = 7
$shortcut.Description = 'Windows clipboard images for configured SSH hosts'
$shortcut.Save()
$launcher = "@echo off`r`n`"$powershellPath`" -NoProfile -File `"%~dp0bridge.ps1`" %*`r`n"
Set-Content -LiteralPath (Join-Path $installDirectory 'clipaste-bridge.cmd') -Value $launcher -Encoding ascii
$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
if ($installDirectory -notin ($userPath -split ';')) {
    [Environment]::SetEnvironmentVariable('PATH', "$userPath;$installDirectory", 'User')
}
# Migrate the old singleton supervisor only once; subsequent hosts are hot-added.
$existing = Get-CimInstance Win32_Process | Where-Object {
    $_.Name -in @('pwsh.exe','powershell.exe') -and $_.CommandLine -like "*-File `"$bridgePath`"*" -and
    ($bridgeChanged -or $_.CommandLine -like '*-HostAlias *')
}
if ($existing) {
    New-Item -ItemType File -Force -Path (Join-Path $installDirectory 'bridge.stop') | Out-Null
    foreach ($process in $existing) { Wait-Process -Id $process.ProcessId -Timeout 15 -ErrorAction Stop }
}
Start-Process -FilePath $powershellPath -ArgumentList $arguments -WindowStyle Hidden

$ready = $false
for ($attempt = 0; $attempt -lt 10; $attempt++) {
    Start-Sleep -Seconds 1
    & ssh -n -o BatchMode=yes -o ConnectTimeout=3 $HostAlias "curl --noproxy '*' -fsS --max-time 2 http://127.0.0.1:$RemotePort/health" 2>$null
    if ($LASTEXITCODE -eq 0) { $ready = $true; break }
}
if (-not $ready) { throw "Tunnel not ready. Run clipaste-bridge status; host-specific SSH logs are in $installDirectory." }
& $daemonPath doctor --json
if ($LASTEXITCODE -ne 0) { throw 'The Windows clipboard daemon failed its health checks.' }
Write-Host "Ready for hook review. In Codex on $HostAlias, open /hooks and trust the clipaste hook once."
Write-Host 'Then copy a screenshot and submit: Explain this @clipboard'
