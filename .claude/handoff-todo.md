## Remaining

- `just release` — it owns the version bump, so there is no separate bump
  step. Name both `handoff` and `claude-plugins` up front.
- Then the bash/Python split per `plans/2026-07-31-python-rewrite-brief.md`.
- Retire memory facts for index headroom: `MEMORY.md` is at 98% of its loader
  budget, so any new entry pushes the tail out of reach. Record the
  `claude --resume` finding in `ddaanet/reference_stale_plugin_code` in the same
  pass.
- Implement gitlore's stale-plugin-root detector per
  `docs/plans/2026-07-31-14-stale-plugin-root-notice.md`, red bats first.
- Add handoff's `restart` transition kind per `brief-driven-restart.md`,
  including the `SessionEnd` marker hook and a `SessionStart(resume)` matcher —
  the drift work's matcher-less `SessionStart` entry already covers `resume`.
- Probe what `reason` an interactive `/exit` writes to `SessionEnd`.
- Patch `handoff-checkpoint`'s gitlore diagnosis into its three real cases, with
  the relaunch as the remedy.
- Rewrite gitlore's bats negatives per `brief-test-suite-negatives-rewrite.md`,
  and report where the paired-structure rule does not hold.
- Add guardrails against snake_case and `name:`/filename drift, then normalise
  every memory `name:` and cross-link to kebab-case. The link parser must skip
  fenced code, or it will rewrite bash `[[ "$output" == ... ]]` conditionals;
  roughly two dozen links currently dangle, split between dropped type prefixes
  and cross-store targets that may legitimately live in another repo.
- Explain the live pointer loss for gitlore's own memory store.
- Place or apply the remaining root-level briefs — `brief-driven-restart.md` and
  `brief-stale-config-after-mid-session-upgrade.md` — in their target repos.
- Migrate the `micro` tier (~40 facts) once a real memory remote is settled; it
  and `general` still point at a local `./.git/gitlore-placeholder`. Then
  `gitmoji` → `general` → `home` → `devddaanet` → `skills` → `candidature` →
  `edify` → `Emploi` → `cwd-safety`.