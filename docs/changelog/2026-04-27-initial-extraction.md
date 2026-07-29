# 2026-04-27 — The toolkit was extracted from handoff and gitmoji (v0.1.0)

Broken out of `handoff/scripts/version-guard.sh` and the inline release recipes
in `handoff/justfile` and `gitmoji/justfile`. The two recipes were unified:
commit-message format settled on `release: X`, dynamic default-branch detection
came from edify, and a manifest-vs-tag mismatch guard was added during the work.

Neither consumer had adopted the toolkit yet — handoff's `0.2.0` release was
postponed pending migration.

Next at the time: migrate `handoff` to consume the toolkit (subtree-add, run
`install.sh`, delete its local `scripts/version-guard.sh` and inline release
recipe), then `gitmoji`. After that, evaluate whether to absorb a small
standard-hooks set (shellcheck, trailing-whitespace) for consumer plugins, or
leave each consumer to define its own `precommit` shape.
