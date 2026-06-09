# Per-Worktree Handoff Root Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every handoff hook resolve `.claude/handoff-task.md` against the *enclosing git worktree's* root, so worktree sessions own their own handoff instead of colliding on the main repo's `.claude/`.

**Architecture:** A new pure python module `scripts/worktree_root.py` walks up from the session cwd via on-disk `.git` linkage to find the enclosing linked-worktree root, falling back to `CLAUDE_PROJECT_DIR` outside a worktree. A one-line `handoff_root` shell wrapper in `_lib.sh` shells out to it (same pattern as `load-handoff.sh` → `extract.py`). Every hook replaces `cwd="${CLAUDE_PROJECT_DIR:-$PWD}"` with `cwd="$(handoff_root "$(jq -r '.cwd // ""' <<<"$input")")"`. Outside a worktree the result is byte-identical to today, so the existing suite stays green.

**Tech Stack:** bash hooks, python3 (stdlib only), pytest (virtual project via uv + direnv venv), bats. Spec: `plans/2026-06-09-per-worktree-handoff-root-design.md`.

---

## File Structure

- Create: `scripts/worktree_root.py` — pure resolver: `worktree_root(cwd, project) -> str` + `__main__` CLI.
- Create: `tests/test_worktree_root.py` — pytest branch matrix (imports the module directly; `pythonpath = ["scripts"]` already set in `pyproject.toml`).
- Modify: `scripts/_lib.sh` — add `handoff_root` wrapper.
- Modify: `scripts/write-guard.sh`, `scripts/read-guard.sh`, `scripts/write-stage.sh`, `scripts/load-handoff.sh`, `scripts/write-rename.sh` — route the root through `handoff_root`.
- Modify: `scripts/_wipe-emit.sh` — `$1` becomes the raw session cwd; compute root internally.
- Modify: `scripts/skill-pre-hook.sh`, `scripts/prompt-pre-hook.sh` — pass raw `.cwd` to `_wipe-emit.sh`.
- Modify: `tests/hook-test.bats` — add `make_worktree` helper + worktree scenarios.
- Modify: `CLAUDE.md`, `DESIGN.md` — document the new behavior.

A note on the empty-cwd guard: `worktree_root("") → project` is **kept** (not dead code). The existing `load-handoff` bats scenarios send payloads with no `cwd`, and a bare `.git` lookup on an empty path would otherwise resolve relative to the python process's CWD — non-deterministic. The guard makes the function total and CWD-independent.

---

### Task 1: `worktree_root.py` resolver (pure logic, pytest)

**Files:**
- Create: `tests/test_worktree_root.py`
- Create: `scripts/worktree_root.py`

- [ ] **Step 1: Write the failing test**

Create `tests/test_worktree_root.py`:

```python
# Branch matrix for scripts/worktree_root.py. tmp_path scaffolds a fake
# linked worktree: a directory whose .git is a *file* containing
# `gitdir: <project>/.git/worktrees/<name>`, mirroring real git layout.
import pytest

from worktree_root import worktree_root


def _make_project(tmp_path):
    project = tmp_path / "proj"
    (project / ".git" / "worktrees").mkdir(parents=True)
    return project


def _make_worktree(project, name="wt"):
    wt = project.parent / name
    wt.mkdir()
    gitdir = project / ".git" / "worktrees" / name
    gitdir.mkdir(parents=True, exist_ok=True)
    (wt / ".git").write_text(f"gitdir: {gitdir}\n")
    return wt


def test_worktree_root_itself(tmp_path):
    project = _make_project(tmp_path)
    wt = _make_worktree(project)
    assert worktree_root(str(wt), str(project)) == str(wt)


def test_worktree_subdir_drifts_up_to_worktree_root(tmp_path):
    project = _make_project(tmp_path)
    wt = _make_worktree(project)
    sub = wt / "src" / "deep"
    sub.mkdir(parents=True)
    assert worktree_root(str(sub), str(project)) == str(wt)


def test_cwd_is_project_returns_project(tmp_path):
    project = _make_project(tmp_path)
    assert worktree_root(str(project), str(project)) == str(project)


def test_main_tree_subdir_returns_project(tmp_path):
    project = _make_project(tmp_path)
    sub = project / "scripts"
    sub.mkdir()
    assert worktree_root(str(sub), str(project)) == str(project)


def test_dotgit_directory_ancestor_returns_project(tmp_path):
    project = _make_project(tmp_path)
    nested = tmp_path / "nested"
    (nested / ".git").mkdir(parents=True)  # a *directory*, not a worktree file
    sub = nested / "sub"
    sub.mkdir()
    assert worktree_root(str(sub), str(project)) == str(project)


def test_gitdir_outside_project_git_returns_project(tmp_path):
    project = _make_project(tmp_path)
    wt = project.parent / "rogue"
    wt.mkdir()
    (wt / ".git").write_text("gitdir: /somewhere/else/.git/worktrees/x\n")
    assert worktree_root(str(wt), str(project)) == str(project)


def test_relative_gitdir_treated_as_non_worktree(tmp_path):
    # git writes absolute gitdir paths; a relative one is not normalized and
    # falls back to project (documented limitation, matches cwd-safety).
    project = _make_project(tmp_path)
    wt = project.parent / "rel"
    wt.mkdir()
    (wt / ".git").write_text("gitdir: ../proj/.git/worktrees/rel\n")
    assert worktree_root(str(wt), str(project)) == str(project)


def test_empty_cwd_returns_project(tmp_path):
    project = _make_project(tmp_path)
    assert worktree_root("", str(project)) == str(project)


def test_unrelated_cwd_no_git_returns_project(tmp_path):
    project = _make_project(tmp_path)
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    assert worktree_root(str(elsewhere), str(project)) == str(project)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_worktree_root.py -q`
Expected: collection/import error — `ModuleNotFoundError: No module named 'worktree_root'`.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/worktree_root.py`:

```python
#!/usr/bin/env python3
"""Resolve the effective handoff root for a session cwd.

When ``cwd`` is inside a linked git worktree of ``project``, returns the
worktree root so each worktree owns its own ``.claude/``; otherwise returns
``project``. Pure filesystem reads, no subprocess. Port of the cwd-safety
plugin's ``_worktree_root`` plus a ``-> project`` fallback.

CLI: ``worktree_root.py <cwd> <project>`` prints the resolved root.
"""

import os
import sys


def _read_gitdir(dotgit_file: str) -> str:
    """Absolute gitdir path from a linked worktree's ``.git`` file, or "".

    A linked worktree's ``.git`` is a file containing ``gitdir: <path>``. A
    relative path is joined to the file's directory but not normalized; git
    writes absolute gitdir paths in practice, so a relative one simply won't
    match ``project/.git`` and the dir is treated as not-a-worktree (safe).
    """
    try:
        with open(dotgit_file, encoding="utf-8") as f:
            content = f.read()
    except (OSError, UnicodeDecodeError):
        return ""
    for line in content.splitlines():
        if line.startswith("gitdir:"):
            path = line[len("gitdir:"):].strip()
            if not path:
                return ""
            if not os.path.isabs(path):
                path = os.path.join(os.path.dirname(dotgit_file), path)
            return path
    return ""


def _is_under(path: str, parent: str) -> bool:
    """True if ``path`` equals ``parent`` or sits inside it (string match)."""
    parent = parent.rstrip(os.sep)
    return path == parent or path.startswith(parent + os.sep)


def worktree_root(cwd: str, project: str) -> str:
    """Effective handoff root for ``cwd`` given main project root ``project``.

    Walks up from ``cwd``; the worktree root is the first ancestor whose
    ``.git`` is a *file* whose ``gitdir:`` resolves under ``project/.git``.
    Returns ``project`` on the main tree, a nested standalone repo, an empty
    input, or anything unrecognized.
    """
    if not cwd or not project:
        return project
    git_main = os.path.join(project, ".git")
    d = cwd
    while True:
        if d == project:
            return project
        dotgit = os.path.join(d, ".git")
        if os.path.isfile(dotgit):
            gitdir = _read_gitdir(dotgit)
            if gitdir and _is_under(gitdir, git_main):
                return d
            return project
        if os.path.isdir(dotgit):
            return project
        parent = os.path.dirname(d)
        if parent == d:
            return project
        d = parent


def main() -> None:
    cwd = sys.argv[1] if len(sys.argv) > 1 else ""
    project = sys.argv[2] if len(sys.argv) > 2 else ""
    print(worktree_root(cwd, project))


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/test_worktree_root.py -q`
Expected: `9 passed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/worktree_root.py tests/test_worktree_root.py
git commit -m "feat: add worktree_root resolver for per-worktree handoff"
```

---

### Task 2: `handoff_root` shell wrapper + bats helper

**Files:**
- Modify: `scripts/_lib.sh` (add `handoff_root` after `handoff_resolve`)
- Modify: `tests/hook-test.bats` (add `make_worktree` helper + 3 unit tests)

- [ ] **Step 1: Write the failing test**

In `tests/hook-test.bats`, add the helper immediately after the `setup()` function (around line 37, before the first `@test`):

```bash
# Build a fake linked git worktree of $tmp under $BATS_TEST_TMPDIR/$name and
# echo its path. Its .git is a *file* pointing under $tmp/.git/worktrees/$name,
# mirroring real git worktree layout. $tmp is CLAUDE_PROJECT_DIR (set in setup).
make_worktree() {
    local name="${1:-wt}"
    local wt="$BATS_TEST_TMPDIR/$name"
    mkdir -p "$wt/.claude" "$tmp/.git/worktrees/$name"
    printf 'gitdir: %s\n' "$tmp/.git/worktrees/$name" > "$wt/.git"
    printf '%s\n' "$wt"
}
```

Then add these tests in the `# --- _lib.sh: handoff_activated detector ---` region (after line 68):

```bash
# --- _lib.sh: handoff_root resolver ---

@test "handoff_root: worktree cwd -> worktree root" {
    wt="$(make_worktree wtA)"
    run handoff_root "$wt"
    [ "$status" -eq 0 ]
    [ "$output" = "$wt" ]
}

@test "handoff_root: worktree subdir -> worktree root" {
    wt="$(make_worktree wtB)"
    run handoff_root "$wt/scripts"
    [ "$status" -eq 0 ]
    [ "$output" = "$wt" ]
}

@test "handoff_root: non-worktree cwd -> CLAUDE_PROJECT_DIR" {
    run handoff_root "$other"
    [ "$status" -eq 0 ]
    [ "$output" = "$tmp" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/hook-test.bats -f handoff_root`
Expected: FAIL — `command not found: handoff_root` (or non-zero status) for all three.

- [ ] **Step 3: Write minimal implementation**

In `scripts/_lib.sh`, add immediately after the `handoff_resolve()` function (after its closing `}` on line 25):

```bash

# Effective project root for the handoff files of THIS session. When the
# session cwd ($1, from hook-input .cwd) is inside a linked git worktree of
# CLAUDE_PROJECT_DIR, returns the worktree root so each worktree owns its own
# .claude/; otherwise returns CLAUDE_PROJECT_DIR (fallback $PWD). The
# branch-heavy resolution lives in worktree_root.py (unit-tested with pytest);
# this is the thin shell wrapper. See
# plans/2026-06-09-per-worktree-handoff-root-design.md.
handoff_root() {
    python3 "$(dirname "${BASH_SOURCE[0]}")/worktree_root.py" \
        "${1:-}" "${CLAUDE_PROJECT_DIR:-$PWD}"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/hook-test.bats -f handoff_root`
Expected: `3 tests, 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add scripts/_lib.sh tests/hook-test.bats
git commit -m "feat: add handoff_root wrapper + worktree bats helper"
```

---

### Task 3: Route the guards through `handoff_root`

**Files:**
- Modify: `scripts/write-guard.sh:18`
- Modify: `scripts/read-guard.sh:20`
- Test: `tests/hook-test.bats` (add 2 worktree scenarios)

- [ ] **Step 1: Write the failing tests**

In `tests/hook-test.bats`, add under `# --- write-guard ---` (after the existing write-guard tests, around line 169):

```bash
@test "write-guard (worktree cwd: allow write to worktree .claude)" {
    wt="$(make_worktree wtG)"
    run bash -c '
        jq -nc --arg cwd "$1" --arg t "$2" --arg fp "$1/.claude/handoff-task.md" \
            "{cwd:\$cwd, transcript_path:\$t, tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | bash scripts/write-guard.sh
    ' _ "$wt" "$repo_root/tests/fixtures/activated-skill.jsonl"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}
```

Add under `# --- read-guard ---` (after the existing read-guard tests, around line 201):

```bash
@test "read-guard (worktree cwd, not activated: deny)" {
    wt="$(make_worktree wtR)"
    run bash -c '
        jq -nc --arg cwd "$1" --arg t "$2" --arg fp "$1/.claude/handoff-task.md" \
            "{cwd:\$cwd, transcript_path:\$t, tool_name:\"Read\", tool_input:{file_path:\$fp}}" \
        | bash scripts/read-guard.sh
    ' _ "$wt" "$repo_root/tests/fixtures/extract-basic.jsonl"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/hook-test.bats -f worktree`
Expected: both new tests FAIL — write-guard emits a `deny` (so `$output` is non-empty) because it anchors on `CLAUDE_PROJECT_DIR=$tmp`; read-guard passes through (empty output, no deny) because it sees the worktree path as "not this project's file".

- [ ] **Step 3: Apply the implementation change**

In `scripts/write-guard.sh`, replace line 18:

```bash
cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
```

with:

```bash
cwd="$(handoff_root "$(jq -r '.cwd // ""' <<<"$input")")"
```

In `scripts/read-guard.sh`, replace line 20 (identical text) with the identical replacement:

```bash
cwd="$(handoff_root "$(jq -r '.cwd // ""' <<<"$input")")"
```

- [ ] **Step 4: Run tests to verify they pass (and nothing regressed)**

Run: `bats tests/hook-test.bats`
Expected: all pass, including the unchanged `write-guard (CLAUDE_PROJECT_DIR overrides cwd drift: allow)` (its drifted `$other` cwd has no `.git`, so `handoff_root` still falls back to `$tmp`).

- [ ] **Step 5: Commit**

```bash
git add scripts/write-guard.sh scripts/read-guard.sh tests/hook-test.bats
git commit -m "fix: anchor read/write guards on the worktree root"
```

---

### Task 4: Route the round-trip (stage + load) through `handoff_root`

**Files:**
- Modify: `scripts/write-stage.sh:17`
- Modify: `scripts/load-handoff.sh:18`
- Test: `tests/hook-test.bats` (add 2 worktree scenarios)

- [ ] **Step 1: Write the failing tests**

In `tests/hook-test.bats`, add under `# --- write-stage ---` (after the existing write-stage tests, around line 113):

```bash
@test "write-stage (worktree cwd: pointer saved in worktree .claude, not main)" {
    wt="$(make_worktree wtS)"
    cp "$tmp/.claude/handoff-task.md" "$wt/.claude/handoff-task.md"
    run bash -c '
        jq -nc --arg cwd "$1" --arg t "$2" --arg fp "$1/.claude/handoff-task.md" \
            "{cwd:\$cwd, transcript_path:\$t, tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | bash scripts/write-stage.sh
    ' _ "$wt" "$transcript"
    [ "$status" -eq 0 ]
    [ "$(cat "$wt/.claude/handoff-session")" = "$transcript" ]
    [ ! -e "$tmp/.claude/handoff-session" ]
}
```

Add under `# --- load-handoff ---` (after the existing load-handoff tests, around line 342):

```bash
@test "load-handoff (worktree cwd: reads worktree task, not main)" {
    wt="$(make_worktree wtL)"
    cat > "$wt/.claude/handoff-task.md" <<'WTTASK'
## Current task

worktree handoff body

## Open decisions

- none
WTTASK
    printf '%s\n' "$transcript" > "$wt/.claude/handoff-session"
    run bash -c '
        jq -nc --arg cwd "$1" --arg e "clear" "{cwd:\$cwd, hook_event_name:\$e}" \
        | bash scripts/load-handoff.sh
    ' _ "$wt"
    [ "$status" -eq 0 ]
    echo "$output" | jq -r '.hookSpecificOutput.additionalContext' | grep -q 'worktree handoff body'
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/hook-test.bats -f worktree`
Expected: the two new tests FAIL — write-stage anchors on `$tmp` so its `target != expected` and it exits early (no pointer at `$wt/.claude/handoff-session`); load-handoff reads `$tmp`'s task (`hook smoke test`) so the assembled context lacks `worktree handoff body`.

- [ ] **Step 3: Apply the implementation change**

In `scripts/write-stage.sh`, replace line 17:

```bash
cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
```

with:

```bash
cwd="$(handoff_root "$(jq -r '.cwd // ""' <<<"$input")")"
```

In `scripts/load-handoff.sh`, replace line 18 (identical text) with the identical replacement:

```bash
cwd="$(handoff_root "$(jq -r '.cwd // ""' <<<"$input")")"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/hook-test.bats`
Expected: all pass, including the existing `load-handoff` scenarios whose payloads omit `cwd` (they degrade to `handoff_root("") → CLAUDE_PROJECT_DIR`, today's behavior).

- [ ] **Step 5: Commit**

```bash
git add scripts/write-stage.sh scripts/load-handoff.sh tests/hook-test.bats
git commit -m "fix: anchor stage + load round-trip on the worktree root"
```

---

### Task 5: Route the wipe path + rename through `handoff_root`

**Files:**
- Modify: `scripts/_wipe-emit.sh` (lines 12, 18 — contract comment + root derivation)
- Modify: `scripts/skill-pre-hook.sh:24-26`
- Modify: `scripts/prompt-pre-hook.sh:18-20`
- Modify: `scripts/write-rename.sh:17`
- Test: `tests/hook-test.bats` (add 2 worktree scenarios)

- [ ] **Step 1: Write the failing tests**

In `tests/hook-test.bats`, add under `# --- skill-pre-hook ---` (after the existing skill-pre-hook tests, around line 254):

```bash
@test "skill-pre-hook (worktree cwd: wipes worktree .claude, not main)" {
    wt="$(make_worktree wtW)"
    : > "$wt/.claude/handoff-task.md"
    run bash -c '
        jq -nc --arg cwd "$1" \
            "{cwd:\$cwd, tool_name:\"Skill\", tool_input:{skill:\"handoff:handoff\"}}" \
        | bash scripts/skill-pre-hook.sh
    ' _ "$wt"
    [ "$status" -eq 0 ]
    [ ! -e "$wt/.claude/handoff-task.md" ]
    [ -e "$tmp/.claude/handoff-task.md" ]
}
```

Add under `# --- write-rename ---` (after the existing write-rename tests, around line 390):

```bash
@test "write-rename (worktree cwd: resolves worktree autorename)" {
    wt="$(make_worktree wtN)"
    echo "WT Title" > "$wt/.claude/autorename"
    run bash -c '
        jq -nc --arg cwd "$1" --arg fp "$1/.claude/autorename" \
            "{cwd:\$cwd, tool_name:\"Write\", tool_input:{file_path:\$fp}}" \
        | env -u TMUX -u TMUX_PANE bash scripts/write-rename.sh
    ' _ "$wt"
    [ "$status" -eq 0 ]
    [ ! -e "$wt/.claude/autorename" ]
    echo "$output" | jq -e '.systemMessage | test("/rename WT Title")' >/dev/null
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/hook-test.bats -f worktree`
Expected: both FAIL — skill-pre-hook wipes `$tmp`'s file (leaving `$wt`'s in place, opposite of the asserted state); write-rename anchors on `$tmp`, so `target != expected`, exits early without deleting `$wt/.claude/autorename` or emitting the `/rename` message.

- [ ] **Step 3: Apply the implementation changes**

In `scripts/_wipe-emit.sh`, update the usage comment on line 12 from:

```bash
# Usage: _wipe-emit.sh <cwd> <hook_event_name>
```

to:

```bash
# Usage: _wipe-emit.sh <session-cwd> <hook_event_name>
# <session-cwd> is the raw hook-input .cwd; the effective root (worktree
# root or CLAUDE_PROJECT_DIR) is derived here via handoff_root.
```

and replace line 18:

```bash
cwd="${1:?cwd required}"
```

with:

```bash
cwd="$(handoff_root "${1:-}")"
```

In `scripts/skill-pre-hook.sh`, replace lines 24-26:

```bash
cwd="${CLAUDE_PROJECT_DIR:-$PWD}"

exec bash "$(dirname "$0")/_wipe-emit.sh" "$cwd" "PreToolUse"
```

with:

```bash
exec bash "$(dirname "$0")/_wipe-emit.sh" "$(jq -r '.cwd // ""' <<<"$input")" "PreToolUse"
```

In `scripts/prompt-pre-hook.sh`, replace lines 18-20:

```bash
cwd="${CLAUDE_PROJECT_DIR:-$PWD}"

exec bash "$(dirname "$0")/_wipe-emit.sh" "$cwd" "UserPromptSubmit"
```

with:

```bash
exec bash "$(dirname "$0")/_wipe-emit.sh" "$(jq -r '.cwd // ""' <<<"$input")" "UserPromptSubmit"
```

In `scripts/write-rename.sh`, replace line 17:

```bash
cwd="${CLAUDE_PROJECT_DIR:-$(jq -r '.cwd // ""' <<<"$input")}"
```

with:

```bash
cwd="$(handoff_root "$(jq -r '.cwd // ""' <<<"$input")")"
```

(Leave the `[[ -n "$cwd" ]] || exit 0` guard on line 18; `handoff_root` always prints a non-empty root, so it is now a harmless belt-and-suspenders check.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/hook-test.bats`
Expected: all pass, including `skill-pre-hook (missing .claude: create)` whose payload omits `cwd` — `_wipe-emit.sh` now receives `""` (no `:?` abort) and `handoff_root("") → CLAUDE_PROJECT_DIR=$fresh`, so `$fresh/.claude` is created as before.

- [ ] **Step 5: Commit**

```bash
git add scripts/_wipe-emit.sh scripts/skill-pre-hook.sh scripts/prompt-pre-hook.sh scripts/write-rename.sh tests/hook-test.bats
git commit -m "fix: anchor wipe + rename hooks on the worktree root"
```

---

### Task 6: Documentation + full verification

**Files:**
- Modify: `CLAUDE.md`
- Modify: `DESIGN.md`
- (already created) `plans/2026-06-09-per-worktree-handoff-root-design.md`, `plans/2026-06-09-per-worktree-handoff-root-plan.md`

- [ ] **Step 1: Update `CLAUDE.md`**

In the `## Layout` section, add a bullet for the new module after the `scripts/extract.py` bullet:

```markdown
- `scripts/worktree_root.py` — pure resolver `worktree_root(cwd, project)`:
  walks up from the session cwd via on-disk `.git` linkage to the enclosing
  linked-worktree root, else returns `project`. Backs `_lib.sh`'s
  `handoff_root`; lets each worktree own its `.claude/`. Unit-tested in
  `tests/test_worktree_root.py` (pytest).
```

In the `scripts/_lib.sh` bullet, append a sentence documenting `handoff_root`:

```markdown
  Also defines `handoff_root()` — the effective handoff root for the session:
  `handoff_root "<.cwd>"` shells out to `worktree_root.py`, returning the
  enclosing worktree root or `CLAUDE_PROJECT_DIR`. Every cwd-scoped hook
  anchors on this rather than `CLAUDE_PROJECT_DIR` directly, so worktree
  sessions resolve to their own `.claude/`.
```

In the `## Conventions` section, replace the line:

```markdown
- All hooks are mechanical and cwd-scoped. Anything that requires
  judgement belongs in the skill, not a hook.
```

with:

```markdown
- All hooks are mechanical and cwd-scoped. They anchor on `handoff_root`
  (the enclosing git-worktree root, else `CLAUDE_PROJECT_DIR`) — never on the
  raw hook-input `.cwd` (drift-prone) nor on `CLAUDE_PROJECT_DIR` directly
  (pinned to the main tree in a worktree session). Anything that requires
  judgement belongs in the skill, not a hook.
```

- [ ] **Step 2: Update `DESIGN.md`**

Append a dated decision note (match the file's existing section style; place it at the end of the decisions/log section):

```markdown
## Per-worktree handoff root (2026-06-09)

Worktree sessions must own their own `.claude/handoff-task.md`. Hooks now
anchor on `handoff_root` — the enclosing linked-worktree root derived from
on-disk `.git` linkage (`scripts/worktree_root.py`, ported from the cwd-safety
plugin), falling back to `CLAUDE_PROJECT_DIR` outside a worktree. Rejected:
trusting the raw `.cwd` field (drifts with `cd`/`/add-dir`) and recording the
root via `WorktreeCreate`/`CwdChanged` hooks (observational, no clean
per-worktree storage, fragile vs. the stateless `.git` walk). Full rationale:
`plans/2026-06-09-per-worktree-handoff-root-design.md`.
```

- [ ] **Step 3: Run the full suite**

Run: `just hook-test`
Expected: bats — all hook + rename tests pass (0 failures).

Run: `just extract-test`
Expected: pytest — `test_worktree_root.py` (9) + existing `test_extract.py` all pass.

Run: `just precommit`
Expected: manifest/settings lint OK, `shellcheck -x scripts/*.sh tests/*.sh tests/*.bats` clean (the new `${BASH_SOURCE[0]}` wrapper and `make_worktree` helper lint clean), bats + pytest both green.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md DESIGN.md plans/2026-06-09-per-worktree-handoff-root-design.md plans/2026-06-09-per-worktree-handoff-root-plan.md
git commit -m "docs: document per-worktree handoff root"
```

(Release — version bump, tag, marketplace — is out of scope and user-driven via `just release`; `version-guard.sh` blocks agent edits to `plugin.json` version.)

---

## Self-Review

**Spec coverage:**
- `handoff_root` helper + algorithm → Task 1 (`worktree_root.py`) + Task 2 (wrapper). ✓
- Call sites write-guard/read-guard → Task 3; write-stage/load-handoff → Task 4; `_wipe-emit` + skill/prompt pre-hooks + write-rename → Task 5. ✓ (all seven sites from the spec covered)
- Round-trip coherence → Task 4 round-trip tests (stage→worktree, load→worktree). ✓
- Test plan: pytest branch matrix → Task 1; bats glue/worktree/regression → Tasks 2-5; `just hook-test`/`extract-test`/`precommit` → Task 6. ✓
- `HANDOFF_REL_*` unchanged, no breaking change → no task touches the constants. ✓
- Non-goals (no new hook events, no recorded state) → honored; nothing in the plan adds them. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full content; every run step states the exact command and expected output. ✓

**Type/name consistency:** `worktree_root(cwd, project)` (module) and `handoff_root "<cwd>"` (wrapper) names are used identically across Tasks 1-5. The replacement string `cwd="$(handoff_root "$(jq -r '.cwd // ""' <<<"$input")")"` is byte-identical across write-guard, read-guard, write-stage, load-handoff. `make_worktree` signature and usage match across all bats tests. ✓
