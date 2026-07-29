# Consolidation pass: shared preamble, detach, watcher scaffold (2026-07-20)

A four-angle review (reuse / simplification / efficiency / altitude) of the
whole plugin converged on the same three duplications, all the same species:
shared logic that predated the helper that should hold it. No behavior change.

- The five path-scoped hooks opened with the same six-line match sequence
  (field parse → basename filter → root resolution → resolve-pair → compare).
  That sequence is the cross-project security boundary, and five copies meant
  a missed edit is a silent guard bypass. Now `handoff_match_target()` in
  `_lib.sh`, with rc 2 ("basename matched, resolved elsewhere") kept distinct
  because `write-guard.sh` denies on it while everyone else passes through.
- The setsid-else-nohup detach block lived in triplicate; now
  `handoff_spawn_detached()`. The portability invariant (setsid Linux-only)
  is stated once.
- The three watchers each carried a byte-identical copy of the tunables,
  `snap()`, and the stable-idle poll loop — in the exact file family whose
  shared lib (`_rename-lib.sh`) existed to prevent that. The drift had
  already begun: the visible-pane-only invariant (2026-07-19 spike) was
  commented in two copies and absent from the third. `snap`, `wait_for_idle`
  and `submit_or_fail` now live in the lib; each watcher keeps only its
  distinct middle. The tunable overrides renamed `AUTONAME_*` →
  `HANDOFF_WATCHER_*` (they gate all three watchers, not the rename).

One efficiency fix rode along: `handoff_root()` short-circuits in bash when
the cwd is empty or already the project root — a strict subset of
`worktree_root.py`'s own trivial branches, so output is identical. Stop and
UserPromptSubmit call it every turn before their real gates, so the common
case no longer pays a python3 startup. The fast path must stay a subset of
the resolver's semantics; a bats test pins it by hiding python3.

Considered and declined: merging the three PostToolUse(Write|Edit) scripts
into one dispatcher to cut two jq spawns per write. It trades the
one-script-per-concern hook layout for a modest saving; the shared preamble
already removed the duplication that made it tempting.
