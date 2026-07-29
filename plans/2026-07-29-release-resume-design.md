# claude-plugin-dev — recovery path for a half-landed release — Design

**Date:** 2026-07-29
**Status:** Approved design, ready for implementation
**Scope:** Move the consumer release flow out of `release.just`'s recipe body
into a `release.sh` script, and add a `--resume` mode that completes a release
which landed only partially. Exposed to consumers as `just resume-release`.

## Problem

`release` is not atomic and cannot easily be made so. It bumps
`.claude-plugin/plugin.json`, commits, tags, `git push`, `git push origin
<tag>`, `gh release create`, and only then bumps
`$MARKETPLACE_DIR/.claude-plugin/marketplace.json` and pushes that repo.
Everything from the tag push onward is irreversible or outward-facing.

Observed live releasing `gitlore` 0.4.3 on 2026-07-28: `just release patch`
passed `prerelease` and `check-version`, bumped `plugin.json`, committed and
tagged — then `git push` was rejected by gitlore's own pre-push hook because a
shared memory tier had diverged from its remote. The recipe died there under
`set -e`, after the irreversible commit and tag but before the tag push.

The toolkit detects the resulting state and refuses to proceed, but nothing
completes it:

- `check-version.sh` compares `plugin.json` against the marketplace entry and
  exits 1. `release` runs it as a pre-flight and aborts. That guard is correct
  and stays.
- Re-running `just release <bump>` is blocked by that pre-flight, by design.
- Forcing past it bumps from the *manifest*, which is already at the new
  version, so it would ship the version after it — burning a version number and
  leaving the interrupted one permanently absent from the marketplace.
- Editing `marketplace.json` by hand clears `check-version` but then trips
  `release`'s clean-tree check on `$MARKETPLACE_DIR`. The bump has to be
  committed and pushed either way.

So the gap is that nothing satisfies the guard except hand-running the
remaining steps against another repo:

```
git push && git push origin v0.4.3 \
  && gh release create v0.4.3 --title "Release 0.4.3" --generate-notes
jq '(.plugins[]|select(.name=="gitlore")|.version)="0.4.3"' \
  "$MARKETPLACE_DIR/.claude-plugin/marketplace.json" > /tmp/mp.json \
  && mv /tmp/mp.json "$MARKETPLACE_DIR/.claude-plugin/marketplace.json" \
  && git -C "$MARKETPLACE_DIR" commit -am "release: gitlore 0.4.3" \
  && git -C "$MARKETPLACE_DIR" push
```

A secondary problem surfaces alongside it: the ~100 lines of bash in
`release.just`'s recipe body are not covered by `precommit`, which shellchecks
only the `.sh` files. The most delicate code in the toolkit is its least
checked, and it is the code a recovery path must share.

## Design

### Interface

`release.sh` joins `check-version.sh` in the toolkit and holds the whole flow.
`release.just` shrinks to thin wrappers:

```just
# Bump plugin.json, commit, tag, push, GitHub release, bump marketplace.
release bump='patch': prerelease
    bash "{{toolkit_prefix}}/release.sh" "{{bump}}"

# Complete a release that landed only partially. Idempotent.
resume-release:
    bash "{{toolkit_prefix}}/release.sh" --resume
```

`resume-release` deliberately does **not** depend on `prerelease`. The code
being released is already committed and tagged; the gate ran when the release
started. Re-running a consumer's slow or paid checks (gitlore's `evals`) merely
to push a tag would make the recovery path expensive enough to route around,
which is how the original problem was reached.

`release.sh` locates its siblings via `BASH_SOURCE` the way `check-version.sh`
does, and runs with the plugin root as cwd.

### Structure

Three blocks, two entry paths through them.

**Common pre-flight** (both modes), unchanged in substance from today's recipe:
`.claude-plugin/plugin.json` exists; clean tree; on the default branch
(`symbolic-ref` on `refs/remotes/origin/HEAD`, `main` fallback);
`MARKETPLACE_DIR` set and its `marketplace.json` present; marketplace repo
clean; entry-exists probe, and when the entry is absent, an `origin` remote to
derive the `github` source from.

**Release-only pre-flight:** `check-version.sh`; manifest-vs-latest-tag match;
the computed tag must not already exist. Then write the manifest, `git add`,
`git commit -m "release: $V"`, `git tag -a`. Falls into the tail with
`V = new_version`.

**Resume-only pre-flight:** `V` is the manifest's current `.version`. The local
tag `v$V` must exist; if it does not, no release was ever started at that
version and the script refuses rather than inventing a tag:

```
error: no tag v0.4.3 for plugin.json version 0.4.3
hint: no release was started at this version.
      run `just release <bump>` instead.
```

This keeps resume from tagging an unrelated commit — the realistic hazard being
a repo where further work landed on top of a failed release. The narrow window
where `git commit` succeeded but `git tag` failed is not covered; it is
recovered by tagging by hand and re-running resume.

### The tail

Shared by both modes, idempotent, one report line per step:

| step | state probe | action when missing |
|---|---|---|
| branch pushed | `git ls-remote origin refs/heads/$branch` vs `HEAD` | `git push` |
| tag pushed | `git ls-remote origin refs/tags/$tag` vs `git rev-parse $tag` | `git push origin $tag` |
| GitHub release | `gh release view $tag` | `gh release create $tag --title "Release $V" --generate-notes` |
| marketplace | entry `.version` vs `$V` | bump-or-create entry, commit, push |

Probes use `ls-remote` and `gh release view` rather than remote-tracking refs,
so the answer is authoritative without requiring a prior `git fetch`.

A remote tag that exists but points at a *different* sha is an error, never a
force-push: it means the tag was moved or reused, which no recovery should
paper over.

The marketplace step keeps both of today's branches (bump an existing entry;
synthesise one from `plugin.json` plus the `origin`-derived repo slug on first
publication) and its existing idempotent-commit check.

When resume finds every step already done it reports `release v$V is already
complete (nothing to do)` and exits 0. Running it against a healthy repo is a
no-op that says so, not an error.

`release` mode's `check-version` failure message gains a line naming
`just resume-release`, so the guard that detects the drift now points at the
tool that fixes it.

## Consumer impact

Non-breaking, unlike v0.4.0. Recipe names and signatures are unchanged,
`resume-release` is additive, and no consumer justfile edit is required — a
plain `just update-plugin-dev v0.5.0` suffices. The toolkit takes a minor bump.

Consumers that have not yet adopted v0.4.0 (`handoff`, `gitmoji`, which still
need `prerelease: precommit`) should pull this release instead, taking both
changes in one subtree pull and one justfile edit.

## Testing

New `tests/release-test.sh`, wired into `precommit` alongside `bash -n` and
`shellcheck` coverage for `release.sh` — coverage the recipe body never had.
Expect a few shellcheck findings to fix during the move.

Harness, entirely offline: a bare `origin.git` plus a plugin clone with the
toolkit copied into `plugin-dev/` (so `BASH_SOURCE` resolution matches a real
consumer's vendored layout), a bare marketplace origin plus a marketplace
clone, and a `gh` stub on `PATH` that records its invocations and answers
`release view` from a marker file `release create` writes. A rejected push is
simulated with a `pre-push` hook that exits 1 — the gitlore failure exactly.

Scenarios:

1. Happy path: `release.sh patch` bumps, commits, tags, pushes both, creates the
   GitHub release, bumps the marketplace.
2. Push rejected mid-release, hook removed, `--resume` completes the remaining
   steps.
3. `--resume` on a healthy repo reports nothing to do and exits 0.
4. `--resume` with no local tag for the manifest version exits 1 naming the tag.
5. First publication: no marketplace entry, entry is created from `plugin.json`
   and the `origin` slug.

`_import-check` keeps its three stub shapes (plain, widened, missing
`prerelease`) and gains an assertion that `resume-release` resolves.

## Documentation

`docs/design.md` gains one section, "Recovery: `resume-release` and the shared
release tail", covering both halves of this change: why a recovery path exists
at all, and why the flow moved out of the recipe body (shellcheck coverage,
offline testability, no just/bash quoting seam). The Limitations list is
revisited — the "release is not atomic" reality stays, but its consequence is
now recoverable.

A write-time record goes to `docs/changelog/<release-date>-resume-release.md`
with a pointer line at the top of `docs/changelog.md`.

`brief-half-landed-release-recovery.md` at the repo root is superseded by this
spec and is deleted when the work lands.

## Out of scope

- **This repo's own self-release recipe stays bespoke.** The `release` recipe in
  the toolkit's local `justfile` has the same tail minus the marketplace step,
  and it failed in the same window once (`v0.4.1` has a `VERSION` bump commit
  and no tag). It is not folded into `release.sh`: resuming it by hand is a tag
  and a `gh release create`, which the toolkit's sole maintainer can do, whereas
  `resume-release` exists as a convenience for consumers. Folding it in would
  also make the toolkit consume its own consumer-shaped code, which the "Don't
  run `release.just`'s recipes from this repo" rule exists to prevent.
- Making `release` atomic. The tag push and `gh release create` are
  outward-facing; the design accepts partial landing and makes it recoverable.
- Rolling a release *back*. Recovery only ever moves forward to the version
  already committed.
- Hybrid Python+plugin repos (`edify`), unchanged from docs/design.md's Limitations.
