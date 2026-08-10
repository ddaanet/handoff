## Remaining

- Keep watching whether a context-size nudge is ever ignored outright — that is
  the evidence that reopens the halt. (Standing watch, not a discrete task.)
- Probe what `reason` an interactive `/exit` writes to `SessionEnd`. Next
  actionable item — start here.
- Patch `handoff-checkpoint`'s gitlore diagnosis into its three real cases, with
  the relaunch as the remedy.
- Propose excluding the memory submodule from the clean-tree check in
  claude-plugin-dev's `release.sh`: `git diff --quiet HEAD` fails on ` M memory`,
  a gitlore repo's resting state, so `release` and `resume-release` both abort
  until someone hand-commits the memory the release would have carried anyway.
  That repo is read-only from here and `plugin-dev/` is a vendored subtree —
  propose, never hand-edit.
- Refresh `claude-plugins`' gitlore hooks: its commit and its push both printed
  "gitlore skipped: hooks dir is stale (plugin upgraded; cache GC'd)", so that
  repo's memory gate is inert until Claude Code is started there once.
- Apply `brief-merge-dispatch-authorization.md` in gitlore: its merge directive
  should state that the dispatch is authorized, so an agent bound by a blanket
  no-unsolicited-dispatch rule can act on it without a round trip.
- Implement gitlore's stale-plugin-root detector per
  `docs/plans/2026-07-31-14-stale-plugin-root-notice.md`, red bats first.
- Rewrite gitlore's bats negatives per `brief-test-suite-negatives-rewrite.md`,
  and report where the paired-structure rule does not hold.
- Add guardrails against snake_case and `name:`/filename drift, then finish
  normalising memory: upstream has done the `ddaanet` tier, leaving the project
  store, the other tiers, and the wikilink targets a link audit reports as
  dangling. The link parser must skip fenced code, or it will rewrite bash
  `[[ "$output" == ... ]]` conditionals.
- Explain the live pointer loss for gitlore's own memory store.
- Place or apply the remaining root-level briefs — `brief-driven-restart.md` and
  `brief-stale-config-after-mid-session-upgrade.md` — in their target repos.
- Migrate the `micro` tier (~40 facts) once a real memory remote is settled; it
  and `general` still point at a local `./.git/gitlore-placeholder`. Then
  `gitmoji` -> `general` -> `home` -> `devddaanet` -> `skills` -> `candidature`
  -> `edify` -> `Emploi` -> `cwd-safety`.
- Resolve the open decision: whether to publish the `ddaanet` tier merge. See
  the task file's `## Open decisions`.