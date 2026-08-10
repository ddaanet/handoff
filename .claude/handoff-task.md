## Current task

Working through the numbered pending-tasks list one item at a time, under TDD
(red tests, then fix, then `just precommit`) per
superpowers:test-driven-development. This segment dropped the context-size
nudge outright (fired too early on large contexts, once right after a
compaction despite the 2026-08-09 fix, and was inconsistently followed) —
`just precommit`-verified and committed. Item 8 (probe what `reason` an
interactive `/exit` writes to `SessionEnd`) is next.

## Open decisions

- The `restart`-kind fork disclosed one TDD-ordering lapse:
  `handoff_resume_command` in `_lib.sh` was implemented before its own bats
  test, rather than red-first. Behavior is covered and green; decide whether
  it still warrants a dedicated redo pass under strict red-then-green.
