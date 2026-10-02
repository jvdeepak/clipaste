param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.@-]*$')]
    [string]$HostAlias,
    [ValidatePattern('^python3(\.[0-9]+)?$')]
    [string]$RemotePython = 'python3.11',
    [ValidatePattern('^[A-Za-z0-9_./-]*$')]
    [string]$RemoteCodexDirectory = '',
    [switch]$RunCodex
)

# Run in pwsh -STA. This briefly replaces the clipboard and restores its formats.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Run with pwsh -STA.' }
$original = [Windows.Forms.Clipboard]::GetDataObject()
$saved = New-Object Windows.Forms.DataObject
if ($null -ne $original) {
    foreach ($format in $original.GetFormats($false)) {
        $value = $original.GetData($format, $false)
        if ($value -is [Drawing.Image]) { $value = $value.Clone() }
        if ($value -is [IO.MemoryStream]) { $value = [IO.MemoryStream]::new($value.ToArray()) }
        if ($null -ne $value) { $saved.SetData($format, $false, $value) }
    }
}

$bitmap = [Drawing.Bitmap]::new(640, 280)
$graphics = [Drawing.Graphics]::FromImage($bitmap)
$font = [Drawing.Font]::new('Arial', 32)
$code = Get-Random -Minimum 100000 -Maximum 999999
try {
    $graphics.Clear([Drawing.Color]::White)
    $graphics.FillEllipse([Drawing.Brushes]::Orange, 30, 30, 170, 170)
    $graphics.DrawString("TEST $code", $font, [Drawing.Brushes]::Black, 220, 90)
    [Windows.Forms.Clipboard]::SetImage($bitmap)
    $staged = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        Start-Sleep -Milliseconds 100
        $kind = Invoke-RestMethod 'http://127.0.0.1:18340/clipboard/type' -TimeoutSec 2
        if ($kind.type -eq 'image') { $staged = $true; break }
    }
    if (-not $staged) { throw 'Windows daemon did not capture the synthetic screenshot.' }
    if (-not [Windows.Forms.Clipboard]::ContainsImage()) { throw 'Daemon changed the image clipboard.' }
    Write-Host "Synthetic test image staged; verification code $code"

    $hookCommand = "~/.local/bin/uv run --offline --no-project --python $RemotePython ~/.codex/clipaste/clipboard_hook.py run --config ~/.codex/clipaste/endpoint.json"
    $eventJson = '{"hook_event_name":"UserPromptSubmit","prompt":"Inspect @clipboard"}'
    $hookOutput = $eventJson | & ssh -o BatchMode=yes $HostAlias $hookCommand
    if ($LASTEXITCODE -ne 0) { throw 'Remote hook failed to fetch the Windows image.' }
    $result = ($hookOutput -join "`n") | ConvertFrom-Json
    if ($result.hookSpecificOutput.additionalContext -notmatch 'view_image') { throw 'Missing image context.' }
    Write-Host 'PASS: Windows clipboard -> SSH tunnel -> remote hook -> image context'

    if ($RunCodex) {
        # One invocation of our reviewed hook only; no persistent trust bypass or sandbox change.
        $prefix = if ($RemoteCodexDirectory) { "env PATH=${RemoteCodexDirectory}:/usr/bin:/bin " } else { '' }
        $command = $prefix + 'timeout 90 codex exec --dangerously-bypass-hook-trust --sandbox read-only --skip-git-repo-check --ephemeral --json -C ~/.local/share/clipaste-codex "Read the verification code and name the colored shape in @clipboard. Do not modify any files. Reply in one short sentence."'
        $lines = & ssh -n -o BatchMode=yes $HostAlias $command
        $exitCode = $LASTEXITCODE
        $lines | ForEach-Object { Write-Host $_ }
        if ($exitCode -ne 0) { throw "Codex verification exited $exitCode" }
        $events = $lines | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} }
        $answers = $events | Where-Object { $_.item.type -eq 'agent_message' } |
            ForEach-Object { $_.item.text }
        $answer = $answers -join "`n"
        if ($answer -notmatch [string]$code -or $answer -notmatch 'orange' -or $answer -notmatch 'circle') {
            throw 'Codex did not correctly identify the synthetic image.'
        }
        Write-Host 'PASS: stock remote Codex understood the clipboard image'
    }

    [Windows.Forms.Clipboard]::SetText('clipaste integration test: no screenshot')
    Start-Sleep -Milliseconds 500
    $kind = Invoke-RestMethod 'http://127.0.0.1:18340/clipboard/type' -TimeoutSec 2
    if ($kind.type -ne 'empty') { throw 'Windows daemon retained a stale screenshot after copying text.' }
    $null = $eventJson | & ssh -o BatchMode=yes $HostAlias $hookCommand
    if ($LASTEXITCODE -ne 2) { throw 'Empty clipboard did not block the marked submission.' }
    Write-Host 'PASS: copying text invalidates the old screenshot and blocks @clipboard'
} finally {
    if ($null -ne $original) { [Windows.Forms.Clipboard]::SetDataObject($saved, $true) }
    else { [Windows.Forms.Clipboard]::Clear() }
    $font.Dispose()
    $graphics.Dispose()
    $bitmap.Dispose()
    Write-Host 'Original Windows clipboard restored.'
}
