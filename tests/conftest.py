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
    if [ -f "{stubdir}/sent_l" ]; then cat "{stubdir}/pane_after_l.txt"
    elif [ -f "{stubdir}/sent_enter" ]; then cat "{stubdir}/pane_after_enter.txt"
    else cat "{stubdir}/pane_idle.txt"; fi ;;
  send-keys)
    printf '%s|' "$@" >> "{sent}"; printf '\\n' >> "{sent}"
    case "$*" in
      *Enter*)
        [ -x "{stubdir}/on_enter.sh" ] && "{stubdir}/on_enter.sh"
        rm -f "{stubdir}/sent_l"; touch "{stubdir}/sent_enter" ;;
      *" -l "*) touch "{stubdir}/sent_l" ;;
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
        (stubdir / "pane_after_l.txt").write_text("──── x ──\n❯ …\n")
        (stubdir / "pane_after_enter.txt").write_text("──── x ──\n❯ \n")
        tmux = stubdir / "tmux"
        tmux.write_text(_TMUX_STUB.format(stubdir=stubdir, sent=self.sent))
        tmux.chmod(tmux.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

    def on_enter(self, script: str) -> None:
        path = self.stubdir / "on_enter.sh"
        path.write_text(f"#!/usr/bin/env bash\n{script}\n")
        path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

    def sent_text(self) -> str:
        return self.sent.read_text()

    def path_env(self) -> str:
        return f"{self.stubdir}{os.pathsep}{os.environ['PATH']}"


@pytest.fixture
def tmux_stub(tmp_path: Path) -> TmuxStub:
    stubdir = tmp_path / "stub"
    stubdir.mkdir()
    return TmuxStub(stubdir)
