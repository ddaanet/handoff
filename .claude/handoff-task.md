## Current task

Pass 3 of the transition work — `autoname` routed through `handoff-checkpoint`
so the checkpoint is the sentinel's one writer — is implemented per
`plans/2026-08-09-autoname-through-checkpoint-design.md` and green on
`just precommit` (260 bats rows, 11 pytest). **Uncommitted.** `skill` takes a
third value whose whole payload is `{"skill","rename"}`, the memory gate moved
inside the boundary branch so an autoname call composes no directive,
`write-drive.sh` is deleted with its hook entry (nine hooks now), and
`write-guard.sh` carries `autodrive` as a second (basename, rel) pair. Docs
landed in the same pass: `docs/changelog/2026-08-09-one-writer-for-the-sentinel.md`,
its index line, `docs/design.md`, and the `CLAUDE.md` entries.

Red-first throughout. The load-bearing negative — an `autoname` call against a
dirty memory submodule emits no directive at all — is mutation-checked:
restoring the unconditional `checkpoint_memory_directive` reds that row alone.

A code review of pass 2 and the ledger/todo scope boundary runs alongside,
fed one item at a time as prose naming a file and a line range. One item has
landed: the comment above `checkpoint.sh`'s held/armed branch, cut back to the
hazard `held` exists for. The rest has not been given yet.

## Open decisions

- Whether to commit pass 3 now or hold it for the remaining review items.
  Neither was asked for.
- Whether to cut a release, and at what bump. Pass 2 removes two user-visible
  skill names (`handoff-continue`, `compact-continue`) and pass 3 changes
  `autoname`'s contract from a single Write to a Bash call, so the earlier
  minor/patch answer covers neither. The context-size threshold is a minor;
  the state machine, the ledger boundary and pass 3 ride as a patch.
  `just release` pushes, cuts a GH release and bumps the marketplace, so it
  waits for an explicit yes.