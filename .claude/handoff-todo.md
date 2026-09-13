## Open decisions

- The version bump for the release carrying this work. `plugin.json` is at
  0.13.1 with `v0.13.1` tagged, and the tagged-union work, the
  apply-before-mutate restructure and its four review minors are all
  unreleased. My recommendation is 0.14.0 — `CLAUDE.md` calls a payload-shape
  change breaking — against 0.13.2. The marketplace cache is keyed by version,
  so a push under an unchanged version reaches no installed repo. Raised in
  five sessions now and not answered.
- Where M3's residual slots into pass 2. A superfluous top-level payload key
  is silently ignored — a payload carrying `tasks` beside a well-formed `task`
  and `todo` exits 0 — while a *misspelled* required key still exits 2, since
  both are required by key presence. The action-object half of M3 is fixed and
  has four table rows; no frozen document defers the top-level half and no
  list carries it. A fix touches `read_payload` or a check in `main` after
  `validate_skill` (the legal key set is skill-dependent, and the four
  forbidden-field validators already encode part of it), plus one row per
  skill.
- Whether to run the shared `memory/MEMORY.md` compaction. `/gitlore:index-audit`
  is the pass. Blocked on an explicit go-ahead, since it rewrites the index
  every ddaanet repo loads. Eleven memory writes are queued behind it.
- Whether `skills/handoff/SKILL.md` should be trimmed back under the ≤2000-word
  guideline in `CLAUDE.md`. It is 2186 words; the overrun predates both the
  M2/m13 paragraph and m14's FR6 sentence.

## Remaining

- m12 is smaller than it reads: the C1 restructure deleted two of its three
  `D2`/`D3` citations outright, so only `tests/test_checkpoint.py:603`'s
  docstring is left, and `D2` is defined only in the 2026-09-04 runbook.
- Pass 2, cosmetic — one editing pass: m10 (jq `test()` regex on dotted paths
  in `checkpoint.bats`), m15 (`CLAUDE.md` narrating its own prior wording),
  m16 — now narrowed, with only the `keep` action leaving the list alone still
  an unclaimed behavioral row — m17 (the task-file location rule is asymmetric
  with the todo's), and m18, where closing it durably means a line in
  `docs/design.md` or a later changelog entry, since the 2026-09-07 entry
  itself is never edited.
- m4 stays out of scope, but scope the eventual `is_empty_body` pass to both
  its routes: a whitespace-only body, and any line beginning with `#` — a
  shebang line reads as empty and removes the file.
- P2 then P1, in that order. P2: codify the report-correction convention in
  `CLAUDE.md`'s `plans/` bullet — the form is `> **Corrected at review,
  <date>.**` quoting the original, naming what was wrong and showing the
  evidence, a sibling of the changelog's `> **Superseded <date>**`. Two
  instances await it: `reports/minors-fix.md` names a commit an amend
  replaced, and `reports/phase-2-corrector.md` used the form ad hoc. Only then
  P1: correct `phase-1-corrector.md:168-173` of the 2026-09-04 job, whose
  mutation does not reconstruct — as written it reds
  `test_handoff_root_unset_refuses` alone and leaves both tests it names
  green, while `root = str(Path.cwd())` unconditionally reds all three. Its
  conclusion holds; its evidence does not.
- Queued memory writes, all blocked on the index cap above: (1) a gitignored
  path on disk but never in the index exits 128 from `git add` with `did not
  match any files`, and `git ls-files` guards that silently where
  `--error-unmatch` writes to stderr; (2) the sandbox's phantom `git status`
  of `$HOME`-shaped dotfiles, which makes edify's `verify-step.sh` report
  DIRTY against a clean tree; (3) the write-then-mutate protocol for a slice
  whose red was consumed by an earlier slice, with the mutation matrix as its
  evidence; (4) the mutation-restore hazard in both its halves; (5) `set -e`
  does not fire on a failed command substitution inside a `[ ]` test, so a
  `-z` test wrapping one reads a failure as an empty result; (6) triage review
  findings by co-location, not severity, and a two-layer review's minor count
  is two reviewers' thresholds concatenated rather than one scale; (7)
  `$TMPDIR` is not stable across Bash calls in one session; (8) a mutation
  check must be validated against the fixture of the row it predicts will red;
  (9) a self-contradicting `Interfaces:` contract propagates verbatim into the
  docstring written from it and survives the code review that tabulated the
  very exception falsifying it; (10) a review finding can be closed with half
  of it standing, so audit a finding's status against the artifact it names —
  never against a later plan, report, changelog entry or commit message, each
  of which is a claim about the state rather than the state; (11) a hook's
  stderr on `exit 0` reaches neither audience — it lands on a `hook_success`
  transcript attachment with no `rendered` field — so a hook that wants its
  stdout JSON parsed has no channel but `systemMessage`/`additionalContext`,
  and the probe shape that shows it (a scratch `--settings` hook under a
  nested `claude --print --output-format stream-json --verbose`, markers read
  back out of the on-disk transcript JSONL). Briefed to craft
  at `inbox/brief-mutation-check-restore.md`; the ddaanet-tier facts are still
  owed. (11) also belongs in plugin-craft's `hook-authoring` skill, whose
  `references/output-channels.md` states the conclusion without the mechanism
  and flags its own stderr claim stale-suspect — that repo is read-only from
  here, so it is a proposal to make, not an edit.
