#!/usr/bin/env python3
"""Exercise provider login links and hidden callback input without a network."""

import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest
from urllib.parse import parse_qs, urlsplit


BINARY = str(Path(sys.argv.pop(1) if len(sys.argv) > 1 else "zig-out/bin/xaq").resolve())
PROVIDERS = ("chatgpt", "claude", "grok")
THREAD_ID = "AAAAAAAAAAAAAAAA"
SECRET = b"callback-secret-must-stay-hidden"
DEVICE_URL = "https://auth.example.test/device?request=" + "abc123" * 24 + "&client=xaq"
CLIPBOARD = re.compile(rb"\x1b\]52;c;([A-Za-z0-9+/=]*)\x1b\\")
CSI = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]")
FAKE_CURL = r'''#!/usr/bin/env python3
import base64, json, os, pathlib, sys, urllib.parse
config = sys.stdin.read()
line = next(line for line in config.splitlines() if line.startswith("data-binary = "))
path = json.loads(line.split("=", 1)[1].strip())[1:]
raw = pathlib.Path(path).read_text()
body = json.loads(raw) if raw.startswith("{") else {
    key: value[0] for key, value in urllib.parse.parse_qs(raw).items()}
url = sys.argv[sys.argv.index("--url") + 1]
with open(os.environ["XAQ_TEST_REQUESTS"], "a") as output:
    output.write(json.dumps({"url": url, "body": body}) + "\n")
if url == "https://auth.x.ai/oauth2/device/code":
    response = {"device_code": "test-device", "user_code": "TEST-CODE",
                "verification_uri": os.environ["XAQ_TEST_DEVICE_URL"],
                "expires_in": 60, "interval": 1}
else:
    assert url in ("https://auth.openai.com/oauth/token",
                   "https://platform.claude.com/v1/oauth/token",
                   "https://auth.x.ai/oauth2/token"), url
    if "code" in body:
        assert body["code"] == "callback-secret-must-stay-hidden", body
    payload = base64.urlsafe_b64encode(json.dumps({
        "https://api.openai.com/auth": {"chatgpt_account_id": "test-account"}
    }).encode()).decode().rstrip("=")
    response = {"access_token": "test." + payload + ".signature",
                "refresh_token": "test-refresh", "expires_in": 3600}
print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n" + json.dumps(response))
'''


class AuthTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="xaq-auth-test-")
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name).resolve()
        self.home = self.work / "home"
        self.config = self.home / ".config" / "xaq"
        key = hashlib.sha256(str(self.work).encode()).hexdigest()[:16]
        threads = self.config / "threads" / key
        threads.mkdir(parents=True)
        entries = [
            {"type": "meta", "id": THREAD_ID, "provider": "chatgpt", "model": "gpt-5.6-sol",
             "cwd": str(self.work), "fast": False},
            {"type": "assistant", "text": "alpha bravo charlie", "calls": [], "raw_items": []},
        ]
        (threads / (THREAD_ID + ".jsonl")).write_text("".join(json.dumps(e) + "\n" for e in entries))
        # Explicit login copying works even when automatic transcript copying is off.
        (self.config / "settings.json").write_text('{"copy_on_select":false}')
        fake_bin = self.work / "bin"
        fake_bin.mkdir()
        for name, script in (
            ("curl", FAKE_CURL),
            ("xdg-open", '#!/bin/sh\n: > "$XAQ_TEST_BROWSER"\n'),
            ("open", '#!/bin/sh\n: > "$XAQ_TEST_BROWSER"\n'),
        ):
            executable = fake_bin / name
            executable.write_text(script)
            executable.chmod(0o755)
        self.requests = self.work / "requests"
        self.browser = self.work / "browser"
        self.environment = os.environ.copy()
        for name in ("NO_COLOR", "XAQ_PLAIN", "CI"):
            self.environment.pop(name, None)
        self.environment.update(
            HOME=str(self.home), TERM="xterm-256color", SSH_CONNECTION="test",
            PATH=str(fake_bin) + os.pathsep + self.environment["PATH"],
            XAQ_TEST_REQUESTS=str(self.requests), XAQ_TEST_BROWSER=str(self.browser),
            XAQ_TEST_DEVICE_URL=DEVICE_URL)

    def start(self, provider, fullscreen):
        self.output = bytearray()
        master, slave = os.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        args = ["--resume", THREAD_ID] if fullscreen else ["login", provider]
        process = subprocess.Popen([BINARY, *args], cwd=self.work, env=self.environment,
                                   stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
        os.close(slave)
        self.process, self.master = process, master

        def cleanup():
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            process.wait(timeout=3)
            os.close(master)

        self.addCleanup(cleanup)
        if fullscreen:
            self.until(lambda: b"\x1b[?2004h" in self.output)
            self.send(f"/login {provider}\r".encode())
        self.login_offset = len(self.output)
        prompt = b"Press Enter to wait for approval" if provider == "grok" else b"Callback URL or code:"
        self.until(lambda: prompt in self.output[self.login_offset:])
        self.assertIn(b"ctrl-y", self.output[self.login_offset:].lower())
        if fullscreen:
            for mode in (1000, 1002, 1006):
                self.assertIn(f"\x1b[?{mode}l".encode(), self.output[self.login_offset:])
                self.assertNotIn(f"\x1b[?{mode}h".encode(), self.output[self.login_offset:])
        self.assertFalse(self.browser.exists(), "SSH login must not open a browser on the remote host")

    def drain(self, duration=0.05):
        deadline = time.monotonic() + duration
        while time.monotonic() < deadline:
            if not select.select([self.master], [], [], max(0, deadline - time.monotonic()))[0]:
                break
            try:
                data = os.read(self.master, 65536)
            except OSError:
                break
            if not data:
                break
            self.output.extend(data)

    def until(self, predicate, timeout=5):
        deadline = time.monotonic() + timeout
        while not predicate():
            self.drain()
            if predicate():
                return
            self.assertIsNone(self.process.poll(), bytes(self.output[-2000:]))
            self.assertLess(time.monotonic(), deadline, bytes(self.output[-2000:]))

    def send(self, data):
        os.write(self.master, data)

    def copies(self):
        return [base64.b64decode(value) for value in CLIPBOARD.findall(self.output)]

    def stop(self):
        self.send(b"\x04")
        self.assertEqual(self.process.wait(timeout=3), 0)
        self.drain()

    def complete_login(self, provider, fullscreen):
        self.start(provider, fullscreen)
        displayed = bytes(self.output)
        # Copy while a callback is partly entered, then finish the same secret.
        if provider != "grok":
            # Reports queued before mouse mode changed must not enter the secret.
            self.send(b"\x1b[<64;8;4M\x1b[M" + bytes([96, 40, 36]))
            self.send(SECRET[:8])
        self.send(b"\x19")
        self.until(lambda: len(self.copies()) == 1)
        url = self.copies()[0]
        visible = re.sub(rb"\s+", b"", CSI.sub(b"", displayed))
        self.assertIn(url, visible, "Copy must use the full displayed URL without wrap whitespace")
        if provider == "grok":
            self.assertEqual(url.decode(), DEVICE_URL)
            offset = len(self.output)
            self.send(b"\r")
            if fullscreen:
                self.until(lambda: b"waiting for approval" in self.output[offset:])
                for mode in (1000, 1002, 1006):
                    self.assertNotIn(f"\x1b[?{mode}h".encode(), self.output[self.login_offset:])
        else:
            parsed = urlsplit(url.decode())
            self.assertEqual(parsed.scheme, "https")
            self.assertEqual(parsed.netloc, "auth.openai.com" if provider == "chatgpt" else "claude.com")
            query = parse_qs(parsed.query)
            self.assertEqual(query["code_challenge_method"], ["S256"])
            self.assertIn("state", query)
            self.send(b"\x1b[200~" + SECRET[8:] + b"\x1b[201~\r")
        auth = self.config / "auth.json"
        self.until(lambda: auth.exists() and json.loads(auth.read_text()).get(provider) is not None)
        if fullscreen:
            self.until(lambda: b"\x1b[?1002h" in self.output[self.login_offset:])
            self.stop()
        else:
            self.assertEqual(self.process.wait(timeout=3), 0)
            self.drain()
        credential = json.loads(auth.read_text())[provider]
        self.assertEqual(credential["refresh"], "test-refresh")
        if provider != "grok":
            request = json.loads(self.requests.read_text().splitlines()[-1])["body"]
            challenge = base64.urlsafe_b64encode(hashlib.sha256(request["code_verifier"].encode()).digest())
            self.assertEqual(query["code_challenge"], [challenge.decode().rstrip("=")])
            self.assertEqual(query["redirect_uri"], [request["redirect_uri"]])
        self.assertNotIn(SECRET, self.output)
        for path in self.config.rglob("*"):
            if path.is_file():
                self.assertNotIn(SECRET, path.read_bytes(), str(path))
        self.assertEqual(self.copies(), [url])

    def test_standalone_login_links_copy_and_callbacks_stay_private(self):
        for provider in PROVIDERS:
            with self.subTest(provider=provider):
                self.complete_login(provider, False)

    def test_fullscreen_login_links_copy_and_restore_mouse(self):
        for provider in PROVIDERS:
            with self.subTest(provider=provider):
                self.complete_login(provider, True)

    def test_cancelled_login_restores_transcript_selection(self):
        for provider in PROVIDERS:
            with self.subTest(provider=provider):
                self.start(provider, True)
                self.send(b"\x03")
                self.until(lambda: b"login cancelled" in self.output[self.login_offset:]
                           and b"\x1b[?1002h" in self.output[self.login_offset:])
                self.assertFalse((self.config / "auth.json").exists())
                offset = len(self.output)
                self.send(f"/resume {THREAD_ID}\r".encode())
                self.until(lambda: b"alpha bravo charlie" in self.output[offset:]
                           and b"\x1b[?2004h" in self.output[offset:])
                self.send(b"\x1b[<0;8;4M\x1b[<32;12;4M\x1b[<0;12;4m\x19")
                self.until(lambda: self.copies() == [b"bravo"])
                self.stop()

    def test_piped_device_login_does_not_wait_for_keyboard_input(self):
        completed = subprocess.run([BINARY, "login", "grok"], cwd=self.work, env=self.environment,
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, timeout=5)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn(b"Grok connected", completed.stdout)
        self.assertNotIn(b"Press Enter", completed.stdout)
        self.assertNotIn(b"\x1b]52;", completed.stdout)

    def test_redirected_login_output_keeps_terminal_callback_hidden(self):
        master, slave = os.openpty()
        self.addCleanup(os.close, master)
        self.addCleanup(os.close, slave)
        process = subprocess.Popen([BINARY, "login", "claude"], cwd=self.work, env=self.environment,
                                   stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True)

        def cleanup():
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=3)

        self.addCleanup(cleanup)
        output = bytearray()

        def wait_for(text):
            deadline = time.monotonic() + 5
            while text not in output:
                if select.select([process.stdout], [], [], 0.05)[0]:
                    output.extend(os.read(process.stdout.fileno(), 65536))
                if text in output:
                    return
                self.assertIsNone(process.poll(), output)
                self.assertLess(time.monotonic(), deadline, output)

        wait_for(b"Callback URL or code:")
        self.assertFalse(termios.tcgetattr(slave)[3] & termios.ECHO)
        os.write(master, SECRET[:8])
        wait_for(b"********")
        os.write(master, b"\x19" + SECRET[8:] + b"\r")
        remaining, errors = process.communicate(timeout=5)
        output.extend(remaining)
        self.assertEqual(process.returncode, 0, errors)
        self.assertIn(b"Claude connected", output)
        self.assertNotIn(b"\x1b]52;", output)
        self.assertNotIn(SECRET, output + errors)
        self.assertEqual(select.select([master], [], [], 0)[0], [], "Callback echoed to the terminal")
        request = json.loads(self.requests.read_text().splitlines()[-1])["body"]
        self.assertEqual(request["code"].encode(), SECRET)


if __name__ == "__main__":
    unittest.main(verbosity=2)
