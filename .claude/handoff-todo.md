## Remaining

- Design pass on the context-size threshold trigger per
  `brief-context-threshold-trigger.md`.
- Split bash/Python per `plans/2026-07-31-python-rewrite-brief.md`.
- Retire memory facts for index headroom: the root index is at 104% of its
  loader budget, so the tail is already out of reach.
- Apply `brief-merge-dispatch-authorization.md` in gitlore: its merge directive
  should state that the dispatch is authorized, so an agent bound by a blanket
  no-unsolicited-dispatch rule can act on it without a round trip.
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