## Current task

Remediating a full-codebase code review, then cutting the release that ships
`.claude/handoff-todo.md`. All findings, their failure scenarios, the fix shape
for finding 1, and the two rejected findings with their disproof are recorded
in `docs/2026-07-22-code-review-audit.md` — read it first; it is the source of
truth for this work and nothing below restates it.

Next action is finding 1: a stale `.claude/autocompact` survives a turn that
never ends normally (Esc, crash, quit) and is armed by a later, unrelated
`Stop` — possibly in a different session, driving a stale `/compact` and a
stale continuation prompt into unrelated work.

Second thread: the `handoff-todo.md` ledger feature is now verified end to end
in live use — the frame injection was confirmed at this session's start, and
the wipe was confirmed by this precompact activation clearing both files. No
verification work remains on it; only the release does.

## Open decisions

- Fix shape for finding 1. Recommended and unchallenged, but not explicitly
  confirmed: have `write-compact.sh` stamp a sidecar with the payload's
  `session_id` at validation time, and have `stop-compact.sh` refuse to arm
  when it does not match the current session. This keeps the agent-authored
  two-line format intact (CLAUDE.md's contract for that file) and adds no
  spawn and no delete to a validate-only hook. Adding `autocompact*` to
  `_wipe-emit.sh`'s wipe list is a cheap complement, not a substitute — the
  wipe only runs on skill re-activation, which the lingering-file scenario
  does not involve.
- Release size. `just release minor` (0.11.0) is the presumed call, since a
  new output path is version-bumping under CLAUDE.md's conventions; patch if
  the new file is judged additive enough not to count.
