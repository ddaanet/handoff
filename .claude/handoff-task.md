## Current task

This session resolved a diverged `ddaanet` gitlore tier merge (commit
`6df0928`) via the memory-merger sub-agent — retiring `feedback_release_flow_naming.md`
(rule relocated into `CLAUDE.md`'s `release.just` bullet) and
`feedback_handoff_tree_local.md` (redundant with `CLAUDE.md`'s "Output
paths" convention) — then committed and published the memory sync
(`70f9eb0` → `origin/live`). A `PostToolBatch` hook then flagged
`memory/MEMORY.md` is still ~25KB and wants it compacted to under 17.1KB,
a much larger cut than the two lines already dropped.

## Open decisions

- Whether to run the ~25KB → <17.1KB `MEMORY.md` compaction pass now (one
  line per entry, detail moved to topic files, stale/merged entries) or
  leave it for a dedicated session under the existing `handoff-todo.md`
  memory-normalising item — asked, no answer yet.
- Whether to commit the pending `CLAUDE.md` edit (the relocated
  release-flow-naming rule) standalone or bundle it with other work.
- The `restart`-kind fork's TDD-ordering lapse, carried over unresolved:
  `handoff_resume_command` in `_lib.sh` was implemented before its own bats
  test rather than red-first. Behavior is covered and green; decide whether
  it still warrants a dedicated redo pass under strict red-then-green.