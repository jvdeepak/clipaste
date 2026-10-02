$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'bridge-config.ps1')
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
$temporary = Join-Path ([IO.Path]::GetTempPath()) "clipaste-config-$([guid]::NewGuid().ToString('N')).json"
try {
    Set-BridgeHost $temporary 'first'
    Set-BridgeHost $temporary 'second' 19340
    Set-BridgeHost $temporary 'FIRST'
    $entries = @(Read-BridgeConfig $temporary)
    Assert ($entries.Count -eq 2) 'Adding/reinstalling a host replaced or duplicated another host'
    $current = @{ first = @{remotePort=18340}; second = @{remotePort=19340} }
    $changes = Get-BridgeChanges $entries $current
    Assert ($changes.Stop.Count -eq 0 -and $changes.Start.Count -eq 0) 'Unchanged tunnels restarted'
    Set-BridgeHostEnabled $temporary 'first' $false
    $changes = Get-BridgeChanges @(Read-BridgeConfig $temporary) $current
    Assert ($changes.Stop.Count -eq 1 -and $changes.Stop[0] -eq 'first') 'Pausing one host affected another'
    Set-BridgeHostEnabled $temporary 'first' $true
    Set-BridgeHost $temporary 'second' 20340
    $changes = Get-BridgeChanges @(Read-BridgeConfig $temporary) $current
    Assert ($changes.Stop.Count -eq 1 -and $changes.Stop[0] -eq 'second') 'Port update disrupted unrelated host'
    Set-BridgeHost $temporary 'second' -Remove
    Assert (@(Read-BridgeConfig $temporary).Count -eq 1) 'Removal lost other hosts'
    $original = Get-Content $temporary -Raw
    try { Set-BridgeHost $temporary '-bad'; throw 'Accepted invalid alias' } catch { Assert ($_.Exception.Message -ne 'Accepted invalid alias') 'Accepted invalid alias' }
    Assert ((Get-Content $temporary -Raw) -eq $original) 'Invalid update modified config'
    Set-BridgeHost $temporary 'first' -Remove
    Assert (@(Read-BridgeConfig $temporary).Count -eq 0) 'Removing last host failed'
    Assert ((Get-BridgeHostKey 'A') -eq (Get-BridgeHostKey 'a')) 'Log keys differ by case'
    Write-Output 'PASS: add, deduplicate, preserve, change-port, remove, empty-config and invalid-config cases'
} finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
