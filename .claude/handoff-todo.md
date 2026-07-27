## Remaining

- Release the ledger-liveness change as a patch bump, naming both `handoff` and
  `claude-plugins` up front so auto-mode auth covers the marketplace push.
- Trim the closing sentence of `_probe-lib.sh`'s `without-commit` directive once
  gitlore's `memory-commit-batch.sh` reports on `additionalContext`.
- Sweep the rest of `memory/` for retire-and-merge candidates, confirming each
  cited path with `ls` and quoting the actual `description:` line rather than
  judging by resemblance.
