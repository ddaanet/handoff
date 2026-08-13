## Open decisions

- Whether to run the shared memory/MEMORY.md compaction. It sits at 23.5KB
  against Claude Code's ~24.4KB loader cap, past which the tail is silently
  dropped and those entries never reach a session; the hook asks for under
  17.1KB. Method already settled: classify each line as WHEN-triggered,
  HOW-triggered or acted-inline, relocate the acted-inline class into
  CLAUDE.md / shared-claude.md, and retire entries whose fact no longer earns
  a slot. Rewriting fact bodies is not the lever — measured at ~2%, with the
  index unmoved. Blocked on an explicit go-ahead, since it rewrites the index
  every ddaanet repo loads.
- How Task 1 should identify the claude process. The plan implements a walk
  matching argv[0]'s basename against claude, and records deriving it from
  tmux's pane_pid as rejected, because handoff_resume_command runs before the
  tmux check in stop-drive.sh and must also serve the not-in-tmux paste path.
  Reopen only if a launch as node .../cli.js has to keep its flags — the
  basename walk takes the bare-resume fallback there.

## Remaining

- Execute the plan's three tasks.
- gitlore's integration_memory_gate.bats:25 flake is unexplained. It
  reproduced once in ~1800 test executions under --jobs 2, inside
  make_parent_with_memory: the memory directory was absent from the fixture
  copy while the template was provably intact either side of it, so the loss
  is in that single cp -a or just after. Its first guard, a bare git
  submodule status, exits 0 for a submodule whose working tree is missing and
  so can never fail.
