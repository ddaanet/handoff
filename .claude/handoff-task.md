## Current task

A high-effort code review of `7525961..HEAD` returned five confirmed defects,
all now fixed red-bats-first with `just precommit` green: the held sentinel
carries its owner on line 1 (`held <session-id>`) and both ends check it, the
hold gates on whether the sentinel types anything rather than on the transition,
`context-threshold.sh` selects objects before indexing, and `rename` is
type-checked and forbidden by key presence under `precompact`. The `rename`
sense inversion flagged before the review was refuted as a defect in itself.
Docs landed in the same pass: `docs/changelog/2026-08-10-held-names-its-owner.md`
plus its index line, and the invalidated prose in `docs/design.md` and
`CLAUDE.md`.

Two rows were green in the red phase and are mutation-checked rather than
assumed — the dead-session sweep and arm-drops-owner. Both mutations reverted.

## Open decisions

- Release bump, and whether anything still gates it. Three unreleased passes now
  stack: pass 2 removes two user-visible skill names (`handoff-continue`,
  `compact-continue`), pass 3 changes `autoname`'s contract from a Write to a
  Bash call, and this pass changes the sentinel's state-line shape. The earlier
  minor/patch answer covers none of them. `just release` pushes, cuts a GH
  release and bumps the marketplace, so it waits for an explicit yes.