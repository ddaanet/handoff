## Current task

Two design specs await review, to land in this order: the transition state
machine (pass 1, no behaviour change) then transitions-become-modes (pass 2).
Pass 1 collapses the `autodrive` / `autodrive.pending` / proposed `.held`
filename family into one file carrying its state on line 1. Pass 2 deletes
`handoff-continue` and `compact-continue`, turning them into `clear`/`compact`
and `continue` payload fields, and adds a `handoff-approved` command that arms
a sentinel held back by gitlore's approval gate. Neither spec is approved; the
next step after approval is the implementation plan for pass 1.

The context-size threshold trigger fired live for the first time this session,
at 150k. The agent finished the step it was on and handed back rather than
compacting, which the user confirmed is the intended reading of a nudge — one
data point, not enough to reopen the halt question.

## Open decisions

- Whether to route `autoname` through `handoff-checkpoint`, making the
  checkpoint the sole writer of the sentinel and collapsing `write-drive.sh`
  into a `write-guard.sh` deny. Recorded as a deliberate third pass in the
  state-machine spec's rejected alternatives, not refused.
- The version bump for pass 2, which removes two user-visible skill names.
- Whether to cut the context-threshold release now — a minor bump: a new hook
  entry point, no change to either boundary file's shape. `just release`
  pushes, cuts a GH release and bumps the marketplace, so it has been left for
  an explicit yes.
- Whether `systemMessage` honours ANSI at all — the drift report's leading
  reset either renders or shows as literal bytes. Its companion assumption,
  that a hook payload's `session_id` matches `CLAUDE_CODE_SESSION_ID`, is
  settled by any `handoff-checkpoint` run that does not refuse on the pointer.
- Whether the main session transcript ever carries a subagent's `usage` entry.
  It should not — subagent usage lives in
  `<session-dir>/subagents/agent-<agent_id>.jsonl` — but if it does the
  measurement reads high, and the fix is a `select(.isSidechain != true)` in
  the `jq` filter.
- Whether the pointer sweep's guard-rail deserves a `handoff-`-prefixed foreign
  file. Its fixture uses `somebody-elses-file`, so it catches a filter widened
  to everything but not one widened to any name this plugin might publish.