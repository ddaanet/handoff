"""Shared pytest fixtures: the tmux stub used by the watcher tests.

Port of tests/watcher-test.bats's make_stub/on_enter — see
docs/changelog/2026-08-10-python-split.md.
"""

import os
import stat
from pathlib import Path

import pytest

_TMUX_STUB = """#!/usr/bin/env bash
sub="$1"; shift
case "$sub" in
  capture-pane)
    if [ -f "{stubdir}/sent_l" ]; then
      if [ -f "{stubdir}/pane_after_l.txt" ]; then cat "{stubdir}/pane_after_l.txt"
      else cat "{stubdir}/pane_after_l.auto"; fi
    elif [ -f "{stubdir}/sent_enter" ]; then cat "{stubdir}/pane_after_enter.txt"
    else cat "{stubdir}/pane_idle.txt"; fi ;;
  display-message)
    case "$*" in
      *pane_current_command*)
        cat "{stubdir}/foreground.txt"
        # Staged by foreground_flips_back_to: take effect from the NEXT
        # reading, so exactly one answer differs.
        if [ -f "{stubdir}/foreground_next.txt" ]; then
          mv "{stubdir}/foreground_next.txt" "{stubdir}/foreground.txt"
        fi ;;
      *) cat "{stubdir}/cursor.txt" ;;
    esac ;;
  send-keys)
    printf '%s|' "$@" >> "{sent}"; printf '\\n' >> "{sent}"
    case "$*" in
      *Enter*)
        [ -x "{stubdir}/on_enter.sh" ] && "{stubdir}/on_enter.sh"
        rm -f "{stubdir}/sent_l"; touch "{stubdir}/sent_enter" ;;
      *" -l "*)
        for a in "$@"; do last="$a"; done
        # \\302\\240 is U+00A0, the gap the real TUI paints after the glyph.
        printf '──── x ──\\n❯\\302\\240%s\\n' "$last" > "{stubdir}/pane_after_l.auto"
        touch "{stubdir}/sent_l" ;;
    esac ;;
esac
exit 0
"""


class TmuxStub:
    """A stub `tmux` on PATH, with pane text staged across three phases."""

    def __init__(self, stubdir: Path) -> None:
        self.stubdir = stubdir
        self.sent = stubdir / "sent.log"
        self.sent.write_text("")
        (stubdir / "pane_idle.txt").write_text("──── x ──\n❯ \n")
        (stubdir / "pane_after_enter.txt").write_text("──── x ──\n❯ \n")
        # No pane_after_l.txt: absent it, the stub echoes whatever was sent
        # literally, the way the real composer does. A test that needs some
        # other post-send pane writes the file and the stub defers to it.
        #
        # Cursor at the composer's start column, which is what an idle pane
        # reads as — the TUI's placeholder paints characters there but never
        # moves the cursor. `compose(x)` stages a user mid-prompt instead.
        self.cursor = stubdir / "cursor.txt"
        self.cursor.write_text("2,1")
        # The pane's foreground command. Defaults to the TUI, which is what it
        # reads as for every test that never exits it.
        self.foreground = stubdir / "foreground.txt"
        self.foreground.write_text("claude\n")
        tmux = stubdir / "tmux"
        tmux.write_text(_TMUX_STUB.format(stubdir=stubdir, sent=self.sent))
        tmux.chmod(tmux.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

    def on_enter(self, script: str) -> None:
        path = self.stubdir / "on_enter.sh"
        path.write_text(f"#!/usr/bin/env bash\n{script}\n")
        path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

    def compose(self, cursor_x: int, cursor_y: int = 1) -> None:
        """Stage a user mid-prompt: the cursor sitting past the start column."""
        self.cursor.write_text(f"{cursor_x},{cursor_y}")

    def set_foreground(self, command: str) -> None:
        """Stage what tmux reports as the pane's foreground process."""
        self.foreground.write_text(f"{command}\n")

    def foreground_changes_to(self, command: str) -> None:
        """Answer the current foreground exactly once more, then ``command``.

        Deterministic where a timer is not: the walker samples its baseline
        from the pane before typing anything, and a thread flipping the file
        races that first read.
        """
        (self.stubdir / "foreground_next.txt").write_text(f"{command}\n")

    def sent_text(self) -> str:
        return self.sent.read_text()

    def path_env(self) -> str:
        return f"{self.stubdir}{os.pathsep}{os.environ['PATH']}"


@pytest.fixture
def tmux_stub(tmp_path: Path) -> TmuxStub:
    stubdir = tmp_path / "stub"
    stubdir.mkdir()
    return TmuxStub(stubdir)
