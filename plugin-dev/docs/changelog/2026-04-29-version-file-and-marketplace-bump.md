# 2026-04-29 — The toolkit learned to identify itself, and release started bumping the marketplace (v0.2.0)

Three changes shipped together.

**`VERSION` file + self-release recipe.** The toolkit had no way to
self-identify from inside a consumer's subtree, because tags don't propagate
through `git subtree`. Added a plain-text `VERSION` at the repo root and a local
`release` recipe in this repo's `justfile` that bumps `VERSION`, tags, and
pushes — with the same manifest-vs-tag mismatch guard as the consumer recipe,
applied to `VERSION`. See "Toolkit version source of truth" in
[design.md](../design.md).

**Marketplace bump in `release.just`.** The consumer release recipe now also
bumps the corresponding entry in
`$MARKETPLACE_DIR/.claude-plugin/marketplace.json` and pushes that repo.
Pre-flight checks (env var set, file exists, entry exists, repo clean) run
before any destructive op. A tag without a marketplace bump is invisible to end
users, so treating them as one atomic release matches reality.

**`symbolic-ref` fix for default-branch detection.** See "Default branch
detection" in [design.md](../design.md).

Also added a hook-test for `version-guard.sh` under `tests/`.

Adoption: `handoff` migrated to the toolkit during this cycle (subtree-add
v0.2.0, ran `install.sh`, deleted its local `scripts/version-guard.sh` and
inline release recipe). `gitmoji` migration was in progress.

Next at the time: finish the `gitmoji` migration, then revisit the
standard-hooks-set question with two real consumers' `precommit` recipes side by
side.
