## Open decisions

- Whether to run the shared `memory/MEMORY.md` compaction. The index sits at
  roughly 24.3KB against a 25600-byte budget, past the ~24.4KB point where
  Claude Code's loader silently drops the tail, so entries at the end never
  reach a session and a new entry appended there would be invisible.
  `/gitlore:index-audit` is the pass for it — measure against the loader cap,
  relocate, retire or merge entries, then audit the diff for lost routing.
  Blocked on an explicit go-ahead, since it rewrites the index every ddaanet
  repo loads.

## Remaining

- `/runbook` the rewritten outline into phases: slice 0 (mechanical payload
  factories, suite green throughout), slice 1 (tdd, the payload layer), slice 2
  (`bash-post.sh`'s stderr redirect), slices 3-4 (both skill bodies, then
  `docs/design.md` + changelog + index line + `CLAUDE.md`).
