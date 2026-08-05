## Current task

Pass 2 of the transition state machine — transitions become modes — is approved
and next to implement, per `plans/2026-08-02-transition-modes-design.md`. It
deletes `handoff-continue` and `compact-continue`, collapses `skill` to two
values, adds two required payload fields (`clear`/`compact`, `continue`), moves
sentinel composition into the checkpoint, and adds a `held` state plus
`bin/handoff-approved` to leave it.

Three corrections landed on that spec and are part of what to implement.
Commit-awareness now keys on **whether the ask this call serves implies a
commit**, not on whether a commit will land later — the old rule was
unanswerable in the prepare-only modes and forced a guess. It is uniform across
`clear` and `compact`: the carve-out that a compaction keeps the session alive,
so a commit named in its continuation prompt would in fact have a live
pre-commit hook, is recorded as declined rather than unnoticed. And
`handoff-approved` is a single executable at `bin/handoff-approved`, not a shim
over `scripts/approved.sh`.

The shipped bodies still carry the retired clause — `skills/handoff/SKILL.md`
step 1, its `precompact` twin, and the superseded paragraph in
`docs/changelog/2026-07-25-commit-awareness.md`. That was a deliberate choice to
ride with pass 2, not an oversight.

Behind pass 2: `plans/2026-08-05-checkpoint-root-via-updatedinput.md`, unstarted.

## Open decisions

- Whether to cut a release, and at what bump. Pass 2 removes two user-visible
  skill names, so it is the question the earlier minor/patch answer did not
  cover. The context-size threshold is a minor; the state machine rides as a
  patch. `just release` pushes, cuts a GH release and bumps the marketplace, so
  it waits for an explicit yes.
- Whether to route `autoname` through `handoff-checkpoint`, making the
  checkpoint the sole writer of the sentinel and collapsing `write-drive.sh`
  into a `write-guard.sh` deny. Recorded as a deliberate third pass in the
  state-machine spec's rejected alternatives, not refused.
- Whether the main session transcript ever carries a subagent's `usage` entry.
  It should not — subagent usage lives in
  `<session-dir>/subagents/agent-<agent_id>.jsonl` — but if it does the
  measurement reads high, and the fix is a `select(.isSidechain != true)` in the
  `jq` filter.
- Whether the pointer sweep's guard-rail deserves a `handoff-`-prefixed foreign
  file. Its fixture uses `somebody-elses-file`, so it catches a filter widened
  to everything but not one widened to any name this plugin might publish.