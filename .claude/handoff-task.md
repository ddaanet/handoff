## Current task

The session-root drift work is implemented and green — `just precommit` passes
(199 bats + 11 pytest) — and **uncommitted**. The whole diff sits in the working
tree; `scripts/session-pointer.sh` and
`docs/changelog/2026-07-31-session-root-drift.md` are untracked. What is left
before it ships, in order:

- `write-guard.sh`'s rc 2 wording under drift. A legitimate agent edit to the
  cwd repo's `handoff-todo.md` resolves outside `$root/.claude/` and is denied
  as cross-project with no mention of the drift that caused it. Decide whether
  the drift report rides there.
- The lifecycle of `/tmp/claude/handoff-root-<session_id>` and
  `/tmp/claude/handoff-drift-<session_id>`. Nothing removes either, and
  `/tmp/claude` is not swept — it holds hand-made files weeks old.
- Then `just release`, which owns the version bump (`version-guard.sh` denies
  agent edits to `plugin.json`'s `.version`). Name both `handoff` and
  `claude-plugins` up front so the marketplace push is authorised too.

## Open decisions

- `SessionStart` hooks are frozen at session start, so `session-pointer.sh` has
  never actually run. `checkpoint.sh` is read from disk per call, so its refusal
  *is* live: what keeps the wrap-up working here is a pointer written by hand at
  `/tmp/claude/handoff-root-dd4de2fc-3e91-44e8-9577-2c48fdb31b48`. A compaction
  keeps the session id so it survives; only a restart exercises the hook.
- Two assumptions the design records as unverified. That a hook payload's
  `session_id` carries the same id as `CLAUDE_CODE_SESSION_ID` — half-settled,
  since the variable matches the id in this session's scratchpad path, but the
  payload half needs the hook to have run. And that `systemMessage` honours
  ANSI at all: if it does not, a literal `ESC[0m` heads the drift line and the
  `--arg lead` in `report-watcher-failure.sh` comes back out.
- `memory/MEMORY.md` is now at 98% of the 25600-byte loader budget — a
  `${n:-default}` fact went into `ddaanet/reference_bats_shellcheck_gotchas`
  this session. Merging is exhausted; retiring facts outright is the only lever
  left, and which ones is the user's call.