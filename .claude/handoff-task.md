## Current task

The transition state machine's spec is approved and its implementation plan is
written at `plans/2026-08-03-transition-state-machine-plan.md`, unexecuted. Three
tasks: the state field (one commit — the file format changes, so the parser and
all six readers/writers move together, and any intermediate state leaves the
suite red), an arm-only guard on the agent's channel that goes beyond the spec,
and docs. Pass 2, transitions-become-modes, follows it and its spec is still
unapproved.

Writing the plan turned up three things the spec did not anticipate, all handled
in it: the `empty file` and old-autorename rows now fail on the state line rather
than the kind, so their assertions change; `report-watcher-failure (stale
autodrive leaves .pending alone)` seeds both files at once and is deleted, since
the collapse makes that state unrepresentable; and the sweep now parses the file,
so a malformed sentinel needs an explicit disposition — it is swept, preserving
what the bare-filename gate did.

This session's own root pointer, `/tmp/claude/handoff-root-<session id>`, was
found naming `/Users/david/code/gitlore` while every other signal named this
repo — the frame injected at 16:07:14 came from this repo's task file, no drift
marker was written for this session id, and the pointer's mtime (16:08:54) is
later than that injection. The checkpoint refused on it, correctly. The pointer
was corrected by hand to let the wrap-up proceed. Several concurrent sessions are
rooted in gitlore and one of them, 7177c50f, drifted into this repo at 16:14.

## Open decisions

- What overwrote this session's pointer. A second `SessionStart` for one session
  id, a cross-write between concurrent sessions, and an id collision all fit the
  timestamps; nothing yet distinguishes them. Whatever it is, the failure is
  silent until a checkpoint call refuses, and it would have sent this repo's task
  file into gitlore had the guard not held.
- Whether to take Task 2 of the plan, which is beyond the spec. Collapsing the
  filename family turns a wrong state from unrepresentable into a content error,
  and an agent-written `pending` is inert on every gate — Stop ignores it, no
  loader owns its kind, the sweep exempts it. Two lines in `write-drive.sh` hold
  the agent's channel to `armed`. Rejecting it breaks nothing.
- Whether to route `autoname` through `handoff-checkpoint`, making the checkpoint
  the sole writer of the sentinel and collapsing `write-drive.sh` into a
  `write-guard.sh` deny. Recorded as a deliberate third pass in the state-machine
  spec's rejected alternatives, not refused.
- The version bump for pass 2, which removes two user-visible skill names. Pass 1
  is a patch: nothing user-visible changes shape and `.claude/autodrive` is
  transient and gitignored, so it can ride with the context-threshold release.
- Whether to cut the context-threshold release now — a minor bump: a new hook
  entry point, no change to either boundary file's shape. `just release` pushes,
  cuts a GH release and bumps the marketplace, so it has been left for an
  explicit yes.
- Whether the main session transcript ever carries a subagent's `usage` entry. It
  should not — subagent usage lives in
  `<session-dir>/subagents/agent-<agent_id>.jsonl` — but if it does the
  measurement reads high, and the fix is a `select(.isSidechain != true)` in the
  `jq` filter.
- Whether the pointer sweep's guard-rail deserves a `handoff-`-prefixed foreign
  file. Its fixture uses `somebody-elses-file`, so it catches a filter widened to
  everything but not one widened to any name this plugin might publish.