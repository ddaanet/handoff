## Current task

Nothing is mid-flight. The context-size trigger mechanism is verified and
recorded in `brief-context-threshold-trigger.md`; the design pass it opens is
the new work. Otherwise the queue is unchanged — the memory-index decision
below, then the todo list in order, starting with the bash/Python split in
`plans/2026-07-31-python-rewrite-brief.md`.

## Open decisions

- The root memory index is 26630 bytes against a 25600-byte budget — 104%.
  Past Claude Code's loader cap the tail truncates silently, and the
  project-local lines are what sit in that tail. Merging overlapping facts is
  exhausted and stripping triggers is ruled out by
  `ddaanet/feedback_index_compaction_triggers`, so retiring facts outright is
  the only lever left. Which ones is not decided.
- Two assumptions the drift design recorded as unverified are still unverified,
  because `SessionStart` hooks freeze at session start and `session-pointer.sh`
  has therefore never run: that a hook payload's `session_id` matches
  `CLAUDE_CODE_SESSION_ID`, and that `systemMessage` honours ANSI at all. The
  first session after a restart settles both — check that
  `/tmp/claude/handoff-root-<session_id>` appears without being hand-written,
  and whether the drift line's leading reset renders or shows as literal bytes.
- The threshold trigger's shape is open: soft nudge versus hard halt, where the
  context-window size comes from (a hardcoded figure or the undocumented
  `autoCompactWindow` key), which script owns it, and whether subagent batches
  are measured at all. The questions and the verified constraints they answer
  to are in `brief-context-threshold-trigger.md`.