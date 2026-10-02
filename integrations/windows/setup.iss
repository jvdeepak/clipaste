#ifndef BuildDir
  #define BuildDir "..\..\target\desktop"
#endif
#ifndef AppVersion
  #define AppVersion "2.6.1.0"
#endif
[Setup]
AppId={{A8A74E40-D630-4DAC-9B13-CCBB54A08DC6}
AppName=Clipaste SSH Clipboard
AppVersion={#AppVersion}
AppPublisher=Clipaste contributors
AppPublisherURL=https://github.com/jvdeepak/clipaste
DefaultDirName={localappdata}\clipaste
DisableDirPage=yes
DefaultGroupName=Clipaste
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#BuildDir}\installer
OutputBaseFilename=Clipaste-Setup-{#AppVersion}-x64
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\ClipasteTray.exe
CloseApplications=yes
RestartApplications=no
SetupLogging=yes

[Tasks]
Name: startup; Description: "Start Clipaste when I sign in to Windows"; Flags: checkedonce

[Files]
Source: "{#BuildDir}\ClipasteTray.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BuildDir}\ClipasteTray.exe"; DestName: "clipaste-shutdown.exe"; Flags: dontcopy
Source: "{#BuildDir}\clipaste.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\codex\clipboard_hook.py"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\codex\bridge.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\codex\bridge-config.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\codex\windows-bridge.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\codex\setup-windows.ps1"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Clipaste"; Filename: "{app}\ClipasteTray.exe"
Name: "{userstartup}\Clipaste"; Filename: "{app}\ClipasteTray.exe"; Parameters: "--background"; Tasks: startup

[InstallDelete]
Type: files; Name: "{userstartup}\clipaste Codex bridge.lnk"
Type: files; Name: "{userstartup}\Clipaste.lnk.lnk"

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueName: "clipaste"; Flags: deletevalue

[Run]
Filename: "{app}\ClipasteTray.exe"; Description: "Open Clipaste"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{app}\ClipasteTray.exe"; Parameters: "--shutdown"; Flags: runhidden waituntilterminated; RunOnceId: "StopClipaste"

[UninstallDelete]
Type: files; Name: "{app}\clipaste-bridge.cmd"

[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
var ResultCode: Integer;
begin
  ExtractTemporaryFile('clipaste-shutdown.exe');
  if not Exec(ExpandConstant('{tmp}\clipaste-shutdown.exe'), '--shutdown', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Result := 'Could not stop the existing clipboard bridge. Close Clipaste and retry.'
  else if ResultCode <> 0 then
    Result := 'The existing clipboard bridge is still stopping. Please retry in a moment.';
end;
