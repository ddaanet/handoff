## Remaining

- Collapse `feedback_directive_states_acts` into
  `feedback_directive_acts_not_mechanism`, keeping `feedback_withhold_dont_forbid`
  as its own file; propose the matching root-index line removal to `gitlore`
  rather than editing that repo.
- Compact `memory/MEMORY.md`, trimming the longest lines first.
- Sweep the rest of `memory/` for further retire-and-merge candidates, confirming
  each cited path with `ls` and quoting the actual `description:` line.
- Trim the closing sentence of `_probe-lib.sh`'s `without-commit` directive once
  gitlore's `memory-commit-batch.sh` reports on `additionalContext`.
