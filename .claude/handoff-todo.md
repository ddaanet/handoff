## Open decisions

- Whether to run the shared `memory/MEMORY.md` compaction. The index measures
  ~24.5KB against a 25600-byte budget, past the point where Claude Code's
  loader silently drops the tail, so an entry appended at the end would be
  invisible. `/gitlore:index-audit` is the pass for it — measure against the
  loader cap, relocate, retire or merge entries, then audit the diff for lost
  routing. Blocked on an explicit go-ahead, since it rewrites the index every
  ddaanet repo loads. Two memory writes are queued behind it, both below.
- The version bump for the release carrying this fix. The marketplace cache is
  keyed by version, so a push under an unchanged version reaches no installed
  repo and `/plugin update` re-fetches nothing. "No bump" is not among the
  outcomes that deliver the fix; the call is my human partner's.

## Remaining

- Resume `/orchestrate` at Phase 1, Item 1.1, slice 1. That slice must also
  delete the `[[tool.mypy.overrides]]` block in `pyproject.toml`: it exists
  only because `task_clear()`/`todo_keep()` currently return `None`, and
  flipping them to dicts makes it dead config. The block's own comment names
  Item 1.1 as its removal trigger, and Item 1.1 carries the list revision.
- Phases 2-4 after it, all `inline` items: `scripts/bash-post.sh`'s stage
  guard and failure channel; both wrap-up SKILL.md bodies; the design record
  (`docs/design.md`, the changelog entry and its index line, `CLAUDE.md`).
- Close the run with the `edify:tdd-auditor` dispatch over every slice's
  reports, then `/deliverable-review
  plans/2026-09-04-checkpoint-null-no-task-file` in a fresh opus session.
- Once Item 1.1 lands, `/handoff` and `/handoff:precompact` fail in any
  session whose skill bodies predate it — the bodies snapshot at session
  start while `checkpoint.py` goes live the moment it is written. The remedy
  is `/handoff:restart`, or `/reload-plugins` for the bodies alone.
- Use `git status --porcelain` plus `just precommit` directly rather than
  edify's `skills/orchestrate/scripts/verify-step.sh`: in this sandbox its
  clean-tree check intermittently reports a phantom tree of `$HOME`-shaped
  dotfiles (`.bashrc`, `.claude/agents`, ...) that do not exist on disk, and
  so returns DIRTY against a clean tree.
- Write the `git add` guard fact to memory once the index has room: a
  gitignored path on disk but never in the index exits 128 with `did not
  match any files`, and `git ls-files` guards that silently where
  `--error-unmatch` writes to stderr and would defeat the redirect removal it
  guards for. Verified against real git.
- Write the sandbox phantom-`git status` observation to memory too, blocked on
  the same index cap: inside the Bash sandbox, `git status --porcelain`
  intermittently lists `$HOME`-shaped dotfiles as untracked in an unrelated
  repo, so any clean-tree gate built on it yields false DIRTY verdicts.
