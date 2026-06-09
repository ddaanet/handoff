"""Pytest port of tests/extract-test.sh — fixture-driven tests of
scripts/extract.py. Behaviour-preserving migration: every assertion from the
shell script is mirrored here.

- Unit tests import the pure functions and assert on return values.
- End-to-end tests render a full frame via the CLI contract — either by
  calling `emit(...)` and capturing stdout, or (for the basic fixture) by
  spawning extract.py as a subprocess so the `__main__` path stays covered.

The fixtures under tests/fixtures/*.jsonl and their sentinel values ARE
the coverage map; all of them are exercised.
"""

import contextlib
import io
import subprocess
import sys
from pathlib import Path

import extract
import pytest

REPO_ROOT = Path(__file__).parent.parent
FIXTURES = REPO_ROOT / "tests" / "fixtures"
EXTRACT_PY = REPO_ROOT / "scripts" / "extract.py"


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------
def render_frame(transcript_path: Path | None, task_path: Path) -> str:
    """Render a frame via emit() and return its stdout.

    The single render path. Uses redirect_stdout rather than capsys so it works
    at any fixture scope (capsys is function-scoped and cannot back a class-
    scoped fixture).
    """
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        extract.emit(
            "" if transcript_path is None else str(transcript_path), str(task_path)
        )
    return buf.getvalue()


def assert_order(haystack: str, *needles: str) -> None:
    """Assert each needle is present in haystack, in the given order."""
    last = -1
    for needle in needles:
        idx = haystack.find(needle)
        assert idx != -1, f"missing: {needle!r}"
        assert idx > last, f"out of order: {needle!r}"
        last = idx


def write_task(tmp_path: Path, body: str) -> Path:
    """Write a handoff-task.md and return its path."""
    p = tmp_path / "handoff-task.md"
    p.write_text(body)
    return p


# --------------------------------------------------------------------------
# unit tests — pure functions
# --------------------------------------------------------------------------
class TestFormatQuote:
    def test_blank_line_renders_bare_gt(self) -> None:
        # blank/whitespace lines render as bare '>' (no trailing space)
        assert extract.format_quote("fourth prompt\n\nwith blank line") == [
            "> fourth prompt",
            ">",
            "> with blank line",
        ]

    def test_whitespace_only_line_is_bare_gt(self) -> None:
        assert extract.format_quote("a\n   \nb") == ["> a", ">", "> b"]


class TestClampAnchorLines:
    def test_at_limit_unchanged(self) -> None:
        lines = [f"L{i}" for i in range(1, extract.ANCHOR_LINE_LIMIT + 1)]
        assert extract.clamp_anchor_lines(lines) == lines

    def test_below_limit_unchanged(self) -> None:
        lines = ["L1", "L2", "L3"]
        assert extract.clamp_anchor_lines(lines) == lines

    def test_above_limit_truncates_with_marker(self) -> None:
        lines = [f"L{i}" for i in range(1, 9)]  # 8 lines
        out = extract.clamp_anchor_lines(lines)
        assert out == ["L1", "L2", "L3", "[ 2 lines omitted ]", "L6", "L7", "L8"]
        assert "L4" not in out
        assert "L5" not in out


class TestIsWrapperEntry:
    @pytest.mark.parametrize(
        "text",
        [
            "<system-reminder>note</system-reminder>",
            "<local-command-stdout>out</local-command-stdout>",
            "<task-notification>job done</task-notification>",
            "<bash-input>ls</bash-input>",
            "<command-name>/handoff:handoff</command-name>",
            "[Request interrupted by user]",
            "Base directory for this skill: /x",
        ],
    )
    def test_wrappers_detected(self, text: str) -> None:
        assert extract.is_wrapper_entry(text) is True

    @pytest.mark.parametrize(
        "text",
        [
            "first prompt",
            "real prompt KEEPME_ONE",
            "fourth prompt\n\nwith blank line",
        ],
    )
    def test_real_prompts_not_wrappers(self, text: str) -> None:
        assert extract.is_wrapper_entry(text) is False


class TestToolUseBlocks:
    def test_extracts_tool_use_only(self) -> None:
        entry = {
            "message": {
                "role": "assistant",
                "content": [
                    {"type": "tool_use", "id": "t1", "name": "Write", "input": {}},
                    {"type": "text", "text": "hi"},
                ],
            }
        }
        blocks = extract.tool_use_blocks(entry)
        assert len(blocks) == 1
        assert blocks[0]["name"] == "Write"

    def test_non_assistant_returns_empty(self) -> None:
        assert (
            extract.tool_use_blocks({"message": {"role": "user", "content": "x"}}) == []
        )

    def test_missing_message_returns_empty(self) -> None:
        assert extract.tool_use_blocks({}) == []


class TestUserText:
    def test_string_content(self) -> None:
        assert extract.user_text({"content": "  hello  "}) == "hello"

    def test_tool_result_only_is_empty(self) -> None:
        msg = {
            "content": [{"type": "tool_result", "tool_use_id": "t1", "content": "ok"}]
        }
        assert extract.user_text(msg) == ""

    def test_non_text_block_placeholder(self) -> None:
        msg = {"content": [{"type": "image", "source": {}}]}
        assert extract.user_text(msg) == "[image block]"

    def test_text_block(self) -> None:
        msg = {"content": [{"type": "text", "text": "hi there"}]}
        assert extract.user_text(msg) == "hi there"


class TestExtractFilesTouched:
    def test_write_edit_only_dedup_first_appearance(self) -> None:
        entries = [
            {
                "message": {
                    "role": "assistant",
                    "content": [
                        {
                            "type": "tool_use",
                            "name": "Write",
                            "input": {"file_path": "/a.py"},
                        }
                    ],
                }
            },
            {
                "message": {
                    "role": "assistant",
                    "content": [
                        {
                            "type": "tool_use",
                            "name": "Read",
                            "input": {"file_path": "/b.py"},
                        }
                    ],
                }
            },
            {
                "message": {
                    "role": "assistant",
                    "content": [
                        {
                            "type": "tool_use",
                            "name": "Edit",
                            "input": {"file_path": "/c.py"},
                        }
                    ],
                }
            },
            {
                "message": {
                    "role": "assistant",
                    "content": [
                        {
                            "type": "tool_use",
                            "name": "Write",
                            "input": {"file_path": "/a.py"},
                        }
                    ],
                }
            },
        ]
        # Read excluded, /a.py deduped, order = first appearance.
        assert extract.extract_files_touched(entries) == ["/a.py", "/c.py"]

    def test_skill_artifacts_excluded(self) -> None:
        """Handoff/gitlore control files are byproducts, not the working set.

        gitlore memory *content* (memory/*.md) is real work and is kept.
        """

        def write(path: str) -> extract.Entry:
            block = {"type": "tool_use", "name": "Write", "input": {"file_path": path}}
            return {"message": {"role": "assistant", "content": [block]}}

        entries = [
            write("/repo/src/feature.py"),
            write("/repo/.claude/handoff-task.md"),
            write("/repo/.claude/autorename"),
            write("/repo/.git/modules/memory/gitlore-commit-msg"),
            write("/repo/memory/feedback_thing.md"),
            write("/repo/memory/MEMORY.md"),
            write("/repo/.claude/handoff-session"),
            write("/repo/.git/modules/memory/gitlore-merge-state"),
        ]
        # Control/scratch files dropped; real work (incl. memory content) kept.
        assert extract.extract_files_touched(entries) == [
            "/repo/src/feature.py",
            "/repo/memory/feedback_thing.md",
            "/repo/memory/MEMORY.md",
        ]


class TestAnchorFor:
    def test_session_start(self) -> None:
        entries = [{"type": "user", "message": {"role": "user", "content": "first"}}]
        assert extract.anchor_for(entries, 0) == "(session start)"

    def test_text_fallback(self) -> None:
        entries: list[extract.Entry] = [
            {
                "message": {
                    "role": "assistant",
                    "content": [{"type": "text", "text": "Wrote file1"}],
                }
            },
            {"type": "user", "message": {"role": "user", "content": "x"}},
        ]
        assert extract.anchor_for(entries, 1) == "Wrote file1"

    def test_file_path_target(self) -> None:
        entries: list[extract.Entry] = [
            {
                "message": {
                    "role": "assistant",
                    "content": [
                        {
                            "type": "tool_use",
                            "name": "Edit",
                            "input": {"file_path": "/f2.py"},
                        }
                    ],
                }
            },
            {"type": "user", "message": {"role": "user", "content": "x"}},
        ]
        assert extract.anchor_for(entries, 1) == "[Edit] /f2.py"

    def test_command_fallback(self) -> None:
        entries: list[extract.Entry] = [
            {
                "message": {
                    "role": "assistant",
                    "content": [
                        {
                            "type": "tool_use",
                            "name": "Bash",
                            "input": {"command": "echo hi"},
                        }
                    ],
                }
            },
            {"type": "user", "message": {"role": "user", "content": "x"}},
        ]
        assert extract.anchor_for(entries, 1) == "[Bash] echo hi"


# --------------------------------------------------------------------------
# integration / contract tests — full-frame renders
# --------------------------------------------------------------------------
class TestExtractBasic:
    """extract-basic.jsonl — full-coverage fixture, rendered via the CLI
    subprocess so the __main__ contract stays covered."""

    @pytest.fixture(scope="class")
    def out(self, tmp_path_factory: pytest.TempPathFactory) -> str:
        d = tmp_path_factory.mktemp("basic")
        task = d / "handoff-task.md"
        task.write_text(
            "## Current task\n\n"
            "inlining test sentinel value 7f3a1b9c\n\n"
            "## Open decisions\n\n- none\n"
        )
        result = subprocess.run(
            [
                sys.executable,
                str(EXTRACT_PY),
                str(FIXTURES / "extract-basic.jsonl"),
                str(task),
            ],
            capture_output=True,
            text=True,
            cwd=REPO_ROOT,
            check=False,  # the returncode assertion below owns the exit check
        )
        assert result.returncode == 0, result.stderr
        return result.stdout

    def test_header_present(self, out: str) -> None:
        assert "# Handoff — " in out

    def test_session_line(self, out: str) -> None:
        assert "Session: `extract-basic`" in out

    def test_task_content_inlined(self, out: str) -> None:
        assert "inlining test sentinel value 7f3a1b9c" in out

    def test_no_at_ref(self, out: str) -> None:
        assert "@handoff-task.md" not in out

    @pytest.mark.parametrize(
        "path",
        [
            "- `/handoff-test/file1.py`",
            "- `/handoff-test/file2.py`",
        ],
    )
    def test_files_listed(self, out: str, path: str) -> None:
        assert path in out

    def test_read_excluded(self, out: str) -> None:
        assert "/handoff-test/file3.py" not in out

    def test_sidechain_file_stripped(self, out: str) -> None:
        assert "/handoff-test/sidechain.py" not in out

    def test_file1_before_file2(self, out: str) -> None:
        assert_order(out, "/handoff-test/file1.py", "/handoff-test/file2.py")

    def test_exactly_five_prompts(self, out: str) -> None:
        assert out.count("**after** ") == 5

    @pytest.mark.parametrize(
        "anchor",
        [
            "**after** (session start)",
            "**after** Wrote file1",
            "**after** Done editing",
            "**after** [Bash] echo hi",
            "**after** [Edit] /handoff-test/file2.py",
        ],
    )
    def test_anchor_variants(self, out: str, anchor: str) -> None:
        assert anchor in out

    def test_image_placeholder(self, out: str) -> None:
        assert "> [image block]" in out

    @pytest.mark.parametrize(
        "needle",
        [
            "> <system-reminder>",
            "> [Request interrupted by user]",
            "> <local-command-stdout>",
            "sidechain prompt",
        ],
    )
    def test_wrapper_and_sidechain_prompts_filtered(
        self, out: str, needle: str
    ) -> None:
        assert needle not in out


class TestCliContract:
    """Cover main()'s argument/exit-code contract — the __main__ failure path
    that emit() does not own."""

    def test_wrong_arg_count_exits_2_with_usage(self) -> None:
        result = subprocess.run(
            [sys.executable, str(EXTRACT_PY)],  # no transcript/task args
            capture_output=True,
            text=True,
            cwd=REPO_ROOT,
            check=False,  # asserting the nonzero exit, so must not raise
        )
        assert result.returncode == 2
        assert "usage:" in result.stderr


class TestEmptyTranscript:
    def test_no_session_data(self, tmp_path: Path) -> None:
        task = write_task(
            tmp_path, "## Current task\n\nempty-transcript sentinel 4c8d2e1f\n"
        )
        out = render_frame(None, task)
        assert "empty-transcript sentinel 4c8d2e1f" in out
        assert "@handoff-task.md" not in out
        assert "Session: `(no transcript)`" in out
        assert "(none extracted)" in out


class TestMissingTranscript:
    def test_path_does_not_exist(self, tmp_path: Path) -> None:
        task = write_task(
            tmp_path, "## Current task\n\nmissing-transcript sentinel 9b6e3f0a\n"
        )
        out = render_frame(tmp_path / "does-not-exist.jsonl", task)
        assert "missing-transcript sentinel 9b6e3f0a" in out
        assert "@handoff-task.md" not in out
        assert "(none extracted)" in out


class TestMissingTask:
    def test_no_task_file_in_output_dir(self, tmp_path: Path) -> None:
        # task path points at a non-existent file: inlined block absent,
        # no orphan heading, surrounding sections still render.
        out = render_frame(None, tmp_path / "handoff-task.md")
        assert "@handoff-task.md" not in out
        assert "## Current task" not in out
        assert "## Files touched" in out
        assert "## Last user prompts" in out


class TestSkillMeta:
    """extract-skill-meta.jsonl — isMeta skill bodies dropped structurally, real
    prompts around them retained."""

    @pytest.fixture(scope="class")
    def out(self) -> str:
        return render_frame(
            FIXTURES / "extract-skill-meta.jsonl", FIXTURES / "does-not-exist-task.md"
        )

    @pytest.mark.parametrize(
        "kept",
        [
            "real prompt KEEPME_ONE",
            "real prompt KEEPME_TWO",
            "real prompt KEEPME_THREE",
        ],
    )
    def test_real_prompts_kept(self, out: str, kept: str) -> None:
        assert kept in out

    @pytest.mark.parametrize(
        "dropped",
        [
            "DROPME_SKILL_TOOL",
            "DROPME_SKILL_SLASH",
            "# Update Config Skill",
            "# Plugin Creation Workflow",
            "TASKNOTIF_DROP",
            "<task-notification>",
        ],
    )
    def test_meta_and_wrappers_dropped(self, out: str, dropped: str) -> None:
        assert dropped not in out


class TestAnchorMultiline:
    """anchor-multiline.jsonl — 3/7-line anchors shown in full; 8-line anchor
    truncated to head 3 + marker + tail 3."""

    @pytest.fixture(scope="class")
    def out(self) -> str:
        return render_frame(
            FIXTURES / "anchor-multiline.jsonl", FIXTURES / "no-task.md"
        )

    @pytest.mark.parametrize(
        "line",
        [
            "**after** ANCHOR3_L1",
            "ANCHOR3_L2",
            "ANCHOR3_L3",
        ],
    )
    def test_three_line_anchor_full(self, out: str, line: str) -> None:
        assert line in out

    @pytest.mark.parametrize(
        "line",
        [
            "**after** ANCHOR7_L1",
            "ANCHOR7_L2",
            "ANCHOR7_L3",
            "ANCHOR7_L4",
            "ANCHOR7_L5",
            "ANCHOR7_L6",
            "ANCHOR7_L7",
        ],
    )
    def test_seven_line_anchor_full(self, out: str, line: str) -> None:
        assert line in out

    def test_eight_line_anchor_truncated(self, out: str) -> None:
        # Head 3 + omission marker + tail 3, in that order, in the rendered
        # frame — the marker's presence and position are a cross-cutting frame
        # property the clamp_anchor_lines unit test cannot discharge.
        assert_order(
            out,
            "**after** ANCHOR8_L1",
            "ANCHOR8_L2",
            "ANCHOR8_L3",
            "[ 2 lines omitted ]",
            "ANCHOR8_L6",
            "ANCHOR8_L7",
            "ANCHOR8_L8",
        )

    @pytest.mark.parametrize("line", ["ANCHOR8_MIDDLE_DROP_4", "ANCHOR8_MIDDLE_DROP_5"])
    def test_eight_line_anchor_middle_absent(self, out: str, line: str) -> None:
        assert line not in out


class TestBounded:
    """extract-bounded.jsonl — prompts after the last handoff-task.md write are
    excluded; everything before the write is kept."""

    @pytest.fixture(scope="class")
    def out(self) -> str:
        return render_frame(FIXTURES / "extract-bounded.jsonl", FIXTURES / "no-task.md")

    @pytest.mark.parametrize(
        "kept",
        [
            "BOUNDED_KEEP_ONE",
            "BOUNDED_KEEP_TWO",
            "BOUNDED_KEEP_THREE",
        ],
    )
    def test_pre_write_prompts_kept(self, out: str, kept: str) -> None:
        assert kept in out

    def test_post_write_prompt_excluded(self, out: str) -> None:
        assert "BOUNDED_DROP_AFTER" not in out
