## Current task

The context-size threshold trigger is designed and planned; nothing is
implemented. Spec: `plans/2026-07-31-context-threshold-trigger-design.md`
(committed, f16c4a8). Plan:
`plans/2026-08-01-context-threshold-trigger-plan.md`, restructured this session
from four tasks to three.

What it does: a `PostToolBatch` hook sums the newest `usage` sample in the
transcript tail and, past 150k tokens, injects one directive telling the agent
to run `/handoff:compact-continue`. Nudge only — no halt. Subagents skipped.
Fires once per climb, gated by `/tmp/claude/handoff-context-<session_id>`,
which `session-pointer.sh` clears at the next `SessionStart`.

The three tasks: (1) `scripts/context-threshold.sh` + `handoff_context_path()`
in `_lib.sh` + the `hooks.json` registration — 11 bats rows, two mutation
checks; (2) the `SessionStart` re-arm in `session-pointer.sh` plus the widened
sweep; (3) docs — changelog entry, index line, `docs/design.md`, `CLAUDE.md`.

Execution is subagent-driven, and the plan's own Execution note records the
shape: task 1 gets a fresh agent; task 2 goes to that same agent as a second
prompt, behind a review gate, because widening the sweep filter is the one edit
that can regress something already working; task 3 is not delegated, since the
changelog is a write-time record of reasoning that lives in the spec and this
session, and `docs/design.md`/`CLAUDE.md` are in a voice a context-free agent
does not have.

Task 1's step 8 requires both mutation runs' `bats` output pasted verbatim into
the agent's report. The rows and the script are written by the same pass there,
so the mutation is the only thing standing in for a red-phase review — a claim
that it went red is not the run that did.

## Open decisions

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
  The threshold trigger's `systemMessage` inherits the same question.
- Whether the main session transcript ever carries a subagent's `usage` entry.
  It should not (subagent usage lives in
  `<session-dir>/subagents/agent-<agent_id>.jsonl`), but if it does the
  measurement reads high; the fix is a `select(.isSidechain != true)` in the
  `jq` filter. Settled at first dogfood, which needs a restart — hooks freeze at
  session start, so the new entry cannot take effect in the session that writes
  it.