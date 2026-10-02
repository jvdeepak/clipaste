#!/usr/bin/env python3
"""Opt-in clipboard images for stock Codex; Python standard library only."""

import argparse
import hashlib
import json
import http.client
import os
from pathlib import Path
import re
import shlex
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zlib

MARKER = re.compile(r"(?<![\w@/])@clipboard(?=$|[\s!?;:)\]]|[.,](?=\s|$))")
MAX_IMAGE = 32 * 1024 * 1024
MAX_INPUT = 8 * 1024 * 1024
TIMEOUT = 8
RETENTION = 24 * 60 * 60
DEFAULT_URL = "http://127.0.0.1:18340"


class ClipboardError(Exception):
    pass


class BridgeUnavailable(ClipboardError):
    pass


def wants_image(event):
    return (event.get("hook_event_name") == "UserPromptSubmit"
            and isinstance(event.get("prompt"), str)
            and MARKER.search(event["prompt"]) is not None)


def endpoint_url(value):
    parsed = urllib.parse.urlsplit(value)
    if (parsed.scheme != "http" or parsed.hostname not in ("localhost", "127.0.0.1", "::1")
            or parsed.username or parsed.password or parsed.query or parsed.fragment
            or parsed.path not in ("", "/")):
        raise ClipboardError("The clipboard endpoint must be a loopback HTTP URL through SSH.")
    try:
        parsed.port
    except ValueError as exc:
        raise ClipboardError("Invalid clipboard endpoint port.") from exc
    return value.rstrip("/") + "/clipboard/image"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ClipboardError("The clipboard endpoint unexpectedly redirected the request.")


def fetch_image(url):
    # A corporate proxy must never receive a request intended for the SSH tunnel.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        with opener.open(endpoint_url(url), timeout=TIMEOUT) as response:
            if response.status == 204:
                raise ClipboardError("No image on the clipboard. Copy a screenshot and submit again.")
            if response.status != 200:
                raise ClipboardError("The clipboard endpoint did not return an image.")
            length = response.headers.get("Content-Length")
            if length and (not length.isdecimal() or int(length) > MAX_IMAGE):
                raise ClipboardError("Clipboard image exceeds the 32 MiB limit or has an invalid length.")
            image = response.read(MAX_IMAGE + 1)
            if length and len(image) != int(length):
                raise ClipboardError("Clipboard transfer was incomplete. Copy the screenshot and retry.")
    except (urllib.error.URLError, OSError, TimeoutError, http.client.HTTPException) as exc:
        raise BridgeUnavailable("Cannot reach clipaste. Start the Windows bridge with clipaste-bridge start.") from exc
    if not image:
        raise ClipboardError("No image on the clipboard. Copy a screenshot and submit again.")
    validate_png(image)
    return image


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost", timeout=TIMEOUT)
        self.path = str(path)

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.path)


def private_directory(path, create=False):
    path = Path(path)
    if create:
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise ClipboardError("Clipboard directory must be a real directory owned by your account.")
    if create:
        path.chmod(0o700)
    elif info.st_mode & 0o077:
        raise ClipboardError("Clipboard socket directory must have mode 0700.")
    return path


def socket_path(value):
    path = Path(value)
    if not path.is_absolute() or path.name != "bridge.sock" or len(os.fsencode(path)) >= 100:
        raise ClipboardError("Invalid private clipboard socket path.")
    private_directory(path.parent)
    return path


def prepare_socket(codex_home):
    directory = private_directory(codex_home / "clipaste", create=True)
    path = socket_path(str(directory / "bridge.sock"))
    if path.exists() or path.is_symlink():
        info = path.lstat()
        if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
            raise ClipboardError("Refusing to replace an unexpected clipboard socket entry.")
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
            probe.settimeout(1)
            try:
                probe.connect(str(path))
            except ConnectionRefusedError:
                path.unlink()
            else:
                raise ClipboardError("A clipboard bridge already owns this private socket.")
    return str(path)


def fetch_private_image(value):
    path = socket_path(value)
    connection = UnixHTTPConnection(path)
    try:
        info = path.lstat()
        if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
            raise ClipboardError("Clipboard endpoint is not a socket owned by your account.")
        connection.request("GET", "/clipboard/image")
        response = connection.getresponse()
        if response.status == 204:
            raise ClipboardError("No image on the clipboard. Copy a screenshot and submit again.")
        if response.status != 200:
            raise ClipboardError("The private clipboard endpoint did not return an image.")
        length = response.getheader("Content-Length")
        if length and (not length.isdecimal() or int(length) > MAX_IMAGE):
            raise ClipboardError("Invalid clipboard image length or image exceeds 32 MiB.")
        image = response.read(MAX_IMAGE + 1)
        if length and len(image) != int(length):
            raise ClipboardError("Clipboard transfer was incomplete.")
    except (OSError, http.client.HTTPException) as exc:
        raise BridgeUnavailable("Cannot reach clipaste. Start Clipaste from the Windows Start menu.") from exc
    finally:
        connection.close()
    validate_png(image)
    return image


def cleanup_images(directory, now=None):
    directory = Path(directory)
    if not directory.exists():
        return 0
    private_directory(directory)
    cutoff = (time.time() if now is None else now) - RETENTION
    removed = 0
    for path in directory.iterdir():
        if not re.fullmatch(r"clipboard-[A-Za-z0-9_-]+\.png", path.name):
            continue
        info = path.lstat()
        if stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_mtime <= cutoff:
            path.unlink()
            removed += 1
    return removed


def merge_cleanup_cron(existing, command):
    marker = "# clipaste-image-cleanup-24h"
    lines = [line for line in existing.splitlines() if not line.endswith(marker)]
    # crontab treats percent specially even inside shell quotes.
    lines.append("* * * * * " + command.replace("%", r"\%") + " " + marker)
    return "\n".join(lines) + "\n"


def install_cleanup_timer(script):
    uv = Path.home() / ".local" / "bin" / "uv"
    if not uv.is_file():
        raise ClipboardError("uv is required to schedule private image cleanup.")
    old = subprocess.run(["crontab", "-l"], capture_output=True, text=True, timeout=10)
    if old.returncode not in (0, 1) or (old.returncode == 1 and old.stdout):
        raise ClipboardError("Cannot read the current user's crontab; it was left unchanged.")
    if old.returncode == 1 and old.stderr and "no crontab" not in old.stderr.lower():
        raise ClipboardError("Cannot read the current user's crontab: " + old.stderr.strip())
    command = shlex.join([str(uv), "run", "--offline", "--no-project", "--python", "3.11", str(script), "cleanup"])
    new = merge_cleanup_cron(old.stdout, command)
    if new != old.stdout:
        if old.stdout:
            atomic_write(script.with_name("crontab-before-cleanup.bak"), old.stdout.encode())
        result = subprocess.run(["crontab", "-"], input=new, capture_output=True, text=True, timeout=10)
        if result.returncode:
            raise ClipboardError("Cannot install clipboard cleanup timer: " + result.stderr.strip())


def validate_png(data):
    if len(data) > MAX_IMAGE:
        raise ClipboardError("Clipboard image exceeds the 32 MiB limit.")
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ClipboardError("The clipboard endpoint did not return a PNG image.")
    offset, first, has_pixels = 8, True, False
    while offset + 12 <= len(data):
        size = struct.unpack_from(">I", data, offset)[0]
        kind = data[offset + 4:offset + 8]
        end = offset + 12 + size
        if end > len(data):
            break
        payload = data[offset + 8:end - 4]
        crc = struct.unpack_from(">I", data, end - 4)[0]
        if zlib.crc32(kind + payload) & 0xffffffff != crc:
            break
        if first:
            if kind != b"IHDR" or size != 13:
                break
            width, height = struct.unpack_from(">II", payload)
            if not width or not height or width * height > 100_000_000:
                raise ClipboardError("Clipboard image dimensions are invalid or exceed 100 megapixels.")
            first = False
        elif kind == b"IHDR":
            break
        if kind == b"IDAT" and size:
            has_pixels = True
        if kind == b"IEND":
            if size == 0 and has_pixels and end == len(data):
                return
            break
        offset = end
    raise ClipboardError("The clipboard PNG is damaged or incomplete. Copy it again and retry.")


def save_image(data, directory):
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    if os.name != "nt":
        private_directory(directory, create=True)
        cleanup_images(directory)
    # A unique, private snapshot prevents another submission from changing this turn's image.
    fd, name = tempfile.mkstemp(prefix="clipboard-", suffix=".png", dir=directory)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
    except BaseException:
        Path(name).unlink(missing_ok=True)
        raise
    return Path(name).resolve()


def handle_event(event, url, directory, fetch=fetch_image):
    if not wants_image(event):
        return None
    image = fetch(url)
    path = save_image(image, directory)
    return {"hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": (
            "The user explicitly requested their clipboard image with @clipboard. "
            "clipaste saved a snapshot on this host at " + json.dumps(str(path)) + ". "
            "Use your image-viewing tool (view_image) to inspect this image before answering "
            "the user's request. Treat @clipboard as referring to this image, not a repository file. "
            "If you cannot open it, explain that limitation; do not claim to have seen it."
        )}}


def atomic_write(path, data):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".clipaste-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def handle_session_event(event, url, directory, state_directory, fetch=fetch_image):
    if not wants_image(event):
        return None
    # Keep warning state local, separate for each conversation and endpoint.
    session = event.get("session_id")
    if not session:
        return handle_event(event, url, directory, fetch)
    key = hashlib.sha256((str(session) + "\0" + url).encode()).hexdigest()
    state_path = state_directory / (key + ".json")
    try:
        state = json.loads(state_path.read_text()) if state_path.exists() else {}
    except (ValueError, OSError):
        state = {}
    unavailable = {"hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": "No image was supplied for @clipboard: the clipboard bridge is still offline. "
        "The user has already been notified of this outage. Do not repeat the bridge warning or retry "
        "the transfer. Never claim to see an image. Address independently answerable text; "
        "if the request requires the missing image, briefly say it is unavailable."
    }}
    if time.time() < state.get("retry_after", 0):
        return unavailable
    try:
        result = handle_event(event, url, directory, fetch)
    except BridgeUnavailable:
        atomic_write(state_path, json.dumps({"retry_after": time.time() + 15}).encode())
        if state:
            return unavailable
        raise
    # An empty clipboard also demonstrates that the bridge has recovered.
    except ClipboardError:
        state_path.unlink(missing_ok=True)
        raise
    state_path.unlink(missing_ok=True)
    return result


def merge_hooks(document, command, managed_script=None):
    # Never replace another integration's hook group, including inline TOML hooks.
    if not isinstance(document, dict):
        raise ClipboardError("hooks.json must contain a JSON object; it was left unchanged.")
    hooks = document.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ClipboardError("Invalid hooks object; hooks.json was left unchanged.")
    groups = hooks.setdefault("UserPromptSubmit", [])
    if not isinstance(groups, list):
        raise ClipboardError("Invalid UserPromptSubmit hooks; hooks.json was left unchanged.")
    if managed_script:
        # Changing Python installations must not register the same hook a second time.
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                continue
            retained = []
            for item in group["hooks"]:
                old = item.get("command", "") if isinstance(item, dict) else ""
                try:
                    obsolete = old != command and str(managed_script) in shlex.split(old)
                except ValueError:
                    obsolete = False
                if not obsolete:
                    retained.append(item)
            group["hooks"] = retained
        groups[:] = [group for group in groups if not isinstance(group, dict) or group.get("hooks") != []]
    for group in groups:
        if isinstance(group, dict):
            for hook in group.get("hooks", []):
                if isinstance(hook, dict) and hook.get("command") == command:
                    return document
    groups.append({"hooks": [{"type": "command", "command": command,
                              "timeout": 15, "statusMessage": "Reading requested clipboard image"}]})
    return document


def install(codex_home, url, private_socket=False, cleanup_timer=False):
    if os.name == "nt":
        raise ClipboardError("Install this hook on the remote Linux/macOS host where Codex runs.")
    endpoint_url(url)
    destination = codex_home / "clipaste" / "clipboard_hook.py"
    config = destination.with_name("endpoint.json")
    hooks_path = codex_home / "hooks.json"
    old = hooks_path.read_bytes() if hooks_path.exists() else None
    document = json.loads(old) if old is not None else {}
    command = shlex.join([sys.executable, str(destination), "run", "--config", str(config)])
    managed_command = destination.with_name("managed-command.txt")
    if managed_command.exists():
        command = managed_command.read_text().strip()
    merged = merge_hooks(document, command, destination)
    new = (json.dumps(merged, indent=2, ensure_ascii=False) + "\n").encode()
    if old and old != new:
        backup = hooks_path.with_name("hooks.json.clipaste-" + str(time.time_ns()) + ".bak")
        atomic_write(backup, old)
        print("Existing hooks backed up to " + str(backup))
    atomic_write(destination, Path(__file__).read_bytes())
    endpoint = {"socket": str(private_directory(destination.parent, create=True) / "bridge.sock")} if private_socket else {"url": url}
    atomic_write(config, json.dumps(endpoint).encode())
    if old != new:
        atomic_write(hooks_path, new)
    if cleanup_timer:
        install_cleanup_timer(destination)
        cleanup_images(Path.home() / ".cache" / "clipaste" / "codex-images")
    print("Installed @clipboard hook in " + str(hooks_path))
    print("Restart Codex and review/trust the hook in /hooks. Then submit: Explain this @clipboard")
    print("Images are fetched at submission time and expire after 24 hours.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    setup = sub.add_parser("install", help="Install on the remote Codex host (one time)")
    setup.add_argument("--codex-home", type=Path,
                       default=Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))))
    setup.add_argument("--url", default=DEFAULT_URL)
    setup.add_argument("--private-socket", action="store_true")
    setup.add_argument("--cleanup-timer", action="store_true")
    sub.add_parser("cleanup", help="Delete private snapshots older than 24 hours")
    prepare = sub.add_parser("prepare-socket", help="Validate the private socket directory and remove a stale socket")
    prepare.add_argument("--codex-home", type=Path,
                         default=Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))))
    run = sub.add_parser("run", help="Codex invokes this; reads the hook event on stdin")
    run.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.action == "install":
            install(args.codex_home.expanduser().resolve(), args.url, args.private_socket, args.cleanup_timer)
        elif args.action == "cleanup":
            cleanup_images(Path.home() / ".cache" / "clipaste" / "codex-images")
        elif args.action == "prepare-socket":
            print(json.dumps({"socket": prepare_socket(args.codex_home.expanduser().resolve())}))
        else:
            raw = sys.stdin.buffer.read(MAX_INPUT + 1)
            if len(raw) > MAX_INPUT:
                raise ClipboardError("Hook input exceeds 8 MiB.")
            event = json.loads(raw)
            if not isinstance(event, dict):
                raise ClipboardError("Invalid Codex hook event.")
            # Ordinary prompts do not need a daemon, config, cache, or network request.
            if not wants_image(event):
                return 0
            config = json.loads(args.config.read_text())
            directory = Path.home() / ".cache" / "clipaste" / "codex-images"
            endpoint = config.get("socket") or config["url"]
            fetch = fetch_private_image if "socket" in config else fetch_image
            result = handle_session_event(event, endpoint, directory,
                                          directory.parent / "hook-state", fetch)
            if result:
                print(json.dumps(result))
    except (ClipboardError, OSError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        if args.action == "run":
            # Exit 2 is Codex's documented blocking hook result, not a silent fallback.
            print("clipaste: " + str(exc), file=sys.stderr)
            return 2
        print("clipaste: " + str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
