# 2026-06-11 — The marketplace step stopped assuming the entry already exists (v0.2.1)

`release.just`'s marketplace step was made robust to the entry's pre-state.
First publication now creates the `marketplace.json` entry from `plugin.json`
(deriving the `github` source from `origin`) instead of aborting with "no entry
for '<name>'" — which had made the *first* release of any plugin impossible
through the recipe, exactly when the marketplace touch matters most.

The marketplace commit also became idempotent: a no-op rewrite (entry already
at the target version) is reported and skipped rather than failing the recipe
*after* the release already landed. Under `set -e` that failure surfaced as
`exit code 1` on a release that had actually succeeded.

See "Marketplace entry: bump if present, create on first publication" in
[design.md](../design.md). Closes `BUG-release-marketplace-noop-commit.md`.
