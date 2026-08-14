## Open decisions

- Whether to run the shared `memory/MEMORY.md` compaction. Now measured at 25881 bytes: over gitlore's 25600 advisory budget, and past the ~24.4KB point where Claude Code's loader silently drops the tail, so entries at the end never reach a session. Method already settled: classify each line as WHEN-triggered, HOW-triggered or acted-inline, relocate the acted-inline class into `CLAUDE.md` / `shared-claude.md`, and retire entries whose fact no longer earns a slot. Rewriting fact bodies is not the lever — measured at ~2%, with the index unmoved. Blocked on an explicit go-ahead, since it rewrites the index every ddaanet repo loads.

## Remaining

- Run a driven restart end to end against the real product. The 2026-08-13 restart-drive-repair work is executed in full and both suites pass, but neither reaches the whole path — the design record makes dogfooding a walker change part of landing it, not a follow-up.