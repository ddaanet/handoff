## Bug: handoff files forced to main repo, not the active worktree

2026-06-08

### Symptom

In a git worktree session (entered via `EnterWorktree`, cwd = the worktree
root), the handoff skill's write of `.claude/handoff-task.md` is **blocked**
and the guard demands the **main** project's `.claude/` instead:

```
write blocked: handoff-task.md outside this project's .claude/.
resolved: /repo/.claude/worktrees/verify-loop/.claude/handoff-task.md;
expected: /repo/.claude/handoff-task.md.
```

This defeats per-worktree handoff isolation. Parallel worktrees should each own
their handoff in their own `.claude/`; instead they collide on the main repo's
single `.claude/handoff-task.md`.

### Root cause

Every handoff hook anchors its expected path on `CLAUDE_PROJECT_DIR`, which
stays pinned to the main project root even when the session cwd is a worktree.
`EnterWorktree` changes the working directory but not `CLAUDE_PROJECT_DIR`.

`scripts/write-guard.sh:18`:
```bash
cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
```
then compares the write target against `$cwd/.claude/handoff-task.md`. With
`CLAUDE_PROJECT_DIR=/repo`, a legitimate worktree write to
`/repo/.claude/worktrees/<wt>/.claude/handoff-task.md` fails the match and is
denied.

The hook already receives the correct directory: the PreToolUse JSON input has
a `.cwd` field = the session's actual working directory (the worktree root).
The scripts ignore it in favor of the env var.

### All affected sites (fix must be consistent across the round-trip)

A partial fix splits write/stage/wipe/load across two `.claude/` dirs and
breaks the handoff round-trip. Every hook uses the same wrong idiom:

- `scripts/write-guard.sh:18` — PreToolUse(Write|Edit), the blocker above.
- `scripts/write-stage.sh:17` — PostToolUse; stages the file + writes the
  session pointer. Would stage into the wrong repo / wrong `.claude/`.
- `scripts/load-handoff.sh:18` — SessionStart; reads task + pointer back.
  Must read from the same worktree `.claude/` the write went to.
- `scripts/read-guard.sh:20` — PreToolUse(Read) guard.
- `scripts/_wipe-emit.sh:18` — takes `cwd` as `$1`; check what the two
  callers pass:
  - `scripts/skill-pre-hook.sh:24` — `${CLAUDE_PROJECT_DIR:-$PWD}`
  - `scripts/prompt-pre-hook.sh:18` — `${CLAUDE_PROJECT_DIR:-$PWD}`
- `scripts/write-rename.sh:17` — already prefers `CLAUDE_PROJECT_DIR` but
  *falls back* to `.cwd` from the JSON input — i.e. it has the right value
  available and demotes it. `autorename` writes to the worktree's `.claude/`
  succeeded in practice precisely because of this fallback ordering being
  more forgiving; make rename consistent with the chosen fix.

### Suggested direction (user to confirm)

Anchor on the session's working directory from the hook-input `.cwd` field
rather than `CLAUDE_PROJECT_DIR`, so each worktree resolves to its own
`.claude/`. Two options for the implementer to weigh:

1. **Minimal:** read `.cwd` from the hook JSON (already parsed in most
   scripts) and use it as the root. Relies on cwd being the worktree root —
   which the sibling `cwd-safety` plugin enforces (it blocks cwd drift), so
   in practice `.cwd` is the worktree root, not a subdir.
2. **Robust:** detect the enclosing worktree root from the on-disk `.git`
   linkage (walk up; a worktree's `.git` is a *file* whose `gitdir:` resolves
   under `<project>/.git`), identical to the logic already shipped in the
   `cwd-safety` plugin's `_worktree_root()` (`~/code/cwd-safety/scripts/
   cwd-safety.py`). Falls back to `CLAUDE_PROJECT_DIR` when not in a worktree.

Note: `SessionStart` may not pass a usable cwd the same way PreToolUse does —
verify the `.cwd` field is present in the SessionStart payload, else
`load-handoff.sh` needs the on-disk detection (option 2).

### NOT a cwd-safety bug

The report that lumped "cwd-safety and handoff" — the redirect is entirely the
**handoff** plugin's write-guard. The `cwd-safety` plugin only guards Bash
(cwd-drift) and is already worktree-aware and correct; it is a *reference
implementation* for option 2, not a culprit.

### Constraints / testing (from CLAUDE.md)

- Hooks must stay mechanical and cwd-scoped; `python3` + `jq` available.
- Changing `HANDOFF_REL_*` constants is a breaking change; this fix does
  **not** change them — only the root they are joined to.
- Add scenarios to existing `tests/*.bats` (hook payloads with a worktree
  `.cwd`) and run `just precommit` / `just hook-test`. A regression test
  should assert a worktree-rooted `.cwd` is accepted and resolves to the
  worktree `.claude/`, and that a genuine cross-project write is still denied.

### Repro

1. From a repo with the handoff plugin active, `EnterWorktree`.
2. Run `/handoff:handoff`; let it write `.claude/handoff-task.md`.
3. Observe the deny with `expected:` pointing at the main repo's `.claude/`.
