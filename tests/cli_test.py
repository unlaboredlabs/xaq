#!/usr/bin/env python3
"""Exercise CLI stream recovery, cancellation, and thread ownership offline."""

import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


BINARY = str(Path(sys.argv.pop(1) if len(sys.argv) > 1 else "zig-out/bin/xaq").resolve())
PROVIDERS = ("chatgpt", "claude", "grok")
FAKE_CURL = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
sys.stdin.read()
with open(os.environ["XAQ_TEST_REQUESTS"], "a") as requests:
    requests.write("request\n")
mode = os.environ["XAQ_TEST_MODE"]
if mode == "rate_limit":
    sys.stdout.write('HTTP/1.1 429 Too Many Requests\nRetry-After: 30\n\n{"message":"retry"}\n')
    sys.exit(0)
sys.stdout.write("HTTP/1.1 200 OK\nContent-Type: text/event-stream\n\n")
def event(value):
    print("data: " + json.dumps(value) + "\n")
claude = os.environ["XAQ_TEST_PROVIDER"] == "claude"
if mode != "tool_only":
    event({"type":"content_block_delta", "index":0,
           "delta":{"type":"text_delta", "text":"answer"}} if claude else
          {"type":"response.output_text.delta", "delta":"answer"})
if mode != "completed":
    arguments = json.dumps({"path":os.environ["XAQ_TEST_MARKER"], "content":"must not run"})
    if claude:
        event({"type":"content_block_start", "index":1,
               "content_block":{"type":"tool_use", "id":"call_1", "name":"write", "input":{}}})
        event({"type":"content_block_delta", "index":1,
               "delta":{"type":"input_json_delta", "partial_json":arguments}})
    else:
        event({"type":"response.output_item.done", "item":{"type":"function_call",
               "call_id":"call_1", "name":"write", "arguments":arguments}})
else:
    event({"type":"message_stop"} if claude else
          {"type":"response.completed", "response":{"usage":{}}})
'''


class CliTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="xaq-cli-test-")
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name)
        self.home = self.work / "home"
        config = self.home / ".config" / "xaq"
        config.mkdir(parents=True)
        credential = {"access": "test", "refresh": "", "expires": 9999999999, "account_id": "test"}
        (config / "auth.json").write_text(json.dumps(dict.fromkeys(PROVIDERS, credential)))
        fake_bin = self.work / "bin"
        fake_bin.mkdir()
        curl = fake_bin / "curl"
        curl.write_text(FAKE_CURL)
        curl.chmod(0o755)
        self.requests = self.work / "requests"
        self.marker = self.work / "must-not-run"
        self.environment = os.environ.copy()
        self.environment.update({
            "HOME": str(self.home),
            "PATH": str(fake_bin) + os.pathsep + self.environment["PATH"],
            "XAQ_TEST_REQUESTS": str(self.requests),
            "XAQ_TEST_MARKER": str(self.marker),
        })

    def start(self, provider, mode, resume=None):
        environment = self.environment | {"XAQ_TEST_PROVIDER": provider, "XAQ_TEST_MODE": mode}
        args = [BINARY, "--provider", provider, "--output-format", "json", "-p", "test response"]
        args += ["--resume", resume] if resume else ["--no-save"]
        process = subprocess.Popen(args, cwd=self.work, env=environment, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                   start_new_session=True)

        def cleanup():
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.communicate()

        self.addCleanup(cleanup)
        return process

    def request_count(self):
        return len(self.requests.read_text().splitlines()) if self.requests.exists() else 0

    def wait_for_request(self, process):
        deadline = time.monotonic() + 5
        while self.request_count() == 0:
            self.assertIsNone(process.poll(), "CLI exited before requesting a response")
            self.assertLess(time.monotonic(), deadline, "CLI did not make a request")
            time.sleep(0.01)
        # Let the HTTP response reach the backoff loop before interrupting it.
        time.sleep(0.1)

    def test_completed_responses(self):
        for provider in PROVIDERS:
            with self.subTest(provider=provider):
                process = self.start(provider, "completed")
                stdout, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 0, stderr)
                result = json.loads(stdout)
                self.assertEqual(result["text"], "answer")
                self.assertEqual(result["stop_reason"], "completed")

    def test_partial_responses_do_not_execute_tools(self):
        for provider in PROVIDERS:
            with self.subTest(provider=provider):
                process = self.start(provider, "partial")
                stdout, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 0, stderr)
                result = json.loads(stdout)
                self.assertEqual(result["text"], "answer")
                self.assertEqual(result["stop_reason"], "stream_interrupted")
                self.assertEqual(result["tool_calls"], 0)
                self.assertFalse(self.marker.exists())

    def test_tool_only_interruption_retries_and_fails(self):
        for provider in ("chatgpt", "claude"):
            with self.subTest(provider=provider):
                before = self.request_count()
                process = self.start(provider, "tool_only")
                _, stderr = process.communicate(timeout=15)
                self.assertNotEqual(process.returncode, 0)
                self.assertIn("Response ended before completion", stderr)
                self.assertEqual(self.request_count() - before, 3)
                self.assertFalse(self.marker.exists())

    def test_retry_backoff_cancels_promptly(self):
        process = self.start("chatgpt", "rate_limit")
        self.wait_for_request(process)
        process.send_signal(signal.SIGINT)
        process.communicate(timeout=2)
        self.assertEqual(process.returncode, 130)
        self.assertEqual(self.request_count(), 1)

    def test_thread_has_one_owner_and_recovers_after_process_exit(self):
        thread_id = "AAAAAAAAAAAAAAAA"
        key = hashlib.sha256(str(self.work).encode()).hexdigest()[:16]
        directory = self.home / ".config" / "xaq" / "threads" / key
        directory.mkdir(parents=True)
        metadata = {"type": "meta", "id": thread_id, "provider": "chatgpt",
                    "model": "gpt-5.6-sol", "cwd": str(self.work), "fast": False}
        (directory / (thread_id + ".jsonl")).write_text(json.dumps(metadata) + "\n")
        owner = self.start("chatgpt", "rate_limit", thread_id)
        self.wait_for_request(owner)
        contender = self.start("chatgpt", "completed", thread_id)
        stdout, stderr = contender.communicate(timeout=2)
        self.assertNotEqual(contender.returncode, 0)
        self.assertIn("thread is open in another session", stdout + stderr)
        self.assertEqual(self.request_count(), 1)
        os.killpg(owner.pid, signal.SIGKILL)
        owner.communicate(timeout=2)
        resumed = self.start("chatgpt", "completed", thread_id)
        stdout, stderr = resumed.communicate(timeout=10)
        self.assertEqual(resumed.returncode, 0, stderr)
        self.assertEqual(json.loads(stdout)["thread_id"], thread_id)


if __name__ == "__main__":
    unittest.main(verbosity=2)
