# Windows desktop installer

Double-click `Clipaste-Setup-2.6.0.1-x64.exe` and follow the setup wizard. It installs
for the current Windows user, adds a Start menu shortcut and an uninstall entry,
and offers automatic startup at sign-in. No administrator privileges, PowerShell
commands, or custom Codex build are needed. Windows x64, .NET Framework 4.x and
Windows OpenSSH Client are required; the app uses your existing SSH configuration
and key authentication. The installer bundles the clipboard daemon.

Existing `bridge-hosts.json` settings are preserved. Setup gracefully stops the
old bridge and replaces its Startup shortcut. Uninstall stops the app and its
dedicated SSH tunnels; host settings, logs, cached images and remote hooks remain.
An upgrade does not reset per-host stopped/running preferences.

Open **Clipaste** from Start or double-click its notification-area icon:

- The host list shows confirmed SSH forwarding, connection attempts and retries.
- Select a host to **Start**, **Stop**, **Reconnect**, read its **Host log**, or
  **Remove** it. Other hosts' connections continue running.
- **Add host** accepts an existing Windows SSH alias and can install/update the
  Codex hook. Remote setup requires `~/.local/bin/uv` and Python 3.11; failures
  appear in the app and `setup.log`. Remote Codex still requires one-time `/hooks`
  review. Existing portable hook registrations are preserved.
- The live clipboard pane previews text or an image. Text previews are limited
  to 8,000 characters. The tray icon changes to **T** or **I**, with a green dot
  when at least one host is connected. Hover shows the connection count/type;
  the tray menu also shows image dimensions or text character count.
- Right-click the icon for all-host controls, the bridge log, logs folder, or
  **Quit Clipaste and stop bridge**. Closing the dashboard merely hides it.

Clipboard contents are never written to application logs or shown in repeated
popup notifications. Image serving remains loopback-only and server-only mode
preserves normal Windows clipboard formats. The Codex workflow remains: copy an
image, then submit a prompt containing `@clipboard` from your usual Alacritty SSH
session. Text continues to use ordinary terminal paste.

## Development

The desktop app uses Windows-provided WinForms/.NET Framework and OpenSSH, with
no new runtime packages. `build.ps1` compiles using the framework compiler,
runs isolated configuration tests, and packages an Inno Setup wizard. Build
the Rust daemon with `cargo build --locked --release` first. Inno Setup 6 or 7
is a build dependency only; pass `-InnoCompiler PATH` if it is not in the default
Inno Setup 6 directory. `-SkipInstaller` builds only the desktop binaries.

`test-desktop.ps1` is an opt-in STA desktop test: it checks actual clipboard
notifications, text/image preview transitions and close-to-tray behavior, renders
a synthetic preview into `target/desktop/preview.png`, and restores the clipboard.
`integrations/codex/test-windows.ps1` tests image delivery through a real SSH host.
Default self-tests perform no network or clipboard access and use a temporary
configuration directory. The installer is currently unsigned.
