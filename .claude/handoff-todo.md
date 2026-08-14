## Open decisions

- Whether to run the shared memory/MEMORY.md compaction. It is now 25493 bytes:
  at gitlore's 25600 advisory budget, and well past the ~24.4KB point where
  Claude Code's loader silently drops the tail, so entries at the end never
  reach a session. Method already settled: classify each line as WHEN-triggered,
  HOW-triggered or acted-inline, relocate the acted-inline class into CLAUDE.md
  / shared-claude.md, and retire entries whose fact no longer earns a slot.
  Rewriting fact bodies is not the lever — measured at ~2%, with the index
  unmoved. Blocked on an explicit go-ahead, since it rewrites the index every
  ddaanet repo loads.

## Remaining

- gitlore's integration_memory_gate.bats:25 flake is unexplained. It
  reproduced once in ~1800 test executions under --jobs 2, inside
  make_parent_with_memory: the memory directory was absent from the fixture
  copy while the template was provably intact either side of it, so the loss
  is in that single cp -a or just after. Its first guard, a bare git
  submodule status, exits 0 for a submodule whose working tree is missing and
  so can never fail.
