## Remaining

- Once gitlore's `memory-commit-batch.sh` reports on `additionalContext`, cut
  the closing sentence of `_probe-lib.sh`'s `without-commit` directive —
  "gitlore's PostToolBatch hook commits the submodule and removes both files on
  success. If they remain, the commit did not run — report that rather than
  retrying." It is the agent's only signal until then, so it must not go first;
  after, it directs the agent to infer from file existence what the hook states
  outright, which is the mechanism-in-a-directive shape
  `feedback_directive_acts_not_mechanism` records.
- Dogfood the probe argument from a session whose *skill bodies* are current.
  The scripts on `PATH` do resolve to this repo, but the loaded body has been
  the pre-change one **four** times now, so the re-phrased Step 1 has still
  never been read by the agent that acts on it.
- Sweep `memory/` for retire-and-merge candidates: confirm every cited path
  with `ls`/`test -f` and quote the actual `description:` line. Zero duplicate
  pairs have ever been confirmed — the one subagent report on it was largely
  fabricated. This is also the only route to the index budget; line-length
  edits recover about a fifth of the gap.
