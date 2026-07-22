## Current task

Built the `handoff-todo.md` remainder ledger end to end: `handoff_frame`
assembly, both skill templates, the activation wipe, read/write guards (via a
now-variadic `handoff_match_target`), `probe_ledger_path` +
`probe_todo_suppression` for SDD suppression, and docs across DESIGN.md,
CLAUDE.md, README and `skills/handoff/references/design.md`. `just precommit`
green — 140 bats, 9 pytest.

Nothing built this session is live *in* it: plugin skill bodies and hooks are
snapshotted at session start, so the feature has never actually run. No real
handoff or precompact has exercised the new frame, wipe, or guards. First
verification needs `/reload-plugins` or a fresh session. The remaining items
are in `handoff-todo.md`, which is itself the first live test of the feature.

## Open decisions

- Whether `handoff-todo.md` should be wiped at activation. I reversed my
  stated position mid-build, and it currently **is** wiped. Reasons: nothing
  else ever deletes a finished list — the skill writes the file only when
  items remain, so a completed list would linger on disk and keep re-injecting
  done items as outstanding — and both loaders re-inject the file, so
  re-authoring is from context rather than from disk, the same guarantee the
  task file has. Cost accepted: an abandoned flow (stalling at the FR11
  approval gate) leaves no todo file where a stale one used to sit. Flipping
  it back is two lines in `_wipe-emit.sh` plus the two wipe tests.
- Release size. A new output path is a version-bumping change under CLAUDE.md's
  conventions; `just release minor` is the presumed call, patch if the new file
  is judged additive enough not to count.
