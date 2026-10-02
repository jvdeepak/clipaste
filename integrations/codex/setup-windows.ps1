param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.@-]*$')]
    [string]$HostAlias,
    [Parameter(Mandatory = $true)]
    [string]$BinaryPath,
    [ValidatePattern('^python3(\.[0-9]+)?$')]
    [string]$RemotePython = 'python3.11'
)

$ErrorActionPreference = 'Stop'
$installDirectory = Join-Path $env:LOCALAPPDATA 'clipaste'
$daemonPath = Join-Path $installDirectory 'clipaste.exe'
$bridgePath = Join-Path $installDirectory 'windows-bridge.ps1'
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
& ssh -n -o BatchMode=yes -o ConnectTimeout=10 $HostAlias "$RemotePython -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'"
if ($LASTEXITCODE -ne 0) { throw 'Check SSH authentication and the remote Python version.' }

New-Item -ItemType Directory -Force -Path $installDirectory | Out-Null
if (-not (Test-Path -LiteralPath $daemonPath) -or
    (Get-FileHash -LiteralPath $BinaryPath).Hash -ne (Get-FileHash -LiteralPath $daemonPath).Hash) {
    Copy-Item -LiteralPath $BinaryPath -Destination $daemonPath
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'windows-bridge.ps1') -Destination $bridgePath

& ssh -n -o BatchMode=yes $HostAlias 'mkdir -p ~/.local/share/clipaste-codex'
if ($LASTEXITCODE -ne 0) { throw 'Cannot create the remote integration directory.' }
& scp (Join-Path $PSScriptRoot 'clipboard_hook.py') "${HostAlias}:.local/share/clipaste-codex/clipboard_hook.py"
if ($LASTEXITCODE -ne 0) { throw 'Cannot copy the remote hook.' }
& ssh -n -o BatchMode=yes $HostAlias "$RemotePython ~/.local/share/clipaste-codex/clipboard_hook.py install"
if ($LASTEXITCODE -ne 0) { throw 'Cannot install the Codex hook.' }

$arguments = "-NoProfile -WindowStyle Hidden -File `"$bridgePath`" -HostAlias $HostAlias"
$startup = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startup 'clipaste Codex bridge.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $powershellPath
$shortcut.Arguments = $arguments
$shortcut.WorkingDirectory = $installDirectory
$shortcut.WindowStyle = 7
$shortcut.Description = "Windows clipboard images for Codex on $HostAlias"
$shortcut.Save()
Start-Process -FilePath $powershellPath -ArgumentList $arguments -WindowStyle Hidden

$ready = $false
for ($attempt = 0; $attempt -lt 10; $attempt++) {
    Start-Sleep -Seconds 1
    & ssh -n -o BatchMode=yes -o ConnectTimeout=3 $HostAlias 'curl --noproxy "*" -fsS --max-time 2 http://127.0.0.1:18340/health' 2>$null
    if ($LASTEXITCODE -eq 0) { $ready = $true; break }
}
if (-not $ready) { throw "Tunnel not ready. See $installDirectory\bridge.log and ssh.stderr.log." }
& $daemonPath doctor --json
if ($LASTEXITCODE -ne 0) { throw 'The Windows clipboard daemon failed its health checks.' }
Write-Host "Ready for hook review. In Codex on $HostAlias, open /hooks and trust the clipaste hook once."
Write-Host 'Then copy a screenshot and submit: Explain this @clipboard'
