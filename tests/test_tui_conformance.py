"""Conformance probe: do the frozen pane fixtures still match a live TUI?

This is not a test of the predicates — ``tests/test_watcher_lib.py`` owns
those, offline and deterministic. It asserts the other half: that the strings
those tests freeze are still what Claude Code actually paints. A frozen fixture
cannot tell you it has gone stale, and that silence is what let ``is_typing``
sit inverted against a U+00A0 composer gap while its suite stayed green — see
``docs/changelog/2026-08-13-predicates-match-the-real-pane.md``.

Excluded from ``just precommit`` by the ``live`` marker: it needs a real
``claude`` on PATH and a real tmux server, so it cannot run inside the agent's
sandbox (which blocks socket creation), and it takes ~40s. Run it with
``just tui-conformance``.

It costs nothing to run. Every line is typed into the composer and then
cleared, never submitted, so no turn is ever taken.

Residual, deliberately uncovered: ``is_busy``'s timer forms. Reaching the
spinner at all needs a submitted turn, which this probe never does, so those
two fixtures stay frozen-only.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import time
from collections.abc import Iterator
from pathlib import Path

import _watcher_lib as wl
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_watcher_lib as fx

pytestmark = pytest.mark.live

REPO = Path(__file__).resolve().parent.parent

# Booting into a directory whose trust dialog has never been accepted parks a
# modal over the composer and every assertion below reads that instead. The
# repo root is already trusted, and its own SessionStart hooks only read.
PROBE_CWD = Path(os.environ.get("HANDOFF_CONFORMANCE_CWD", str(REPO)))

BOOT_TIMEOUT = 30.0
SETTLE = 12.0  # boot latency repaints the pane for several seconds after ❯


def _tmux(sock: str, *args: str) -> str:
    proc = subprocess.run(
        ["tmux", "-L", sock, *args], capture_output=True, text=True, check=False
    )
    return proc.stdout


def _capture(sock: str, pane: str) -> str:
    """Snapshot the pane the way the walker's own ``snap`` does."""
    return "\n".join(_tmux(sock, "capture-pane", "-p", "-t", pane).split("\n")[-40:])


def _composer_line(text: str) -> str:
    """Return the last ``❯`` line of a captured pane, verbatim."""
    lines = [ln for ln in wl.strip(text).split("\n") if "❯" in ln]
    return lines[-1] if lines else ""


def _type(sock: str, pane: str, line: str) -> str:
    """Type ``line`` and poll for it exactly as the walker does.

    Polls rather than reading once at VERIFY_DELAY, because the composer does
    not always repaint that fast — which is the race wait_for_landing exists to
    absorb, and asserting through it is what keeps this probe measuring the TUI
    rather than the paint latency of one run.
    """
    _tmux(sock, "send-keys", "-t", pane, "-l", line)
    deadline = time.monotonic() + wl._env_float("HANDOFF_WATCHER_LANDING_DELAY", 3.0)
    captured = _capture(sock, pane)
    while time.monotonic() < deadline and not wl.line_landed(captured, line):
        time.sleep(0.1)
        captured = _capture(sock, pane)
    return captured


def _clear(sock: str, pane: str) -> None:
    _tmux(sock, "send-keys", "-t", pane, "C-u")
    time.sleep(0.7)


def _cursor(sock: str, pane: str) -> tuple[int, int]:
    out = _tmux(sock, "display-message", "-p", "-t", pane, "#{cursor_x},#{cursor_y}")
    x, _, y = out.strip().partition(",")
    return int(x), int(y)


@pytest.fixture(scope="module")
def live_pane() -> Iterator[tuple[str, str]]:
    """Boot a real Claude Code TUI in a private tmux server; yield (sock, pane).

    A client is attached because an unattached server has no focus state to
    report, and the user's own tmux runs with ``focus-events on``.
    """
    for tool in ("tmux", "claude", "script"):
        if not shutil.which(tool):
            pytest.skip(f"{tool} not on PATH — conformance probe needs a real TUI")

    sock = f"handoff-conformance-{os.getpid()}"
    conf = Path(tempfile.gettempdir()) / f"{sock}.conf"
    conf.write_text("set -g focus-events on\nset -g status off\n", encoding="utf-8")

    client: subprocess.Popen[bytes] | None = None
    try:
        _tmux(
            sock,
            "-f",
            str(conf),
            "new-session",
            "-d",
            "-x",
            "200",
            "-y",
            "50",
            "-c",
            str(PROBE_CWD),
            "claude",
        )
        pane = _tmux(sock, "list-panes", "-t", "0", "-F", "#{pane_id}").split("\n")[0]
        if not pane:
            pytest.fail("tmux reported no pane — the probe server never started")

        client = subprocess.Popen(
            [
                "script",
                "-q",
                "-c",
                f"stty rows 50 cols 200; tmux -L {sock} attach -t 0",
                "/dev/null",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        deadline = time.monotonic() + BOOT_TIMEOUT
        while time.monotonic() < deadline:
            time.sleep(0.5)
            if "❯" in _capture(sock, pane):
                break
        else:
            pytest.fail(
                "the TUI never painted a ❯ composer within "
                f"{BOOT_TIMEOUT}s. Either it failed to boot, or the composer "
                f"glyph changed.\nPane:\n{_capture(sock, pane)}"
            )

        time.sleep(SETTLE)
        yield sock, pane
    finally:
        if client is not None:
            client.kill()
        _tmux(sock, "kill-server")
        conf.unlink(missing_ok=True)


@pytest.mark.parametrize(
    "line",
    ["/compact", "/rename Conformance Probe", "continue with the task"],
    ids=["slash", "slash-with-args", "prose"],
)
def test_composer_gap_is_still_the_frozen_one(
    live_pane: tuple[str, str], line: str
) -> None:
    """The load-bearing assertion: the gap character the fixtures encode.

    If this reds, re-capture and update ``test_watcher_lib``'s fixtures — the
    predicates match ``\\s`` and so will keep working, but the fixtures have
    stopped describing the pane and stop being evidence of anything.
    """
    sock, pane = live_pane
    _clear(sock, pane)
    captured = _composer_line(_type(sock, pane, line))
    _clear(sock, pane)
    assert captured == f"❯{fx.NBSP}{line}"


@pytest.mark.parametrize(
    "line",
    ["/compact", "/rename Conformance Probe", "continue with the task"],
    ids=["slash", "slash-with-args", "prose"],
)
def test_line_landed_sees_a_line_the_walker_just_typed(
    live_pane: tuple[str, str], line: str
) -> None:
    """The behaviour the frozen suite claims, against the real thing."""
    sock, pane = live_pane
    _clear(sock, pane)
    captured = _type(sock, pane, line)
    _clear(sock, pane)
    assert wl.line_landed(captured, line), (
        f"walker would abort on: {_composer_line(captured)!r}"
    )


def test_line_landed_false_on_the_live_idle_placeholder(
    live_pane: tuple[str, str],
) -> None:
    """Paired with the positives: the same pane, nothing typed.

    The composer is not empty when idle — the TUI paints a suggestion into it —
    so this is the row that catches a confirm predicate reverting to "is there
    anything here".
    """
    sock, pane = live_pane
    _clear(sock, pane)
    assert not wl.line_landed(_capture(sock, pane), "/compact")


def test_the_idle_placeholder_does_not_read_as_a_user_composing(
    live_pane: tuple[str, str],
) -> None:
    """The pre-send bail, against a real idle pane and a real cursor.

    Load-bearing: a false positive here aborts every line before the walker
    types it, and it would bite hardest right after a transition, where the
    composer is freshest and the placeholder is showing.
    """
    sock, pane = live_pane
    _clear(sock, pane)
    full = _tmux(sock, "capture-pane", "-p", "-t", pane)
    x, y = _cursor(sock, pane)
    assert not wl.composer_has_user_text(full, x, y), (
        f"idle composer read as a user mid-prompt: cursor=({x},{y}) "
        f"line={_composer_line(full)!r}"
    )


def test_a_typed_line_does_read_as_content_in_the_composer(
    live_pane: tuple[str, str],
) -> None:
    """Paired with the row above, over the same pane: the bail must still fire.

    Without this, widening the bail into always-False would pass unnoticed and
    the walker would type over a half-composed prompt.
    """
    sock, pane = live_pane
    _clear(sock, pane)
    _type(sock, pane, "half a prompt")
    full = _tmux(sock, "capture-pane", "-p", "-t", pane)
    x, y = _cursor(sock, pane)
    _clear(sock, pane)
    assert wl.composer_has_user_text(full, x, y), (
        f"typed text did not read as composing: cursor=({x},{y})"
    )


def test_is_unknown_command_still_matches_the_rejection_text(
    live_pane: tuple[str, str],
) -> None:
    """``is_unknown_command`` greps a bare substring, so it is exposed too.

    A gap the TUI repaints inside this sentence would break it exactly the way
    the composer gap broke is_typing, and nothing else would notice.
    """
    sock, pane = live_pane
    _clear(sock, pane)
    captured = _type(sock, pane, "/compzzz-no-such-command")
    # Poll past VERIFY_DELAY: "never painted" and "painted too late for the
    # walker to see it" are different defects and want different fixes.
    seen_at: float | None = None
    waited = wl._env_float("HANDOFF_WATCHER_VERIFY_DELAY", 0.5)
    for target in (0.5, 1.0, 2.0, 4.0, 8.0):
        if target > waited:
            time.sleep(target - waited)
            waited = target
            captured = _capture(sock, pane)
        if wl.is_unknown_command(captured):
            seen_at = waited
            break
    _clear(sock, pane)
    window = wl._env_float("HANDOFF_WATCHER_RECOGNITION_DELAY", 3.0)
    assert seen_at is not None, (
        "the TUI never painted 'No commands match' within 8s — the walker "
        f"would Enter a command it has already rejected.\nPane:\n{captured}"
    )
    assert seen_at <= window, (
        f"'No commands match' took until {seen_at}s, past the walker's "
        f"{window}s recognition window, so the check gives up before the "
        "rejection is painted and the command goes through to Enter"
    )
