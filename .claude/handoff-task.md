## Current task

Two threads, both at a natural stopping point.

**Commit awareness** (plan of record: `docs/2026-07-25-commit-awareness-design.md`,
status `implemented`). Both probes take a required `with-commit|without-commit`
argument; under `with-commit` the memory directive names only the summary file,
deferring the memory commit to the parent commit. The stated problem was wrong
and was corrected on 2026-07-26: the standalone path never split history,
because the standalone commit is a *submodule* commit and the parent's
pre-commit hook stages the moved gitlink unconditionally
(`/Users/david/code/gitlore/scripts/git-hooks/pre-commit:75-91`, verified at
source in both the `saved_index` and plain branches). Both paths end with one
parent commit carrying source and pointer together. The real gain is **one call
instead of two**, since agents batch the two IPC writes into a single assistant
message only 43% of the time (28 of 65 measured writes). `DESIGN.md`, the spec's
`## Problem` plus its changelog, `CLAUDE.md`, `README.md`, `_probe-lib.sh` and
the `reference_gitlore_memory_commit_routing` memory were all rewritten on that
premise; no code, mode or test changed. `just precommit` is green at 177 bats /
9 pytest, and the load-bearing negative — `with-commit` output never mentions
the trigger, in any form — is mutation-checked at 7 red across the two probe
suites.

**The post-commit round-trip question is answered, and the deliverable is now
in gitlore's court.** `scripts/cc-hooks/memory-commit-batch.sh` reports every
outcome on `systemMessage` alone, which is user-visible and model-blind, so the
agent re-checks a commit it requested after 62 of 68 landings (91%) — `ls` the
IPC files, then `git -C memory log`/`status`. The control is the parent-commit
path, where the outcome arrives inside a readable Bash tool result: 5 of 14
(35%). A cross-tab rules out handoff's own directive as the cause (58/64 blind
cases with it present, 4/4 without, no difference), so the fix belongs to the
hook. A brief and a proposed diff are dropped in that repo as
`docs/plans/brief-memory-commit-batch-model-channel.md` and the sibling
`.patch`; gitlore itself was not modified. The quantified channel finding is
folded into the `reference_hook_output_channels` memory.

The loaded `handoff` skill body was again the pre-change one — the fourth time
this session's skills have loaded stale — so this wrap-up followed the repo's
current five-step `SKILL.md` rather than the body in context.

## Open decisions

None blocking.
