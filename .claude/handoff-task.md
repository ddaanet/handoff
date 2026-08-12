## Current task

No task in progress.

## Open decisions

- The `restart`-kind fork's TDD-ordering lapse: `handoff_resume_command` in
  `scripts/_lib.sh` was implemented before its own bats test rather than
  red-first. Behavior is covered and green; decide whether it still
  warrants a dedicated redo pass under strict red-then-green.