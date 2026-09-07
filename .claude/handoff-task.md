## Current task

`/orchestrate` on `plans/2026-09-04-checkpoint-null-no-task-file/runbook.md`,
phases in order. Phase 0 is done and reviewed: the five payload factories are
in place in `tests/test_checkpoint.py` and the suite is 113 tests green, so
Phase 1 can change the schema by flipping five factory bodies rather than the
~118 literal sites they replaced.

Phase 1 (Item 1.1, type `tdd`, four slices) is next — the tagged-union rewrite
of `scripts/checkpoint.py`'s payload layer, four dispatches per slice: RED,
test review, GREEN, code review.

Model assignment my human partner set for the run: `edify:test-driver` sonnet,
`edify:corrector` and every prose edit opus. Items 2.1, 3.1 and 4.1 are
`inline` — the orchestrator executes those itself rather than dispatching.
