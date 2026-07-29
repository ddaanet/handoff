# Task — cut toolkit 0.5.0 and propagate

## Current task

`resume-release` is **done and merged**. `main` is at `c1f7e61` (merge commit,
`--no-ff`), 22 commits unpushed, tree clean, `just precommit` green. The feature
branch is deleted and the SDD workspace under `.superpowers/` is removed — this
file and the task list are now the record.

What shipped: `release.sh` (the whole consumer release flow, `patch|minor|major`
and `--resume`); `tests/release-test.sh` (offline harness, 12 scenarios, `gh`
stub, bare-repo origins, no network); `release.just` thinned to one-line
wrappers, with `resume-release` deliberately free of any `prerelease`
dependency; `docs/design.md`'s "Recovery" section; a changelog entry.

The whole-branch review found one Critical in the feature itself:
`bump_marketplace` decided "already done" from the staged diff (local) while
every sibling tail step asked the remote, so a marketplace commit whose push was
rejected made the next `--resume` skip the push and report the release complete
— a silent false success on the exact failure the feature exists to recover
from. Committing and pushing are now two questions with two probes.

## Remaining — by hand, not agent work

Network, `gh` auth, irreversible pushes across repos. Full detail in task #5.

1. `just release minor` for 0.5.0. This repo is **not** a plugin — its
   self-release recipe reads `VERSION`, not `plugin.json`.
2. `just update-plugin-dev v0.5.0` in handoff, gitmoji, gitlore. handoff and
   gitmoji each need `prerelease: precommit` added **in the same commit as the
   subtree pull**, or their justfiles fail to compile on arrival.
3. Verify in one consumer: `just check-version && just --list`.
4. Check consumer justfiles for multi-line recipe doc comments.

## Open decisions

None. Two review residuals are parked with rulings: the detached-HEAD
`mp_branch` edge (pre-existing shape, unreachable in the supported flow) and the
`assert_not_contains` helper (extract only if a third must-not-contain site
appears).
