## Remaining

- Confirm in a fresh session that `@memory/ddaanet/shared-claude.md` appears in
  the `claudeMd` block — the only proof the import resolved.
- Fix `shared-claude.md`'s own contradiction in the `ddaanet` tier: it forbids
  naming the user in anything the agent authors, then says "get David's call".
  Six repos load that file, so the fix belongs at the tier and needs a push.
- Review and approve the transitions-become-modes spec, then plan pass 2.
- Explain how a session's root pointer comes to name a repo none of that
  session's other hooks resolve to, and decide what the checkpoint should do
  about it beyond refusing.
- Release the context-size threshold trigger (minor bump), then keep watching
  whether a nudge is ever ignored outright — that is the evidence that reopens
  the halt — and whether the main transcript carries a subagent `usage` entry.
- Split bash/Python per `plans/2026-07-31-python-rewrite-brief.md`.
- Retire memory facts for index headroom. No longer blocking — the root index
  loads whole again — but it sits close enough to the cap that the next few
  additions will crowd it.
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