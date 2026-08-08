## Current task

Implement pass 3 of the transition work — `autoname` routed through
`handoff-checkpoint` so the checkpoint is the sentinel's only writer — per
`plans/2026-08-09-autoname-through-checkpoint-design.md`, which is the
approved spec. Red bats first. The spec's own test section names the rows,
including the load-bearing negative: an `autoname` call against a dirty memory
submodule emits no directive at all, mutation-checked by restoring the
unconditional `checkpoint_memory_directive` and watching that row alone go red.

A code review of pass 2 and the ledger/todo scope boundary runs alongside it,
fed one item at a time as prose naming a file and a line range. One item has
landed: the comment above `checkpoint.sh`'s held/armed branch, cut back to the
hazard `held` exists for. The rest of that review has not been given yet.

## Open decisions

- Whether to cut a release, and at what bump. Pass 2 removes two user-visible
  skill names (`handoff-continue`, `compact-continue`) and pass 3 changes
  `autoname`'s contract from a single Write to a Bash call, so the earlier
  minor/patch answer covers neither. The context-size threshold is a minor;
  the state machine, the ledger boundary and pass 3 ride as a patch.
  `just release` pushes, cuts a GH release and bumps the marketplace, so it
  waits for an explicit yes.