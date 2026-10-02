param(
    [string]$DaemonPath = "$PSScriptRoot\..\..\target\release\clipaste.exe",
    [string]$InnoCompiler = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    [switch]$SkipInstaller
)
$ErrorActionPreference = 'Stop'
$output = [IO.Path]::GetFullPath("$PSScriptRoot\..\..\target\desktop")
New-Item -ItemType Directory -Force -Path $output | Out-Null
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe "/out:$output\ClipasteTray.exe" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll "$PSScriptRoot\ClipasteTray.cs"
if ($LASTEXITCODE -ne 0) { throw 'Desktop compilation failed.' }
$test = Start-Process "$output\ClipasteTray.exe" -ArgumentList '--self-test' -WindowStyle Hidden -PassThru -Wait
if ($test.ExitCode -ne 0) { throw 'Desktop self-test failed.' }
Copy-Item -LiteralPath $DaemonPath -Destination "$output\clipaste.exe"
if (-not $SkipInstaller) {
    & $InnoCompiler "/DBuildDir=$output" "$PSScriptRoot\setup.iss"
    if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed.' }
    Get-FileHash "$output\installer\*.exe" -Algorithm SHA256
}
