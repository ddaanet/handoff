## Current task

`/orchestrate` finished `plans/2026-09-08-apply-before-mutate/runbook.md` — both
phases, seven dispatches, no UNFIXABLE at any gate. The whole job rides a single
commit, amended after each dispatch per item 2.1's own instruction, so the shas
named inside `reports/item-1-1-s1-green.md` and `reports/item-2-1.md` are stale
by construction and resolve to nothing; `reports/phase-2-corrector.md` carries a
dated correction note for the same reason.

Next is `/deliverable-review plans/2026-09-08-apply-before-mutate` in a fresh
session on opus, then the pass-2 minors, then the release.
