#!/usr/bin/env python3
"""Opt-in clipboard images for stock Codex; Python standard library only."""

import argparse
import json
import http.client
import os
from pathlib import Path
import re
import shlex
import struct
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
DEFAULT_URL = "http://127.0.0.1:18340"


class ClipboardError(Exception):
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
        raise ClipboardError("Cannot reach clipaste. Check the Windows daemon and reconnect SSH.") from exc
    if not image:
        raise ClipboardError("No image on the clipboard. Copy a screenshot and submit again.")
    validate_png(image)
    return image


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


def merge_hooks(document, command):
    # Never replace another integration's hook group, including inline TOML hooks.
    if not isinstance(document, dict):
        raise ClipboardError("hooks.json must contain a JSON object; it was left unchanged.")
    hooks = document.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ClipboardError("Invalid hooks object; hooks.json was left unchanged.")
    groups = hooks.setdefault("UserPromptSubmit", [])
    if not isinstance(groups, list):
        raise ClipboardError("Invalid UserPromptSubmit hooks; hooks.json was left unchanged.")
    for group in groups:
        if isinstance(group, dict):
            for hook in group.get("hooks", []):
                if isinstance(hook, dict) and hook.get("command") == command:
                    return document
    groups.append({"hooks": [{"type": "command", "command": command,
                              "timeout": 15, "statusMessage": "Reading requested clipboard image"}]})
    return document


def install(codex_home, url):
    if os.name == "nt":
        raise ClipboardError("Install this hook on the remote Linux/macOS host where Codex runs.")
    endpoint_url(url)
    destination = codex_home / "clipaste" / "clipboard_hook.py"
    config = destination.with_name("endpoint.json")
    hooks_path = codex_home / "hooks.json"
    old = hooks_path.read_bytes() if hooks_path.exists() else None
    document = json.loads(old) if old is not None else {}
    command = shlex.join([sys.executable, str(destination), "run", "--config", str(config)])
    merged = merge_hooks(document, command)
    new = (json.dumps(merged, indent=2, ensure_ascii=False) + "\n").encode()
    if old and old != new:
        backup = hooks_path.with_name("hooks.json.clipaste-" + str(time.time_ns()) + ".bak")
        atomic_write(backup, old)
        print("Existing hooks backed up to " + str(backup))
    atomic_write(destination, Path(__file__).read_bytes())
    atomic_write(config, json.dumps({"url": url}).encode())
    if old != new:
        atomic_write(hooks_path, new)
    print("Installed @clipboard hook in " + str(hooks_path))
    print("Restart Codex and review/trust the hook in /hooks. Then submit: Explain this @clipboard")
    print("Images are fetched at submission time and retained in ~/.cache/clipaste/codex-images.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    setup = sub.add_parser("install", help="Install on the remote Codex host (one time)")
    setup.add_argument("--codex-home", type=Path,
                       default=Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))))
    setup.add_argument("--url", default=DEFAULT_URL)
    run = sub.add_parser("run", help="Codex invokes this; reads the hook event on stdin")
    run.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.action == "install":
            install(args.codex_home.expanduser().resolve(), args.url)
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
            result = handle_event(event, config["url"], directory)
            if result:
                print(json.dumps(result))
    except (ClipboardError, OSError, ValueError, KeyError) as exc:
        if args.action == "run":
            # Exit 2 is Codex's documented blocking hook result, not a silent fallback.
            print("clipaste: " + str(exc), file=sys.stderr)
            return 2
        print("clipaste: " + str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
