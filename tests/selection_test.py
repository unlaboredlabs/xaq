#!/usr/bin/env python3
"""Check fullscreen selection and clipboard settings through a real PTY."""

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


BINARY = str(Path(sys.argv.pop(1) if len(sys.argv) > 1 else "zig-out/bin/xaq").resolve())
THREAD_ID = "AAAAAAAAAAAAAAAA"
CLIPBOARD = re.compile(rb"\x1b\]52;c;([A-Za-z0-9+/=]*)\x1b\\")


class SelectionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="xaq-selection-test-")
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name).resolve()
        self.home = self.work / "home"
        self.config = self.home / ".config" / "xaq"
        key = hashlib.sha256(str(self.work).encode()).hexdigest()[:16]
        directory = self.config / "threads" / key
        directory.mkdir(parents=True)
        entries = [
            {"type": "meta", "id": THREAD_ID, "provider": "chatgpt", "model": "gpt-5.6-sol",
             "cwd": str(self.work), "fast": False},
            {"type": "assistant", "text": "alpha bravo charlie", "calls": [], "raw_items": []},
        ]
        (directory / (THREAD_ID + ".jsonl")).write_text("".join(json.dumps(e) + "\n" for e in entries))
        self.output = bytearray()

    def start(self, enabled=None):
        if enabled is not None:
            (self.config / "settings.json").write_text(json.dumps({"copy_on_select": enabled}))
        master, slave = os.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        environment = os.environ.copy()
        for variable in ("NO_COLOR", "XAQ_PLAIN", "CI"):
            environment.pop(variable, None)
        # Force terminal clipboard output so tests cannot change a desktop clipboard.
        environment.update(HOME=str(self.home), TERM="xterm-256color", SSH_CONNECTION="test")
        self.process = subprocess.Popen([BINARY, "--resume", THREAD_ID], cwd=self.work, env=environment,
                                        stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
        os.close(slave)
        self.master = master

        def cleanup():
            if self.process.poll() is None:
                try:
                    os.killpg(self.process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            self.process.wait(timeout=3)
            os.close(master)

        self.addCleanup(cleanup)
        self.until(lambda: b"\x1b[?2004h" in self.output)
        self.drain()
        self.assertIn(b"\x1b[?1002h", self.output)

    def drain(self, duration=0.1):
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
            self.assertIsNone(self.process.poll(), bytes(self.output[-2000:]))
            self.assertLess(time.monotonic(), deadline, bytes(self.output[-2000:]))
            self.drain(0.05)

    def send(self, text):
        os.write(self.master, text)

    def mouse(self, button, column, final="M"):
        # At 100 columns, the resumed header is row 3 and the answer is row 4.
        self.send(f"\x1b[<{button};{column};4{final}".encode())

    def copies(self):
        return [base64.b64decode(value) for value in CLIPBOARD.findall(self.output)]

    def drag(self, reverse=False):
        self.mouse(0, 12 if reverse else 8)
        self.mouse(32, 8 if reverse else 12)
        self.mouse(0, 8 if reverse else 12, "m")

    def test_default_copies_only_on_release_and_restores_mouse_mode(self):
        self.start()
        self.mouse(0, 8)
        self.mouse(0, 8, "m")
        self.drain()
        self.assertEqual(self.copies(), [])
        self.mouse(0, 8)
        self.mouse(32, 12)
        self.until(lambda: b"\x1b[7m" in self.output)
        self.assertEqual(self.copies(), [])
        self.mouse(0, 12, "m")
        self.until(lambda: len(self.copies()) == 1)
        self.assertEqual(self.copies(), [b"bravo"])
        self.send(b"\x04")
        self.until(lambda: b"\x1b[?1002l" in self.output)
        self.assertEqual(self.process.wait(timeout=3), 0)

    def test_disabled_auto_copy_preserves_selection_for_manual_copy(self):
        self.start(False)
        self.drag(reverse=True)
        self.until(lambda: b"\x1b[7m" in self.output)
        self.assertEqual(self.copies(), [])
        self.send(b"\x19")
        self.until(lambda: len(self.copies()) == 1)
        self.assertEqual(self.copies(), [b"bravo"])
        offset = len(self.output)
        self.send(b"\x1b")
        self.until(lambda: b"\x1b[3;1H\x1b[2K" in self.output[offset:])
        self.send(b"\x19")
        self.drain()
        self.assertEqual(self.copies(), [b"bravo"])

    def test_settings_toggle_applies_immediately_and_persists(self):
        self.start()
        self.send(b"/settings\r")
        self.until(lambda: b"copy on select" in self.output)
        self.send(b"\x1b[B" * 8 + b"\r")
        self.until(lambda: b"copy transcript selection on release" in self.output)
        self.send(b"\x1b[B\r")
        settings = self.config / "settings.json"
        self.until(lambda: settings.exists() and json.loads(settings.read_text())["copy_on_select"] is False)
        offset = len(self.output)
        self.send(b"\x1b")
        self.until(lambda: b"\x1b[?2004h" in self.output[offset:])
        # Repaint the known transcript to keep mouse coordinates deterministic.
        offset = len(self.output)
        self.send(f"/resume {THREAD_ID}\r".encode())
        self.until(lambda: b"resumed " in self.output[offset:])
        self.drain()
        self.drag()
        self.drain()
        self.assertEqual(self.copies(), [])
        self.send(b"\x19")
        self.until(lambda: len(self.copies()) == 1)
        self.assertEqual(self.copies(), [b"bravo"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
