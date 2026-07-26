## Current task

Three threads.

**Ledger liveness.** `probe_ledger_path` now detects a *live* superpowers SDD
run rather than a file's presence at a fixed path; DESIGN.md's dated section
carries the full rationale and the rejected alternatives. The one thing not
on disk: this changes released probe behaviour, so it wants a version bump,
and `plugin.json` is deliberately untouched because `version-guard.sh` owns
`.version` — the release recipe is the only path.

**Memory curation, unstarted.** `feedback_directive_states_acts` is confirmed
subsumed by `feedback_directive_acts_not_mechanism`: read side by side, every
one of the former's three bullets appears in the latter, which adds two more
cut-items, the user's own words and the negative test.
`feedback_withhold_dont_forbid` earns its own file and stays. This is the
first *confirmed* retire-and-merge pair — an earlier subagent report on it was
largely fabricated, so confirm any further candidate by reading both files
rather than by resemblance. Retiring the file also drops a pointer line that
`/Users/david/code/gitlore/memory/MEMORY.md` carries in its own root index;
that is a proposal to make there, not an edit — other repos stay read-only.

**The `_probe-lib.sh` directive trim, blocked on gitlore.** Cut the closing
sentence of the `without-commit` memory directive once gitlore's
`memory-commit-batch.sh` reports on `additionalContext` instead of
`systemMessage`. Until then that sentence is the agent's only signal, so it
cannot go first; after, it asks the agent to infer from file existence what
the hook states outright. The brief and patch already live in gitlore's repo
as `docs/plans/brief-memory-commit-batch-model-channel.md` plus the sibling
`.patch`.

## Open decisions

- Whether the abandoned-workspace false positive needs more than the
  most-recently-modified tiebreak. A run abandoned rather than completed keeps
  its workspace and its identity line, so it still reads as live; mtime only
  mitigates. The fallback is the brief's rejected alternative — drop the
  suppression and always write `handoff-todo.md` — if detection alone proves
  too fragile.
