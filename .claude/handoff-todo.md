## Remaining

- `git mv DESIGN.md docs/design.md` and repoint every reference — `CLAUDE.md`, `README.md`, `scripts/`, `tests/`, `skills/handoff/references/design.md`, `memory/ddaanet/feedback_design_doc_writing.md`; grep `DESIGN.md` before declaring done.
- Restyle `docs/changelog.md` to the reference format: newest first, date inside the link text.
- `git mv` the four loose prospective design docs out of `docs/` into `plans/` (`2026-07-18-precompact-drive-design.md`, `2026-07-22-code-review-audit.md`, `2026-07-25-commit-awareness-design.md`, `2026-07-27-checkpoint-channel-design.md`) and repoint the scripts and design prose that cite them.
- `git mv docs/superpowers/{specs,plans}/` contents into `plans/` and remove the emptied tree; grep `docs/superpowers` before declaring done.
- Drop the committed `.DS_Store` and `._*` files under `docs/` and add the ignores — a separate change, per the brief.
- Compact `memory/MEMORY.md`: 23.4 KiB against the 24.4 KiB point where Claude Code's loader silently truncates the tail. Index lines are functional for agent-matching, so count each trigger literal index-wide before and after rather than shortening mechanically.
- Fix `checkpoint_memory_directive`'s failure message when `git config gitlore.memoryApprovalClauseFile` is unset: it reports gitlore as disabled or not installed, but the key is re-pinned only at gitlore's `SessionStart`, which a plugin update does not fire.