## Open decisions

- Whether to run the shared `memory/MEMORY.md` compaction. The index measures
  24480 bytes against a 25600-byte budget, past the point where Claude Code's
  loader silently drops the tail — this session hit it directly: the index was
  not in context and had to be read from disk to route recall. An entry
  appended at the end would be invisible. `/gitlore:index-audit` is the pass
  for it — measure against the loader cap, relocate, retire or merge entries,
  then audit the diff for lost routing. Blocked on an explicit go-ahead, since
  it rewrites the index every ddaanet repo loads.

## Remaining

- `/orchestrate` `plans/2026-09-04-checkpoint-null-no-task-file/runbook.md`,
  phases in order. Phase 0 must land immediately before Phase 1: its
  meaning-preservation argument rests on no test in `tests/test_checkpoint.py`
  pre-creating `.claude/handoff-task.md`, which is true today and is what
  makes flipping 61 `task_clear()` sites from no-op to unlink safe.
- Write the `git add` guard fact to memory once the index has room: a
  gitignored path on disk but never in the index exits 128 with `did not match
  any files`, and `git ls-files` guards that silently where `--error-unmatch`
  writes to stderr and would defeat the redirect removal it guards for.
  Verified against real git this session; deferred only because the index is
  at its cap.
- Decide the version bump for the release carrying this fix. The marketplace
  cache is keyed by version, so a push under an unchanged version reaches no
  installed repo and `/plugin update` re-fetches nothing.
