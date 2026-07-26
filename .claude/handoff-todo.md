## Remaining

- Release the ledger-liveness change: `just release` a patch bump, naming both
  `handoff` and `claude-plugins` up front so auto-mode auth covers the
  marketplace push.
- Collapse `feedback_directive_states_acts` into
  `feedback_directive_acts_not_mechanism`, keeping `feedback_withhold_dont_forbid`
  as its own file; propose the matching root-index line removal to `gitlore`
  rather than editing that repo.
- Compact `memory/MEMORY.md` to clear gitlore's own 80% of 25600 bytes, trimming
  the longest index lines first — not the harness's unsourced 17.1KB, which
  measurement showed truncates nothing at the current size.
- Sweep the rest of `memory/` for further retire-and-merge candidates, confirming
  each cited path with `ls` and quoting the actual `description:` line.
- Trim the closing sentence of `_probe-lib.sh`'s `without-commit` directive once
  gitlore's `memory-commit-batch.sh` reports on `additionalContext`.
