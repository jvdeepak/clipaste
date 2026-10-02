function Read-BridgeConfig([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($config.version -ne 1 -or $null -eq $config.hosts) { throw 'Invalid bridge config: expected version 1 and hosts.' }
    $seen = @{}
    foreach ($entry in @($config.hosts)) {
        if ($entry.alias -isnot [string] -or $entry.alias -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.@-]*$') { throw 'Invalid SSH alias.' }
        if ($seen.ContainsKey($entry.alias)) { throw "Duplicate SSH alias: $($entry.alias)" }
        if ($entry.remotePort -isnot [long] -and $entry.remotePort -isnot [int]) { throw 'Invalid remote port.' }
        if ($entry.remotePort -lt 1 -or $entry.remotePort -gt 65535) { throw 'Remote port must be 1-65535.' }
        if ($null -ne $entry.enabled -and $entry.enabled -isnot [bool]) { throw 'Host enabled must be true or false.' }
        if ($entry.remoteSocket -and ($entry.remoteSocket -cnotmatch '^/[A-Za-z0-9_./-]+/bridge\.sock$' -or '..' -in ($entry.remoteSocket -split '/'))) { throw 'Invalid private socket path.' }
        $seen[$entry.alias] = $true
        $entry
    }
}
function Write-BridgeConfig([string]$Path, [array]$Hosts) {
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        @{ version = 1; hosts = @($Hosts) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporary -Encoding utf8
        $null = @(Read-BridgeConfig $temporary)
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, "$temporary.bak") }
        else { [IO.File]::Move($temporary, $Path) }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
        if (Test-Path -LiteralPath "$temporary.bak") { Remove-Item -LiteralPath "$temporary.bak" }
    }
}
function Set-BridgeHost([string]$Path, [string]$Alias, [int]$Port = 18340, [switch]$Remove, [string]$RemoteSocket) {
    $lock = New-Object Threading.Mutex($false, 'Local\clipaste-codex-config')
    if (-not $lock.WaitOne(10000)) { $lock.Dispose(); throw 'Another bridge config update is in progress.' }
    try {
        $entries = @(Read-BridgeConfig $Path | Where-Object { $_.alias -ine $Alias })
        if (-not $Remove) {
            $entry = [pscustomobject]@{ alias = $Alias; remotePort = $Port }
            if ($RemoteSocket) { $entry | Add-Member -NotePropertyName remoteSocket -NotePropertyValue $RemoteSocket }
            $entries += $entry
        }
        Write-BridgeConfig $Path $entries
    } finally { $lock.ReleaseMutex(); $lock.Dispose() }
}
function Get-BridgeChanges([array]$Desired, [hashtable]$Current) {
    $Desired = @($Desired | Where-Object { $_.enabled -ne $false })
    $wanted = @{}
    foreach ($entry in $Desired) { $wanted[$entry.alias] = $entry }
    $stop = @($Current.Keys | Where-Object { -not $wanted.ContainsKey($_) -or $wanted[$_].remotePort -ne $Current[$_].remotePort })
    $start = @($Desired | Where-Object { -not $Current.ContainsKey($_.alias) -or $_.alias -in $stop })
    [pscustomobject]@{ Stop = $stop; Start = $start }
}
function Set-BridgeHostEnabled([string]$Path, [string]$Alias, [bool]$Enabled) {
    $lock = New-Object Threading.Mutex($false, 'Local\clipaste-codex-config')
    if (-not $lock.WaitOne(10000)) { $lock.Dispose(); throw 'Another config update is in progress.' }
    try {
        $entries = @(Read-BridgeConfig $Path)
        $entry = $entries | Where-Object alias -IEQ $Alias
        if (-not $entry) { throw "Unknown host: $Alias" }
        $entry | Add-Member -NotePropertyName enabled -NotePropertyValue $Enabled -Force
        Write-BridgeConfig $Path $entries
    } finally { $lock.ReleaseMutex(); $lock.Dispose() }
}
function Request-BridgeReconnect([string]$Directory, [string]$Alias = '') {
    if ($Alias -and $Alias -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.@-]*$') { throw 'Invalid SSH alias.' }
    $requests = Join-Path $Directory 'bridge-requests'
    New-Item -ItemType Directory -Force -Path $requests | Out-Null
    $name = Join-Path $requests ([guid]::NewGuid().ToString('N'))
    @{ action='reconnect'; alias=$Alias } | ConvertTo-Json | Set-Content -LiteralPath "$name.tmp" -Encoding utf8
    Move-Item -LiteralPath "$name.tmp" -Destination "$name.json"
}
function Get-BridgeHostKey([string]$Alias) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Alias.ToLowerInvariant())))).Replace('-', '').Substring(0, 16) }
    finally { $sha.Dispose() }
}
