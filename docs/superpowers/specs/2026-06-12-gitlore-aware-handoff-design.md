# gitlore-aware handoff — design

**Date:** 2026-06-12
**Status:** approved, pending implementation plan

## Goal

Make `/handoff:handoff` proactively commit gitlore-managed memory at
wrap-up. handoff already updates memory (Step 1); in a gitlore repo
those writes leave the memory submodule dirty and uncommitted until the
next ambient parent commit. handoff is the natural human-in-the-loop
moment to land them: it summarizes the pending memory changes, gets the
user's approval, and commits via gitlore's blessed entry point.

This depends on a gitlore prerequisite that is **already shipped**:
`commit-memory.sh` (D16), a standalone arg-driven entry point that
commits the memory submodule and advances local `live` without a parent
commit, discoverable via `git config gitlore.commitCommand`.

## Prerequisite contract (gitlore, shipped — do not modify)

`commit-memory.sh`:

- **Discover:** `git config gitlore.commitCommand` → absolute path,
  re-pinned every `SessionStart` (self-healing across plugin-cache path
  changes) and seeded at install. One lookup; no coupling to gitlore's
  internal layout.
- **Activate:** presence of the `gitlore-memory` submodule in
  `.gitmodules` (FR12) — *not* the key. The key only answers *where* the
  script is.
- **Invoke:** `commit-memory.sh -m "<summary>"` or `-F -` (stdin).
  Dirty memory + summary → writes the summary to the commit-msg file
  (satisfies the freshness gate by construction) → advances `live`.
  Graceful `exit 0` on clean / no-submodule / no-worktree; `exit 1` on
  dirty-without-summary.
- Runs without `CLAUDE_PLUGIN_ROOT`: its `PLUGIN_ROOT` falls back to
  `git config gitlore.hooksDir`, so an agent can invoke it directly from
  the Bash tool by absolute path.

handoff never touches the sentinel, `push HEAD:live`, or merge-state —
it resolves the key and calls.

## Settled mechanics (verified by test, not assumption)

- `CLAUDE_PLUGIN_ROOT` is **unset** in the agent's Bash tool
  environment (verified: `env` dump). Only hook processes get it.
- Claude Code adds **every installed plugin's `<root>/bin` to PATH**
  automatically — no `bin` key in `plugin.json` required (verified: the
  cache plugin bins appear on PATH). This holds from the cache path, so
  it works for end-users, not just a dev checkout.
- A `bin/` executable **resolves by bare name** from a fresh agent Bash
  call (verified: a throwaway `bin/handoff-probe-test` ran by name).

These facts make a skill body able to invoke its own bundled script via
a uniquely-named `bin/` executable — **no hook required**.

## Architecture

Four-part split (factor-4/8/7/10 of "12-factor agents"; matches the
plugin's own "harness over agent" rule):

1. **detect** — deterministic script (no agent judgement)
2. **summarize** — agent (natural-language work)
3. **approve** — human-in-the-loop
4. **commit** — deterministic script (gitlore's, unchanged)

The agent carries **no conditional**. It runs the probe unconditionally
and follows whatever the probe prints. The dirty-or-not branch lives in
deterministic code.

### Components

**1. `bin/handoff-memory-probe`** — thin PATH entry. Self-locates via
`dirname "$0"` and execs `scripts/memory-probe.sh`. Logic stays in
`scripts/` (testable as the other scripts are); `bin/` is only the
PATH-exposed shim.

**2. `scripts/memory-probe.sh`** — read-only detector. Owns the whole
conditional and emits the agent's next action on stdout:

- `script=$(git config gitlore.commitCommand)` — empty / not executable
  → emit a no-op line. Present-but-not-executable (stale plugin-cache
  path mid-session) adds a "restart your session to re-pin" hint.
- `root=$(git rev-parse --show-toplevel)`;
  `mempath=$(git config --file "$root/.gitmodules" submodule.gitlore-memory.path)`
  — unset → no-op (not gitlore-managed). This is the FR12 public gate;
  `gitlore-memory` is gitlore's stable submodule name.
- `"$root/$mempath/.git"` absent → no-op (submodule not materialized).
- `git -C "$root/$mempath" status --porcelain` empty → no-op (clean).
- **Dirty** → emit the directive: the changed-file list
  (`status --porcelain`, plus a diffstat) followed by an imperative
  instruction — *"Draft a 1–3 sentence summary of these memory changes.
  Present it to the user for approval (they may edit it). On approval,
  commit by piping the approved summary to `<resolved-abs-path> -F -`."*
  The resolved absolute `commit-memory.sh` path is inlined so the agent
  runs an absolute path (no `CLAUDE_PLUGIN_ROOT` needed).

Couples only to two public gitlore contracts: the `gitlore.commitCommand`
key and the `gitlore-memory` submodule registration. No reach into
gitlore internals. (Contrast `[[feedback_hook_deny_wording]]`: actionable
phrasing is *correct* here — this is a directive the agent must follow,
the inverse of a deny message.)

**3. `skills/handoff/SKILL.md`** — flow change:

- Step 1 (Update memory) — unchanged. Memory is written first, so the
  probe sees Step 1's changes.
- Step 2 (the three-parallel batch) — in the **same turn**: `Write
  autorename`, `Write handoff-task.md` (only if active task), and
  `Bash: handoff-memory-probe`. Then a single instruction: *"follow the
  instructions the probe returns."* No `if dirty` in the skill prose;
  the script decides. The probe is read-only and independent of the two
  writes, so batching is safe.
- The heredoc alternative is rejected: heredoc'd writes would bypass the
  `write-stage.sh` and `write-rename.sh` PostToolUse hooks.

**4. The commit** — agent runs the absolute `commit-memory.sh -F -` the
probe inlined, piping the approved summary on stdin.

**5. Approval interaction** — prose, not a modal. The agent presents the
drafted summary; the user can approve **or redline it** before commit (a
modal can't be hand-edited). Per `[[feedback_prose_over_modals_design]]`.

**6. Non-tmux rename fix** (parked decision #2) — `write-rename.sh` lines
32–36 currently emit only `systemMessage` (user-facing, unseen by the
agent — the dead relay). Add `additionalContext` (agent-facing)
instructing the agent to present the `/rename <title>` line in a fenced
block. Remove the now-redundant SKILL.md lines 63–64. The hook becomes
self-sufficient (`[[feedback_hook_agent_feedback]]`).

## Why gitlore's `commit-memory.sh` stays in `scripts/` (not `bin/`)

Considered moving it to gitlore's `bin/` for bare-name invocation;
rejected. The two scripts have different invocation constraints:

- handoff's probe is the **first** thing the agent runs from the skill
  body — no prior step resolves its path, so it needs a PATH-resolvable
  bare name (`bin/`). Intra-plugin call; no layout-coupling concern.
- `commit-memory.sh` is called **after** the probe already resolved its
  absolute path. Bare-name would add nothing.

And the discovery key is strictly more robust than a PATH bin for a
cross-plugin callee: self-healing per-`SessionStart`; no name-collision
or PATH-presence dependency; no coupling to gitlore's layout (the abstraction
D16 was built to provide). Moving it would reopen a shipped, 204-green
feature and widen `commit-memory`'s surface to the user's interactive
shell. So: `bin/` is handoff's answer to its own entry-point problem;
gitlore's config key is the better answer to cross-plugin discovery.

## Flow (end to end)

1. Step 1: agent writes memory files → memory submodule now dirty.
2. Step 2 (one turn): `Write autorename` + `Write handoff-task.md` +
   `Bash: handoff-memory-probe`.
3. Probe prints either a no-op line or the dirty directive (with the
   changed-file list and the inlined absolute commit command).
4. If a directive: agent drafts a 1–3 sentence summary, presents it,
   user approves/edits.
5. Agent runs `<abs>/commit-memory.sh -F -` with the approved summary on
   stdin → memory committed, local `live` advanced.

## Testing

- `tests/memory-probe.bats` (new): dirty → directive; clean → no-op;
  not-gitlore (no submodule) → no-op; key present-but-not-executable →
  no-op + restart hint; submodule registered but not materialized →
  no-op. Drives `scripts/memory-probe.sh` against synthetic git state,
  mirroring the existing bats fixtures.
- Extend the rename tests: assert the non-tmux `write-rename.sh` path
  emits `additionalContext` carrying the `/rename` line.
- `bin/handoff-memory-probe` is covered by exercising the probe through
  it (bare-name shim → `scripts/memory-probe.sh`).

## Release

Feature + new `bin/` entry; no change to the output path
(`.claude/handoff-task.md`) or the session pointer, so not a breaking
change. Minor version bump via the `release` recipe (which also bumps
the marketplace entry).

## Non-goals

- Modifying gitlore. The prerequisite is shipped; handoff consumes it.
- Committing memory outside a gitlore repo, or auto-committing without
  approval. Approval is mandatory (gitlore's freshness gate + the user's
  redline opportunity).
- Touching `handoff-task.md` / `autorename` staging. Those remain
  parent-repo tree-local files via `write-stage.sh` / `write-rename.sh`;
  the memory submodule commit is independent.
