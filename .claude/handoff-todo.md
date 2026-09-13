## Open decisions

- Whether `skills/handoff/SKILL.md` should be trimmed back under the ≤2000-word
  guideline in `CLAUDE.md`. It is 2213 words; the overrun predates both the
  M2/m13 paragraph and m14's FR6 sentence, and m17's two lines added to it.

## Remaining

- M3's residual: a superfluous top-level payload key is silently ignored — a
  payload carrying `tasks` beside a well-formed `task` and `todo` exits 0 —
  while a *misspelled* required key still exits 2, since both are required by
  key presence. A fix touches `read_payload` or a check in `main` after
  `validate_skill` (the legal key set is skill-dependent, and the four
  forbidden-field validators already encode part of it), plus one row per
  skill.
- m4's two routes into `is_empty_body`, no longer out of scope — the marker
  came from the 2026-09-04 outline and died with that job: a whitespace-only
  body writes a 3-byte file that passes `load-handoff.sh`'s non-empty gate,
  and any line beginning with `#` — a shebang, not only a heading — reads as
  empty and removes the file.
- Review and write the eleven learnings still owed as memory facts: (1) a
  gitignored path on disk but never in the index exits 128 from `git add` with
  `did not match any files`, and `git ls-files` guards that silently where
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
  back out of the on-disk transcript JSONL). Briefed to craft at
  `inbox/brief-mutation-check-restore.md`; the ddaanet-tier facts are still
  owed. (11) also belongs in plugin-craft's `hook-authoring` skill, whose
  `references/output-channels.md` states the conclusion without the mechanism
  and flags its own stderr claim stale-suspect — that repo is read-only from
  here, so it is a proposal to make, not an edit.
