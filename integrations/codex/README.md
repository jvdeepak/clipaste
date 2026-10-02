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
submission gets its own immutable image file that expires after 24 hours. Ordinary prompts never access
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

Use the [graphical Windows installer](../windows/README.md). It provides a tray
app, host controls, live clipboard previews, logs, startup and uninstall.
No PowerShell commands are required. Existing hosts migrate automatically.

Each remote uses `$CODEX_HOME/clipaste/bridge.sock` (normally
`~/.codex/clipaste/bridge.sock`) inside an account-owned directory with mode 0700.
The native bridge never creates a shared remote TCP clipboard port. Other ordinary
users cannot traverse the socket directory. Your own account and remote root
remain trusted. SSH aliases with inherited forwarding directives are rejected
rather than silently exposing an additional port. No insecure fallback is used.

The Add host dialog installs the runtime, private endpoint and a per-user cleanup
cron job. Remote setup requires uv, Python 3.11, OpenSSH Unix-domain forwarding and
working crontab support. Existing cron entries and portable hook registrations are
preserved. Each host still needs one-time Codex `/hooks` review.

Images expire after 24 hours. The Windows daemon sweeps its cache every minute
while running and at startup; each remote independently sweeps its private Codex
snapshot directory every minute through cron. Cleanup also runs on marked image
submissions. A sleeping/offline machine catches up once it runs again. Old image
paths in conversations therefore stop working after expiry. Cleanup skips symlinks
and unrelated files. Removing the Windows app does not remove the remote cleanup job.

The old script supervisor delegates to the native app. The legacy upstream TCP
helpers described elsewhere are separate from this private Codex integration;
this integration does not install Claude clipboard shims.

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
