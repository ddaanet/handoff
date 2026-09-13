## Open decisions

- The version bump for the release carrying this work. `plugin.json` is at
  0.13.1 with `v0.13.1` tagged, and both the tagged-union work and the
  apply-before-mutate restructure are unreleased. My recommendation is 0.14.0 —
  `CLAUDE.md` calls a payload-shape change breaking — against 0.13.2. The
  marketplace cache is keyed by version, so a push under an unchanged version
  reaches no installed repo. Raised in four sessions now and not answered.
- Whether to run the shared `memory/MEMORY.md` compaction. `/gitlore:index-audit`
  is the pass. The index was not injected into this session's context either —
  every recall gate ran against store filenames instead — which is the symptom
  that pass exists for. Blocked on an explicit go-ahead, since it rewrites the
  index every ddaanet repo loads. Nine memory writes are queued behind it.
- Whether `skills/handoff/SKILL.md` should be trimmed back under the ≤2000-word
  guideline in `CLAUDE.md`. It is 2152 words; the overrun predates the M2/m13
  paragraph.

## Remaining

- `/deliverable-review plans/2026-09-08-apply-before-mutate` in a fresh session
  on opus — the follow-up `/orchestrate` prescribes. Its two open threads from
  the TDD audit: nothing in the pipeline checks a docstring's claim against the
  code unless it names a retired symbol, and the runbook's own `Interfaces:`
  bullet contradicted the same item's `keep` instruction.
- Pass 2, substantive — m5 (a handoff root that is not a git repository now
  reports `failed to stage` on both channels at every checkpoint, plus git's raw
  `fatal:` on stderr; one `git rev-parse --git-dir` separates the whole-run case,
  and none of the nine `bash-post` rows covers it). Settle m6 first: if a
  PostToolUse hook's stderr never reaches the user outside debug mode, m5 shrinks
  to transcript noise and `bash-post.sh:77-78`'s comment needs downgrading to
  what is demonstrated. Then m7 (`bash-post.sh` consumes the manifest even when
  every path failed), m12 (`D2` in `tests/test_checkpoint.py` is the one
  remaining live citation that resolves nowhere in `docs/design.md`), m14 (FR6's
  empty-body removal is stated in neither skill body).
- Pass 2, cosmetic — one editing pass: m10 (jq `test()` regex on dotted paths in
  `checkpoint.bats`), m15 (CLAUDE.md narrating its own prior wording), m16
  (CLAUDE.md lists the union's rejection rows but none of its behavioral ones),
  m17 (the task-file location rule is asymmetric with the todo's), m18 (the
  changelog names one of two routes). m3 was subsumed by C1's restructure. m4
  stays explicitly out of scope.
- P2 then P1, in that order. P2: codify the report-correction convention in
  `CLAUDE.md`'s `plans/` bullet — the form is `> **Corrected at review, <date>.**`
  quoting the original, naming what was wrong and showing the evidence, a sibling
  of the changelog's `> **Superseded <date>**`. This session used that form ad hoc
  in `reports/phase-2-corrector.md`; the bullet is still unwritten. Only then P1:
  correct `phase-1-corrector.md:168-173` **of the 2026-09-04 job**, whose mutation
  does not reconstruct — as written it reds `test_handoff_root_unset_refuses`
  alone and leaves both tests it names green, while `root = str(Path.cwd())`
  unconditionally reds all three. Its conclusion holds; its evidence does not.
- Queued memory writes, all blocked on the index cap above: (1) a gitignored path
  on disk but never in the index exits 128 from `git add` with `did not match any
  files`, and `git ls-files` guards that silently where `--error-unmatch` writes
  to stderr; (2) the sandbox's phantom `git status` of `$HOME`-shaped dotfiles,
  which makes edify's `verify-step.sh` report DIRTY against a clean tree — hit
  again this session at every post-item verification, worked around with
  `git status --porcelain && just precommit` as one compound command; (3) the
  write-then-mutate protocol for a slice whose red was consumed by an earlier
  slice, with the mutation matrix as its evidence; (4) the mutation-restore hazard
  in both its halves; (5) `set -e` does not fire on a failed command substitution
  inside a `[ ]` test, so `[ -z "$(cmd)" ]` reads a failure as an empty result;
  (6) triage review findings by co-location, not severity, and a two-layer
  review's minor count is two reviewers' thresholds concatenated rather than one
  scale; (7) `$TMPDIR` is not stable across Bash calls in one session — set for
  the call that writes a backup, empty for the call that reads it — which is the
  dangerous half of (4), since the mutation runs and the restore route is gone;
  (8) a mutation check must be validated against the fixture of the row it
  predicts will red — a row whose fixture satisfies the guard either way stays
  green under the mutation, so the check gets recorded as evidence while proving
  nothing; (9) a self-contradicting `Interfaces:` contract propagates verbatim
  into the docstring written from it and survives the code review that tabulated
  the very exception falsifying it — no gate checks a docstring's claim against
  code unless it names a retired symbol, so the catch is accidental. Briefed to
  craft at `inbox/brief-mutation-check-restore.md`; the ddaanet-tier facts are
  still owed.
