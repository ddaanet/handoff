## Remaining

- Dogfood the walker and the loaders against a real tmux pane — one `/handoff:autoname` (kind `rename`), one `/handoff:compact-continue`, one `/handoff:handoff-continue`. The checkpoint, `bash-post.sh` and `report-watcher-failure.sh` have already run live; nothing has typed into a pane yet, and the suites are the only evidence for that half.
- Settle the `memory/MEMORY.md` size question, then compact only if it is real. Merge or drop whole entries rather than shaving words; count each trigger literal index-wide before and after, and have the diff audited.
- Decide whether this lands as a release, per the open decision in the task file.
- Two throwaway probe transcripts remain at `~/.claude/projects/-tmp-claude-1000-…-clearprobe-repo/` (sessions `1a8d2bf3…` and `85b5eb48…`, the ones the design doc cites as evidence for the clear boundary). Outside the sandbox's writable set, so removing them needs the user.