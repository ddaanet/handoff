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

# Captures, not compositions. Every string below was read off `tmux
# capture-pane` against a live Claude Code TUI on 2026-08-13. The fixtures
# above were hand-written and put an ASCII space in the composer gap; the TUI
# pads with U+00A0, and that one character made is_typing False for every line
# the walker has ever typed. Spelled as an escape so it survives an edit and a
# reader can see it.
NBSP = "\N{NO-BREAK SPACE}"
RULE = "─" * 200  # the composer's box rules span the pane width
STATUS = "  ❷ Opus ◉ xhigh    handoff   main  $0.00    -   Plan 5h 17%/25%"
MODE = "  ⏵⏵ auto mode on (shift+tab to cycle)"


def _composer(body: str, gap: str = NBSP) -> str:
    """A captured composer block, with ``body`` after the ``❯`` gap."""
    return "\n".join([RULE, f"❯{gap}{body}", RULE, STATUS, MODE])


REAL_EMPTY = _composer("")
REAL_SLASH = _composer("/compact")
REAL_PROSE = _composer("continue with the thing you were doing")

# The slash-command popup renders ABOVE the composer and carries no ❯ of its
# own, so is_typing's "last ❯ line" still lands on the composer.
REAL_SLASH_WITH_POPUP = (
    "  /compact             Free up context by summarizing the conversation\n"
    "  /handoff:handoff     (handoff) Snapshot the in-progress task and st…\n"
    f"{REAL_SLASH}"
)

REAL_SPINNER_UNDER_A_MINUTE = "✻ Flummoxing… (37s · ↓ 2.4k tokens)"
REAL_SPINNER_OVER_A_MINUTE = "✻ Transmuting… (8m 30s · ↓ 23.1k tokens)"


@pytest.mark.parametrize("gap", [" ", NBSP], ids=["ascii-space", "nbsp"])
def test_line_landed_whatever_whitespace_pads_the_composer(gap: str) -> None:
    """The gap is the TUI's choice, and it has already changed once."""
    assert wl.line_landed(_composer("/compact", gap=gap), "/compact")


def test_line_landed_true_on_captured_slash_line() -> None:
    assert wl.line_landed(REAL_SLASH, "/compact")


def test_line_landed_true_on_captured_prose_line() -> None:
    assert wl.line_landed(REAL_PROSE, "continue with the thing you were doing")


def test_line_landed_true_on_captured_slash_line_under_popup() -> None:
    assert wl.line_landed(REAL_SLASH_WITH_POPUP, "/compact")


def test_line_landed_false_on_captured_empty_composer() -> None:
    """Paired with the positives above: the same block, nothing typed."""
    assert not wl.line_landed(REAL_EMPTY, "/compact")


def test_line_landed_false_on_the_idle_placeholder() -> None:
    """The composer is never empty — the TUI paints a faint suggestion in it.

    Asking "is there anything here" answers yes to that, which is why the walker
    asks for its own line instead.
    """
    placeholder = _composer('Try "how does hook-test.bats work?"')
    assert not wl.line_landed(placeholder, "/compact")


def test_line_landed_true_across_a_row_wrap_that_splits_a_word() -> None:
    """A long line wraps at the pane width, mid-word, and still counts."""
    wrapped = "\n".join(
        [RULE, f"❯{NBSP}continue with the thi", "ng you were doing", RULE]
    )
    assert wl.line_landed(wrapped, "continue with the thing you were doing")


def test_line_landed_false_when_the_line_is_only_in_the_scrollback() -> None:
    """Bounding to the composer is load-bearing: the walker types prose, and
    prose it typed before is still on screen above the composer."""
    echoed = f"● I will continue with the thing you were doing\n{REAL_EMPTY}"
    assert not wl.line_landed(echoed, "continue with the thing you were doing")


@pytest.mark.parametrize("gap", [" ", NBSP], ids=["ascii-space", "nbsp"])
def test_composer_start_column_is_derived_from_the_line(gap: str) -> None:
    assert wl.composer_start_column(f"❯{gap}/compact") == 2


def test_composer_start_column_follows_an_indented_glyph() -> None:
    """Pinning today's column is what the derivation exists to avoid."""
    assert wl.composer_start_column(f"│ ❯{NBSP}/compact") == 4


def _glyph_row(text: str) -> int:
    """The row the composer glyph sits on, as a cursor_y would index it."""
    lines = text.split("\n")
    return max(i for i, line in enumerate(lines) if "❯" in line)


def test_composer_has_user_text_false_with_the_cursor_at_the_start() -> None:
    """The placeholder case: characters painted, cursor never moved."""
    placeholder = _composer('Try "how does hook-test.bats work?"')
    assert not wl.composer_has_user_text(placeholder, 2, _glyph_row(placeholder))


def test_composer_has_user_text_true_with_the_cursor_past_the_start() -> None:
    typed = _composer("half a prompt")
    assert wl.composer_has_user_text(typed, 15, _glyph_row(typed))


def test_composer_has_user_text_true_when_their_text_wrapped_below() -> None:
    typed = _composer("half a prompt")
    assert wl.composer_has_user_text(typed, 3, _glyph_row(typed) + 1)


def test_composer_has_user_text_false_with_the_cursor_above_the_composer() -> None:
    assert not wl.composer_has_user_text(_composer("half a prompt"), 40, 0)


def test_composer_has_user_text_false_on_an_unreadable_cursor() -> None:
    """cursor_position's (-1, -1) must read as "no user text", or a broken tmux
    query would abort every line the walker ever types."""
    assert not wl.composer_has_user_text(_composer("half a prompt"), -1, -1)


def test_composer_has_user_text_false_with_no_composer_at_all() -> None:
    assert not wl.composer_has_user_text("some-shell$ \n", 12, 0)


def test_is_busy_true_on_captured_spinner_under_a_minute() -> None:
    assert wl.is_busy(REAL_SPINNER_UNDER_A_MINUTE)


def test_is_busy_true_on_captured_spinner_over_a_minute() -> None:
    """Past 60s the timer reads `8m 30s`, so `[0-9]+s` no longer abuts the `(`.

    This is the case that matters: confirming a line can take CONSUME_TIMEOUT
    (300s), and FR-H re-gates on is_busy for every line after the first.
    """
    assert wl.is_busy(REAL_SPINNER_OVER_A_MINUTE)


def test_is_busy_false_on_captured_empty_composer() -> None:
    """Paired with the two positives: widening the timer must not catch this."""
    assert not wl.is_busy(REAL_EMPTY)


def test_is_busy_true_on_spinner_text() -> None:
    assert wl.is_busy(BUSY_TEXT)


def test_is_busy_false_on_idle_text() -> None:
    assert not wl.is_busy(IDLE_TEXT)


def test_line_landed_true_on_nonempty_prompt() -> None:
    assert wl.line_landed(TYPING_TEXT, "hello there")


def test_line_landed_false_on_empty_prompt() -> None:
    assert not wl.line_landed(IDLE_TEXT, "hello there")


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
