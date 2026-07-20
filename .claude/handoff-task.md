## Current task

The precompact drive spec is now spike-verified and its trigger architecture
reworked onto `Stop` + `SessionStart(compact)` hooks, leaving implementation
(five new scripts, three probe/skill rewrites, bats coverage) still to do.

## Open decisions

- Whether to derive a formal plan via `writing-plans` first or implement
  directly from the spec, which is already organized component-by-component
  with a per-file "Files touched" list.
- Whether to cut a release before starting implementation: `v0.9.0` is the last
  tag and the per-worktree-handoff-root work shipped without one.
