## Current task

Fix pass 1 on the deliverable review of
`plans/2026-09-04-checkpoint-null-no-task-file`. C1's remedy is settled as (b),
plan-then-apply.

`/runbook` on `plans/2026-09-08-apply-before-mutate/` is finished: the runbook
is written, `runbook-corrector` applied 4 major and 7 minor fixes, and
`runbook-simplifier` found no consolidation warranted. Both reports sit in that
plan's `reports/`.

The `/proof` loop on that runbook is the open thread. It reached its
orientation checkpoint with 14 items enumerated and no verdicts recorded, so it
restarts cleanly from entry rather than resuming mid-iteration. Once it passes,
`/orchestrate` the runbook in a fresh session — the runbook's own closing note
puts orchestration in its own context budget — then the pass-2 minors, then the
release.
