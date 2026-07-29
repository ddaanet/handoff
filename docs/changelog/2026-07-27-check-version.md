# 2026-07-27 — `check-version.sh` catches a release that tagged but never bumped the marketplace (v0.4.1, v0.4.2)

`release`'s marketplace step runs *after* `plugin.json` is bumped, committed,
tagged, pushed, and the GitHub release created. If anything from `gh release
create` onward fails, the plugin is left tagged and pushed at the new version
while `marketplace.json` is still at the old one — invisible to end users, and
nothing in the toolkit detected it: the pre-flight in `release` only compared
`plugin.json` against the latest tag, and the version-guard hook only fires on
edits to `plugin.json`.

`check-version.sh` compares `plugin.json`'s `.version` against the consumer's
entry in `$MARKETPLACE_DIR/.claude-plugin/marketplace.json`. It is exposed as a
`just check-version` recipe and runs automatically as a `release` pre-flight, so
a new release refuses to start on top of a drifted marketplace.

Absorbed from a gitlore-local script (which had motivated the `prerelease` gate)
with two fixes: the plugin name is read from `plugin.json` instead of hardcoded,
and the marketplace path comes from `$MARKETPLACE_DIR` rather than an assumed
`../claude-plugins` sibling. A missing marketplace entry is treated as
pre-first-publication state (skip), not drift (fail), consistent with how
`release.just`'s marketplace step treats a missing entry.

See "`check-version.sh`: catching a partially-completed release" in
[design.md](../design.md).

Note: `v0.4.1` was released without a tag ever reaching the remote — the
toolkit's own half-landed release, and the same failure shape this check
detects in consumers.
