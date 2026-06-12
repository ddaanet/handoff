## Current task

Execute the gitlore-aware handoff implementation plan
(`docs/superpowers/plans/2026-06-12-gitlore-aware-handoff.md`, 7 TDD tasks):
add `scripts/memory-probe.sh` + `bin/handoff-memory-probe` so handoff
detects a dirty gitlore-memory submodule at wrap-up and drives
summarize → approve → commit via gitlore's `commit-memory.sh`, plus the
non-tmux autorename `additionalContext` fix.

## Open decisions

- Execution mode for the plan: subagent-driven (recommended — fresh
  subagent per task, review between) vs inline. All design decisions are
  already settled in the spec; this is only how to run it.
