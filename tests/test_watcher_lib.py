"""Unit tests for _watcher_lib.py: pure predicates over captured pane text and
the two transcript-count primitives.

Port of the predicate/transcript sections of tests/watcher-test.bats — see
docs/changelog/2026-08-10-python-split.md.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import TYPE_CHECKING

import _watcher_lib as wl
import pytest

if TYPE_CHECKING:
    from conftest import TmuxStub

BUSY_TEXT = (
    "  ⎿  running\n* Flummoxing… (37s · ↓ 2.4k tokens)\n──── name pending ──\n❯ \n────"
)
IDLE_TEXT = (
    "  ⎿  done\n──── name pending ──\n❯ \n────\n  ▄▂▁15s│3m▅▆ 15:30 / 7d Wed 12:42"
)
TYPING_TEXT = "──── name pending ──\n❯ hello there\n────"

MARKER = "run code-review per the task file"
TITLE = "Driven Transitions Design"


def test_is_busy_true_on_spinner_text() -> None:
    assert wl.is_busy(BUSY_TEXT)


def test_is_busy_false_on_idle_text() -> None:
    assert not wl.is_busy(IDLE_TEXT)


def test_is_typing_true_on_nonempty_prompt() -> None:
    assert wl.is_typing(TYPING_TEXT)


def test_is_typing_false_on_empty_prompt() -> None:
    assert not wl.is_typing(IDLE_TEXT)


def test_is_unknown_command_true_on_no_commands_match() -> None:
    assert wl.is_unknown_command('No commands match "/compzzz"\n❯ /compzzz')


def test_is_unknown_command_false_on_autocomplete_row() -> None:
    assert not wl.is_unknown_command("/compact  Compact the conversation\n❯ /compact")


def test_is_unknown_command_false_on_plain_idle_text() -> None:
    assert not wl.is_unknown_command(IDLE_TEXT)


def _tp_entry(entry_type: str, content: str, **extra: object) -> str:
    if entry_type == "assistant":
        return json.dumps(
            {
                "type": "assistant",
                "message": {
                    "role": "assistant",
                    "content": [{"type": "text", "text": content}],
                },
            }
        )
    payload: dict[str, object] = {
        "type": entry_type,
        "message": {"role": "user", "content": content},
    }
    payload.update(extra)
    return json.dumps(payload)


def test_transcript_prompt_count_missing_transcript(tmp_path: Path) -> None:
    assert wl.transcript_prompt_count(str(tmp_path / "nope.jsonl"), MARKER) == 0


def test_transcript_prompt_count_empty_path() -> None:
    assert wl.transcript_prompt_count("", MARKER) == 0


def test_transcript_prompt_count_counts_genuine_prompt(tmp_path: Path) -> None:
    tr = tmp_path / "t.jsonl"
    tr.write_text(_tp_entry("user", f"please {MARKER} now") + "\n")
    assert wl.transcript_prompt_count(str(tr), MARKER) == 1


def test_transcript_prompt_count_ignores_meta_compact_summary_and_assistant(
    tmp_path: Path,
) -> None:
    tr = tmp_path / "t.jsonl"
    lines = [
        _tp_entry("user", f"frame quoting {MARKER}", isMeta=True),
        _tp_entry("user", f"summary quoting {MARKER}", isCompactSummary=True),
        _tp_entry("assistant", f"I will {MARKER}"),
    ]
    tr.write_text("\n".join(lines) + "\n")
    assert wl.transcript_prompt_count(str(tr), MARKER) == 0


def test_transcript_prompt_count_no_match_on_unrelated_prompt(tmp_path: Path) -> None:
    tr = tmp_path / "t.jsonl"
    tr.write_text(_tp_entry("user", "something else entirely") + "\n")
    assert wl.transcript_prompt_count(str(tr), MARKER) == 0


def test_transcript_prompt_count_skips_scalar_line(tmp_path: Path) -> None:
    tr = tmp_path / "t.jsonl"
    tr.write_text("42\n" + _tp_entry("user", f"please {MARKER} now") + "\n")
    assert wl.transcript_prompt_count(str(tr), MARKER) == 1


def test_transcript_title_count_exact_match(tmp_path: Path) -> None:
    tr = tmp_path / "t.jsonl"
    entry = {"type": "custom-title", "customTitle": TITLE, "sessionId": "abc"}
    tr.write_text(json.dumps(entry) + "\n")
    assert wl.transcript_title_count(str(tr), TITLE) == 1


def test_transcript_title_count_ai_title_does_not_count(tmp_path: Path) -> None:
    tr = tmp_path / "t.jsonl"
    tr.write_text(json.dumps({"type": "ai-title", "customTitle": TITLE}) + "\n")
    assert wl.transcript_title_count(str(tr), TITLE) == 0


def test_transcript_title_count_different_title_does_not_count(tmp_path: Path) -> None:
    tr = tmp_path / "t.jsonl"
    entry = {"type": "custom-title", "customTitle": "Something Else"}
    tr.write_text(json.dumps(entry) + "\n")
    assert wl.transcript_title_count(str(tr), TITLE) == 0


def test_transcript_title_count_prefix_does_not_count(tmp_path: Path) -> None:
    tr = tmp_path / "t.jsonl"
    tr.write_text(json.dumps({"type": "custom-title", "customTitle": TITLE}) + "\n")
    assert wl.transcript_title_count(str(tr), "Driven") == 0


def test_transcript_title_count_missing_or_unset_path(tmp_path: Path) -> None:
    assert wl.transcript_title_count(str(tmp_path / "nope.jsonl"), TITLE) == 0
    assert wl.transcript_title_count("", TITLE) == 0


def test_transcript_title_count_skips_malformed_line(tmp_path: Path) -> None:
    tr = tmp_path / "t.jsonl"
    entry = json.dumps({"type": "custom-title", "customTitle": TITLE})
    tr.write_text("not json at all\n" + entry + "\n")
    assert wl.transcript_title_count(str(tr), TITLE) == 1


def test_transcript_title_count_skips_scalar_line(tmp_path: Path) -> None:
    tr = tmp_path / "t.jsonl"
    entry = json.dumps({"type": "custom-title", "customTitle": TITLE})
    tr.write_text('"just a string"\n' + entry + "\n")
    assert wl.transcript_title_count(str(tr), TITLE) == 1


def test_confirmation_primitives_return_rather_than_raise(
    tmux_stub: TmuxStub, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """None of the four primitives may raise on a non-delivery.

    The walker owns failure for the whole sequence and calls watcher_fail once,
    at the top.
    """
    monkeypatch.setenv("PATH", tmux_stub.path_env())
    monkeypatch.setenv("HANDOFF_WATCHER_VERIFY_DELAY", "0.01")
    monkeypatch.setenv("HANDOFF_WATCHER_CONSUME_TIMEOUT", "1")
    monkeypatch.setenv("HANDOFF_WATCHER_CONSUME_POLL", "0.05")
    monkeypatch.setenv("HANDOFF_TRANSCRIPT", str(tmp_path / "absent.jsonl"))
    pending = tmp_path / "pending"
    pending.write_text("")
    monkeypatch.setenv("HANDOFF_PENDING_FILE", str(pending))
    monkeypatch.setenv("HANDOFF_EXIT_FILE", str(tmp_path / "never-created"))

    assert wl.submit_consumed("%9") is False
    assert wl.submit_titled("%9", "Nope") is False
    assert wl.submit_prompted("nope", "%9") is False
    assert wl.submit_exited("%9") is False


def test_submit_exited_confirms_by_exit_file_appearing(
    tmux_stub: TmuxStub, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("PATH", tmux_stub.path_env())
    monkeypatch.setenv("HANDOFF_WATCHER_VERIFY_DELAY", "0.01")
    exit_file = tmp_path / "autodrive.exited"
    monkeypatch.setenv("HANDOFF_EXIT_FILE", str(exit_file))
    tmux_stub.on_enter(f"touch '{exit_file}'")

    assert wl.submit_exited("%9") is True
    assert not exit_file.exists()  # consumed once confirmed


def test_submit_exited_reports_false_when_nothing_creates_the_file(
    tmux_stub: TmuxStub, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("PATH", tmux_stub.path_env())
    monkeypatch.setenv("HANDOFF_WATCHER_VERIFY_DELAY", "0.01")
    monkeypatch.setenv("HANDOFF_WATCHER_CONSUME_TIMEOUT", "0.2")
    monkeypatch.setenv("HANDOFF_WATCHER_CONSUME_POLL", "0.05")
    monkeypatch.setenv("HANDOFF_EXIT_FILE", str(tmp_path / "never-created"))

    assert wl.submit_exited("%9") is False


def test_submit_exited_unset_env_var_tolerated(
    tmux_stub: TmuxStub, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Matches submit_consumed's fallback: an unset marker path is trusted."""
    monkeypatch.setenv("PATH", tmux_stub.path_env())
    monkeypatch.delenv("HANDOFF_EXIT_FILE", raising=False)

    assert wl.submit_exited("%9") is True
