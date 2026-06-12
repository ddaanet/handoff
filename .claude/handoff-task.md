## Current task

Making handoff gitlore-aware: the brief for the gitlore standalone
memory-commit entry point is written (`/Users/david/code/gitlore/brief-standalone-memory-commit.md`)
and parked — next build that entry point in the gitlore repo, then return here
to implement handoff's detection + proactive summarize→approve→commit call.

## Open decisions

- Confirm the write-time shape: keep three-parallel (two Write-tool calls +
  one detection Bash call) vs the user's heredoc-script idea. Recommendation is
  three-parallel — a heredoc bypasses `write-stage.sh` and `write-rename.sh` —
  but the user floated the heredoc and hasn't confirmed.
