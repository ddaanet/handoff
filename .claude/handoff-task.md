## Current task

Working through the numbered pending-tasks list one item at a time, under
TDD (red tests, then fix, then `just precommit`) per
`superpowers:test-driven-development`. Item 6 (bash/Python split) and item 7
(handoff's `restart` transition kind, per `brief-driven-restart.md`) are both
done and independently `just precommit`-verified; this handoff's own commit
bundles them together with item 3's checkpoint-root-via-updatedInput work,
which had been sitting uncommitted since before this segment. Item 8 (probe
what `reason` an interactive `/exit` writes to `SessionEnd`) is next.

## Open decisions

- The `restart`-kind fork disclosed one TDD-ordering lapse:
  `handoff_resume_command` in `_lib.sh` was implemented before its own bats
  test, rather than red-first. Behavior is covered and green; decide whether
  it still warrants a dedicated redo pass under strict red-then-green.
