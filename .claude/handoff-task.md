## Current task

Deduped and cross-linked entries in `memory/MEMORY.md` (this repo's gitlore
store): merged `feedback_agent_executes.md` into `feedback_harness_over_agent.md`
(generalized rule + both anecdotes, repointed 4 citing memories), merged
`feedback_git_status_unsandboxed.md` into `feedback_git_status_sandbox.md`
(added the slash-command caveat), deleted `feedback_prose_over_modals_design.md`
as superseded by `feedback_no_askuserquestion.md`, and added cross-links between
several related memories (verify-handoff-pending ↔ memory-status-claims-rot,
mutation-check-negatives ↔ bats-vacuous-negative, design-doc-structure into the
DESIGN.md cluster). Confirmed gitlore's compose/sync hook only settles stale
index-line resync when both `memory/MEMORY.md` and `memory/ddaanet/MEMORY.md`
are edited via Edit/Write in the same pass — a Bash `rm` of the underlying file
alone left the line reappearing across several composition cycles.

## Open decisions

- Root `memory/MEMORY.md` is 26.75KB against a hook-enforced budget of 17.1KB
  (tightened from the 24.4KB limit surfaced earlier this session). Asked the
  user whether to trim by moving detail into topic files (kept, just dropped
  from the index) or by cutting stale/low-value entries outright — not yet
  answered.
