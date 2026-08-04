## Current task

`plans/2026-08-01-shared-claude-import-brief.md` is applied and filed under
`plans/`: this repo's `CLAUDE.md` now ends with
`@memory/ddaanet/shared-claude.md`, and the two rules the shared file already
states were dropped from it. The import resolves on disk but has not been
observed loading — only a fresh session's `claudeMd` block proves that.

The transition state machine landed whole: the state field, the arm-only guard
holding the agent's channel to `armed`, and its docs and test coverage. Pass 2,
transitions-become-modes, is next and its spec is still unapproved.

A root-pointer defect is open and unexplained. A session's own
`/tmp/claude/handoff-root-<session id>` was found naming a different repo than
every other signal for that session — the frame it had been injected was this
repo's, and no drift marker existed for its id — with an mtime later than that
injection. The checkpoint refused on it, correctly, and it was corrected by
hand. Several concurrent sessions were rooted in the other repo at the time,
and one of them drifted into this one minutes later.

## Open decisions

- What overwrote that root pointer. A second `SessionStart` for one session id,
  a cross-write between concurrent sessions, and an id collision all fit the
  timestamps; nothing yet distinguishes them. Whatever it is, the failure is
  silent until a checkpoint call refuses, and it would have sent this repo's
  task file into the other had the guard not held.
- Whether to route `autoname` through `handoff-checkpoint`, making the
  checkpoint the sole writer of the sentinel and collapsing `write-drive.sh`
  into a `write-guard.sh` deny. Recorded as a deliberate third pass in the
  state-machine spec's rejected alternatives, not refused.
- Whether to cut a release now, and at what bump. The context-size threshold is
  a minor — a new hook entry point, no change to either boundary file's shape —
  and the state machine rides as a patch, since nothing user-visible changed
  shape and `.claude/autodrive` is transient and gitignored. Pass 2 removes two
  user-visible skill names and needs its own answer. `just release` pushes, cuts
  a GH release and bumps the marketplace, so it has been left for an explicit
  yes.
- Whether the main session transcript ever carries a subagent's `usage` entry.
  It should not — subagent usage lives in
  `<session-dir>/subagents/agent-<agent_id>.jsonl` — but if it does the
  measurement reads high, and the fix is a `select(.isSidechain != true)` in the
  `jq` filter.
- Whether the pointer sweep's guard-rail deserves a `handoff-`-prefixed foreign
  file. Its fixture uses `somebody-elses-file`, so it catches a filter widened
  to everything but not one widened to any name this plugin might publish.