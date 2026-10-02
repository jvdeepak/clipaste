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
the clipboard. An empty or damaged image blocks the marked submission. When the
bridge is offline, the first marked request reports an error; subsequent requests
in the same Codex session suppress duplicate hook errors and tell the model that
no image was supplied. A 15-second cooldown avoids repeated connection attempts.
Recovery resets the warning state. Codex must have `view_image` available.

## One-time remote setup

Requires stock Codex with `UserPromptSubmit` hooks (verified target: 0.160.0),
Python 3.9 or later, uv, and the clipaste Windows daemon/tunnel. No Python packages
are needed. On RHEL 8, use `python3.11` rather than the system Python 3.6.

Copy `clipboard_hook.py` to the remote server and run:

```sh
uv run --offline --no-project --python 3.11 clipboard_hook.py install
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

**Recommended:** use the [Windows desktop installer](../windows/README.md).
It provides a setup wizard, notification-area app, independent host controls,
live text/image preview, logs, automatic startup and uninstall. It preserves
existing host settings and does not require PowerShell commands. The commands
below remain available for development and older script-based installations.

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

After the first installation, use these commands in a new Windows shell:

```powershell
clipaste-bridge add sgxmgt01-rh8
clipaste-bridge status
clipaste-bridge start
clipaste-bridge stop
clipaste-bridge remove sgxmgt01-rh8
```

`add` installs the remote hook and registers an SSH alias without replacing other
hosts. One Windows clipboard daemon is shared by independent tunnels for all
configured hosts. Each tunnel reconnects independently, with backoff up to 60
seconds. Adding/removing a host hot-reloads the config and leaves other tunnels
alone. Multiple Alacritty windows share their server's tunnel; keep using your
normal `ssh HOST` commands. SSH must authenticate non-interactively, with normal
host-key verification. Removing a host closes its tunnel but retains remote hook
files and previously saved images. Each server needs the one-time hook review.

The host list lives in `%LOCALAPPDATA%\clipaste\bridge-hosts.json`. The Startup
shortcut launches the supervisor without a hostname. Old single-host launch
commands and shortcuts are migrated without dropping their original host.
Each distinct server can use remote port 18340; `add HOST -RemotePort 19340`
selects a different port if needed. Do not configure two aliases for the same
physical server/listen port. `status` reports SSH process state, not a remote
health guarantee; setup also checks the remote HTTP endpoint.

Do not also add the same `RemoteForward` through `clipaste ssh-setup` for this
host. The supervisor owns the port so multiple Alacritty windows can share it.
Its endpoint is accessible to processes on the remote machine, as with upstream
clipaste; use this with a trusted remote host. It never binds a public address.

Logs are in `%LOCALAPPDATA%\clipaste\bridge.log` and per-host `ssh-*.stderr.log`
files (the exact path appears in `status`). To stop all tunnels, run
`clipaste-bridge stop`. Remove the
Startup shortcut to disable login startup. The clipboard daemon is left running
for other consumers. To remove the Codex integration, remove its one hook entry
from `hooks.json` and the `clipaste` subdirectory; leave other hook entries intact.

Images are retained in `~/.cache/clipaste/codex-images` with mode `0600` and are
not automatically deleted, so older conversations retain their image paths.
Delete unwanted images there when no longer needed.

Claude Code's existing clipboard-helper workflow remains available; the daemon
and tunnel can be shared. This feature itself installs only a Codex hook.

## Portable Codex settings

Keep the portable launcher and hook registration in your Codex settings repo,
while this fork remains the source of the hook runtime. Host endpoints, images,
warning state, and trust hashes belong outside Git. A settings installer may
write its reviewed launcher command to `$CODEX_HOME/clipaste/managed-command.txt`;
clipaste's installer then preserves that command during runtime/endpoint updates.
It also migrates old registrations of the same script when the Python path changes.

## Verification

```sh
uv run --offline --no-project --python 3.11 python -m unittest discover -s integrations/codex -v
```

Tests cover marker matching, no access for ordinary prompts, private snapshots,
empty/error/oversized responses, PNG integrity, timeouts, loopback-only URLs,
installer idempotency, existing-hook preservation, outage suppression/recovery,
and the blocking exit code. Run `test-bridge-config.ps1` for multi-host config
updates, deduplication, and isolation tests.
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
Multi-host verification additionally covered clipboard transfer to `sgxmgt01-rh8`,
an unreachable third host, removal, and recovery of one tunnel without restarting
the other. A subprocess test verified one warning per session while offline.
