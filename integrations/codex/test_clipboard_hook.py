import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import socket
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zlib

SCRIPT = Path(__file__).with_name("clipboard_hook.py")
spec = importlib.util.spec_from_file_location("clipboard_hook", SCRIPT)
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


PNG = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(b"\0\xff\0\0"))
       + chunk(b"IEND", b""))


class HookTests(unittest.TestCase):
    @unittest.skipIf(os.name == "nt", "Unix account permissions")
    def test_private_socket_directory_and_stale_socket_handling(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            path = Path(hook.prepare_socket(home))
            self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(str(path))
                server.listen(1)
                with self.assertRaisesRegex(hook.ClipboardError, "already owns"):
                    hook.prepare_socket(home)
            self.assertTrue(path.exists())
            hook.prepare_socket(home)
            self.assertFalse(path.exists())
            path.symlink_to(home / "unrelated")
            with self.assertRaises(hook.ClipboardError):
                hook.prepare_socket(home)
            self.assertTrue(path.is_symlink())
            path.parent.chmod(0o755)
            with self.assertRaisesRegex(hook.ClipboardError, "0700"):
                hook.socket_path(str(path))

    @unittest.skipIf(os.name == "nt", "Unix account permissions")
    def test_cleanup_24_hour_boundary_and_safe_file_selection(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            images = root / "images"
            images.mkdir(mode=0o700)
            old = images / "clipboard-old.png"
            fresh = images / "clipboard-new.png"
            unrelated = images / "unrelated.png"
            for file in (old, fresh, unrelated):
                file.write_bytes(PNG)
            os.utime(old, (0, 0))
            os.utime(fresh, (1, 1))
            os.utime(unrelated, (0, 0))
            link = images / "clipboard-link.png"
            link.symlink_to(unrelated)
            self.assertEqual(hook.cleanup_images(images, now=hook.RETENTION), 1)
            self.assertFalse(old.exists())
            self.assertTrue(fresh.exists())
            self.assertTrue(link.is_symlink())
            self.assertTrue(unrelated.exists())

    def test_cleanup_cron_preserves_existing_jobs_and_is_idempotent(self):
        original = "CRON_TZ=Asia/Singapore\n*/5 * * * * existing-job\n"
        merged = hook.merge_cleanup_cron(original, "uv run script cleanup")
        self.assertTrue(merged.startswith(original))
        self.assertEqual(hook.merge_cleanup_cron(merged, "uv run script cleanup"), merged)
        self.assertIn(r"\%", hook.merge_cleanup_cron(original, "'path%name' cleanup"))

    @unittest.skipIf(os.name == "nt", "Unix account permissions")
    def test_missing_private_socket_is_quiet_bridge_outage(self):
        with tempfile.TemporaryDirectory() as temp:
            path = hook.prepare_socket(Path(temp))
            with self.assertRaises(hook.BridgeUnavailable):
                hook.fetch_private_image(path)

    @unittest.skipIf(os.name == "nt", "Unix account permissions")
    def test_private_fetch_checks_socket_owner_and_validates_image(self):
        with tempfile.TemporaryDirectory() as temp:
            path = hook.prepare_socket(Path(temp))
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(path)
                with mock.patch.object(hook, "UnixHTTPConnection") as connection:
                    response = self.response(PNG)
                    response.getheader = response.headers.get
                    connection.return_value.getresponse.return_value = response
                    self.assertEqual(hook.fetch_private_image(path), PNG)
                    connection.return_value.request.assert_called_once_with("GET", "/clipboard/image")
                    connection.return_value.close.assert_called_once()
            Path(path).unlink()
            Path(path).write_bytes(PNG)
            with self.assertRaisesRegex(hook.ClipboardError, "not a socket"):
                hook.fetch_private_image(path)

    def event(self, prompt):
        return {"hook_event_name": "UserPromptSubmit", "prompt": prompt}

    def test_explicit_marker_only(self):
        for prompt in ("@clipboard", "explain @clipboard please", "Fix this (@clipboard)."):
            self.assertTrue(hook.wants_image(self.event(prompt)))
        for prompt in ("normal prompt", "x@clipboard.com", "@clipboard.png", "src/@clipboard",
                       "@clipboard_extra", "@@clipboard"):
            self.assertFalse(hook.wants_image(self.event(prompt)))
        self.assertFalse(hook.wants_image({"hook_event_name": "Stop", "prompt": "@clipboard"}))

    def test_no_marker_never_fetches_or_writes(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp) / "absent"
            fetch = mock.Mock(side_effect=AssertionError("unexpected clipboard read"))
            self.assertIsNone(hook.handle_event(self.event("hello"), "invalid", directory, fetch))
            self.assertFalse(directory.exists())

    def test_success_produces_private_immutable_snapshots(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp) / "images"
            results = [hook.handle_event(self.event("inspect @clipboard"), "test", directory,
                                         lambda _: PNG) for _ in range(2)]
            files = list(directory.iterdir())
            self.assertEqual(len(files), 2)
            for file in files:
                self.assertEqual(file.read_bytes(), PNG)
                if os.name != "nt":
                    self.assertEqual(stat.S_IMODE(file.stat().st_mode), 0o600)
                self.assertTrue(any(str(file) in result["hookSpecificOutput"]["additionalContext"]
                                    for result in results))

    def test_png_validation(self):
        hook.validate_png(PNG)
        for data in (b"<html>proxy error</html>", PNG[:-1], PNG + b"junk",
                     PNG[:40] + b"bad" + PNG[43:]):
            with self.assertRaises(hook.ClipboardError):
                hook.validate_png(data)

    def test_only_loopback_endpoints(self):
        for value in ("http://127.0.0.1:18340", "http://[::1]:1234/", "http://localhost:1234"):
            self.assertTrue(hook.endpoint_url(value).endswith("/clipboard/image"))
        for value in ("https://example.com", "http://127.0.0.1@evil.test", "file:///tmp/image",
                      "http://localhost/path", "http://localhost:bad", "http://localhost/?x=y"):
            with self.assertRaises(hook.ClipboardError):
                hook.endpoint_url(value)

    def response(self, data, status=200):
        response = io.BytesIO(data)
        response.status = status
        response.headers = {"Content-Length": str(len(data))}
        return response

    def test_http_success_and_failure(self):
        for data, status in ((PNG, 200), (b"", 204), (b"oops", 200)):
            with mock.patch.object(hook.urllib.request, "build_opener") as build:
                build.return_value.open.return_value = self.response(data, status)
                if status == 200 and data == PNG:
                    self.assertEqual(hook.fetch_image(hook.DEFAULT_URL), PNG)
                else:
                    with self.assertRaises(hook.ClipboardError):
                        hook.fetch_image(hook.DEFAULT_URL)

    def test_http_size_and_timeout(self):
        with mock.patch.object(hook.urllib.request, "build_opener") as build:
            response = self.response(PNG)
            response.headers["Content-Length"] = str(hook.MAX_IMAGE + 1)
            build.return_value.open.return_value = response
            with self.assertRaises(hook.ClipboardError):
                hook.fetch_image(hook.DEFAULT_URL)
            build.return_value.open.side_effect = TimeoutError()
            with self.assertRaisesRegex(hook.ClipboardError, "clipaste-bridge start"):
                hook.fetch_image(hook.DEFAULT_URL)

    def test_outage_warns_once_per_session_then_recovers(self):
        with tempfile.TemporaryDirectory() as temp:
            images, states = Path(temp) / "images", Path(temp) / "states"
            event = dict(self.event("@clipboard"), session_id="session-one")
            offline = mock.Mock(side_effect=hook.BridgeUnavailable("offline"))
            with mock.patch.object(hook.time, "time", return_value=100):
                with self.assertRaises(hook.BridgeUnavailable):
                    hook.handle_session_event(event, "test", images, states, offline)
                result = hook.handle_session_event(event, "test", images, states, offline)
                self.assertIn("No image was supplied", result["hookSpecificOutput"]["additionalContext"])
                self.assertEqual(offline.call_count, 1)
            with mock.patch.object(hook.time, "time", return_value=120):
                hook.handle_session_event(event, "test", images, states, offline)
                self.assertEqual(offline.call_count, 2)
            with mock.patch.object(hook.time, "time", return_value=140):
                result = hook.handle_session_event(event, "test", images, states, lambda _: PNG)
                self.assertIn("view_image", result["hookSpecificOutput"]["additionalContext"])
                with self.assertRaises(hook.BridgeUnavailable):
                    hook.handle_session_event(event, "test", images, states, offline)
            with self.assertRaises(hook.BridgeUnavailable):
                hook.handle_session_event(dict(event, session_id="session-two"), "test", images, states, offline)

    def test_merge_preserves_other_hooks_and_is_idempotent(self):
        existing = {"hooks": {"Stop": [{"hooks": [{"command": "other"}]}],
                              "UserPromptSubmit": [{"hooks": [{"command": "validate"}]}]}}
        merged = hook.merge_hooks(copy.deepcopy(existing), "python hook.py")
        self.assertEqual(merged["hooks"]["Stop"], existing["hooks"]["Stop"])
        self.assertEqual(merged["hooks"]["UserPromptSubmit"][0],
                         existing["hooks"]["UserPromptSubmit"][0])
        self.assertEqual(hook.merge_hooks(copy.deepcopy(merged), "python hook.py"), merged)

    def test_interpreter_migration_removes_only_previous_managed_hook(self):
        old = {"hooks": {"UserPromptSubmit": [{"hooks": [
            {"command": "/old/python /home/user/.codex/clipaste/clipboard_hook.py run"},
            {"command": "validate-prompt"}]}]}}
        result = hook.merge_hooks(old, "sh portable-launcher.sh",
                                  Path("/home/user/.codex/clipaste/clipboard_hook.py"))
        commands = [item["command"] for group in result["hooks"]["UserPromptSubmit"] for item in group["hooks"]]
        self.assertEqual(commands, ["validate-prompt", "sh portable-launcher.sh"])

    @unittest.skipIf(os.name == "nt", "installer targets the Unix remote")
    def test_install_backup_reinstall_and_invalid_config(self):
        with tempfile.TemporaryDirectory(prefix="clipaste space '") as temp:
            home = Path(temp)
            hooks = home / "hooks.json"
            original = b'{"hooks":{"Stop":[]}}'
            hooks.write_bytes(original)
            with mock.patch("sys.stdout", new_callable=io.StringIO):
                hook.install(home, hook.DEFAULT_URL)
                installed = hooks.read_bytes()
                hook.install(home, "http://127.0.0.1:18341")
            self.assertEqual(hooks.read_bytes(), installed)
            self.assertEqual(len(list(home.glob("*.bak"))), 1)
            self.assertEqual(next(home.glob("*.bak")).read_bytes(), original)
            command = json.loads(installed)["hooks"]["UserPromptSubmit"][0]["hooks"][0]["command"]
            result = subprocess.run(command, shell=True, input=json.dumps(self.event("hello")),
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            hooks.write_text("invalid")
            with self.assertRaises(ValueError):
                hook.install(home, hook.DEFAULT_URL)
            self.assertEqual(hooks.read_text(), "invalid")

    def test_process_blocks_requested_image_on_invalid_config(self):
        with tempfile.TemporaryDirectory() as temp:
            config = Path(temp) / "config.json"
            config.write_text('{"url":"http://example.com"}')
            result = subprocess.run([sys.executable, str(SCRIPT), "run", "--config", str(config)],
                                    input=json.dumps(self.event("@clipboard")), capture_output=True,
                                    text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn("loopback", result.stderr)
            self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
