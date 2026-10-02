# Clipboard images in stock Codex over SSH

Copy a screenshot on Windows, then send a prompt such as:

> Fix the layout shown here @clipboard

Codex's `UserPromptSubmit` hook retrieves the screenshot through an SSH tunnel,
saves a private PNG on the remote host, and tells Codex to open it with
`view_image` before answering. No manual file saving, uploading, paths, terminal
switching, custom Codex build, or Alacritty keybinding is required.

This is a submit-time image workflow, not an attachment preview in the composer.
The screenshot that is on the clipboard **when you submit** is the one used.
Keep the screenshot on the clipboard while typing your prompt. Each marked
submission gets its own immutable image file. Ordinary prompts never access
the clipboard. A failed transfer or empty clipboard blocks the marked submission
with a useful error. Codex must have its `view_image` tool available.

## One-time remote setup

Requires stock Codex with `UserPromptSubmit` hooks (verified target: 0.160.0),
Python 3.9 or later, and the clipaste Windows daemon/tunnel. No Python packages
are needed. On RHEL 8, use `python3.11` rather than the system Python 3.6.

Copy `clipboard_hook.py` to the remote server and run:

```sh
python3.11 clipboard_hook.py install
```

The installer copies the hook into `$CODEX_HOME/clipaste` (default `~/.codex/clipaste`)
and merges a `UserPromptSubmit` entry into `hooks.json`. Existing hooks are kept
and changed JSON is backed up. Repeating installation updates the script without
duplicating its hook. Use `--url http://127.0.0.1:PORT` for a different SSH port
forward endpoint, or `--codex-home /path/to/config` for a specific Codex home.

Restart Codex and open **`/hooks` to review and trust the clipaste hook once**.
Codex requires this review for new or changed hook definitions. The installer
does not bypass trust or modify your other Codex settings.

## Windows bridge

Use a build of this fork: the upstream v2.5.0 Windows release does not support
server-only mode. The fork also clears stale screenshots when the clipboard is
changed to text, and captures an image already on the clipboard at startup.

From this repository on Windows, one command installs the remote hook, creates
the Windows Startup shortcut, starts the bridge, and checks the tunnel:

```powershell
.\integrations\codex\setup-windows.ps1 -HostAlias stssgoffmgt01-rh8 -BinaryPath .\target\release\clipaste.exe
```

Alternatively, point `-BinaryPath` to `clipaste.exe` downloaded from this fork's
`clipaste-windows` Check workflow artifact. `-RemotePython python3.11` is the
default; specify another Python 3.9+ executable if needed. After installation,
review the hook once in Codex `/hooks`.

For manual setup:

Place `clipaste.exe` and `windows-bridge.ps1` in `%LOCALAPPDATA%\clipaste`, then run:

```powershell
pwsh.exe -NoProfile -WindowStyle Hidden -File "$env:LOCALAPPDATA\clipaste\windows-bridge.ps1" -HostAlias stssgoffmgt01-rh8
```

Create a Windows Startup shortcut with the same command for automatic login
startup. The bridge keeps one SSH tunnel open, reconnects after disconnects,
and starts/restarts the clipboard daemon in server-only mode. Existing Alacritty
connections use it without reconnecting or changing their launch command. SSH
must already authenticate non-interactively; normal host-key verification is
retained. For other hosts, change the alias; this supervisor currently supports
one configured remote host per Windows login.

Do not also add the same `RemoteForward` through `clipaste ssh-setup` for this
host. The supervisor owns the port so multiple Alacritty windows can share it.
Its endpoint is accessible to processes on the remote machine, as with upstream
clipaste; use this with a trusted remote host. It never binds a public address.

Logs are in `%LOCALAPPDATA%\clipaste\bridge.log` and `ssh.stderr.log`.
To stop its tunnel, create `%LOCALAPPDATA%\clipaste\bridge.stop`. Remove the
Startup shortcut to disable login startup. The clipboard daemon is left running
for other consumers. To remove the Codex integration, remove its one hook entry
from `hooks.json` and the `clipaste` subdirectory; leave other hook entries intact.

Images are retained in `~/.cache/clipaste/codex-images` with mode `0600` and are
not automatically deleted, so older conversations retain their image paths.
Delete unwanted images there when no longer needed.

Claude Code's existing clipboard-helper workflow remains available; the daemon
and tunnel can be shared. This feature itself installs only a Codex hook.

## Verification

```sh
python3.11 -m unittest discover -s integrations/codex -v
```

Tests cover marker matching, no access for ordinary prompts, private snapshots,
empty/error/oversized responses, PNG integrity, timeouts, loopback-only URLs,
installer idempotency, existing-hook preservation, and the blocking exit code.
Also verify a real Windows clipboard image through the tunnel and a real Codex
turn; unit tests do not establish end-to-end image understanding.

The Windows smoke test temporarily stages a synthetic screenshot, restores the
original clipboard afterwards, and checks that copying text invalidates it:

```powershell
pwsh -STA -NoProfile -File .\integrations\codex\test-windows.ps1 -HostAlias stssgoffmgt01-rh8
```

Add `-RunCodex` to run a read-only Codex turn that identifies a random code and
colored shape. If Node/Codex is installed through nvm and unavailable to
non-interactive SSH commands, also set `-RemoteCodexDirectory` to its remote
`bin` directory. This test uses Codex's documented one-invocation hook-trust
bypass for the reviewed test hook; it does not persist trust or bypass the
read-only sandbox. Use it only after reviewing all enabled hooks on that host.

Verified on Windows -> `stssgoffmgt01-rh8` (RHEL 8, Python 3.11, stock Codex
0.160.0): the model correctly identified the random code and orange circle;
text copying cleared the staged screenshot; and terminating only the managed
SSH tunnel caused the supervisor to reconnect and restore the endpoint.
