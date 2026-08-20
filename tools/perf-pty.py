#!/usr/bin/env python3
"""Measure the time until xaq's fullscreen editor is ready for input."""

from __future__ import annotations

import argparse
import fcntl
import os
import pty
import select
import signal
import statistics
import struct
import subprocess
import sys
import tempfile
import termios
import time
from pathlib import Path


READY_MARKER = b"\x1b[?2004h"
PROMPT_P95_BUDGET_MS = 15.0
STARTUP_TIMEOUT_SECONDS = 2.0


def percentile(samples: list[int], percent: int) -> int:
    ordered = sorted(samples)
    rank = max(1, (len(ordered) * percent + 99) // 100)
    return ordered[rank - 1]


def format_ms(nanoseconds: int | float) -> str:
    return f"{nanoseconds / 1_000_000:.2f} ms"


def stop_process(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    process.wait()


def prompt_ready_once(binary: str, cwd: str, home: str) -> int:
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
    environment = os.environ.copy()
    environment.update({"HOME": home, "TERM": "xterm-256color"})
    for name in ("XAQ_LOG", "XAQ_LOG_SCOPES", "XAQ_PLAIN", "NO_COLOR"):
        environment.pop(name, None)

    started = time.perf_counter_ns()
    process = subprocess.Popen(
        [binary, "--no-save"],
        cwd=cwd,
        env=environment,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        close_fds=True,
        start_new_session=True,
    )
    os.close(slave)
    transcript = bytearray()
    deadline = time.monotonic() + STARTUP_TIMEOUT_SECONDS
    try:
        while READY_MARKER not in transcript:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError("fullscreen input was not ready within 2 seconds")
            readable, _, _ = select.select([master], [], [], remaining)
            if not readable:
                continue
            try:
                chunk = os.read(master, 16 * 1024)
            except OSError as error:
                if process.poll() is not None:
                    excerpt = bytes(transcript[-500:]).decode("utf-8", "replace")
                    raise RuntimeError(
                        f"xaq exited before input was ready (code {process.returncode}): {excerpt}"
                    ) from error
                raise
            if not chunk:
                raise RuntimeError("xaq closed the terminal before input was ready")
            transcript.extend(chunk)
        return time.perf_counter_ns() - started
    finally:
        stop_process(process)
        os.close(master)


def discard_binary_cache(binary: str) -> bool:
    if not hasattr(os, "posix_fadvise") or not hasattr(os, "POSIX_FADV_DONTNEED"):
        return False
    descriptor = os.open(binary, os.O_RDONLY)
    try:
        os.posix_fadvise(descriptor, 0, 0, os.POSIX_FADV_DONTNEED)
    finally:
        os.close(descriptor)
    return True


def cold_help_once(binary: str) -> int | None:
    if not discard_binary_cache(binary):
        return None
    started = time.perf_counter_ns()
    subprocess.run(
        [binary, "--help"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=True,
    )
    return time.perf_counter_ns() - started


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Measure ReleaseSmall fullscreen readiness in a local Git worktree; "
            "cold help startup is reported where POSIX_FADV_DONTNEED is available."
        )
    )
    parser.add_argument("binary", help="path to the xaq benchmark executable")
    parser.add_argument("--runs", type=int, default=200)
    parser.add_argument("--no-check", action="store_true")
    options = parser.parse_args()
    if options.runs < 1 or options.runs > 10_000:
        parser.error("--runs must be between 1 and 10000")
    return options


def main() -> int:
    options = parse_args()
    binary = str(Path(options.binary).resolve())
    cwd = os.getcwd()
    warmups = min(10, options.runs)

    with tempfile.TemporaryDirectory(prefix="xaq-perf-home-") as home:
        for _ in range(warmups):
            prompt_ready_once(binary, cwd, home)
        prompt_samples = [
            prompt_ready_once(binary, cwd, home) for _ in range(options.runs)
        ]

    prompt_p50 = percentile(prompt_samples, 50)
    prompt_p95 = percentile(prompt_samples, 95)
    prompt_mean = statistics.fmean(prompt_samples)
    print(
        "  prompt   "
        f"p50 {format_ms(prompt_p50)}, "
        f"p95 {format_ms(prompt_p95)}, "
        f"mean {format_ms(prompt_mean)} "
        f"({options.runs} runs, local Git worktree)"
    )

    cold_samples: list[int] = []
    for _ in range(min(30, options.runs)):
        elapsed = cold_help_once(binary)
        if elapsed is None:
            break
        cold_samples.append(elapsed)
    if cold_samples:
        print(
            "  cold     help "
            f"p50 {format_ms(percentile(cold_samples, 50))}, "
            f"p95 {format_ms(percentile(cold_samples, 95))} "
            f"({len(cold_samples)} cache-discard runs)"
        )
    else:
        print("  cold     unavailable on this platform")

    if options.no_check:
        print("  prompt budget skipped")
        return 0
    if prompt_p95 <= PROMPT_P95_BUDGET_MS * 1_000_000:
        print("  prompt budget pass")
        return 0
    print(
        f"  prompt budget fail (p95 exceeds {PROMPT_P95_BUDGET_MS:.0f} ms)",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
