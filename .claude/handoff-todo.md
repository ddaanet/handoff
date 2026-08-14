## Open decisions

- Whether to run the shared memory/MEMORY.md compaction. It is now 25284
  bytes, past the ~24.4KB point where Claude Code's loader silently drops the
  tail, so entries at the end never reach a session; the gitlore hook's own
  advisory budget is 25600. The "23.5KB" figure this decision carried before
  was stale — tier composition has grown it since. Method already settled:
  classify each line as WHEN-triggered, HOW-triggered or acted-inline,
  relocate the acted-inline class into CLAUDE.md / shared-claude.md, and
  retire entries whose fact no longer earns a slot. Rewriting fact bodies is
  not the lever — measured at ~2%, with the index unmoved. Blocked on an
  explicit go-ahead, since it rewrites the index every ddaanet repo loads.
  Live consequence: an update to green-is-not-evidence this session added two
  shapes to the file body but its index line was left unlengthened, because
  widening the hook would have pushed further past the cutoff.

## Remaining

- Dogfood a driven /handoff:restart end to end. Both defects it just fixed
  were invisible to the suites, and the same is true of whatever remains. One
  lead if it hangs: in a tmux probe with an attached client, `/exit` typed and
  Entered into a live TUI landed in the composer and cleared, but the process
  did not terminate within 30s and #{pane_current_command} stayed `claude`.
  The live failure that motivated the plan proves /exit does work in the real
  path, so this is most likely a probe artifact — but it is unexplained, and
  it is the failure mode that would strand a restart after the session is
  gone.
- gitlore's integration_memory_gate.bats:25 flake is unexplained. It
  reproduced once in ~1800 test executions under --jobs 2, inside
  make_parent_with_memory: the memory directory was absent from the fixture
  copy while the template was provably intact either side of it, so the loss
  is in that single cp -a or just after. Its first guard, a bare git
  submodule status, exits 0 for a submodule whose working tree is missing and
  so can never fail.
