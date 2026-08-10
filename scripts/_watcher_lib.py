#!/usr/bin/env python3
"""Shared machinery for drive_when_idle.py, the one detached watcher.

Pure predicates over captured tmux pane text, the pane-polling scaffold (snap /
wait_for_idle / the three submit confirmations, all pane-scoped) and the
tunables, read from the environment at call time so tests can override them per-
call rather than at import time. Port of _watcher-lib.sh — see
docs/changelog/2026-08-10-python-split.md.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any

# A parsed transcript JSONL entry. Its shape is read defensively field by
# field below, never assumed — see _read_transcript_entries.
JSONDict = dict[str, Any]

_ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


def _env_float(name: str, default: float) -> float:
    """Read a tunable from the environment, falling back to ``default``."""
    return float(os.environ.get(name, default))


def strip(text: str) -> str:
    """Strip ANSI escapes and carriage returns from captured pane text."""
    return _ANSI_RE.sub("", text).replace("\r", "")


def is_busy(text: str) -> bool:
    """Report whether the Claude TUI chrome spinner is on screen."""
    return bool(re.search(r"\([0-9]+s ·|esc to interrupt", strip(text)))


def is_typing(text: str) -> bool:
    """Report whether the last ``❯`` prompt line has non-space content."""
    lines = [line for line in strip(text).split("\n") if "❯" in line]
    if not lines:
        return False
    return bool(re.search(r"❯[ \t]+\S", lines[-1]))


composer_landed = is_typing


def is_unknown_command(text: str) -> bool:
    """Report whether the composer holds a command the TUI will not run."""
    return "No commands match" in strip(text)


def snap(pane: str) -> str:
    """Capture the visible pane text (never scrollback), last 40 lines."""
    result = subprocess.run(
        ["tmux", "capture-pane", "-p", "-t", pane],
        capture_output=True,
        text=True,
        check=False,
    )
    lines = result.stdout.split("\n")
    return "\n".join(lines[-40:])


def wait_for_idle(pane: str) -> None:
    """Wait until idle is stable for ~3 consecutive polls, up to TIMEOUT.

    Falls through on timeout — the caller's is_typing check is the real gate
    against typing over a live composer.
    """
    timeout = _env_float("HANDOFF_WATCHER_TIMEOUT", 30)
    poll = _env_float("HANDOFF_WATCHER_POLL", 0.1)
    deadline = time.monotonic() + timeout
    stable = 0
    while time.monotonic() < deadline:
        if is_busy(snap(pane)):
            stable = 0
            time.sleep(poll)
            continue
        stable += 1
        if stable >= 3:
            return
        time.sleep(poll)


def _submit_until(pane: str, check: Callable[[], bool]) -> bool:
    """Enter, then wait for ``check()`` to pass.

    Retry 3x, then poll long.
    """
    verify_delay = _env_float("HANDOFF_WATCHER_VERIFY_DELAY", 0.5)
    consume_timeout = _env_float("HANDOFF_WATCHER_CONSUME_TIMEOUT", 300)
    consume_poll = _env_float("HANDOFF_WATCHER_CONSUME_POLL", 1)

    for _ in range(3):
        subprocess.run(["tmux", "send-keys", "-t", pane, "Enter"], check=False)
        time.sleep(verify_delay)
        if check():
            return True

    deadline = time.monotonic() + consume_timeout
    while time.monotonic() < deadline:
        if check():
            return True
        time.sleep(consume_poll)
    return False


def submit_consumed(pane: str) -> bool:
    """Confirm /compact and /clear: HANDOFF_PENDING_FILE disappearing."""
    pending = os.environ.get("HANDOFF_PENDING_FILE", "")
    if not pending:
        subprocess.run(["tmux", "send-keys", "-t", pane, "Enter"], check=False)
        return True
    return _submit_until(pane, lambda: not Path(pending).exists())


def _read_transcript_entries(transcript: str) -> list[JSONDict]:
    if not transcript or not Path(transcript).is_file():
        return []
    entries: list[JSONDict] = []
    with Path(transcript).open(encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(entry, dict):
                entries.append(entry)
    return entries


def transcript_prompt_count(transcript: str, marker: str) -> int:
    """Count genuine user-prompt entries whose decoded text contains marker.

    "Genuine" excludes harness-injected user entries (isMeta, isCompactSummary,
    isSidechain) — only a real submitted prompt counts.
    """
    n = 0
    for entry in _read_transcript_entries(transcript):
        if entry.get("type") != "user":
            continue
        if (
            entry.get("isMeta")
            or entry.get("isCompactSummary")
            or entry.get("isSidechain")
        ):
            continue
        content = (entry.get("message") or {}).get("content")
        if isinstance(content, list):
            content = " ".join(
                block.get("text", "") for block in content if isinstance(block, dict)
            )
        if isinstance(content, str) and marker in content:
            n += 1
    return n


def transcript_title_count(transcript: str, title: str) -> int:
    """Count custom-title entries whose customTitle is EXACTLY title."""
    n = 0
    for entry in _read_transcript_entries(transcript):
        if entry.get("type") == "custom-title" and entry.get("customTitle") == title:
            n += 1
    return n


def submit_titled(pane: str, title: str) -> bool:
    """/rename <title>: confirmed by a custom-title entry carrying it."""
    transcript = os.environ.get("HANDOFF_TRANSCRIPT", "")
    baseline = transcript_title_count(transcript, title)
    return _submit_until(
        pane, lambda: transcript_title_count(transcript, title) > baseline
    )


def submit_prompted(marker: str, pane: str) -> bool:
    """Prose: confirmed by a new genuine user-prompt entry containing marker."""
    transcript = os.environ.get("HANDOFF_TRANSCRIPT", "")
    baseline = transcript_prompt_count(transcript, marker)
    return _submit_until(
        pane, lambda: transcript_prompt_count(transcript, marker) > baseline
    )


def submit_exited(pane: str) -> bool:
    """Confirm /exit: HANDOFF_EXIT_FILE appearing, then consume it.

    The opposite polarity of submit_consumed (which waits for a file to
    disappear): SessionEnd, not a SessionStart, is the confirming event, and it
    can only ever CREATE the marker — stop-drive.sh clears any copy a stale,
    only-partly-successful earlier restart left behind before spawning the
    walker, so a leftover cannot false-positive this attempt.
    """
    exit_file = os.environ.get("HANDOFF_EXIT_FILE", "")
    if not exit_file:
        subprocess.run(["tmux", "send-keys", "-t", pane, "Enter"], check=False)
        return True
    if _submit_until(pane, lambda: Path(exit_file).exists()):
        Path(exit_file).unlink(missing_ok=True)
        return True
    return False


def watcher_fail(reason: str) -> None:
    """Record a non-delivery reason, then raise SystemExit(1).

    Unset HANDOFF_FAIL_FILE is tolerated: recording is additive, never a
    precondition for driving the pane.
    """
    fail_file = os.environ.get("HANDOFF_FAIL_FILE", "")
    if fail_file:
        Path(fail_file).write_text(reason + "\n", encoding="utf-8")
    raise SystemExit(1)
