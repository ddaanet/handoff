#!/usr/bin/env python3
"""Shared machinery for drive_when_idle.py, the one detached watcher.

Pure predicates over captured tmux pane text, the readers that feed them (snap,
capture_full, cursor_position), the pane-polling scaffold (wait_for_idle and the
four submit confirmations, all pane-scoped) and the tunables, read from the
environment at call time so tests can override them per call rather than at
import time.

Port of _watcher-lib.sh — see docs/changelog/2026-08-10-python-split.md.
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
    r"""Report whether the Claude TUI chrome spinner is on screen.

    The elapsed timer carries a unit per magnitude once it passes a minute —
    ``(37s ·`` becomes ``(8m 30s ·`` — so the seconds no longer abut the ``(``.
    Every gap is ``\s``, never a literal space, for the reason in line_landed:
    the TUI's own padding is not the ASCII one an author assumes.
    """
    return bool(
        re.search(r"\((?:[0-9]+[hm]\s)*[0-9]+s\s·|esc to interrupt", strip(text))
    )


PROMPT_GLYPH = "❯"


def line_landed(text: str, line: str) -> bool:
    """Report whether ``line`` is sitting in the composer.

    Asks for the text the walker just typed, rather than whether the composer
    is non-empty: an idle composer is *not* empty — the TUI paints a faint
    placeholder into it — so non-emptiness answers a different question than
    the caller is asking. Matching the line itself needs no opinion about the
    padding around it, which is what made the older predicate invert when that
    padding turned out to be U+00A0.

    Whitespace is squashed on both sides, so a composer row-wrap that splits
    the line — mid-word, at whatever width the pane happens to be — still
    matches.
    """
    wanted = _squash(line)
    return bool(wanted) and wanted in _squash(_composer_region(text))


def wait_for_landing(pane: str, line: str) -> bool:
    """Poll until ``line`` is in the composer, up to ``LANDING_DELAY``.

    A single read at VERIFY_DELAY is a race the pane loses often enough to
    matter: the composer had still not repainted 0.5s after the send on one
    run in four of the conformance probe, showing its idle placeholder where
    the line should have been. Read once, that is indistinguishable from a
    swallowed keystroke, and the walker aborts a line it successfully typed.
    """
    deadline = time.monotonic() + _env_float("HANDOFF_WATCHER_LANDING_DELAY", 3.0)
    poll = _env_float("HANDOFF_WATCHER_POLL", 0.1)
    while time.monotonic() < deadline:
        if line_landed(snap(pane), line):
            return True
        time.sleep(poll)
    return False


def composer_has_user_text(text: str, cursor_x: int, cursor_y: int) -> bool:
    """Report whether the user has something half-typed in the composer.

    Keys on the cursor, not the text, for the placeholder reason in
    line_landed: the glyph row carries painted characters either way, and only
    the cursor distinguishes the TUI's own suggestion from something a person
    typed.

    Residual: a user who has typed and then sent the cursor home reads as
    empty here. No signal on this pane separates that from an idle composer,
    and the walker's send would concatenate onto their text.
    """
    lines = strip(text).split("\n")
    index = _composer_index(lines)
    if index is None:
        return False
    if cursor_y != index:
        # Below the glyph row means their text wrapped onto it; above means
        # the cursor is not in the composer at all.
        return cursor_y > index
    return cursor_x > composer_start_column(lines[index])


def composer_start_column(line: str) -> int:
    """Return where composer content begins, derived from the line itself.

    Never a constant. The glyph's column and the width of the gap after it are
    the TUI's layout, and pinning today's values is exactly what makes a
    predicate invert in silence when they move.
    """
    index = line.find(PROMPT_GLYPH)
    after = line[index + 1 :]
    return index + 1 + (len(after) - len(after.lstrip()))


def _composer_region(text: str) -> str:
    """Return the composer's rows: the last glyph row through end of capture.

    The conversation renders above the composer, so starting at the last glyph
    is what stops a prose line quoted earlier in the scrollback from matching.
    """
    lines = strip(text).split("\n")
    index = _composer_index(lines)
    return "\n".join(lines[index:]) if index is not None else ""


def _composer_index(lines: list[str]) -> int | None:
    for index in range(len(lines) - 1, -1, -1):
        if PROMPT_GLYPH in lines[index]:
            return index
    return None


def _squash(text: str) -> str:
    return re.sub(r"\s+", "", strip(text))


def is_unknown_command(text: str) -> bool:
    """Report whether the composer holds a command the TUI will not run."""
    return "No commands match" in strip(text)


def snap(pane: str) -> str:
    """Capture the visible pane text (never scrollback), last 40 lines."""
    return "\n".join(capture_full(pane).split("\n")[-40:])


def capture_full(pane: str) -> str:
    """Capture every visible row, untruncated.

    composer_has_user_text compares the cursor's row against the glyph's, and
    both must be indices into the same frame — snap's 40-line tail would shift
    one and not the other.
    """
    result = subprocess.run(
        ["tmux", "capture-pane", "-p", "-t", pane],
        capture_output=True,
        text=True,
        check=False,
    )
    return result.stdout


def cursor_position(pane: str) -> tuple[int, int]:
    """Read the pane's cursor as ``(x, y)``, both 0-based rows/columns.

    An unreadable answer returns ``(-1, -1)``, which every caller reads as "no
    user text". Failing open is deliberate: the bail this feeds is protective,
    and failing closed would abort every line the walker ever types the moment
    this one query broke.
    """
    result = subprocess.run(
        ["tmux", "display-message", "-p", "-t", pane, "#{cursor_x},#{cursor_y}"],
        capture_output=True,
        text=True,
        check=False,
    )
    x, _, y = result.stdout.strip().partition(",")
    try:
        return int(x), int(y)
    except ValueError:
        return -1, -1


def wait_for_idle(pane: str) -> None:
    """Wait until idle is stable for ~3 consecutive polls, up to TIMEOUT.

    Falls through on timeout — the caller's composer_has_user_text check is the
    real gate against typing over a live composer.
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


def wait_for_foreground_change(pane: str, baseline: str, timeout: float) -> bool:
    """Wait until the pane's foreground command is no longer ``baseline``.

    Claude Code stops consuming input well before it releases the terminal,
    and a keystroke sent inside that window is dropped leaving no trace: the
    pane looks untouched and the line simply never appears. The foreground
    command reverting from Claude Code to the pane's own shell is the
    observable end of that window, which a fixed sleep can only guess at.

    Two consecutive readings, so a transient during teardown does not release
    the gate early. Returns False on timeout rather than raising — the walker
    owns failure for the whole sequence.
    """
    poll = _env_float("HANDOFF_WATCHER_FOREGROUND_POLL", 0.1)
    deadline = time.monotonic() + timeout
    seen = 0
    while time.monotonic() < deadline:
        if pane_foreground(pane) != baseline:
            seen += 1
            if seen >= 2:
                return True
        else:
            seen = 0
        time.sleep(poll)
    return False


def pane_foreground(pane: str) -> str:
    """Read what tmux reports as the pane's foreground process."""
    result = subprocess.run(
        ["tmux", "display-message", "-p", "-t", pane, "#{pane_current_command}"],
        capture_output=True,
        text=True,
        check=False,
    )
    return result.stdout.strip()


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
