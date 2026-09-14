#!/usr/bin/env python3
"""Shared helpers for checkpoint.py (handoff-checkpoint).

Also reached via the --is-empty-body CLI by write-stage.sh (bash, unmoved). Port
of _checkpoint-lib.sh — see docs/changelog/2026-08-10-python-split.md. Each
directive function takes the git worktree root and returns its directive text,
or "" when silent; the caller decides whether to print it.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path


def _printf_lines(*args: str) -> str:
    r"""Mirror bash's `printf '%s\n' arg...`: each arg followed by a newline."""
    return "\n".join(args) + "\n"


def is_empty_body(content: str) -> bool:
    """Report whether content is empty once ATX headings/blanks are removed.

    A `## Remaining` with no items, a task file with headings and no content:
    both are empty. Shared by checkpoint.py and write-stage.sh so the two
    writers cannot drift on what counts as empty.

    "Blank" is the line with no trailing whitespace left, so a line of spaces
    alone is blank rather than content. "Heading" is an ATX heading and not
    merely a leading `#` (`_ATX_HEADING`): `#!/bin/sh`, `#tag` and a run of
    seven `#` are all content, the `#` run in each being followed by something
    other than whitespace or the line's end. The leading-space bound is
    markdown's own: up to three indents a heading, and a fourth opens a code
    block, whose `# comment` line is content like any other. Testing the
    stripped line instead would put that line back in the class this function
    exists to keep out of it.
    """
    for raw in content.split("\n"):
        line = raw.rstrip()
        if line == "" or _ATX_HEADING.fullmatch(line):
            continue
        return False
    return True


# Markdown's own ATX rule: up to three leading spaces, 1-6 `#`, then the line
# ends or whitespace separates the text. Read only by is_empty_body, above.
_ATX_HEADING = re.compile(r" {0,3}#{1,6}(\s.*)?")


def _resolve_submodule_path(root: str) -> str:
    gitmodules = Path(root) / ".gitmodules"
    result = subprocess.run(
        ["git", "config", "--file", str(gitmodules), "submodule.gitlore-memory.path"],
        capture_output=True,
        text=True,
        check=False,
    )
    mempath = result.stdout.strip()
    return mempath if result.returncode == 0 else ""


def _resolve_approval_clause(root: str) -> str | None:
    """Return the clause text, or None when it cannot be read.

    The caller reports the key-and-restart fallback on None.
    """
    clause_result = subprocess.run(
        ["git", "-C", root, "config", "--get", "gitlore.memoryApprovalClauseFile"],
        capture_output=True,
        text=True,
        check=False,
    )
    clause_file = clause_result.stdout.strip() if clause_result.returncode == 0 else ""
    path = Path(clause_file) if clause_file else None
    if path is None or not path.is_file() or not os.access(path, os.R_OK):
        return None
    return path.read_text(encoding="utf-8").rstrip("\n")


def memory_directive(root: str, mode: str) -> str:
    """Return the gitlore memory-commit directive, or "" if nothing to commit.

    `mode` ("with-commit"/"without-commit") selects which of gitlore's two
    commit paths the agent is told to take. The with-commit text never mentions
    the trigger file — its reader has no other source for that filename, so
    saying nothing is what makes the standalone commit unreachable.
    """
    mempath = _resolve_submodule_path(root)
    if not mempath:
        return ""
    mem = Path(root) / mempath
    if not (mem / ".git").exists():
        return ""

    status = subprocess.run(
        ["git", "-C", str(mem), "status", "--porcelain"],
        capture_output=True,
        text=True,
        check=False,
    ).stdout.rstrip("\n")
    if not status.strip():
        return ""

    clause = _resolve_approval_clause(root)
    if clause is None:
        return _printf_lines(
            "gitlore memory has uncommitted changes, but this session cannot read "
            "the memory-approval wording: git config "
            "gitlore.memoryApprovalClauseFile is unset or its file is missing. "
            "gitlore pins that key at SessionStart — run /handoff:restart (or "
            "exit and relaunch with --resume, by hand), then retry. Nothing has "
            "been written and the memory changes are still pending."
        )

    msgfile = Path(root) / ".claude" / "gitlore-memory-message"
    trigger = Path(root) / ".claude" / "gitlore-commit-memory"
    approve_files = "the file below" if mode == "with-commit" else "either file below"

    common = _printf_lines(
        "gitlore memory has uncommitted changes:",
        "",
        status,
        "",
        "Summarize these changes as a commit message, its title line at most "
        "72 characters.",
        "",
        clause,
        "",
        "Present it to the user as a markdown blockquote (lines prefixed with "
        f"'> ', not a code fence) and get their approval — they may edit it. Do "
        f"not write {approve_files} before the user approves.",
        "",
    )
    if mode == "with-commit":
        specific = _printf_lines(
            "Once approved, write the approved summary to:",
            "",
            f"     {msgfile}",
            "",
            "The commit that lands these changes carries the memory. Nothing "
            "further is needed from you.",
        )
    else:
        specific = _printf_lines(
            "Once approved, commit the memory with two file writes (no Bash):",
            "",
            "  1. Write the approved summary to:",
            f"     {msgfile}",
            "  2. Write the trigger file (any content) to:",
            f"     {trigger}",
        )
    return common + specific


def arming_directive() -> str:
    """Return the instruction that releases a held transition."""
    return _printf_lines(
        "Once that is done, run `handoff-approved` (Bash, no arguments)."
    )


def ledger_path(root: str) -> str | None:
    """Return the live workflow-owned progress ledger under root, or None.

    Project-relative. Liveness, not presence: only a workspace whose first line
    is SDD's identity line counts; several live workspaces resolve by mtime,
    ties keeping the lexically-first (glob order).
    """
    root_path = Path(root)
    best: Path | None = None
    best_mtime = float("-inf")
    for f in sorted((root_path / ".superpowers" / "sdd").glob("*/progress.md")):
        if not f.is_file():
            continue
        try:
            first = f.read_text(encoding="utf-8").split("\n", 1)[0]
        except OSError:
            continue
        if not first.startswith("# SDD ledger — plan: "):
            continue
        mtime = f.stat().st_mtime
        if mtime > best_mtime:
            best, best_mtime = f, mtime
    if best is None:
        return None
    return str(best.relative_to(root_path))


def sdd_directive(root: str) -> str:
    """Return the durable-progress nudge (precompact only), or "".

    Silent when there is no live ledger.
    """
    ledger = ledger_path(root)
    if ledger is None:
        return ""
    return _printf_lines(
        "You are running superpowers SDD. Before compacting, bring the ledger "
        f"current at {ledger} — after compaction the SDD skill trusts the "
        "ledger over recollection. Ensure:",
        "",
        "  - every task whose review came back clean has its `Task N: complete "
        "(commits <base>..<head>, review clean)` line",
        "  - any Minor findings seen so far are recorded for the final "
        "whole-branch review",
        "",
        "A task that completed but is missing from the ledger can be "
        "re-dispatched after compaction — the most expensive SDD failure.",
        "",
        "That ledger holds this plan's tasks. Keep them out of "
        ".claude/handoff-todo.md, which holds only work outstanding outside "
        "the plan.",
    )


def todo_boundary(root: str) -> str:
    """Return the ledger/todo-file boundary (handoff only), or "".

    Silent when there is no live ledger.
    """
    ledger = ledger_path(root)
    if ledger is None:
        return ""
    return _printf_lines(
        f"A workflow-owned progress ledger at {ledger} holds this plan's tasks, "
        "and it survives the /clear. Keep those tasks out of "
        ".claude/handoff-todo.md, removing them if they are already there; that "
        "file holds only work outstanding outside the plan. Bring the ledger "
        "current if it has drifted."
    )


def _cli(argv: list[str]) -> int:
    """Run `checkpoint_lib.py --is-empty-body`.

    Reads content on stdin, exits 0 if empty, 1 otherwise. write-stage.sh's cold
    branch can afford the spawn.
    """
    if len(argv) == 2 and argv[1] == "--is-empty-body":
        content = sys.stdin.read()
        return 0 if is_empty_body(content) else 1
    print("checkpoint_lib.py: unknown invocation", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(_cli(sys.argv))
