"""Tests for scripts/checkpoint.py (handoff-checkpoint) — the schema validation,
write semantics, manifest, transition/sentinel composition, and directive
composition that live in checkpoint.py + _checkpoint_lib.py. Port of the
checkpoint.sh-specific rows of tests/checkpoint.bats — see
docs/changelog/2026-08-10-python-split.md.

inject-checkpoint-root.sh, bash-post.sh, bin/handoff-approved and the
bin/handoff-checkpoint shim stay bash and stay tested in tests/checkpoint.bats;
this file covers only checkpoint.py's own behavior.
"""

import json
import os
import shutil
import subprocess
import sys
from collections.abc import Mapping
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
CHECKPOINT = REPO_ROOT / "scripts" / "checkpoint.py"
LIB = REPO_ROOT / "scripts" / "_lib.sh"

GITLORE_MEMORY_APPROVAL_CLAUSE = (
    "The commit message is a subject line, a blank line, then one paragraph per\n"
    "changed memory file, each opening with a bold prefix naming the file's kind and\n"
    "its tier/slug. Template:\n"
    "\n"
    "    <subject line, no conventional-commit prefix>\n"
    "\n"
    "    **New <tier>/<slug>:** what the fact records, and what prompted writing it\n"
    "    now rather than earlier."
)


@pytest.fixture(autouse=True)
def _session_id(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("CLAUDE_CODE_SESSION_ID", "sess-checkpoint")
    monkeypatch.delenv("CLAUDE_PROJECT_DIR", raising=False)


def make_repo(tmp_path: Path, name: str = "repo") -> Path:
    repo = tmp_path / name
    if repo.exists():
        shutil.rmtree(repo)
    (repo / ".claude").mkdir(parents=True)
    subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
    return repo


def make_gitlore_repo(tmp_path: Path, name: str = "glrepo") -> Path:
    repo = tmp_path / name
    if repo.exists():
        shutil.rmtree(repo)
    (repo / "memory").mkdir(parents=True)
    (repo / ".claude").mkdir(parents=True)
    subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
    (repo / ".gitmodules").write_text(
        '[submodule "gitlore-memory"]\n\tpath = memory\n\turl = ./memory\n'
    )
    mem = repo / "memory"
    subprocess.run(["git", "init", "-q"], cwd=mem, check=True)
    (mem / "seed.md").write_text("seed\n")
    subprocess.run(["git", "add", "-A"], cwd=mem, check=True)
    subprocess.run(
        ["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "seed"],
        cwd=mem,
        check=True,
    )
    clause_file = repo / ".gitlore-memory-approval-clause.txt"
    clause_file.write_text(GITLORE_MEMORY_APPROVAL_CLAUSE + "\n")
    subprocess.run(
        ["git", "config", "gitlore.memoryApprovalClauseFile", str(clause_file)],
        cwd=repo,
        check=True,
    )
    return repo


def dirty_memory(repo: Path) -> None:
    (repo / "memory" / "feedback_x.md").write_text("new entry\n")


def add_sdd_ledger(repo: Path, slug: str = "feature-plan") -> None:
    d = repo / ".superpowers" / "sdd" / slug
    d.mkdir(parents=True)
    (repo / ".superpowers" / "sdd" / ".gitignore").write_text("*\n")
    (d / "progress.md").write_text(
        f"# SDD ledger — plan: docs/plans/{slug}.md\n"
        "Task 1: complete (commits abc1234..def5678, review clean)\n"
    )


def add_flat_sdd_ledger(repo: Path) -> None:
    d = repo / ".superpowers" / "sdd"
    d.mkdir(parents=True)
    (d / ".gitignore").write_text("*\n")
    (d / "progress.md").write_text(
        "Task 1: complete (commits abc1234..def5678, review clean)\n"
    )


def add_unidentified_sdd_ledger(repo: Path, slug: str = "ghmem") -> None:
    d = repo / ".superpowers" / "sdd" / slug
    d.mkdir(parents=True)
    (repo / ".superpowers" / "sdd" / ".gitignore").write_text("*\n")
    (d / "progress.md").write_text("# ghmem — progress (C2 COMPLETE)\n")


def task_content(content: str) -> str:
    return content


def task_clear() -> dict[str, str]:
    return {"action": "clear"}


def todo_content(content: str) -> str:
    return content


def todo_keep() -> dict[str, str]:
    return {"action": "keep"}


def todo_edit(old: str, new: str) -> dict[str, str]:
    return {"action": "edit", "old_string": old, "new_string": new}


def run_checkpoint(
    repo: Path, payload: Mapping[str, object] | str, root: Path | None = None
) -> subprocess.CompletedProcess[str]:
    """Run checkpoint.py with cwd=repo, HANDOFF_ROOT=root (default repo)."""
    env = dict(os.environ)
    env["HANDOFF_ROOT"] = str(root if root is not None else repo)
    env["CLAUDE_CODE_SESSION_ID"] = os.environ.get(
        "CLAUDE_CODE_SESSION_ID", "sess-checkpoint"
    )
    env.pop("CLAUDE_PROJECT_DIR", None)
    text = payload if isinstance(payload, str) else json.dumps(payload)
    return subprocess.run(
        [sys.executable, str(CHECKPOINT)],
        cwd=repo,
        input=text,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


def read_back_drive(drive_path: Path) -> bool:
    """Mirror `handoff_drive_read` (bash, unmoved) reading back a sentinel."""
    script = f'source "{LIB}"; handoff_drive_read "{drive_path}"'
    result = subprocess.run(
        ["bash", "-c", script], capture_output=True, text=True, check=False
    )
    return result.returncode == 0


def drive_state(drive_path: Path) -> tuple[str, str]:
    script = (
        f'source "{LIB}"; handoff_drive_read "{drive_path}" >/dev/null 2>&1; '
        'printf "%s\\n%s\\n" "$DRIVE_STATE" "$DRIVE_OWNER"'
    )
    result = subprocess.run(
        ["bash", "-c", script], capture_output=True, text=True, check=False
    )
    lines = result.stdout.splitlines()
    return (lines[0] if lines else "", lines[1] if len(lines) > 1 else "")


# ==========================================================================
# The session root
# ==========================================================================


def test_handoff_root_unset_refuses(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "handoff",
        "commit": "with-commit",
        "rename": "T",
        "clear": False,
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    env = dict(os.environ)
    env.pop("HANDOFF_ROOT", None)
    env.pop("CLAUDE_PROJECT_DIR", None)
    result = subprocess.run(
        [sys.executable, str(CHECKPOINT)],
        cwd=repo,
        input=json.dumps(payload),
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 2
    assert "HANDOFF_ROOT" in result.stderr


def test_handoff_root_names_non_directory_refuses(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "handoff",
        "commit": "with-commit",
        "rename": "T",
        "clear": False,
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload, root=repo / "does-not-exist")
    assert result.returncode == 2
    assert "HANDOFF_ROOT" in result.stderr


def test_drifted_cwd_writes_injected_root_never_cwd(tmp_path: Path) -> None:
    root = make_repo(tmp_path, "launch")
    elsewhere = make_repo(tmp_path, "elsewhere")
    payload = {
        "skill": "handoff",
        "commit": "with-commit",
        "rename": "T",
        "clear": False,
        "continue": None,
        "task": task_content("## Current task\n\nbody\n"),
        "todo": todo_keep(),
    }
    result = run_checkpoint(elsewhere, payload, root=root)
    assert result.returncode == 0
    assert (root / ".claude" / "handoff-task.md").is_file()
    assert (root / ".claude" / "checkpoint-manifest").is_file()
    assert not (elsewhere / ".claude" / "handoff-task.md").exists()
    assert not (elsewhere / ".claude" / "checkpoint-manifest").exists()


# ==========================================================================
# Schema validation (FR2)
# ==========================================================================


def test_skill_missing_errors_naming_skill(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "commit": "with-commit",
        "rename": "T",
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert "skill" in result.stderr


def test_skill_unknown_value_errors_naming_skill(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "bogus",
        "commit": "with-commit",
        "rename": "T",
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert "skill" in result.stderr


def test_commit_missing_errors_naming_commit(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "handoff",
        "rename": "T",
        "clear": False,
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert "commit" in result.stderr


def test_commit_unknown_value_errors_naming_commit(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "handoff",
        "commit": "maybe",
        "rename": "T",
        "clear": False,
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert "commit" in result.stderr


def test_rename_missing_under_handoff_errors_naming_rename(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "handoff",
        "commit": "with-commit",
        "clear": False,
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert "rename" in result.stderr


def test_each_of_two_skill_values_accepted(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "precompact",
        "commit": "without-commit",
        "compact": False,
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    assert run_checkpoint(repo, payload).returncode == 0
    payload = {
        "skill": "handoff",
        "commit": "without-commit",
        "rename": "T",
        "clear": False,
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    assert run_checkpoint(repo, payload).returncode == 0


def test_retired_driven_skill_names_rejected(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    for s in ("handoff-continue", "compact-continue"):
        payload = {
            "skill": s,
            "commit": "without-commit",
            "clear": False,
            "continue": None,
            "task": task_clear(),
            "todo": todo_keep(),
        }
        result = run_checkpoint(repo, payload)
        assert result.returncode == 2
        assert "skill" in result.stderr
        assert s in result.stderr


def test_rename_present_under_precompact_errors(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "precompact",
        "commit": "with-commit",
        "rename": "Not Allowed",
        "compact": False,
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert "rename" in result.stderr
    assert "precompact" in result.stderr


@pytest.mark.parametrize("value", ["", None])
def test_empty_or_null_rename_under_precompact_errors(
    tmp_path: Path, value: object
) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "precompact",
        "commit": "with-commit",
        "compact": False,
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
        "rename": value,
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert "rename" in result.stderr
    assert "precompact" in result.stderr


@pytest.mark.parametrize("value", [{"title": "Fix parser"}, 42, ["A Title"], True])
def test_rename_not_a_string_errors(tmp_path: Path, value: object) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "handoff",
        "commit": "with-commit",
        "clear": False,
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
        "rename": value,
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert "rename" in result.stderr
    assert not (repo / ".claude" / "autodrive").exists()


def test_precompact_with_rename_omitted_accepted(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "precompact",
        "commit": "without-commit",
        "compact": False,
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    assert run_checkpoint(repo, payload).returncode == 0


@pytest.mark.parametrize(
    ("field", "value", "reason"),
    [
        ("task", {"action": "emty"}, 'got "emty"'),
        ("todo", {"action": "emty"}, 'got "emty"'),
        ("task", {"action": "keep"}, 'got "keep"'),
        (
            "task",
            {"action": "edit", "old_string": "a", "new_string": "b"},
            'got "edit"',
        ),
        ("task", {}, "action: required"),
        ("todo", {}, "action: required"),
        ("task", 42, "got number"),
        ("todo", 42, "got number"),
        (
            "todo",
            {"action": "edit", "new_string": "b"},
            'old_string: required for {"action": "edit"}',
        ),
        (
            "todo",
            {"action": "edit", "old_string": "a"},
            'new_string: required for {"action": "edit"}',
        ),
        (
            "todo",
            {"action": "edit", "old_string": 5, "new_string": "b"},
            "old_string: must be a string, got number",
        ),
        (
            "todo",
            {"action": "edit", "old_string": "a", "new_string": None},
            "new_string: must be a string, got null",
        ),
    ],
    ids=[
        "task_unknown_action",
        "todo_unknown_action",
        "task_keep_rejected",
        "task_edit_rejected",
        "task_no_action_key",
        "todo_no_action_key",
        "task_not_string_or_object",
        "todo_not_string_or_object",
        "todo_edit_missing_old_string",
        "todo_edit_missing_new_string",
        "todo_edit_old_string_not_a_string",
        "todo_edit_new_string_not_a_string",
    ],
)
def test_task_or_todo_action_vocabulary_errors_naming_field(
    tmp_path: Path, field: str, value: object, reason: str
) -> None:
    """Everything outside the union is a named error.

    Both fields dispatch on an `action` key, and `edit`'s own required keys
    are checked by the same dispatch: an unknown action, a missing `action`
    key, a value that is neither string nor object, `task` receiving a
    `todo`-only action (`keep`, `edit`), and `edit` missing — or mistyping —
    either required key independently: each exits 2 naming the offending field
    and its own reason. The two mistyped rows are what keeps `edit` from being
    the one arm of the union that types nothing: every other arm's content is
    a checked string, and an unchecked one reaches `apply_edit`'s
    `content.count(old)` as a TypeError traceback, which exits 1 and names no
    field.

    `task_edit_rejected`, `todo_edit_missing_old_string` and
    `todo_edit_missing_new_string` restate, in action vocabulary,
    `test_task_with_old_string_new_string_errors` /
    `test_todo_only_new_string_errors` / `test_todo_only_old_string_errors` —
    the same contract reached through the dispatch instead of through
    key-combination sniffing on a bare object. Each `reason` pins that
    shape's own diagnostic and no other: an `edit` missing a key must say
    `required for`, not the `does not exist` / `not found` / `ambiguous` the
    same `todo.old_string` namespace also carries.
    """
    repo = make_repo(tmp_path)
    payload: dict[str, object] = {
        "skill": "handoff",
        "commit": "with-commit",
        "rename": "T",
        "clear": False,
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    payload[field] = value
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert field in result.stderr
    assert reason in result.stderr


def test_malformed_json_errors_naming_payload(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    result = run_checkpoint(repo, "{not valid json")
    assert result.returncode == 2
    assert "payload" in result.stderr


@pytest.mark.parametrize("skill", ["handoff", "precompact"])
@pytest.mark.parametrize(
    ("field", "shape", "reason"),
    [
        ("task", "null", "got null"),
        ("task", "absent", "required"),
        ("todo", "null", "got null"),
        ("todo", "absent", "required"),
    ],
    ids=["task_null", "task_absent", "todo_null", "todo_absent"],
)
def test_task_or_todo_null_or_absent_errors_naming_field(
    tmp_path: Path, skill: str, field: str, shape: str, reason: str
) -> None:
    """D2: task/todo are each required by key presence, with no default.

    `null` and an absent key are distinct, named errors on both fields — the
    defect being fixed is an agent choosing a spelling that silently did the
    wrong thing, so both wrong spellings must fail loudly with their own
    reason, and neither may write its target file before failing. Run at both
    boundaries: the rule is main's `skill in ("handoff", "precompact")` gate,
    and a gate naming only one of them is the way it breaks.
    """
    repo = make_repo(tmp_path)
    payload: dict[str, object] = {
        "skill": skill,
        "commit": "with-commit",
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    if skill == "handoff":
        payload["rename"] = "T"
        payload["clear"] = False
    else:
        payload["compact"] = False
    if shape == "null":
        payload[field] = None
    else:
        del payload[field]
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert field in result.stderr
    assert reason in result.stderr
    target = "handoff-task.md" if field == "task" else "handoff-todo.md"
    assert not (repo / ".claude" / target).exists()


# ==========================================================================
# Write semantics (FR5) and empty-body removal (FR6)
# ==========================================================================


@pytest.mark.parametrize("skill", ["handoff", "precompact"])
def test_task_write_creates_file_manifest_records_w(tmp_path: Path, skill: str) -> None:
    """Run at both boundaries: `main`'s `if skill in ("handoff", "precompact")`
    gate must not merely validate the payload for precompact — it must also
    apply it.

    A gate narrowed to `handoff` alone would still validate a precompact payload
    correctly and then skip the write, which every prior row here left
    unobserved because it never ran a `precompact` payload through this
    assertion.
    """
    repo = make_repo(tmp_path)
    content = "## Current task\n\nreal content\n"
    payload: dict[str, object] = {
        "skill": skill,
        "commit": "with-commit",
        "continue": None,
        "task": task_content(content),
        "todo": todo_keep(),
    }
    if skill == "handoff":
        payload["rename"] = "T"
        payload["clear"] = False
    else:
        payload["compact"] = False
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    assert (repo / ".claude" / "handoff-task.md").is_file()
    assert (repo / ".claude" / "handoff-task.md").read_text() == content
    assert (
        "W .claude/handoff-task.md"
        in (repo / ".claude" / "checkpoint-manifest").read_text().splitlines()
    )


def test_task_clear_removes_pre_existing_file_manifest_records_d(
    tmp_path: Path,
) -> None:
    repo = make_repo(tmp_path)
    (repo / ".claude" / "handoff-task.md").write_text("## Current task\n\nstale\n")
    payload = {
        "skill": "handoff",
        "commit": "with-commit",
        "rename": "T",
        "clear": False,
        "continue": None,
        "task": task_clear(),
        "todo": todo_content("## Remaining\n\n- an item\n"),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    assert not (repo / ".claude" / "handoff-task.md").exists()
    manifest = (repo / ".claude" / "checkpoint-manifest").read_text()
    # Carries the same live-manifest todo line as its never-existed partner, so
    # the pair differs only in whether the task file exists first.
    assert "W .claude/handoff-todo.md" in manifest.splitlines()
    assert "D .claude/handoff-task.md" in manifest.splitlines()


def test_task_clear_never_existed_writes_nothing_no_d(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "handoff",
        "commit": "with-commit",
        "rename": "T",
        "clear": False,
        "continue": None,
        "task": task_clear(),
        "todo": todo_content("## Remaining\n\n- an item\n"),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    assert not (repo / ".claude" / "handoff-task.md").exists()
    assert (repo / ".claude" / "checkpoint-manifest").is_file()
    manifest = (repo / ".claude" / "checkpoint-manifest").read_text()
    # The todo line proves the manifest is live, so the absence below is a claim
    # about the task route rather than about an empty manifest.
    assert "W .claude/handoff-todo.md" in manifest.splitlines()
    assert "handoff-task.md" not in manifest


def test_task_write_only_headings_pre_existing_removed_manifest_records_d(
    tmp_path: Path,
) -> None:
    repo = make_repo(tmp_path)
    (repo / ".claude" / "handoff-task.md").write_text("## Current task\n\nstale\n")
    payload = {
        "skill": "handoff",
        "commit": "with-commit",
        "rename": "T",
        "clear": False,
        "continue": None,
        "task": task_content("## Current task\n\n## Open decisions\n"),
        "todo": todo_content("## Remaining\n\n- an item\n"),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    assert not (repo / ".claude" / "handoff-task.md").exists()
    manifest = (repo / ".claude" / "checkpoint-manifest").read_text().splitlines()
    assert "D .claude/handoff-task.md" in manifest
    assert "W .claude/handoff-todo.md" in manifest


def test_task_write_only_headings_never_existed_no_d(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "handoff",
        "commit": "with-commit",
        "rename": "T",
        "clear": False,
        "continue": None,
        "task": task_content("## Current task\n\n## Open decisions\n"),
        "todo": todo_content("## Remaining\n\n- an item\n"),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    assert not (repo / ".claude" / "handoff-task.md").exists()
    assert (repo / ".claude" / "checkpoint-manifest").is_file()
    manifest = (repo / ".claude" / "checkpoint-manifest").read_text()
    # The todo line proves the manifest is live, so the absence below is a claim
    # about the task route rather than about an empty manifest.
    assert "W .claude/handoff-todo.md" in manifest.splitlines()
    assert "handoff-task.md" not in manifest


@pytest.mark.parametrize("skill", ["handoff", "precompact"])
def test_todo_write_creates_file_manifest_records_w(tmp_path: Path, skill: str) -> None:
    """Mirrors test_task_write_creates_file_manifest_records_w's own note: the
    `precompact` half proves `main` applies the payload it validates, not merely
    validates it."""
    repo = make_repo(tmp_path)
    content = "## Remaining\n\n- an item\n"
    payload: dict[str, object] = {
        "skill": skill,
        "commit": "with-commit",
        "continue": None,
        "task": task_clear(),
        "todo": todo_content(content),
    }
    if skill == "handoff":
        payload["rename"] = "T"
        payload["clear"] = False
    else:
        payload["compact"] = False
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    assert (repo / ".claude" / "handoff-todo.md").is_file()
    assert (repo / ".claude" / "handoff-todo.md").read_text() == content
    assert (
        "W .claude/handoff-todo.md"
        in (repo / ".claude" / "checkpoint-manifest").read_text().splitlines()
    )


def test_todo_write_no_items_pre_existing_removed_manifest_records_d(
    tmp_path: Path,
) -> None:
    repo = make_repo(tmp_path)
    (repo / ".claude" / "handoff-todo.md").write_text("## Remaining\n\n- stale\n")
    payload = {
        "skill": "handoff",
        "commit": "with-commit",
        "rename": "T",
        "clear": False,
        "continue": None,
        "task": task_content("## Current task\n\nreal content\n"),
        "todo": todo_content("## Remaining\n"),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    assert not (repo / ".claude" / "handoff-todo.md").exists()
    manifest = (repo / ".claude" / "checkpoint-manifest").read_text().splitlines()
    assert "D .claude/handoff-todo.md" in manifest
    assert "W .claude/handoff-task.md" in manifest


def test_todo_write_no_items_never_existed_no_d(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "handoff",
        "commit": "with-commit",
        "rename": "T",
        "clear": False,
        "continue": None,
        "task": task_content("## Current task\n\nreal content\n"),
        "todo": todo_content("## Remaining\n"),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    assert not (repo / ".claude" / "handoff-todo.md").exists()
    assert (repo / ".claude" / "checkpoint-manifest").is_file()
    manifest = (repo / ".claude" / "checkpoint-manifest").read_text()
    # The task line proves the manifest is live, so the absence below is a claim
    # about the todo route rather than about an empty manifest.
    assert "W .claude/handoff-task.md" in manifest.splitlines()
    assert "handoff-todo.md" not in manifest


def test_todo_edit_replaces_first_occurrence_stages_w(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    (repo / ".claude" / "handoff-todo.md").write_text(
        "## Remaining\n\n- finish A\n- finish B\n"
    )
    payload = {
        "skill": "handoff",
        "commit": "with-commit",
        "rename": "T",
        "clear": False,
        "continue": None,
        "task": task_clear(),
        "todo": todo_edit("- finish A\n", ""),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    content = (repo / ".claude" / "handoff-todo.md").read_text()
    assert "finish A" not in content
    assert "finish B" in content
    assert (
        "W .claude/handoff-todo.md"
        in (repo / ".claude" / "checkpoint-manifest").read_text().splitlines()
    )


def test_todo_edit_old_string_absent_errors(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    (repo / ".claude" / "handoff-todo.md").write_text("## Remaining\n\n- keep this\n")
    payload = {
        "skill": "handoff",
        "commit": "with-commit",
        "rename": "T",
        "clear": False,
        "continue": None,
        "task": task_clear(),
        "todo": todo_edit("- not present", "- x"),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert "old_string" in result.stderr
    assert "not found" in result.stderr
    assert "keep this" in (repo / ".claude" / "handoff-todo.md").read_text()


def test_todo_edit_old_string_ambiguous_errors(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    (repo / ".claude" / "handoff-todo.md").write_text("## Remaining\n\n- dup\n- dup\n")
    payload = {
        "skill": "handoff",
        "commit": "with-commit",
        "rename": "T",
        "clear": False,
        "continue": None,
        "task": task_clear(),
        "todo": todo_edit("- dup", "- single"),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert "old_string" in result.stderr
    assert "ambiguous" in result.stderr


def test_todo_edit_requested_file_missing_errors(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "handoff",
        "commit": "with-commit",
        "rename": "T",
        "clear": False,
        "continue": None,
        "task": task_clear(),
        "todo": todo_edit("a", "b"),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert "does not exist" in result.stderr


def test_todo_keep_leaves_pre_existing_list_alone(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    before = "## Remaining\n\n- untouched\n"
    (repo / ".claude" / "handoff-todo.md").write_text(before)
    payload = {
        "skill": "handoff",
        "commit": "with-commit",
        "rename": "T",
        "clear": False,
        "continue": None,
        "task": task_content("## Current task\n\nreal content\n"),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    assert (repo / ".claude" / "handoff-todo.md").read_text() == before
    manifest = (repo / ".claude" / "checkpoint-manifest").read_text()
    # The task line proves the manifest is live, so the absence below is a claim
    # about the todo route rather than about an empty manifest.
    assert "W .claude/handoff-task.md" in manifest.splitlines()
    assert "handoff-todo.md" not in manifest


# ==========================================================================
# Manifest -- FR7 -- and rename -- FR8
# ==========================================================================


def test_rename_only_manifest_present_empty_sentinel_written(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "handoff",
        "commit": "with-commit",
        "rename": "Two Words Title",
        "clear": False,
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    manifest = repo / ".claude" / "checkpoint-manifest"
    assert manifest.is_file()
    assert manifest.stat().st_size == 0
    assert (
        repo / ".claude" / "autodrive"
    ).read_text() == "armed\nrename\n/rename Two Words Title\n"
    assert read_back_drive(repo / ".claude" / "autodrive")


def test_multiline_title_flattened_to_one_line(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "handoff",
        "commit": "with-commit",
        "rename": "Two  Words\nAnd More",
        "clear": False,
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    content = (repo / ".claude" / "autodrive").read_text()
    assert len(content.splitlines()) == 3
    assert "/rename Two Words And More" in content.splitlines()


def test_whitespace_only_title_errors(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "handoff",
        "commit": "with-commit",
        "rename": "   ",
        "clear": False,
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert "rename" in result.stderr


def test_precompact_nothing_touched_manifest_still_written_empty(
    tmp_path: Path,
) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "precompact",
        "commit": "without-commit",
        "compact": False,
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    manifest = repo / ".claude" / "checkpoint-manifest"
    assert manifest.is_file()
    assert manifest.stat().st_size == 0


def test_task_and_todo_both_written_manifest_lists_both(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "handoff",
        "commit": "with-commit",
        "rename": "T",
        "clear": False,
        "continue": None,
        "task": task_content("## Current task\n\nbody\n"),
        "todo": todo_content("## Remaining\n\n- x\n"),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    manifest = (repo / ".claude" / "checkpoint-manifest").read_text().splitlines()
    assert "W .claude/handoff-task.md" in manifest
    assert "W .claude/handoff-todo.md" in manifest


# ==========================================================================
# The transition and the continuation
# ==========================================================================


def test_clear_missing_under_handoff_errors(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "handoff",
        "commit": "with-commit",
        "rename": "T",
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert "clear" in result.stderr


def test_clear_not_boolean_errors(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "handoff",
        "commit": "with-commit",
        "rename": "T",
        "clear": "yes",
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert "clear" in result.stderr


def test_clear_present_under_precompact_errors(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "precompact",
        "commit": "with-commit",
        "clear": True,
        "compact": False,
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert "clear" in result.stderr


def test_compact_missing_under_precompact_errors(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "precompact",
        "commit": "with-commit",
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert "compact" in result.stderr


def test_compact_present_under_handoff_errors(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "handoff",
        "commit": "with-commit",
        "rename": "T",
        "clear": False,
        "compact": True,
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert "compact" in result.stderr


def test_compact_neither_boolean_nor_string_errors(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "precompact",
        "commit": "with-commit",
        "compact": ["focus"],
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert "compact" in result.stderr


def test_empty_compact_directive_errors(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "precompact",
        "commit": "with-commit",
        "compact": "",
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert "compact" in result.stderr


def test_multiline_compact_directive_errors(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "precompact",
        "commit": "with-commit",
        "compact": "keep the parser\nand the tests",
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert "compact" in result.stderr


def test_continue_missing_errors_at_either_boundary(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "handoff",
        "commit": "with-commit",
        "rename": "T",
        "clear": True,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert "continue" in result.stderr

    payload = {
        "skill": "precompact",
        "commit": "with-commit",
        "compact": True,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert "continue" in result.stderr


def test_continuation_against_untyped_transition_errors(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "handoff",
        "commit": "with-commit",
        "rename": "T",
        "clear": False,
        "continue": "pick up per the task file",
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert "continue" in result.stderr

    payload = {
        "skill": "precompact",
        "commit": "with-commit",
        "compact": False,
        "continue": "pick up per the task file",
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert "continue" in result.stderr


def test_multiline_continuation_errors(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "handoff",
        "commit": "with-commit",
        "rename": "T",
        "clear": True,
        "continue": "first line\nsecond line",
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert "continue" in result.stderr


def test_continuation_beginning_with_slash_errors(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "handoff",
        "commit": "with-commit",
        "rename": "T",
        "clear": True,
        "continue": "/resume the work",
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert "continue" in result.stderr


def test_whitespace_only_continuation_errors(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "handoff",
        "commit": "with-commit",
        "rename": "T",
        "clear": True,
        "continue": "   ",
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert "continue" in result.stderr


def test_continue_neither_null_nor_string_errors(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "handoff",
        "commit": "with-commit",
        "rename": "T",
        "clear": True,
        "continue": True,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert "continue" in result.stderr


# --- the six legal combinations ---


def test_handoff_clear_true_no_continuation(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "handoff",
        "commit": "without-commit",
        "rename": "A Title",
        "clear": True,
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    assert (
        repo / ".claude" / "autodrive"
    ).read_text() == "armed\nclear\n/rename A Title\n/clear\n"
    assert read_back_drive(repo / ".claude" / "autodrive")


def test_handoff_clear_true_with_continuation(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "handoff",
        "commit": "without-commit",
        "rename": "A Title",
        "clear": True,
        "continue": "pick up per the task file",
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    assert (repo / ".claude" / "autodrive").read_text() == (
        "armed\nclear\n/rename A Title\n/clear\npick up per the task file\n"
    )
    assert read_back_drive(repo / ".claude" / "autodrive")


def test_precompact_compact_false_two_line_marker(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "precompact",
        "commit": "without-commit",
        "compact": False,
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    assert (repo / ".claude" / "autodrive").read_text() == "armed\ncompact\n"


def test_precompact_compact_true_no_continuation_bare_compact(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "precompact",
        "commit": "without-commit",
        "compact": True,
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    assert (repo / ".claude" / "autodrive").read_text() == "armed\ncompact\n/compact\n"
    assert read_back_drive(repo / ".claude" / "autodrive")


def test_precompact_focus_directive_and_continuation_both_carried(
    tmp_path: Path,
) -> None:
    repo = make_repo(tmp_path)
    payload = {
        "skill": "precompact",
        "commit": "without-commit",
        "compact": "keep the parser work",
        "continue": "continue with task 3",
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    assert (repo / ".claude" / "autodrive").read_text() == (
        "armed\ncompact\n/compact keep the parser work\ncontinue with task 3\n"
    )
    assert read_back_drive(repo / ".claude" / "autodrive")


# --- held versus armed ---


def test_typed_transition_with_memory_gate_pending_held(tmp_path: Path) -> None:
    repo = make_gitlore_repo(tmp_path)
    dirty_memory(repo)
    payload = {
        "skill": "handoff",
        "commit": "without-commit",
        "rename": "A Title",
        "clear": True,
        "continue": "pick up per the task file",
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    first_line = (repo / ".claude" / "autodrive").read_text().splitlines()[0]
    assert first_line == "held sess-checkpoint"
    assert "handoff-approved" in result.stdout


def test_held_sentinel_names_the_session_that_holds_it(tmp_path: Path) -> None:
    repo = make_gitlore_repo(tmp_path)
    dirty_memory(repo)
    payload = {
        "skill": "handoff",
        "commit": "without-commit",
        "rename": "A Title",
        "clear": True,
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    state, owner = drive_state(repo / ".claude" / "autodrive")
    assert state == "held"
    assert owner == "sess-checkpoint"


def test_typed_transition_no_memory_gate_armed_no_arming_instruction(
    tmp_path: Path,
) -> None:
    repo = make_gitlore_repo(tmp_path)
    payload = {
        "skill": "handoff",
        "commit": "without-commit",
        "rename": "A Title",
        "clear": True,
        "continue": "pick up per the task file",
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    first_line = (repo / ".claude" / "autodrive").read_text().splitlines()[0]
    assert first_line == "armed"
    assert "handoff-approved" not in result.stdout


def test_untyped_handoff_still_types_rename_so_it_holds_too(tmp_path: Path) -> None:
    repo = make_gitlore_repo(tmp_path)
    dirty_memory(repo)
    payload = {
        "skill": "handoff",
        "commit": "without-commit",
        "rename": "A Title",
        "clear": False,
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    first_line = (repo / ".claude" / "autodrive").read_text().splitlines()[0]
    assert first_line == "held sess-checkpoint"
    assert "handoff-approved" in result.stdout


def test_sentinel_typing_nothing_arms_even_with_memory_gate_pending(
    tmp_path: Path,
) -> None:
    repo = make_gitlore_repo(tmp_path)
    dirty_memory(repo)
    payload = {
        "skill": "precompact",
        "commit": "without-commit",
        "compact": False,
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
    }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    first_line = (repo / ".claude" / "autodrive").read_text().splitlines()[0]
    assert first_line == "armed"
    assert "handoff-approved" not in result.stdout


def test_autoname_arms_against_dirty_memory_having_asked_nothing(
    tmp_path: Path,
) -> None:
    repo = make_gitlore_repo(tmp_path)
    dirty_memory(repo)
    payload = {"skill": "autoname", "rename": "A Side Conversation"}
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    first_line = (repo / ".claude" / "autodrive").read_text().splitlines()[0]
    assert first_line == "armed"


# ==========================================================================
# the autoname skill
# ==========================================================================


def test_autoname_rename_sentinel_armed_nothing_else(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {"skill": "autoname", "rename": "A Side Conversation"}
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    assert (
        repo / ".claude" / "autodrive"
    ).read_text() == "armed\nrename\n/rename A Side Conversation\n"
    state, _ = drive_state(repo / ".claude" / "autodrive")
    assert state == "armed"


def test_autoname_manifest_present_empty_neither_file_touched(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {"skill": "autoname", "rename": "A Side Conversation"}
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    manifest = repo / ".claude" / "checkpoint-manifest"
    assert manifest.is_file()
    assert manifest.stat().st_size == 0
    assert not (repo / ".claude" / "handoff-task.md").exists()
    assert not (repo / ".claude" / "handoff-todo.md").exists()


def test_rename_missing_under_autoname_errors(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {"skill": "autoname"}
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert "rename" in result.stderr


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("commit", "with-commit"),
        ("task", task_content("body")),
        ("todo", todo_content("body")),
        ("clear", True),
        ("compact", True),
        ("continue", "pick up per the task file"),
    ],
)
def test_every_boundary_field_is_schema_error_under_autoname(
    tmp_path: Path, field: str, value: object
) -> None:
    repo = make_repo(tmp_path)
    payload = {"skill": "autoname", "rename": "A Side Conversation", field: value}
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert field in result.stderr
    assert "autoname" in result.stderr


# ==========================================================================
# the restart skill
# ==========================================================================
#
# Structurally the fourth "neither boundary" skill value, alongside autoname:
# its whole payload is its own name and an optional continuation, and every
# boundary field (commit, task, todo, rename, clear, compact) is a schema
# error under it rather than a silent ignore. Unlike autoname it DOES carry
# `continue` — the restart's own third typed line — so it is not simply
# autoname's forbidden-field set reused.


def test_restart_sentinel_no_continuation(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {"skill": "restart", "continue": None}
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    assert (repo / ".claude" / "autodrive").read_text() == (
        "armed\nrestart\n/exit\nclaude --resume sess-checkpoint\n"
    )
    assert read_back_drive(repo / ".claude" / "autodrive")


def test_restart_sentinel_with_continuation(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {"skill": "restart", "continue": "continue with task 3"}
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    assert (repo / ".claude" / "autodrive").read_text() == (
        "armed\nrestart\n/exit\nclaude --resume sess-checkpoint\ncontinue with task 3\n"
    )
    assert read_back_drive(repo / ".claude" / "autodrive")


def test_restart_manifest_present_empty_neither_file_touched(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {"skill": "restart", "continue": None}
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    manifest = repo / ".claude" / "checkpoint-manifest"
    assert manifest.is_file()
    assert manifest.stat().st_size == 0
    assert not (repo / ".claude" / "handoff-task.md").exists()
    assert not (repo / ".claude" / "handoff-todo.md").exists()


def test_restart_never_holds_even_with_dirty_memory(tmp_path: Path) -> None:
    """Restart composes no memory directive at all, so it never holds."""
    repo = make_gitlore_repo(tmp_path)
    dirty_memory(repo)
    payload = {"skill": "restart", "continue": None}
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    first_line = (repo / ".claude" / "autodrive").read_text().splitlines()[0]
    assert first_line == "armed"
    assert result.stdout == ""


def test_continue_missing_errors_under_restart(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    payload = {"skill": "restart"}
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert "continue" in result.stderr


def test_restart_session_id_unset_errors(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    env = dict(os.environ)
    env["HANDOFF_ROOT"] = str(repo)
    env.pop("CLAUDE_CODE_SESSION_ID", None)
    env.pop("CLAUDE_PROJECT_DIR", None)
    result = subprocess.run(
        [sys.executable, str(CHECKPOINT)],
        cwd=repo,
        input=json.dumps({"skill": "restart", "continue": None}),
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 2
    # Guard against a vacuous pass: the generic "unknown skill" error also
    # echoes the rejected value, so it contains the literal text "restart"
    # too. Rule that message out explicitly rather than just pattern-matching
    # for it.
    assert 'must be "handoff"' not in result.stderr
    assert "SESSION_ID" in result.stderr or "session" in result.stderr.lower()


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("commit", "with-commit"),
        ("task", task_content("body")),
        ("todo", todo_content("body")),
        ("rename", "Not Allowed"),
        ("clear", True),
        ("compact", True),
    ],
)
def test_every_boundary_field_is_schema_error_under_restart(
    tmp_path: Path, field: str, value: object
) -> None:
    repo = make_repo(tmp_path)
    payload = {"skill": "restart", "continue": None, field: value}
    result = run_checkpoint(repo, payload)
    assert result.returncode == 2
    assert field in result.stderr
    assert "restart" in result.stderr
    # Guard against a vacuous pass: "restart" appears in the generic
    # "unknown skill" error too (it echoes the rejected value), and
    # "precompact" contains "compact" as a substring.
    assert 'must be "handoff"' not in result.stderr


def test_autoname_against_dirty_memory_no_directive_at_all(tmp_path: Path) -> None:
    repo = make_gitlore_repo(tmp_path)
    dirty_memory(repo)
    payload = {"skill": "autoname", "rename": "A Side Conversation"}
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    assert result.stdout == ""


# ==========================================================================
# Memory directive
# ==========================================================================


def handoff_payload(commit: str) -> dict[str, object]:
    return {
        "skill": "handoff",
        "commit": commit,
        "rename": "Session Title",
        "clear": False,
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
    }


def precompact_payload(commit: str) -> dict[str, object]:
    return {
        "skill": "precompact",
        "commit": commit,
        "compact": False,
        "continue": None,
        "task": task_clear(),
        "todo": todo_keep(),
    }


def test_not_gitlore_managed_silent(tmp_path: Path) -> None:
    repo = make_repo(tmp_path, "plain")
    result = run_checkpoint(repo, handoff_payload("without-commit"))
    assert result.returncode == 0
    assert result.stdout == ""


def test_gitlore_clean_memory_silent(tmp_path: Path) -> None:
    repo = make_gitlore_repo(tmp_path)
    result = run_checkpoint(repo, handoff_payload("without-commit"))
    assert result.returncode == 0
    assert result.stdout == ""


def test_submodule_registered_not_materialized_silent(tmp_path: Path) -> None:
    repo = make_gitlore_repo(tmp_path)
    shutil.rmtree(repo / "memory" / ".git")
    result = run_checkpoint(repo, handoff_payload("without-commit"))
    assert result.returncode == 0
    assert result.stdout == ""


def test_dirty_memory_directive_names_both_ipc_paths(tmp_path: Path) -> None:
    repo = make_gitlore_repo(tmp_path)
    dirty_memory(repo)
    result = run_checkpoint(repo, handoff_payload("without-commit"))
    assert result.returncode == 0
    assert "uncommitted changes" in result.stdout
    assert "feedback_x.md" in result.stdout
    assert str(repo / ".claude" / "gitlore-memory-message") in result.stdout
    assert str(repo / ".claude" / "gitlore-commit-memory") in result.stdout


def test_clause_resolved_content_is_its_own_block(tmp_path: Path) -> None:
    repo = make_gitlore_repo(tmp_path)
    dirty_memory(repo)
    result = run_checkpoint(repo, handoff_payload("without-commit"))
    assert result.returncode == 0
    assert GITLORE_MEMORY_APPROVAL_CLAUSE in result.stdout
    assert f"\n\n{GITLORE_MEMORY_APPROVAL_CLAUSE}\n\n" in result.stdout
    assert "72 characters" in result.stdout


def test_clause_file_unset_names_key_and_restart(tmp_path: Path) -> None:
    repo = make_gitlore_repo(tmp_path)
    dirty_memory(repo)
    subprocess.run(
        ["git", "config", "--unset", "gitlore.memoryApprovalClauseFile"],
        cwd=repo,
        check=True,
    )
    result = run_checkpoint(repo, handoff_payload("without-commit"))
    assert result.returncode == 0
    assert "gitlore.memoryapprovalclausefile" in result.stdout.lower()
    assert "/handoff:restart" in result.stdout
    assert str(repo / ".claude" / "gitlore-memory-message") not in result.stdout
    assert str(repo / ".claude" / "gitlore-commit-memory") not in result.stdout


def test_clause_file_missing_same_key_and_restart_report(tmp_path: Path) -> None:
    repo = make_gitlore_repo(tmp_path)
    dirty_memory(repo)
    subprocess.run(
        [
            "git",
            "config",
            "gitlore.memoryApprovalClauseFile",
            str(repo / ".gitlore-memory-approval-clause-missing.txt"),
        ],
        cwd=repo,
        check=True,
    )
    result = run_checkpoint(repo, handoff_payload("without-commit"))
    assert result.returncode == 0
    assert "gitlore.memoryapprovalclausefile" in result.stdout.lower()
    assert "/handoff:restart" in result.stdout
    assert str(repo / ".claude" / "gitlore-memory-message") not in result.stdout


def test_unset_and_missing_clause_reports_are_the_same(tmp_path: Path) -> None:
    repo_unset = make_gitlore_repo(tmp_path, "glrepo_unset")
    dirty_memory(repo_unset)
    subprocess.run(
        ["git", "config", "--unset", "gitlore.memoryApprovalClauseFile"],
        cwd=repo_unset,
        check=True,
    )
    unset_result = run_checkpoint(repo_unset, handoff_payload("without-commit"))

    repo_missing = make_gitlore_repo(tmp_path, "glrepo_missing")
    dirty_memory(repo_missing)
    subprocess.run(
        [
            "git",
            "config",
            "gitlore.memoryApprovalClauseFile",
            str(repo_missing / "gone.txt"),
        ],
        cwd=repo_missing,
        check=True,
    )
    missing_result = run_checkpoint(repo_missing, handoff_payload("without-commit"))

    assert unset_result.returncode == 0
    assert missing_result.returncode == 0
    assert unset_result.stdout == missing_result.stdout


def test_with_commit_summary_write_only_no_trigger_mention(tmp_path: Path) -> None:
    repo = make_gitlore_repo(tmp_path)
    dirty_memory(repo)
    result = run_checkpoint(repo, handoff_payload("with-commit"))
    assert result.returncode == 0
    assert str(repo / ".claude" / "gitlore-memory-message") in result.stdout
    assert "gitlore-commit-memory" not in result.stdout
    assert "trigger" not in result.stdout
    assert "two file writes" not in result.stdout


def test_with_commit_states_commit_carries_the_memory(tmp_path: Path) -> None:
    repo = make_gitlore_repo(tmp_path)
    dirty_memory(repo)
    result = run_checkpoint(repo, handoff_payload("with-commit"))
    assert result.returncode == 0
    assert "carries the memory" in result.stdout.lower()


def test_without_commit_keeps_standalone_two_file_instruction(tmp_path: Path) -> None:
    repo = make_gitlore_repo(tmp_path)
    dirty_memory(repo)
    result = run_checkpoint(repo, handoff_payload("without-commit"))
    assert result.returncode == 0
    assert "two file writes" in result.stdout
    assert "Write the trigger file (any content)" in result.stdout
    assert "carries the memory" not in result.stdout


# ==========================================================================
# Composition
# ==========================================================================


def test_handoff_composition_carries_todo_boundary_not_sdd_nudge(
    tmp_path: Path,
) -> None:
    repo = make_gitlore_repo(tmp_path)
    dirty_memory(repo)
    add_sdd_ledger(repo)
    result = run_checkpoint(repo, handoff_payload("without-commit"))
    assert result.returncode == 0
    assert ".superpowers/sdd/feature-plan/progress.md" in result.stdout
    assert "handoff-todo.md" in result.stdout
    assert "Minor findings" not in result.stdout
    assert "re-dispatched" not in result.stdout


def test_precompact_composition_carries_sdd_nudge_memory_first(tmp_path: Path) -> None:
    repo = make_gitlore_repo(tmp_path)
    dirty_memory(repo)
    add_sdd_ledger(repo)
    result = run_checkpoint(repo, precompact_payload("without-commit"))
    assert result.returncode == 0
    assert str(repo / ".claude" / "gitlore-commit-memory") in result.stdout
    assert ".superpowers/sdd/feature-plan/progress.md" in result.stdout
    out_lines = result.stdout.splitlines()
    mem_line = next(
        i for i, line in enumerate(out_lines) if "gitlore-commit-memory" in line
    )
    sdd_line = next(
        i
        for i, line in enumerate(out_lines)
        if ".superpowers/sdd/feature-plan/progress.md" in line
    )
    assert mem_line < sdd_line


@pytest.mark.parametrize("skill", ["handoff", "precompact"])
def test_each_boundary_composes_own_directive_not_the_others(
    tmp_path: Path, skill: str
) -> None:
    repo = make_gitlore_repo(tmp_path, "bnd")
    dirty_memory(repo)
    add_sdd_ledger(repo)
    if skill == "handoff":
        payload = {
            "skill": skill,
            "commit": "without-commit",
            "rename": "T",
            "clear": False,
            "continue": None,
            "task": task_clear(),
            "todo": todo_keep(),
        }
    else:
        payload = {
            "skill": skill,
            "commit": "without-commit",
            "compact": False,
            "continue": None,
            "task": task_clear(),
            "todo": todo_keep(),
        }
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    if skill == "handoff":
        assert "survives the /clear" in result.stdout
        assert "re-dispatched" not in result.stdout
    else:
        assert "re-dispatched" in result.stdout
        assert "survives the /clear" not in result.stdout
    lines = result.stdout.splitlines()
    mem = next(i for i, line in enumerate(lines) if "gitlore-memory-message" in line)
    led = next(
        i
        for i, line in enumerate(lines)
        if ".superpowers/sdd/feature-plan/progress.md" in line
    )
    assert mem < led


@pytest.mark.parametrize("skill", ["handoff", "precompact"])
def test_live_ledger_scopes_todo_file_rather_than_standing_it_down(
    tmp_path: Path, skill: str
) -> None:
    repo = make_gitlore_repo(tmp_path, "scope")
    add_sdd_ledger(repo)
    payload = (
        handoff_payload("without-commit")
        if skill == "handoff"
        else precompact_payload("without-commit")
    )
    result = run_checkpoint(repo, payload)
    assert result.returncode == 0
    assert ".claude/handoff-todo.md" in result.stdout
    assert "outside the plan" in result.stdout
    assert "must not exist" not in result.stdout


def test_precompact_no_ledger_memory_directive_only(tmp_path: Path) -> None:
    repo = make_gitlore_repo(tmp_path)
    dirty_memory(repo)
    result = run_checkpoint(repo, precompact_payload("without-commit"))
    assert result.returncode == 0
    assert str(repo / ".claude" / "gitlore-memory-message") in result.stdout
    assert ".superpowers/sdd/feature-plan/progress.md" not in result.stdout


def test_flat_path_stray_does_not_suppress_todo_file(tmp_path: Path) -> None:
    repo = make_gitlore_repo(tmp_path)
    dirty_memory(repo)
    add_flat_sdd_ledger(repo)
    result = run_checkpoint(repo, handoff_payload("without-commit"))
    assert result.returncode == 0
    assert "handoff-todo.md" not in result.stdout


def test_unidentified_workspace_does_not_suppress_todo_file(tmp_path: Path) -> None:
    repo = make_gitlore_repo(tmp_path)
    dirty_memory(repo)
    add_unidentified_sdd_ledger(repo)
    result = run_checkpoint(repo, handoff_payload("without-commit"))
    assert result.returncode == 0
    assert "handoff-todo.md" not in result.stdout


def test_flat_path_ledger_alone_precompact_silent(tmp_path: Path) -> None:
    repo = tmp_path / "sddflat"
    (repo / ".claude").mkdir(parents=True)
    subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
    add_flat_sdd_ledger(repo)
    result = run_checkpoint(repo, precompact_payload("without-commit"))
    assert result.returncode == 0
    assert result.stdout == ""


def test_several_live_workspaces_most_recently_modified_wins(tmp_path: Path) -> None:
    for i, pair in enumerate((("a-live", "z-stale"), ("z-live", "a-stale")), start=1):
        live, stale = pair
        repo = tmp_path / f"sddmulti{i}"
        (repo / ".claude").mkdir(parents=True)
        subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
        add_sdd_ledger(repo, stale)
        add_sdd_ledger(repo, live)
        old_time = 1735689600  # 2025-01-01
        os.utime(
            repo / ".superpowers" / "sdd" / stale / "progress.md", (old_time, old_time)
        )
        result = run_checkpoint(repo, precompact_payload("without-commit"))
        assert result.returncode == 0
        assert f".superpowers/sdd/{live}/progress.md" in result.stdout
        assert stale not in result.stdout
