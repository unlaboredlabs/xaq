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
config = sys.stdin.read()
data_line = next(line for line in config.splitlines() if line.startswith("data-binary = "))
request_path = json.loads(data_line.split("=", 1)[1].strip())[1:]
body = json.loads(pathlib.Path(request_path).read_text())
with open(os.environ["XAQ_TEST_REQUESTS"], "a") as requests:
    requests.write("request\n")
mode = os.environ["XAQ_TEST_MODE"]
if mode == "claude_client_version":
    headers = [json.loads(line.split("=", 1)[1].strip())
               for line in config.splitlines() if line.startswith("header = ")]
    user_agent = next(header.split(": ", 1)[1] for header in headers
                      if header.lower().startswith("user-agent: "))
    version = tuple(map(int, user_agent.removeprefix("claude-cli/").split(".")))
    if version < (2, 1, 251):
        sys.stdout.write('HTTP/1.1 400 Bad Request\n\n'
                         '{"error":{"message":"Claude Code 2.1.251 or newer is required"}}\n')
        sys.exit(0)
    mode = "completed"
if mode == "astra":
    assert body["model"] == "gpt-6-astra", body["model"]
    assert body["reasoning"]["effort"] == "ultra", body.get("reasoning")
    assert body["service_tier"] == "priority", body.get("service_tier")
    assert sys.argv[sys.argv.index("--url") + 1] == "https://chatgpt.com/backend-api/codex/responses"
    assert 'header = "x-codex-routing-hint: model=gpt-6-astra;tier=priority"' in config
    mode = "completed"
if mode == "rate_limit":
    sys.stdout.write('HTTP/1.1 429 Too Many Requests\nRetry-After: 30\n\n{"message":"retry"}\n')
    sys.exit(0)
if mode in ("chat_completions", "chat_tool"):
    assert sys.argv[sys.argv.index("--url") + 1] == "http://localhost:11434/v1/chat/completions"
    headers = [json.loads(line.split("=", 1)[1].strip())
               for line in config.splitlines() if line.startswith("header = ")]
    assert "Authorization: Bearer local-test-key" in headers, headers
    assert "X-Title: xaq-test" in headers, headers
    assert not any(h.lower().startswith("x-api-key") for h in headers), headers
    assert body["model"] == "qwen3-coder", body["model"]
    assert body["stream"] is True and body["stream_options"] == {"include_usage": True}
    assert body["messages"][0]["role"] == "system"
    assert "provider=ollama" in body["messages"][0]["content"]
    assert body["reasoning_effort"] == "high", body.get("reasoning_effort")
    assert body["tools"][0]["type"] == "function" and "function" in body["tools"][0]
    sys.stdout.write("HTTP/1.1 200 OK\nContent-Type: text/event-stream\n\n")
    def chunk(delta, finish=None, usage=None):
        value = {"choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
        if usage is not None:
            value["usage"] = usage
        print("data: " + json.dumps(value) + "\n")
    tool_messages = [m for m in body["messages"] if m.get("role") == "tool"]
    if mode == "chat_tool" and not tool_messages:
        chunk({"tool_calls": [{"index": 0, "id": "call_1", "type": "function",
                               "function": {"name": "bash", "arguments": ""}}]})
        chunk({"tool_calls": [{"index": 0, "function": {"arguments": json.dumps({"command": "printf tool-ran"})}}]})
        chunk({}, finish="tool_calls")
        print("data: [DONE]\n")
        sys.exit(0)
    if mode == "chat_tool":
        assert tool_messages[0]["tool_call_id"] == "call_1", tool_messages
        assert "tool-ran" in tool_messages[0]["content"], tool_messages
        assistant = [m for m in body["messages"] if m.get("role") == "assistant"][-1]
        assert assistant["tool_calls"][0]["function"]["name"] == "bash", assistant
    chunk({"role": "assistant", "content": ""})
    chunk({"content": "answer"})
    chunk({}, finish="stop", usage={"prompt_tokens": 11, "completion_tokens": 2,
                                   "prompt_tokens_details": {"cached_tokens": 4}})
    print("data: [DONE]\n")
    sys.exit(0)
sys.stdout.write("HTTP/1.1 200 OK\nContent-Type: text/event-stream\n\n")
def event(value):
    print("data: " + json.dumps(value) + "\n")
claude = os.environ["XAQ_TEST_PROVIDER"] == "claude"
if mode in ("binary_read", "binary_bash", "binary_read_large"):
    entries = body["messages" if claude else "input"]
    results = ([block["content"] for entry in entries
                for block in (entry["content"] if isinstance(entry.get("content"), list) else [])
                if block.get("type") == "tool_result"] if claude else
               [entry["output"] for entry in entries if entry.get("type") == "function_call_output"])
    if results:
        if mode == "binary_read_large":
            assert len(results) == 1 and isinstance(results[0], str)
            assert len(results[0].encode("utf-8")) <= 50 * 1024
            assert results[0].endswith("\n[tool result truncated]")
        else:
            assert results == ["before\ufffdafter"], repr(results)
        mode = "completed"
    else:
        name = "read" if mode.startswith("binary_read") else "bash"
        arguments = json.dumps({"path":os.environ["XAQ_TEST_BINARY"]} if name == "read" else
                               {"command":"printf 'before\\377after'"})
        if claude:
            event({"type":"content_block_start", "index":0,
                   "content_block":{"type":"tool_use", "id":"call_1", "name":name, "input":{}}})
            event({"type":"content_block_delta", "index":0,
                   "delta":{"type":"input_json_delta", "partial_json":arguments}})
            event({"type":"message_stop"})
        else:
            event({"type":"response.output_item.done", "item":{"type":"function_call",
                   "call_id":"call_1", "name":name, "arguments":arguments}})
            event({"type":"response.completed", "response":{"usage":{}}})
        sys.exit(0)
if mode == "binary_stdin":
    entries = body["messages" if claude else "input"]
    user = next(entry for entry in entries if entry.get("role") == "user")
    content = user["content"]
    text = content if isinstance(content, str) else content[0]["text"]
    assert text == "before\ufffdafter", repr(text)
    mode = "completed"
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
        binary_file = self.work / "binary.txt"
        binary_file.write_bytes(b"before\xffafter")
        self.environment = os.environ.copy()
        self.environment.update({
            "HOME": str(self.home),
            "PATH": str(fake_bin) + os.pathsep + self.environment["PATH"],
            "XAQ_TEST_REQUESTS": str(self.requests),
            "XAQ_TEST_MARKER": str(self.marker),
            "XAQ_TEST_BINARY": str(binary_file),
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

    def write_custom_provider(self, **overrides):
        definition = {
            "api": "chat_completions",
            "base_url": "http://localhost:11434/v1/",
            "api_key_env": "XAQ_TEST_OLLAMA_KEY",
            "headers": {"X-Title": "xaq-test"},
            "models": ["qwen3-coder", "llama4"],
            "context_tokens": 64000,
            "efforts": ["low", "high"],
        }
        definition.update(overrides)
        settings = self.home / ".config" / "xaq" / "settings.json"
        settings.write_text(json.dumps({"providers": {"ollama": definition}}))

    def run_custom(self, mode, *extra_args, provider_args=("--provider", "ollama")):
        environment = self.environment | {"XAQ_TEST_PROVIDER": "ollama", "XAQ_TEST_MODE": mode,
                                          "XAQ_TEST_OLLAMA_KEY": "local-test-key"}
        args = [BINARY, *provider_args, *extra_args, "--output-format", "json", "--no-save", "-p", "test response"]
        return subprocess.run(args, cwd=self.work, env=environment, stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=30)

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

    def test_custom_chat_completions_provider_round_trips(self):
        self.write_custom_provider()
        result = self.run_custom("chat_completions", "--effort", "high")
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["text"], "answer")
        self.assertEqual(payload["provider"], "ollama")
        self.assertEqual(payload["model"], "qwen3-coder")
        self.assertEqual(payload["stop_reason"], "completed")
        self.assertEqual(payload["usage"], {"input_tokens": 11, "cached_input_tokens": 4, "output_tokens": 2})

    def test_custom_provider_tool_calls_round_trip_as_tool_messages(self):
        self.write_custom_provider()
        result = self.run_custom("chat_tool", "--effort", "high")
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["text"], "answer")
        self.assertEqual(payload["tool_calls"], 1)
        self.assertEqual(payload["num_turns"], 2)
        self.assertEqual(self.request_count(), 2)

    def test_custom_model_id_selects_its_provider_and_missing_env_fails_cleanly(self):
        self.write_custom_provider()
        result = self.run_custom("chat_completions", "--effort", "high", provider_args=("--model", "qwen3-coder"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["provider"], "ollama")

        environment = self.environment | {"XAQ_TEST_PROVIDER": "ollama", "XAQ_TEST_MODE": "chat_completions"}
        missing = subprocess.run([BINARY, "--provider", "ollama", "--output-format", "json", "--no-save", "-p", "x"],
                                 cwd=self.work, env=environment, stdin=subprocess.DEVNULL,
                                 capture_output=True, text=True, timeout=30)
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("XAQ_TEST_OLLAMA_KEY is not set", missing.stderr)
        self.assertEqual(self.request_count(), 1)

        unknown = subprocess.run([BINARY, "--provider", "nowhere", "-p", "x"], cwd=self.work, env=environment,
                                 stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(unknown.returncode, 0)
        self.assertIn("not configured", unknown.stderr)

    def test_provider_subcommand_writes_settings_without_exposing_keys(self):
        environment = self.environment
        add = subprocess.run([BINARY, "provider", "add", "router", "--api", "chat_completions", "--base-url",
                              "https://openrouter.ai/api/v1", "--api-key-stdin", "--model", "a/b", "--effort", "low"],
                             cwd=self.work, env=environment, input="sk-from-stdin\n", capture_output=True,
                             text=True, timeout=30)
        self.assertEqual(add.returncode, 0, add.stderr)
        settings = json.loads((self.home / ".config" / "xaq" / "settings.json").read_text())
        self.assertEqual(settings["providers"]["router"]["api_key"], "sk-from-stdin")
        self.assertEqual(settings["providers"]["router"]["models"], ["a/b"])
        listed = subprocess.run([BINARY, "provider", "list"], cwd=self.work, env=environment, stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(listed.returncode, 0, listed.stderr)
        self.assertIn("router", listed.stdout)
        self.assertNotIn("sk-from-stdin", listed.stdout)
        rejected = subprocess.run([BINARY, "provider", "add", "claude", "--api", "messages", "--base-url", "https://x",
                                   "--model", "m"], cwd=self.work, env=environment, stdin=subprocess.DEVNULL,
                                  capture_output=True, text=True, timeout=30)
        self.assertEqual(rejected.returncode, 2)
        removed = subprocess.run([BINARY, "provider", "remove", "router"], cwd=self.work, env=environment,
                                 stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
        self.assertEqual(removed.returncode, 0, removed.stderr)
        settings = json.loads((self.home / ".config" / "xaq" / "settings.json").read_text())
        self.assertIsNone(settings.get("providers"))

    def test_completed_responses(self):
        for provider in PROVIDERS:
            with self.subTest(provider=provider):
                process = self.start(provider, "completed")
                stdout, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 0, stderr)
                result = json.loads(stdout)
                self.assertEqual(result["text"], "answer")
                self.assertEqual(result["stop_reason"], "completed")

    def test_astra_model_infers_provider_and_sends_ultra_fast_options(self):
        # Remember another provider so an unrecognized model would route incorrectly.
        (self.home / ".config" / "xaq" / "state.json").write_text(json.dumps({
            "provider": "claude",
            "claude": {"model": "claude-opus-5"},
        }))
        completed = subprocess.run(
            [BINARY, "--model", "gpt-6-astra", "--effort", "ultra", "--fast",
             "--no-save", "--output-format", "json", "-p", "test response"],
            cwd=self.work,
            env=self.environment | {"XAQ_TEST_PROVIDER": "chatgpt", "XAQ_TEST_MODE": "astra"},
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, timeout=10)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        result = json.loads(completed.stdout)
        self.assertEqual(result["text"], "answer")
        self.assertEqual(result["stop_reason"], "completed")
        self.assertEqual(self.request_count(), 1)

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

    def test_claude_requests_meet_model_client_version_requirement(self):
        process = self.start("claude", "claude_client_version")
        stdout, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, stderr)
        result = json.loads(stdout)
        self.assertEqual(result["text"], "answer")
        self.assertEqual(result["stop_reason"], "completed")
        self.assertEqual(self.request_count(), 1)

    def test_binary_tool_output_remains_provider_text(self):
        for provider in PROVIDERS:
            for mode in ("binary_read", "binary_bash"):
                with self.subTest(provider=provider, mode=mode):
                    process = self.start(provider, mode)
                    stdout, stderr = process.communicate(timeout=10)
                    self.assertEqual(process.returncode, 0, stderr)
                    result = json.loads(stdout)
                    self.assertEqual(result["text"], "answer")
                    self.assertEqual(result["tool_calls"], 1)

    def test_non_utf8_stdin_remains_provider_text(self):
        for provider in PROVIDERS:
            with self.subTest(provider=provider):
                completed = subprocess.run(
                    [BINARY, "--provider", provider, "--no-save", "--output-format", "json"],
                    cwd=self.work,
                    env=self.environment | {"XAQ_TEST_PROVIDER": provider, "XAQ_TEST_MODE": "binary_stdin"},
                    input=b"before\xffafter", stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertEqual(json.loads(completed.stdout)["text"], "answer")

    def test_replacement_characters_do_not_expand_tool_budget(self):
        Path(self.environment["XAQ_TEST_BINARY"]).write_bytes(b"\xff" * (50 * 1024))
        for provider in PROVIDERS:
            with self.subTest(provider=provider):
                process = self.start(provider, "binary_read_large")
                stdout, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 0, stderr)
                self.assertEqual(json.loads(stdout)["tool_calls"], 1)

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
