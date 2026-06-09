# Design: per-worktree handoff root

2026-06-09

Fixes the bug in [`bug-worktree-handoff-location.md`](bug-worktree-handoff-location.md):
in a git-worktree session the handoff hooks anchor on `CLAUDE_PROJECT_DIR`
(pinned to the main tree), so a legitimate worktree write to
`<wt>/.claude/handoff-task.md` is denied and the round-trip collides on the
main repo's single `.claude/`.

## Decision

Anchor every handoff hook on an **effective project root** derived from the
session cwd by walking the on-disk `.git` linkage — not on `CLAUDE_PROJECT_DIR`
directly, and not on the raw `.cwd` field.

Rejected alternatives:

- **Minimal — use `.cwd` as the root directly.** Regresses the documented
  decision behind `feedback_claude_project_dir`: `.cwd` is the live working
  directory (`cwd: E.string()` on the hook base schema) and drifts with shell
  `cd` and `/add-dir`. A drifted cwd would resolve `.claude/handoff-task.md`
  into a wrong nested directory — reintroducing the class of bug the original
  `CLAUDE_PROJECT_DIR` switch killed.
- **Record/reset the worktree root via `WorktreeCreate`/`WorktreeRemove` /
  `CwdChanged` hooks.** These events exist (verified in the CC 2.1.168 bundle)
  but are the wrong tool: `CwdChanged` is observational (honors only
  `watchPaths` + `systemMessage`, no `additionalContext`, no block; dispatched
  async fire-and-forget with swallowed errors), `new_cwd` is still just cwd
  (drift-prone, gives nothing the `.git` walk doesn't), and a per-worktree
  record has no clean storage home — the main tree is shared across worktrees
  (the very collision being fixed), and a session that *attaches* to an
  existing worktree never saw its create event. This trades a stateless
  idempotent computation for fragile event-ordering-dependent cached state,
  against the plugin's stateless-derivation philosophy (cf. `handoff_activated`).

The chosen approach is a direct port of the sibling `cwd-safety` plugin's
`_worktree_root` (already shipped + tested) plus a `→ CLAUDE_PROJECT_DIR`
fallback.

## Algorithm

The root-resolution logic is **branch-heavy** (worktree subdir, main-tree
subdir, `.git`-directory, gitdir-outside-project, relative-gitdir resolution,
filesystem root), so it lives as a python module tested with pytest — the same
side of the glue/logic line as `extract.py`, not an `_lib.sh` heredoc like the
thin `handoff_resolve`.

- `scripts/worktree_root.py` — `def worktree_root(cwd: str, project: str) -> str`
  (pure; the algorithm below) plus a `__main__` CLI contract
  (`worktree_root.py <cwd> <project>` → prints the resolved root) so bash can
  call it. Direct port of `cwd-safety`'s `_worktree_root` + the
  `→ project` fallback.
- `scripts/_lib.sh` — `handoff_root` is a one-line wrapper, same pattern as
  `load-handoff.sh` shelling out to `extract.py`:

  ```bash
  handoff_root() {
      python3 "$(dirname "${BASH_SOURCE[0]}")/worktree_root.py" \
          "${1:-}" "${CLAUDE_PROJECT_DIR:-$PWD}"
  }
  ```

```
worktree_root(cwd, project):
    d = cwd
    loop:
        if d == project:            return project   # main worktree, not linked
        dotgit = d/.git
        if dotgit is a FILE:                          # linked-worktree marker
            gitdir = parse "gitdir: <path>" from it   # relative → resolve vs dirname(dotgit)
            return d        if gitdir resolves UNDER project/.git
            return project  otherwise
        if dotgit is a DIRECTORY:   return project   # nested standalone repo
        parent = dirname(d)
        if parent == d:             return project   # filesystem root
        d = parent
```

One extra `python3` spawn per hook — already the norm (`write-guard.sh` spawns
separately for `handoff_resolve` and `handoff_activated`; hooks are not a hot
path). Not folded into `handoff_resolve`'s subprocess: unrelated concerns.

Properties:

- **Drift-proof.** `cwd` is only a starting point to walk *up* from; the
  `.git`-file linkage check pins the actual root. A cwd drifted into a worktree
  subdir still resolves up to the worktree root; a cwd drifted in the main tree
  resolves to `CLAUDE_PROJECT_DIR`.
- **Stateless / idempotent.** Pure function of cwd + filesystem; nothing
  recorded, nothing to reset, no staleness.
- **Outside-worktree = byte-identical to today** (`CLAUDE_PROJECT_DIR`), so
  existing behavior and tests are unaffected.
- The empty-cwd case needs no special branch: `cwd` is required on every hook
  payload, and were it ever `""`, `dirname("") == ""` trips the
  filesystem-root branch → `project`.

## Call-site changes

Every hook replaces `cwd="${CLAUDE_PROJECT_DIR:-$PWD}"` with the effective
root, keeping the variable named `cwd` so nothing downstream churns:

```bash
cwd="$(handoff_root "$(jq -r '.cwd // ""' <<<"$input")")"
```

Sites that source `_lib.sh` and call `handoff_root` directly:

- `scripts/write-guard.sh` — the blocker; resolves expected path against the
  effective root.
- `scripts/write-stage.sh` — stages + writes the session pointer into the
  effective root; `git -C "$root" add -f` (per-worktree index, correct).
- `scripts/read-guard.sh` — gates this project's `handoff-task.md` read.
- `scripts/load-handoff.sh` — SessionStart; reads task + pointer from the
  effective root. SessionStart carries `cwd` (same base schema), so no
  special-casing; the fallback path is `CLAUDE_PROJECT_DIR` = today's behavior.

Wipe path — push the computation into `_wipe-emit.sh` (already sources
`_lib.sh`) so the two filter scripts stay thin:

- `scripts/_wipe-emit.sh` — `$1` becomes the **raw session cwd**; it calls
  `handoff_root "$1"` internally to derive the root it wipes. (Contract change
  in the comment header.)
- `scripts/skill-pre-hook.sh` / `scripts/prompt-pre-hook.sh` — pass
  `$(jq -r '.cwd // ""' <<<"$input")` instead of `${CLAUDE_PROJECT_DIR:-$PWD}`.
  No `_lib.sh` sourcing added.

Consistency:

- `scripts/write-rename.sh` — already prefers `.cwd` on fallback; route it
  through `handoff_root` so `autorename` resolves to the same effective root as
  the rest of the round-trip.

`HANDOFF_REL_*` constants are unchanged — this fix only changes the root they
are joined to, so it is **not** a breaking change.

## Round-trip coherence

Write and read both derive the root from the same `.cwd` via the same helper,
so a worktree session writes and reads its own `.claude/`. A partial fix that
updated only some sites would split the round-trip across two `.claude/` dirs;
the test plan guards against that by exercising write → stage → load in a
worktree.

## Test plan

Logic coverage in pytest; glue/round-trip coverage in bats — mirroring the
`extract.py` (pytest) / hooks (bats) split.

**`tests/test_worktree_root.py`** — imports `worktree_root` directly
(a new file adds no just recipe; pytest auto-discovers `test_*.py`). Uses
`tmp_path` to scaffold a fake linked worktree: a directory whose `.git` is a
*file* containing `gitdir: <project>/.git/worktrees/<wt>`, with the matching
`<project>/.git/worktrees/<wt>/` present. Parametrized branch matrix:

- worktree subdir → worktree root
- main-tree subdir → `project`
- `cwd == project` → `project`
- `.git` is a *directory* (nested standalone repo) → `project`
- gitdir resolving *outside* `project/.git` → `project`
- relative `gitdir:` resolved against `dirname(.git-file)`
- filesystem-root termination → `project`

**`tests/hook-test.bats`** — the glue, not the branch matrix:

- **write-guard**: a worktree-rooted `.cwd` write to the worktree's
  `.claude/handoff-task.md` is **accepted**; a genuine cross-project write is
  **still denied**.
- **Regression**: a non-worktree cwd still resolves to `CLAUDE_PROJECT_DIR`
  (existing accepted/denied cases keep passing).
- Round-trip smoke: write (write-guard allow) → stage (write-stage targets the
  worktree) → load (load-handoff reads the worktree) all agree on one
  `.claude/`.

Run `just hook-test`, `just extract-test` (pytest), and `just precommit`.

## Non-goals

- No change to `HANDOFF_REL_*` constants or the output-path contract.
- No new hook events (`WorktreeCreate`/`CwdChanged` etc.) — rejected above.
- No recorded/cached worktree state.
