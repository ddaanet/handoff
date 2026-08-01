## Current task

The context-size threshold trigger is implemented, end to end. A
`PostToolBatch` hook takes the newest `usage` sample from the transcript tail
and, past 150k tokens, injects one directive naming `/handoff:compact-continue`
— a nudge, never a halt, fired once per climb and re-armed by the next
`SessionStart` rather than by a measurement falling back under. Subagent
batches exit before reading anything. Design, plan, and all three
implementation tasks are done, docs included.

What remains is the release (minor bump: new hook entry point, no change to
either boundary file's shape) and then the dogfood, which this session cannot
do — `hooks.json` freezes at session start, so the entry takes effect only
after an exit and a fresh `claude`.

Tasks 1 and 2 ran subagent-driven and both reports were verified at their
source rather than accepted: the marker-gate mutation was re-run here and the
restored script confirmed byte-identical to its commit.

## Open decisions

- Whether to cut the release now. Everything it would carry is committed and
  the gate is green; `just release` pushes, cuts a GH release, and bumps the
  marketplace, so it has been left for an explicit yes.
- The root memory index is 25.7KB against a 24.4KB loader cap, so the tail is
  already invisible and **any addition is rejected outright**. Merging is
  exhausted and stripping triggers is ruled out by
  `ddaanet/feedback_index_compaction_triggers`, so retiring facts is the only
  lever left. Which ones is still not decided.
- Two assumptions the drift design recorded as unverified are still unverified,
  because `SessionStart` hooks freeze at session start and `session-pointer.sh`
  has therefore never run: that a hook payload's `session_id` matches
  `CLAUDE_CODE_SESSION_ID`, and that `systemMessage` honours ANSI at all. The
  first session after a restart settles both — check that
  `/tmp/claude/handoff-root-<session_id>` appears without being hand-written,
  and whether the drift line's leading reset renders or shows as literal bytes.
  The threshold trigger's own `systemMessage` inherits the same question.
- Whether the main session transcript ever carries a subagent's `usage` entry.
  It should not — subagent usage lives in
  `<session-dir>/subagents/agent-<agent_id>.jsonl` — but if it does the
  measurement reads high, and the fix is a `select(.isSidechain != true)` in
  the `jq` filter. Settled at the first dogfood.
- Whether the pointer sweep's guard-rail deserves a `handoff-`-prefixed foreign
  file. Its fixture uses `somebody-elses-file`, so it catches a filter widened
  to everything but not one widened to any name this plugin might publish.
  Recorded in `CLAUDE.md` and deliberately left out of the threshold work's
  scope.