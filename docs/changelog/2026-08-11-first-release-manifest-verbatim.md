# 2026-08-11 — A first release publishes the manifest version as-is

Reported from `prohibitions`'s actual first release. `plugin.json` held
`0.1.0` and that was the version to publish, but `just release patch`
produces `0.1.1` — the manifest version is a bump *source*, so the version
the plugin was scaffolded with can never be the version it ships. The
workaround used at the time was to hand-create tag `v0.1.0` and run `just
resume-release`, which takes the manifest version verbatim and only needs
the tag to already exist locally.

The `0.1.0` seed does not come from this toolkit. It comes from the official
Anthropic `plugin-dev` marketplace plugin's `/plugin-dev:create-plugin`
scaffold — an unrelated project that happens to share a near-identical name
with this one. `install.sh` here only vendors the toolkit and wires up the
recipe and hook against an *existing* manifest, so there is no seed value to
fix at the source; any fix has to live on the `release.just` side. Every
plugin scaffolded by that toolkit and released by this one hits the same
conflict on its first release.

Fixed in `release_preflight`: when a plugin has never been released, `V`
becomes the manifest version rather than a bump forward from it, and
`bump_commit_tag` tags HEAD without rewriting or committing the manifest —
there is nothing to rewrite. An explicit bump argument in that state is
refused, with a hint naming the version that would be published.

"Never been released" is `git tag --list 'v*'` empty **and** no marketplace
entry. Both conjuncts were deliberate: no-tags alone misreads a repo whose
tags were lost or never fetched, and would republish over a version already
out there; no-entry alone misreads a plugin that is tagged but not yet
published, which `check-version.sh` already treats as the ordinary
pre-first-publication state. Both are covered by tests that must stay green
in the old bump-forward path.

`release.just`'s `release` recipe changed from `bump='patch'` to `bump=''`,
passing the argument through even when empty. The `patch` default moved into
`release.sh`. Without this the recipe would turn a bare `just release` into
an explicit `patch` before `release.sh` ever saw it, and the refusal would
leave a first release with no working invocation at all. Consumer-visible
behaviour on an already-released plugin is unchanged: `just release` still
means patch, `just release minor` still means minor.

An empirical check across the eight current consumers found all of them
tagged (4 to 31 tags each) with manifest versions matching their latest tag.
None was exposed; this is purely the new-plugin path.

Rejected: seeding consumers at `0.0.0` so `0.0.0` reads as "nothing
released" and a first release is `just release minor`. It leaves an
already-vendored, never-released plugin — the case that surfaced this —
still broken, and puts `install.sh` in the business of rewriting the field
the version-guard hook protects.

See "First release publishes the manifest version as-is" in
[design.md](../design.md).
