No active task — trimmed stop-compact.sh's Stop systemMessage so it no longer echoes the full `/compact <directive>` line (the watcher types that same line into the pane moments later, so it was shown twice); the confirmation now just names the pane and that /compact will run. DESIGN.md carries the dated rationale. Tests (`just hook-test`) and shellcheck pass. About to commit.

## Open decisions

- Compact `memory/MEMORY.md` (~23.7KB, ~92% of the 25.6KB budget a hook warns about) without losing symptoms/identifiers the way a prior compaction did — deferred at David's request; needs a careful, audited pass, not a mechanical byte-target trim.