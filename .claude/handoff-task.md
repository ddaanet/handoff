## Current task

No active task — trimmed the closing sentence of the without-commit memory
directive in `checkpoint_memory_directive` now that gitlore v0.4.2 carries
the fix (62b1e59) it depended on, and deduped two ddaanet memory entries
(errexit-in-condition, pipefail-fallback-appends) once `shell-scripting`'s
shell-gotchas skill absorbed them (v0.3.2).

## Open decisions

- Compact `memory/MEMORY.md` (~23KB, 93% of the 25.6KB budget a hook warns
  about) without losing symptoms/identifiers the way a prior compaction did
  — deferred at David's request; needs a careful, audited pass, not a
  mechanical byte-target trim.