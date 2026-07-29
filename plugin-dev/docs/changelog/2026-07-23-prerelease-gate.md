# 2026-07-23 — `release` binds to a consumer-defined `prerelease` gate (v0.4.0, breaking)

`release` now depends on a consumer-defined `prerelease` recipe instead of
`precommit` directly, so a consumer whose release gate is bigger than its commit
gate can express that. Raised from `gitlore`, whose paid `evals` gate never ran
at release time: with `release` hardcoded to `precommit`, `just release` shipped
without it, and the workaround — remembering to type `just prerelease release` —
is discipline, not a gate.

**Every consumer must add `prerelease: precommit` to its justfile** when
adopting this tag. Without it, just rejects the whole justfile with `unknown
dependency prerelease`, so *every* recipe fails, `just precommit` included. That
blast radius is deliberate: it fires at update time, when the maintainer is
already in the justfile, and names the exact missing recipe.

`_import-check` now tests three stub shapes — plain (`prerelease: precommit`),
widened (`prerelease: precommit evals`), and missing — asserting via `--dry-run`
that `release` resolves to the right gate chain in the first two and that the
third fails with an error naming `prerelease`. Verified against just 1.46.0.

See "Release gate: `release` depends on `prerelease`" in
[design.md](../design.md) for the rejected alternatives, notably the private
`_release-gate` override that would have required
`set allow-duplicate-recipes := true` repo-wide.
