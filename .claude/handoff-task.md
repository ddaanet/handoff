## Current task

Cutting the handoff release that ships `.claude/handoff-todo.md` plus the
remediation of a full-codebase code review. All five audit findings are fixed
and committed; only the release itself remains.

The audit is `docs/2026-07-22-code-review-audit.md` — the point-in-time record,
including the two rejected findings with their disproof, so they are not
re-investigated. It is not a checklist to work through: everything in it is
done.

Fixes landed as `3052b08..HEAD` — `7f4c406` (sweep a stale `autocompact` at
UserPromptSubmit), `9de3210` (line 1 confirms against the compaction, not the
pane), `351e71e` (rename watcher gets a failure channel;
`report-compact-failure.sh` became `report-watcher-failure.sh` and reads both
`.failed` files), `c3afda2` (dead `.gitignore` entries, the stale
`.claude/handoff-session` on disk, a stale CLAUDE.md sentence, and a false
`set -e` rationale in three watcher headers). `just precommit` was green before
each. DESIGN.md carries three new dated sections for the design changes.

Three findings were fixed beyond what the audit recorded, each found while
fixing something else, so they are not in that document: `autorename*` and
`autocompact*` were never in `.gitignore` at all; `hook-test.bats` was driving
the real tmux server, because `TMUX=fake` does not stop tmux falling back to the
default socket and `%0` is a live pane; and finding 1's fix shape was changed
from the audit's recommendation (a `session_id` sidecar misses the Esc case,
which leaves the file in the *same* session).

The working tree is clean apart from an uncommitted `memory` submodule pointer
bump from this session's memory commit — it needs to ride a commit before or
with the release.

## Open decisions

- Release size. `just release minor` (0.11.0) is the presumed call: the release
  ships a new output path (`.claude/handoff-todo.md`), which is version-bumping
  under CLAUDE.md's conventions. Patch if the new file is judged additive
  enough not to count. Not yet explicitly confirmed by the user.
- The release needs `MARKETPLACE_DIR` from `.envrc` and bumps the marketplace
  entry in the sibling `claude-plugins` repo, pushing both. Name both repos up
  front so auto-mode auth covers the marketplace push.
