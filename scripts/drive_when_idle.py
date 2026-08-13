#!/usr/bin/env python3
"""Handoff watcher: type a sequence of lines into a tmux pane, one at a time.

Each line is waited for and then confirmed. Run detached — by stop-drive.sh for
the lines typed before a transition, and by the transition's own SessionStart
loader for the lines typed after it — so it outlives the turn that spawned it.

Usage: drive_when_idle.py <pane-id> <line>...

One argument per line: the caller passes the sentinel's lines through verbatim,
and they are the literal keystrokes. The walker does not know which command
belongs to which kind of transition — that is fixed by handoff_drive_read's per-
kind validation, upstream. What it dispatches on is the command itself, which is
what lets `/rename` appear in two kinds with two different fates: terminal under
`rename`, followed by `/clear` under `clear`.

Port of drive-when-idle.sh — see docs/changelog/2026-08-10-python-split.md.
"""

from __future__ import annotations

import subprocess
import sys
import time

from _watcher_lib import (
    _env_float,
    capture_full,
    composer_has_user_text,
    cursor_position,
    is_unknown_command,
    snap,
    submit_consumed,
    submit_exited,
    submit_prompted,
    submit_titled,
    wait_for_idle,
    wait_for_landing,
    watcher_fail,
)


def _send_literal(pane: str, line: str) -> None:
    subprocess.run(["tmux", "send-keys", "-t", pane, "-l", line], check=False)


def _drive_shell_line(pane: str, line: str, settle: float) -> None:
    """Type one line into a bare shell prompt, following a confirmed /exit.

    _drive_line's checks assume the Claude Code TUI: composer_has_user_text and
    line_landed read the `❯` composer, is_unknown_command its "No commands
    match" text — neither
    exists once the process has exited to a shell, and neither is a reliable
    signal of a shell's own readiness across every user's shell prompt. So this
    line skips them entirely: a fixed settle after the confirmed /exit, then the
    same Enter-retry-then-poll _submit_until already uses for the other
    primitives (via submit_consumed, unchanged — the resumed session's
    SessionStart is still what confirms it).
    """
    time.sleep(settle)
    _send_literal(pane, line)
    if not submit_consumed(pane):
        watcher_fail(
            f"`{line}` was typed and Entered, but no SessionStart(resume) followed"
        )


def _drive_line(pane: str, line: str, verify_delay: float) -> None:
    """Type one line into a pane, confirmed by its own primitive.

    See the module docstring for the dispatch rules per command kind.
    """
    # FR-H: every line re-gates. Confirming the previous one can take
    # minutes and the pane is live throughout, so idleness established
    # before it says nothing about now.
    wait_for_idle(pane)

    # Load-bearing, not defensive: send-keys concatenates onto
    # half-typed user text. A bail is a non-delivery like any other.
    if composer_has_user_text(capture_full(pane), *cursor_position(pane)):
        watcher_fail(f"the user was composing a prompt, so `{line}` was never typed")

    # Send literally so nothing in the line is read as tmux key names;
    # Enter is always a separate keystroke, sent by confirmation below.
    _send_literal(pane, line)

    # Type-verify-submit gap for a `/` line (recognition), settle for
    # prose (an Enter sent right after a long literal send lands inside
    # the TUI's paste window and is absorbed as a line break).
    time.sleep(verify_delay)

    # A dead pane or a pane in copy mode swallows the literal send: the
    # composer looks untouched. Polled, not read once — see wait_for_landing.
    if not wait_for_landing(pane, line):
        watcher_fail(
            f"`{line}` did not land in the composer — a dead pane or copy "
            "mode may have swallowed it"
        )

    if line.startswith("/") and _was_rejected(pane):
        # Clear the composer and leave the pane as we found it. Never
        # Enter on a command the TUI has already said it cannot run.
        subprocess.run(["tmux", "send-keys", "-t", pane, "C-u"], check=False)
        watcher_fail(f"the TUI did not recognize `{line}`, so it was cleared unrun")

    _confirm_line(pane, line)


def _was_rejected(pane: str) -> bool:
    """Poll for the TUI's "No commands match", which lands after VERIFY_DELAY.

    The single read this replaced sampled at VERIFY_DELAY, before the pane had
    painted anything, and passed every unknown command straight to Enter.

    The paint is not prompt and not stable: measured at ~1s and ~2s on
    consecutive runs of the same probe, so the window is sized from the slower
    observation with margin rather than from a figure that looked typical. A
    *recognized* command waits the window out in full — that latency is the
    price of the check being real, and it is paid once per slash line.

    Residual: a machine slower than the margin still misses the rejection and
    Enters the command. `just tui-conformance` asserts against this exact
    tunable, so a drift past it fails there rather than in a transition.
    """
    deadline = time.monotonic() + _env_float("HANDOFF_WATCHER_RECOGNITION_DELAY", 3.0)
    while time.monotonic() < deadline:
        if is_unknown_command(snap(pane)):
            return True
        time.sleep(_env_float("HANDOFF_WATCHER_POLL", 0.1))
    return False


def _confirm_line(pane: str, line: str) -> None:
    """Confirm a just-typed line against a harness-authoritative signal.

    Never the pane. Failing here stops the sequence.
    """
    if line.startswith("/rename "):
        title = line[len("/rename ") :]
        if not submit_titled(pane, title):
            watcher_fail(
                f"`{line}` was typed and Entered, but the session title never changed"
            )
    elif line.startswith(("/compact", "/clear")):
        if not submit_consumed(pane):
            watcher_fail(
                f"`{line}` was typed and Entered, but no "
                f"{line.split(maxsplit=1)[0]} followed"
            )
    elif line == "/exit":
        if not submit_exited(pane):
            watcher_fail(f"`{line}` was typed and Entered, but the session never ended")
    elif not submit_prompted(line, pane):
        watcher_fail(
            "the continuation prompt was typed but three Enters did not submit it"
        )


def main(argv: list[str]) -> int:
    """Drive pane argv[1] through the lines in argv[2:], one at a time."""
    if len(argv) < 2:
        print("drive_when_idle.py: pane id required", file=sys.stderr)
        return 1
    pane = argv[1]
    lines = argv[2:]
    verify_delay = _env_float("HANDOFF_WATCHER_VERIFY_DELAY", 0.5)
    shell_settle = _env_float("HANDOFF_WATCHER_SHELL_SETTLE", 1.0)

    for line in lines:
        if line.startswith("claude --resume "):
            _drive_shell_line(pane, line, shell_settle)
        else:
            _drive_line(pane, line, verify_delay)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
