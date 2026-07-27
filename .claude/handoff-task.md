## Current task

Two carried threads, both untouched today.

**Ledger liveness, awaiting release.** `probe_ledger_path` detects a *live*
superpowers SDD run rather than a file at a fixed path; DESIGN.md carries the
rationale and rejected alternatives. This changes released probe behaviour, so
it wants a patch bump. `plugin.json` is deliberately untouched — `version-guard.sh`
owns `.version` and the release recipe is the only path.

**The `_probe-lib.sh` directive trim, blocked on gitlore.** Cut the closing
sentence of the `without-commit` memory directive once gitlore's
`memory-commit-batch.sh` reports on `additionalContext` instead of
`systemMessage`. Until then that sentence is the agent's only signal, so it
cannot go first; after, it asks the agent to infer from file existence what the
hook states outright. Brief and patch already live in gitlore's repo as
`docs/plans/brief-memory-commit-batch-model-channel.md` plus the sibling `.patch`.

## Open decisions

- Whether gitlore's own byte-budget hook should stand down. It fired on every
  index edit this session demanding compaction to 17.1KB, while
  `feedback_index_compaction_triggers` — stored *in* that index — records the
  last such compaction as a defect that cost 12 routing tokens. A hook
  contradicting the memory it carries is the thing to resolve; the 17.1KB
  figure is also unsourced and was measured to truncate nothing at this size.

- Whether the decision procedure dropped from the merged
  `feedback_directive_states_acts` index line needs its own routing surface.
  The line keeps the rule but not the test ("ask who else could supply the
  identifier; nobody → say nothing"); the procedure survives only in the file
  body, so nothing routes an agent to it mid-task.

- Whether the abandoned-workspace false positive needs more than the
  most-recently-modified tiebreak. A run abandoned rather than completed keeps
  its workspace and identity line, so it still reads as live; mtime only
  mitigates. Fallback is the brief's rejected alternative — drop the
  suppression and always write `handoff-todo.md`.
