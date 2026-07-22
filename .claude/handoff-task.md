## Current task

Cutting handoff 0.11.0 — the release that ships `.claude/handoff-todo.md`
alongside the remediation of the 2026-07-22 full-codebase code review.
Everything that gates it is done: the five audit findings, and the follow-up
pass on both skills' todo guidance that the user gated the release on.

The audit is `docs/2026-07-22-code-review-audit.md` — a point-in-time record,
including two rejected findings with their disproof, so those are not
re-investigated. It is not a checklist; everything in it is done.

Release size is settled: **minor**, 0.11.0, chosen by the user against the
patch alternative. `just release minor` needs `MARKETPLACE_DIR` from `.envrc`,
bumps the marketplace entry in the sibling `claude-plugins` repo, and pushes
both — name both repos when authorizing, so auto-mode covers the marketplace
push.

## Open decisions

- Whether to convert the eight remaining `you`/`your` uses in the skill bodies
  to imperative form, per `plugin-dev:skill-development`. Raised twice, never
  answered. The recommendation was to leave them: `your post-compaction self`
  names the file's future reader, which is precompact's whole frame, and the
  rest describe what the harness does to the agent. Purely cosmetic either way
  — not a release gate.
