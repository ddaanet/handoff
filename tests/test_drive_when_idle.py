"""End-to-end tests for drive_when_idle.py against the tmux stub.

Port of the walker sections of tests/watcher-test.bats — see
docs/changelog/2026-08-10-python-split.md.
"""

from __future__ import annotations

import json
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from conftest import TmuxStub

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "drive_when_idle.py"

TITLE = "Driven Transitions Design"


def walk(
    tmux_stub: TmuxStub,
    *lines: str,
    env: dict[str, str] | None = None,
    timeout: float = 5,
    consume: float = 1,
) -> subprocess.CompletedProcess[str]:
    full_env = {
        "PATH": tmux_stub.path_env(),
        "HANDOFF_WATCHER_TIMEOUT": str(timeout),
        "HANDOFF_WATCHER_POLL": "0.01",
        "HANDOFF_WATCHER_VERIFY_DELAY": "0.01",
        "HANDOFF_WATCHER_CONSUME_POLL": "0.05",
        "HANDOFF_WATCHER_CONSUME_TIMEOUT": str(consume),
    }
    if env:
        full_env.update(env)
    return subprocess.run(
        [sys.executable, str(SCRIPT), "%9", *lines],
        env=full_env,
        capture_output=True,
        text=True,
        check=False,
    )


def test_slash_line_typed_then_recognition_read_back_then_entered(
    tmux_stub: TmuxStub, tmp_path: Path
) -> None:
    (tmux_stub.stubdir / "pane_after_l.txt").write_text(
        "/compact  Compact the conversation\n❯ /compact\n"
    )
    result = walk(
        tmux_stub,
        "/compact keep the parser work",
        env={"HANDOFF_PENDING_FILE": str(tmp_path / "absent")},
    )
    assert result.returncode == 0
    sent = tmux_stub.sent_text()
    assert "-l|/compact keep the parser work|" in sent
    assert "Enter|" in sent
    lines = sent.splitlines()
    l_line = next(i for i, line in enumerate(lines) if "-l|" in line)
    e_line = next(i for i, line in enumerate(lines) if "Enter|" in line)
    assert l_line < e_line


def test_unrecognized_command_cleared_with_ctrl_u_never_entered(
    tmux_stub: TmuxStub, tmp_path: Path
) -> None:
    (tmux_stub.stubdir / "pane_after_l.txt").write_text(
        'No commands match "/compzzz"\n❯ /compzzz\n'
    )
    fail_file = tmp_path / "autodrive.failed"
    result = walk(
        tmux_stub,
        "/compzzz",
        "a continuation that must never be typed",
        env={"HANDOFF_FAIL_FILE": str(fail_file)},
    )
    assert result.returncode != 0
    sent = tmux_stub.sent_text()
    assert "C-u|" in sent
    assert "Enter|" not in sent
    assert "continuation" not in sent
    assert "recognize" in fail_file.read_text().lower()
    assert len(fail_file.read_text().splitlines()) == 1


def test_nothing_sent_while_user_is_composing(
    tmux_stub: TmuxStub, tmp_path: Path
) -> None:
    (tmux_stub.stubdir / "pane_idle.txt").write_text(
        "──── x ──\n❯ half-typed thought\n"
    )
    fail_file = tmp_path / "autodrive.failed"
    result = walk(
        tmux_stub,
        "/clear",
        "should not send",
        env={"HANDOFF_FAIL_FILE": str(fail_file)},
        timeout=1,
    )
    assert result.returncode != 0
    assert tmux_stub.sent_text() == ""
    assert "composing" in fail_file.read_text().lower()


def test_non_delivery_with_no_fail_file_still_stops_walker(
    tmux_stub: TmuxStub, tmp_path: Path
) -> None:
    result = walk(
        tmux_stub,
        "a prose line nothing will accept",
        env={"HANDOFF_TRANSCRIPT": str(tmp_path / "absent.jsonl")},
    )
    assert result.returncode != 0


def test_line_swallowed_by_pane_fails_fast_before_enter(
    tmux_stub: TmuxStub, tmp_path: Path
) -> None:
    (tmux_stub.stubdir / "pane_after_l.txt").write_text("──── x ──\n❯ \n")
    fail_file = tmp_path / "autodrive.failed"
    result = walk(
        tmux_stub,
        "/compact keep the parser work",
        env={"HANDOFF_FAIL_FILE": str(fail_file)},
    )
    assert result.returncode != 0
    sent = tmux_stub.sent_text()
    assert "-l|/compact keep the parser work|" in sent
    assert "Enter|" not in sent
    text = fail_file.read_text().lower()
    assert "did not land" in text
    assert "was typed and entered" not in text


def test_swallowed_prose_line_fails_fast_before_enter(
    tmux_stub: TmuxStub, tmp_path: Path
) -> None:
    (tmux_stub.stubdir / "pane_after_l.txt").write_text("──── x ──\n❯ \n")
    fail_file = tmp_path / "autodrive.failed"
    result = walk(
        tmux_stub, "continue with task 3", env={"HANDOFF_FAIL_FILE": str(fail_file)}
    )
    assert result.returncode != 0
    sent = tmux_stub.sent_text()
    assert "-l|continue with task 3|" in sent
    assert "Enter|" not in sent
    assert "did not land" in fail_file.read_text().lower()


def test_rename_line_confirms_by_custom_title_entry(
    tmux_stub: TmuxStub, tmp_path: Path
) -> None:
    tr = tmp_path / "t.jsonl"
    tr.write_text("")
    tmux_stub.on_enter(
        f'printf \'{{"type":"custom-title","customTitle":"{TITLE}"}}\\n\' >> \'{tr}\''
    )
    result = walk(tmux_stub, f"/rename {TITLE}", env={"HANDOFF_TRANSCRIPT": str(tr)})
    assert result.returncode == 0
    assert f"-l|/rename {TITLE}|" in tmux_stub.sent_text()


def test_rename_line_not_confirmed_by_title_merely_on_pane(
    tmux_stub: TmuxStub, tmp_path: Path
) -> None:
    (tmux_stub.stubdir / "pane_after_l.txt").write_text(
        f"──── {TITLE} ──\n❯ /rename {TITLE}\n"
    )
    tr = tmp_path / "t.jsonl"
    tr.write_text("")
    fail_file = tmp_path / "autodrive.failed"
    result = walk(
        tmux_stub,
        f"/rename {TITLE}",
        env={"HANDOFF_TRANSCRIPT": str(tr), "HANDOFF_FAIL_FILE": str(fail_file)},
    )
    assert result.returncode != 0
    assert "title never changed" in fail_file.read_text().lower()


def test_rename_line_not_confirmed_by_preexisting_entry(
    tmux_stub: TmuxStub, tmp_path: Path
) -> None:
    tr = tmp_path / "t.jsonl"
    tr.write_text(f'{{"type":"custom-title","customTitle":"{TITLE}"}}\n')
    fail_file = tmp_path / "autodrive.failed"
    result = walk(
        tmux_stub,
        f"/rename {TITLE}",
        env={"HANDOFF_TRANSCRIPT": str(tr), "HANDOFF_FAIL_FILE": str(fail_file)},
    )
    assert result.returncode != 0
    assert "title never changed" in fail_file.read_text().lower()


def test_compact_line_confirms_by_pending_file_consumed(
    tmux_stub: TmuxStub, tmp_path: Path
) -> None:
    (tmux_stub.stubdir / "pane_after_l.txt").write_text(
        "/compact  Compact the conversation\n❯ /compact\n"
    )
    pending = tmp_path / "autodrive"
    pending.write_text("")
    fail_file = tmp_path / "autodrive.failed"

    def consume_soon() -> None:
        time.sleep(0.3)
        pending.unlink(missing_ok=True)

    threading.Thread(target=consume_soon, daemon=True).start()
    result = walk(
        tmux_stub,
        "/compact keep the parser work",
        env={"HANDOFF_PENDING_FILE": str(pending), "HANDOFF_FAIL_FILE": str(fail_file)},
        consume=5,
    )
    assert result.returncode == 0
    assert not fail_file.exists()


def test_compact_line_reported_when_nothing_consumes_it(
    tmux_stub: TmuxStub, tmp_path: Path
) -> None:
    (tmux_stub.stubdir / "pane_after_l.txt").write_text(
        "/compact  Compact the conversation\n❯ /compact\n"
    )
    pending = tmp_path / "autodrive"
    pending.write_text("")
    fail_file = tmp_path / "autodrive.failed"
    result = walk(
        tmux_stub,
        "/compact keep the parser work",
        env={"HANDOFF_PENDING_FILE": str(pending), "HANDOFF_FAIL_FILE": str(fail_file)},
    )
    assert result.returncode != 0
    assert "no /compact followed" in fail_file.read_text().lower()


def test_clear_line_with_nothing_to_confirm_not_reported_failed(
    tmux_stub: TmuxStub, tmp_path: Path
) -> None:
    (tmux_stub.stubdir / "pane_after_l.txt").write_text(
        "/clear  Clear the conversation\n❯ /clear\n"
    )
    fail_file = tmp_path / "autodrive.failed"
    result = walk(tmux_stub, "/clear", env={"HANDOFF_FAIL_FILE": str(fail_file)})
    assert result.returncode == 0
    assert not fail_file.exists()


def test_prose_confirms_queued_submit_that_shows_no_spinner(
    tmux_stub: TmuxStub, tmp_path: Path
) -> None:
    tr = tmp_path / "t.jsonl"
    stale = {
        "type": "user",
        "message": {"role": "user", "content": "continue with task 3 (stale copy)"},
    }
    tr.write_text(json.dumps(stale) + "\n")
    fresh = {
        "type": "user",
        "message": {"role": "user", "content": "continue with task 3"},
    }
    tmux_stub.on_enter(f"printf '{json.dumps(fresh)}\\n' >> '{tr}'")
    result = walk(
        tmux_stub, "continue with task 3", env={"HANDOFF_TRANSCRIPT": str(tr)}
    )
    assert result.returncode == 0
    sent = tmux_stub.sent_text()
    assert "-l|continue with task 3|" in sent
    assert sent.count("Enter|") == 1


def test_prose_retries_three_times_and_reports_when_enter_absorbed(
    tmux_stub: TmuxStub, tmp_path: Path
) -> None:
    tr = tmp_path / "t.jsonl"
    tr.write_text("")
    fail_file = tmp_path / "autodrive.failed"
    result = walk(
        tmux_stub,
        "continue with task 3",
        env={"HANDOFF_TRANSCRIPT": str(tr), "HANDOFF_FAIL_FILE": str(fail_file)},
    )
    assert result.returncode != 0
    sent = tmux_stub.sent_text()
    assert sent.count("Enter|") == 3
    assert sent.count("-l|") == 1
    assert "continuation prompt" in fail_file.read_text().lower()
    assert len(fail_file.read_text().splitlines()) == 1


def test_prose_confirms_submit_landing_after_fast_retry_window(
    tmux_stub: TmuxStub, tmp_path: Path
) -> None:
    tr = tmp_path / "t.jsonl"
    tr.write_text("")

    entry = {
        "type": "user",
        "message": {"role": "user", "content": "continue with task 3"},
    }

    def land_late() -> None:
        time.sleep(1)
        with Path(tr).open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry) + "\n")

    threading.Thread(target=land_late, daemon=True).start()
    result = walk(
        tmux_stub,
        "continue with task 3",
        env={"HANDOFF_TRANSCRIPT": str(tr)},
        consume=5,
    )
    assert result.returncode == 0
    assert tmux_stub.sent_text().count("Enter|") == 3


def test_multiline_sequence_types_every_line_in_order(
    tmux_stub: TmuxStub, tmp_path: Path
) -> None:
    tr = tmp_path / "t.jsonl"
    tr.write_text("")
    pending = tmp_path / "autodrive"
    pending.write_text("")
    tmux_stub.on_enter(
        f'printf \'{{"type":"custom-title","customTitle":"{TITLE}"}}\\n\' >> \'{tr}\'; '
        f"rm -f '{pending}'"
    )
    fail_file = tmp_path / "autodrive.failed"
    result = walk(
        tmux_stub,
        f"/rename {TITLE}",
        "/clear",
        env={
            "HANDOFF_TRANSCRIPT": str(tr),
            "HANDOFF_PENDING_FILE": str(pending),
            "HANDOFF_FAIL_FILE": str(fail_file),
        },
    )
    assert result.returncode == 0
    assert not fail_file.exists()
    sent_lines = tmux_stub.sent_text().splitlines()
    rename_line = next(i for i, line in enumerate(sent_lines) if "-l|/rename" in line)
    clear_line = next(i for i, line in enumerate(sent_lines) if "-l|/clear" in line)
    assert rename_line < clear_line


def test_line_that_never_confirms_stops_sequence(
    tmux_stub: TmuxStub, tmp_path: Path
) -> None:
    tr = tmp_path / "t.jsonl"
    tr.write_text("")
    fail_file = tmp_path / "autodrive.failed"
    result = walk(
        tmux_stub,
        f"/rename {TITLE}",
        "/clear",
        "pick up per the task file",
        env={"HANDOFF_TRANSCRIPT": str(tr), "HANDOFF_FAIL_FILE": str(fail_file)},
    )
    assert result.returncode != 0
    sent = tmux_stub.sent_text()
    assert "/clear" not in sent
    assert "pick up per the task file" not in sent
    contents = fail_file.read_text()
    assert len(contents.splitlines()) == 1
    assert TITLE in contents


def test_exit_line_confirms_by_exit_file_appearing(
    tmux_stub: TmuxStub, tmp_path: Path
) -> None:
    (tmux_stub.stubdir / "pane_after_l.txt").write_text("/exit\n❯ /exit\n")
    exit_file = tmp_path / "autodrive.exited"
    tmux_stub.on_enter(f"touch '{exit_file}'")
    result = walk(tmux_stub, "/exit", env={"HANDOFF_EXIT_FILE": str(exit_file)})
    assert result.returncode == 0
    assert "-l|/exit|" in tmux_stub.sent_text()
    assert not exit_file.exists()


def test_exit_line_reported_when_nothing_confirms_it(
    tmux_stub: TmuxStub, tmp_path: Path
) -> None:
    (tmux_stub.stubdir / "pane_after_l.txt").write_text("/exit\n❯ /exit\n")
    fail_file = tmp_path / "autodrive.failed"
    exit_file = tmp_path / "autodrive.exited"
    result = walk(
        tmux_stub,
        "/exit",
        env={"HANDOFF_EXIT_FILE": str(exit_file), "HANDOFF_FAIL_FILE": str(fail_file)},
    )
    assert result.returncode != 0
    assert "session" in fail_file.read_text().lower()


def test_resume_line_bypasses_composer_checks_and_settles_first(
    tmux_stub: TmuxStub, tmp_path: Path
) -> None:
    """A `claude --resume` line targets a bare shell, not the TUI composer.

    Pane text that would fail _drive_line's is_typing bail/delivery checks
    (no ❯ at all — nothing recognizable as a shell prompt either) must not
    stop this line from being sent: the whole point of the shell-line path is
    that it does not read composer chrome.
    """
    for name in ("pane_idle.txt", "pane_after_l.txt", "pane_after_enter.txt"):
        (tmux_stub.stubdir / name).write_text("some-shell$ \n")
    pending = tmp_path / "autodrive"
    pending.write_text("")

    start = time.monotonic()

    def consume_soon() -> None:
        time.sleep(0.2)
        pending.unlink(missing_ok=True)

    threading.Thread(target=consume_soon, daemon=True).start()
    result = walk(
        tmux_stub,
        "claude --resume sess-42",
        env={"HANDOFF_PENDING_FILE": str(pending)},
        consume=2,
    )
    elapsed = time.monotonic() - start

    assert result.returncode == 0
    assert "-l|claude --resume sess-42|" in tmux_stub.sent_text()
    assert elapsed >= 1  # HANDOFF_WATCHER_SHELL_SETTLE default, unset here


def test_resume_line_settle_is_configurable(
    tmux_stub: TmuxStub, tmp_path: Path
) -> None:
    (tmux_stub.stubdir / "pane_after_l.txt").write_text("some-shell$ \n")
    pending = tmp_path / "autodrive"
    pending.write_text("")

    def consume_soon() -> None:
        time.sleep(0.05)
        pending.unlink(missing_ok=True)

    threading.Thread(target=consume_soon, daemon=True).start()
    start = time.monotonic()
    result = walk(
        tmux_stub,
        "claude --resume sess-42",
        env={
            "HANDOFF_PENDING_FILE": str(pending),
            "HANDOFF_WATCHER_SHELL_SETTLE": "0.05",
        },
        consume=2,
    )
    elapsed = time.monotonic() - start
    assert result.returncode == 0
    assert elapsed < 1


def test_restart_sequence_exit_then_resume_in_order(
    tmux_stub: TmuxStub, tmp_path: Path
) -> None:
    (tmux_stub.stubdir / "pane_after_l.txt").write_text("/exit\n❯ /exit\n")
    exit_file = tmp_path / "autodrive.exited"
    pending = tmp_path / "autodrive"
    pending.write_text("")
    tmux_stub.on_enter(f"touch '{exit_file}'; rm -f '{pending}'")
    result = walk(
        tmux_stub,
        "/exit",
        "claude --resume sess-42",
        env={
            "HANDOFF_EXIT_FILE": str(exit_file),
            "HANDOFF_PENDING_FILE": str(pending),
            "HANDOFF_WATCHER_SHELL_SETTLE": "0.01",
        },
        consume=2,
    )
    assert result.returncode == 0
    sent_lines = tmux_stub.sent_text().splitlines()
    exit_line = next(i for i, line in enumerate(sent_lines) if "-l|/exit|" in line)
    resume_line = next(
        i for i, line in enumerate(sent_lines) if "-l|claude --resume sess-42|" in line
    )
    assert exit_line < resume_line


def test_sequence_re_gates_on_idle_between_lines(
    tmux_stub: TmuxStub, tmp_path: Path
) -> None:
    (tmux_stub.stubdir / "pane_after_enter.txt").write_text(
        "* Flummoxing… (12s · ↓ 1k tokens)\n❯ \n"
    )
    tr = tmp_path / "t.jsonl"
    tr.write_text("")
    tmux_stub.on_enter(
        f'printf \'{{"type":"custom-title","customTitle":"{TITLE}"}}\\n\' >> \'{tr}\''
    )

    start = time.monotonic()
    walk(
        tmux_stub,
        f"/rename {TITLE}",
        "the second line",
        env={"HANDOFF_TRANSCRIPT": str(tr)},
        timeout=3,
    )
    elapsed = time.monotonic() - start

    assert "-l|the second line|" in tmux_stub.sent_text()
    assert elapsed >= 2
