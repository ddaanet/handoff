## Current task

Two threads, both unstarted.

**Memory curation.** `feedback_directive_states_acts` is confirmed subsumed by
`feedback_directive_acts_not_mechanism`: read side by side, every one of the
former's three bullets appears in the latter, which adds two more cut-items, the
user's own words and the negative test. `feedback_withhold_dont_forbid` earns its
own file and stays. This is the first *confirmed* retire-and-merge pair — earlier
sweeps produced none, and one subagent report on it was largely fabricated, so
confirm any further candidate by reading both files rather than by resemblance.
Retiring the file also means dropping the pointer line one other mount
(`/Users/david/code/gitlore/memory/MEMORY.md`) carries in its own root index;
that is a proposal to make there, not an edit — other repos stay read-only. Of
the four mounts only `gitlore` carries it (`cwd-safety` and `onekeys` do not),
`gitlore_compose_dangling` reports and never refuses
(`scripts/lib/index-compose.sh:208`), and gitlore's index merging is being fixed
independently — so nothing here is blocking and the mechanism should not be
designed around.

The same commit is the moment to compact the root index: 88% of the 25600-byte
budget, with the hook asking for under 17.1KB. Bytes live in the longest lines —
`feedback_posttooluse_print_mode` 623, `reference_gitlore_memory_commit_routing`
465, `reference_git_stderr_and_parsing` 456.

**The `_probe-lib.sh` directive trim**, still blocked on gitlore. Cut the closing
sentence of the `without-commit` directive once gitlore's
`memory-commit-batch.sh` reports on `additionalContext` instead of
`systemMessage`. Until then that sentence is the agent's only signal, so it
cannot go first; after, it asks the agent to infer from file existence what the
hook states outright. The brief and patch are already in gitlore's repo as
`docs/plans/brief-memory-commit-batch-model-channel.md` plus the sibling
`.patch`.

## Open decisions

- Whether the index compaction targets the hook's 17.1KB (a ~4.8KB cut, which
  at these line lengths means rewriting many entries) or only removes genuinely
  redundant text and accepts staying above it. `feedback_memory_index_lines_functional`
  says index lines serve agent-matching and ambient awareness, not just
  pointing, and warns against mechanical shortening to hit an advisory number —
  the two pull in opposite directions and the budget is advisory.
