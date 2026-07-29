# claude-plugin-dev — Design

Living design document. Updated when meaningful design decisions land
or get overturned. Not a changelog of features — a record of *why this
project has the shape it has*.

## Motivation

Several Claude Code plugins under the same author (currently `handoff`
and `gitmoji`; eventually more) need the same release infrastructure:
a `just release` recipe that bumps `.claude-plugin/plugin.json`,
commits, tags, pushes, and creates a GitHub release. Each plugin had
diverged on small details (commit message format, interactive vs.
non-interactive confirmation, branch detection), and a real bug landed
when an agent edited `plugin.json` directly during development —
caught only when the release recipe failed days later.

Two problems stacked:

1. **Drift.** Three near-identical recipes maintained independently.
   A fix in one didn't propagate.
2. **Missing guardrails.** The release recipe is the canonical version
   bumper, but nothing stopped an agent from manually editing
   `plugin.json`. The fact-of-the-mismatch was only discoverable at
   release time.

Both problems want the same answer: a single source of truth for
release infra, vendored into each consumer plugin and enforced via a
`PreToolUse` hook on `plugin.json`.

The toolkit captures: the unified release recipe, the version-guard
hook, and a one-shot install script. Vendored via `git subtree` so the
content is versioned with each consumer.

## Requirements

- Provide a `release` recipe that handles bump → commit → tag → push
  → GitHub release for any plugin whose manifest is at
  `.claude-plugin/plugin.json`.
- Provide a `PreToolUse(Write|Edit)` hook that refuses agent edits to
  `.claude-plugin/plugin.json`'s `.version`.
- Provide a one-shot installer that vendors the toolkit and wires it
  into the consumer's `justfile` and `.claude/settings.json`.
- **Reproducibility:** old consumer-plugin tags must build identically
  to when they were tagged — the toolkit content vendored at the time
  must be retrievable, not subject to drift.
- **Portability:** fresh clones of a consumer plugin must work without
  any contributor-side dotfiles, system config, or central
  installation. CI must be able to run the recipe with no setup.
- **Fail-fast:** misconfigured invocations (missing manifest, dirty
  tree, version desync) abort with actionable errors before any
  destructive or slow operation.
- **Idempotent install:** re-running `install.sh` with everything
  already wired is a no-op.
- **Self-hosting quality:** the toolkit's own scripts pass the same
  kind of checks (`bash -n`, `shellcheck`) it implicitly recommends
  for consumers.

## Design decisions

### Distribution: git subtree, vendored at `plugin-dev/`

The toolkit content lives in each consumer plugin as committed files
under `plugin-dev/`, brought in via `git subtree add` at a tagged
release.

Alternatives rejected:

- **A Claude Code plugin published in the marketplace.** Wrong
  audience: a Claude Code plugin extends end-users' sessions during
  *their* work, while the toolkit extends maintainers' sessions during
  *plugin development*. Same hooks API, totally different lifecycle
  and install destination.
- **Git submodule.** Pointer-vs-content split causes workflow friction
  — fresh clones need `--recurse-submodules`, CI needs an extra init
  step, the parent repo's working tree shows pointer changes that
  disorient agents. Subtree gives "just files" semantics.
- **User-level dotfiles + `just import` from `~/.config/...`.**
  Rejected because release infra must be versioned with the repo so
  CI, fresh clones, and old tags all reproduce. Dotfiles would
  introduce a contributor-side dependency that breaks any of those.
- **Manual copy / vendoring without subtree.** Drift inevitable; no
  command for "pull updates from upstream."

`--squash` is used on both `subtree add` and `subtree pull` so the
consumer's git log isn't polluted with the toolkit's history. The
trade-off is harder push-upstream, but the toolkit-to-consumer flow is
one-directional in practice.

**Never hand-edit the vendored copy in a consumer.** The files under a
consumer's `plugin-dev/` are subtree-managed content owned by this
repo. To change what a consumer vendors, edit the source *here*, cut a
tagged toolkit release, then propagate into each consumer with `just
update-plugin-dev vX.Y.Z` (which runs `git subtree pull`). Editing
`<consumer>/plugin-dev/*` directly reintroduces exactly the drift the
subtree model exists to prevent: the consumer's copy silently diverges
from every other consumer and from the tagged source, and the next
`subtree pull` will conflict. The single source of truth is
`ddaanet/claude-plugin-dev` at a tag — nowhere else.

### Versioning: tags only, never `HEAD`

`install.sh` and `update-plugin-dev` both expect a ref like `v0.2.0`.
Branch refs (`main`, `master`, `HEAD`) are warned against.

Reasoning: the toolkit's whole purpose is release discipline. It would
be inconsistent to ship that infrastructure with no version discipline
of its own. More concretely:

- A consumer-plugin checkout at an old tag must give the *exact*
  toolkit content vendored at the time. Tracking `main` makes the
  subtree's effective version a function of "when did I last pull,"
  which is unrecoverable.
- Bisection across toolkit changes only works if there are stable
  refs to bisect over.
- Forced reflection at toolkit-release time — same discipline the
  toolkit imposes on consumers.

### Separate repository, not part of any plugin

The toolkit lives at `ddaanet/claude-plugin-dev`, separate from the
plugins that consume it.

Pairs with `ddaanet/claude-plugins` (the marketplace) as a coherent
naming set: `claude-plugins` is what gets shipped to users;
`claude-plugin-dev` is what the maintainer uses to ship them.

Embedding the toolkit inside any single consumer would couple the
toolkit's release cadence to that plugin's, and make subtree-pull's
canonical URL ambiguous.

### Single `install.sh` handles bootstrap and wire

`install.sh` does three things in one invocation: `git subtree add`
the toolkit (if not already present), inject the `import` line into
the consumer's `justfile`, and add the version-guard hook to
`.claude/settings.json`.

Earlier draft: split into a separate "vendor" step (manual `git
subtree add`) and a vendored "wire" step (`bash plugin-dev/install.sh`
post-vendor). Rejected — the bootstrap loop ("you can't run
`plugin-dev/install.sh` until `plugin-dev/` exists") is solved by
making the script self-aware of which phase it's in. One step is
worth more than the conceptual purity of separation.

`curl … | bash` is *not* the recommended bootstrap path. The README
points to `git clone --depth 1 -b vX.Y.Z … /tmp/cpd` followed by
`bash /tmp/cpd/install.sh vX.Y.Z`, so the script can be inspected
before execution.

### Run-in-target invocation pattern

`install.sh` reads `$PWD` as the target plugin. The alternative —
taking a target path as argument — was rejected for ergonomics
(matches `pre-commit install`, `npm init`, etc.). The magic-cwd risk
is contained by an early guard: the script aborts if the cwd doesn't
contain `.claude-plugin/plugin.json`.

### Dual-channel hook output

`version-guard.sh` emits two distinct fields when denying an edit:

- `permissionDecisionReason` — verbose, agent-facing. Names the
  legitimate path (`just release …`), forbids workarounds, no escape
  hatches the agent can self-authorise.
- `systemMessage` — one short line, human-facing. Surfaces *that* a
  block happened, not *why* in detail.

This split exists because agents read instructions literally. A
diagnostic message intended for human eyes that says "if you really
need to bypass this, run X" gets parsed as a green light to run X.
The agent channel is therefore worded as unconditional refusal with
redirect; the human channel is curt and informative.

The Edit branch parses `tool_input.new_string` with grep+sed (not
jq), because `new_string` is a fragment, not a full JSON document.
The Write branch uses jq because `tool_input.content` is the full
file.

### Toolkit version source of truth: `VERSION` file (not tags only)

The toolkit ships a plain-text `VERSION` file at the repo root, bumped
by the self-release recipe in lockstep with the git tag.

Tag-only SOT was the obvious first choice — the toolkit has no
`plugin.json`, and tags already encode releases. It was rejected
because the toolkit is consumed via `git subtree`, and **tags don't
propagate through subtree pulls**. A consumer's vendored
`plugin-dev/` directory is "just files," with no way to ask "what
version is this?" from inside the consumer's checkout.

Concrete consequences without `VERSION`:

- Consumers had to hand-maintain a version string in their
  `CLAUDE.md` to remember what they vendored — drift inevitable.
- `update-plugin-dev vX.Y.Z` had no way to verify the subtree pull
  actually applied (a half-applied pull, e.g. with merge conflicts,
  could leave older content in place silently).
- The toolkit's own `install.sh` and scripts couldn't self-identify
  without `git describe`, which fails on subtree-vendored copies.

`VERSION` solves all three: `cat plugin-dev/VERSION` is the
authoritative answer inside any consumer; `update-plugin-dev` can
warn on mismatch; toolkit scripts can read their own version from
disk.

The cost is one line in the self-release recipe (write VERSION before
the commit) and the discipline of bumping it together with the tag —
the same invariant the consumer release recipe enforces on
`plugin.json`. Submodules and packages would have made this moot,
but those were rejected for other reasons (see "Distribution").

### Manifest version represents the *last released* version

`plugin.json`'s `.version` field reflects whatever was last tagged.
The release recipe bumps from there: `0.1.1 → 0.2.0` etc.

This is the invariant the version-guard hook protects. It's also
checked by the release recipe itself: if `plugin.json` and the latest
tag disagree, release aborts with guidance to revert the manual bump.

The bug that motivated the guard: an agent committed a version bump
inside a feature commit (intending it to land at the next release).
The release recipe, which bumps from current, would have produced the
*next* version after that — silently skipping the intended one.
Caught at release time when the recipe's tag mismatch happened to
trigger a check; would have shipped wrong otherwise.

### Marketplace entry: bump if present, create on first publication

The release recipe's marketplace step handles both a plugin that already
has a `marketplace.json` entry and one being published for the first time:

- **Entry present** → rewrite its `.version` to the new version (the
  original behaviour).
- **Entry absent** → append a new entry synthesised from `plugin.json`
  (`name`, `description`, `author`, `repository`/`homepage`, `license`)
  plus a `github` `source` whose `repo` is derived from the plugin's
  `origin` remote (owner/repo, parsed from either the SSH or HTTPS URL).

Originally the recipe treated a missing entry as a fatal pre-flight error
(`no entry for '<name>'`). That made the *first* release of any plugin
impossible through the recipe — the maintainer had to hand-edit
`marketplace.json` first, then release. Since the recipe's whole premise
is that "a tag without a marketplace bump is invisible to end users,"
first publication is exactly when the marketplace touch matters most.
Creating the entry from the manifest closes that gap: one `just release`
publishes a brand-new plugin end to end.

`source` is the one field not present in `plugin.json`, so it's derived
from `origin` rather than the manifest. The recipe only targets
single-plugin GitHub-hosted repos (the consumer-plugin model), so a
`github` source with an owner/repo slug is always correct here; the
monorepo `git-subdir` sources (e.g. the skills bundle) are out of scope
and hand-maintained. The `origin`-remote requirement for new plugins is
validated in the pre-flight block, before any destructive op.

The commit is idempotent. When the rewrite produces no change — the entry
was pre-added at exactly the version being released — `git commit` would
exit non-zero under `set -e` and abort the recipe *after* the
irreversible commit/tag/push/`gh release create` had already run, leaving
the maintainer staring at `exit code 1` on a release that actually
succeeded. The step checks `git diff --cached --quiet` and skips the
commit when nothing changed.

That check answers "should I commit?" and *only* that. Whether to push is
a separate question with a separate probe: the marketplace repo's own
`HEAD` against its own `origin`, via `ls-remote` on its own branch. The
two were once one check, which meant a marketplace commit whose push was
rejected could never be recovered — the next run found nothing staged,
skipped the push along with the commit, and reported the release
complete. Idempotence has to be measured against the remote, not against
the working tree, or a recovery tool reports success on the state it
exists to repair.

### No interactive confirmation in `release`

The `release` recipe runs non-interactively. It does not prompt
`Release X? [y/N]` before committing/tagging/pushing, and there is no
`--yes` argument.

An earlier version prompted with `read -rp` and offered `--yes` as a
skip. Both were removed: `release` always executes behind Claude Code's
permission layer (or a human's own `just` invocation), which already
gates the command. The inner prompt re-asked the same question, and
`--yes` existed only to silence it in the common case where an outer
gate was present — i.e. almost always. Dropping both collapses a
double-confirmation into the single gate that matters.

Safety is unchanged: the pre-flight guards (dirty tree, wrong branch,
manifest/tag desync, marketplace pre-flight) still abort before any
destructive op. Only the interactive keystroke was removed.

The same applies to this repo's own self-release recipe (the `release`
in the local `justfile`): it too dropped its `read -rp` prompt and
`--yes` for the identical reason.

### Recipe naming: `precommit`, not `validate`

The consumer-defined commit gate is called `precommit`. `validate` was
considered but rejected:

- `validate` isn't an established convention — it shows up mostly in
  schema-validation contexts (k8s, terraform), not "the gate before a
  commit/release."
- `precommit` names the *moment* it should fire, matches the
  pre-commit ecosystem's vocabulary, and is already used in adjacent
  projects (e.g. `edify`).
- `release` reaching `precommit` reads naturally: "the same gates that
  pass for a commit must pass for a release."

That last point was an argument about what to *name* the commit gate, and
it predates a consumer whose release gate is bigger than its commit gate.
It is not an argument for `precommit` being the recipe `release` binds to
— `release` now depends on `prerelease` (next section), which for most
consumers is exactly `prerelease: precommit`.

### Release gate: `release` depends on `prerelease`

`release` depends on a consumer-defined `prerelease` recipe, not on
`precommit`. Consumers define both; the usual body is one line:

```just
prerelease: precommit
```

A consumer whose release gate is larger widens it there:

```just
prerelease: precommit evals
```

The motivating consumer is `gitlore`, which has a fast `precommit`
(check-version, lint, test) and a slow, paid `evals` gate that drives the
real `claude` CLI. With `release` hardcoded to `precommit`, `just release`
shipped without ever running the evals; the workaround — remembering to
type `just prerelease release` — is discipline, not a gate. A release
recipe that can be satisfied by remembering something is not a gate.

Rejected alternatives:

- **A private `_release-gate: precommit` in `release.just`, overridden in
  the consumer's justfile.** Non-breaking, and the shape most of the
  design pressure initially pointed at. Rejected because overriding an
  imported recipe requires `set allow-duplicate-recipes := true`, which
  the toolkit would have to declare on the consumer's behalf — a
  repo-wide setting that silently turns the consumer's *accidental*
  duplicate recipes from an error into last-definition-wins. Trading a
  global safety check for one override point is a bad exchange, and the
  backward compatibility it buys isn't needed: consumers update their
  justfile as part of `update-plugin-dev` anyway.
- **`just "$gate"` as the recipe's first shell line**, with an overridable
  `release_gate := "precommit"` variable. Non-breaking, but the gate
  vanishes from just's dependency graph and `--list`, and failures surface
  through a nested `just` invocation. Also inconsistent: every other
  precondition in `release` is a real dependency or a pre-flight check.
- **Taking the recipe name from a variable** (`release: {{gate}}`) — just
  does not support recipe names from variables in a dependency list.

This is a **breaking change**: a consumer that pulls the new toolkit
without adding `prerelease` gets `error: Recipe release has unknown
dependency prerelease`. That error is a whole-justfile compile error, so
*every* recipe fails, `just precommit` included — not just `release`. The
blast radius is deliberate and, on reflection, the better failure mode: it
fires at update time, when the maintainer is already in the justfile, and
names the exact missing recipe. The alternative — a `release` that quietly
runs a narrower gate than intended — is the bug this section exists to
fix.

Locked in by `_import-check`, which builds three stub consumers — plain
(`prerelease: precommit`), widened (`prerelease: precommit evals`), and one
with `prerelease` missing — and asserts via `--dry-run` that `release`
resolves to the right gate chain in the first two and that the third fails
with an error naming `prerelease`. Verified against just 1.46.0.

### `check-version.sh`: catching a partially-completed release

`release`'s marketplace step (see "Marketplace entry" above) runs *after*
`plugin.json` is bumped, committed, tagged, pushed, and the GitHub release
created. If anything from `gh release create` onward fails, the plugin is
left tagged and pushed at the new version while `marketplace.json` is still
at the old one — invisible to end users, and nothing in the toolkit
previously detected it: the pre-flight in `release` only compares
`plugin.json` against the latest tag, and the version-guard hook only fires
on edits to `plugin.json`, not on marketplace staleness.

`check-version.sh` closes this by comparing `plugin.json`'s `.version`
against the consumer's entry in `$MARKETPLACE_DIR/.claude-plugin/marketplace.json`.
It's exposed as a `just check-version` recipe and also runs automatically as
a `release` pre-flight step, so a new release refuses to start on top of a
drifted marketplace from a previous incomplete one.

It was originally a gitlore-local script (motivating the `prerelease` gate
above), hardcoded to gitlore's plugin name and a `../claude-plugins` sibling
path. Absorbed into the toolkit with two fixes: the plugin name is read from
`plugin.json` instead of hardcoded, and the marketplace path comes from
`$MARKETPLACE_DIR` (matching `release.just`'s own convention) instead of an
assumed sibling directory. A missing marketplace entry is treated as
pre-first-publication state (skip), not drift (fail) — consistent with how
`release.just`'s marketplace step treats a missing entry.

### Recovery: `resume-release` and the shared release tail

`check-version.sh` detects a half-landed release but cannot fix one, and the
guard it feeds is deliberately strict: `release` refuses to start on top of
drift. Before `resume-release` nothing satisfied that guard except hand-editing
another repository. `resume-release` is the forward exit.

The last four steps of a release — push the branch, push the tag, create the
GitHub release, bump the marketplace — are one idempotent block that both
`release` and `resume-release` run. Each step probes remote state before acting:
`git ls-remote` for the branch and tag, `gh release view` for the release, and
`ls-remote` again — against the marketplace repo's own origin — for the
marketplace push. Probing the remote directly means the
answer is authoritative without a `git fetch`, so recovery never depends on how
stale the local remote-tracking refs are. A step that finds its work already
done says so and returns; only steps that act set `acted`.

Resume takes its version from `plugin.json` and requires the matching local tag
to already exist. It completes a release; it never starts one. Tagging `HEAD` on
a guess would tag whatever landed since the interrupted release, so a missing
tag is a refusal that points at `just release <bump>` instead. When every step
finds nothing to do, the summary says the release is already complete rather
than claiming to have completed it — that distinction is what makes running it
on a healthy repo safe rather than merely harmless.

A tag that exists on the remote at a *different* sha is an error, never a
force-push. A reused tag means something published under that version already,
and no recovery path should paper over that.

`resume-release` has no `prerelease` dependency, unlike `release`. The code it
completes is already committed, tagged, and in most cases pushed — the gate
already passed once, before the interruption. Re-running it would make recovery
cost whatever the consumer's slowest gate costs, and a consumer with paid checks
would route around the recipe and finish by hand, which is the situation this
exists to end.

The flow moved out of `release.just`'s recipe body into `plugin-dev/release.sh`
to get three things a justfile recipe cannot have: `shellcheck` coverage,
offline end-to-end tests driving real git repos with a stubbed `gh`, and no
just/bash quoting seam — `{{...}}` interpolation inside a shell body is a
recurring source of quoting bugs that no linter sees. `release.just` keeps the
two recipes as one-line wrappers, which is also the whole interface consumers
depend on.

This repo's own self-release recipe stays bespoke. It has the same tail minus
the marketplace step, and it failed in the same window once — `v0.4.1` has a
`VERSION` bump commit and no tag. Resuming it by hand is a tag and a `gh release
create`, which the toolkit's sole maintainer can do; `resume-release` exists as
a convenience for consumers, who are more numerous and less close to the code.
Folding it in would also make the toolkit consume its own consumer-shaped code,
which the "don't run `release.just`'s recipes from this repo" rule exists to
prevent.

### Default branch detection via `origin/HEAD`

The release recipe doesn't hardcode `main` — it reads the default
branch from `git symbolic-ref --short refs/remotes/origin/HEAD` and
falls back to `"main"` if unset. Lets the recipe work on `master`,
`trunk`, fork-default branches, etc., with no behaviour change in the
common case.

`symbolic-ref` rather than `rev-parse --abbrev-ref` because the latter
exits non-zero *and* prints `"origin/HEAD"` to stdout when the ref is
unset. Combined with `pipefail` and a `|| echo "main"` fallback, the
substitution captured both, producing a two-line `main_branch` and the
nonsensical error "must be on HEAD (currently main)".
`symbolic-ref` is silent on stdout when the ref is unset, so the
fallback fires cleanly.

## Limitations

- **Hybrid Python+plugin repos (e.g. edify)** are out of scope. Their
  release recipes need PyPI publish, dry-run, rollback, and version
  bumping via `uv version` — different shape entirely. Wrapping
  edify-style flows into the unified recipe would either require
  conditionals that obscure the main path, or break edify outright.
  Edify keeps its bespoke recipe.
- **`release` is not atomic, but it is recoverable.** The tag push,
  `gh release create` and marketplace push are outward-facing and cannot
  be rolled back, so any failure from the version commit onward leaves
  the plugin tagged at the new version with a stale marketplace entry.
  That remains true. Its consequence no longer is: `just resume-release`
  completes the release from wherever it stopped. Recovery only ever
  moves forward to the version already committed — rolling a release
  back is still out of scope.
- **No automated propagation.** When the toolkit ships a new tag,
  each consumer plugin must run `just update-plugin-dev vX.Y.Z`
  individually. Adopting changes is a deliberate per-consumer
  decision — by design, but worth being explicit about.
- **Subtree pull requires the toolkit URL be reachable.** Fully
  offline development of consumers works, but updates need network.
- **The version-guard hook fires only in consumers that ran
  `install.sh`.** A consumer that vendored the toolkit but skipped
  installing the hook is unprotected. Mitigation: `install.sh` does
  both in one step.
- **Toolkit updates may require a consumer justfile edit.** Adopting a
  new toolkit tag is not always a pure `git subtree pull` — the
  `prerelease` gate landed as a required consumer-side recipe. Consumers
  are expected to read the release notes at `update-plugin-dev` time.
- **Solo-author workflow assumed.** The toolkit is built around one
  maintainer's plugins. Multi-contributor scenarios (e.g. forks
  proposing changes back to the toolkit) work mechanically but
  haven't been ergonomics-tested.
- **No standardised hook library yet.** The toolkit doesn't
  prescribe shellcheck, trailing-whitespace, end-of-file-fixer, etc.
  for consumer plugins — each consumer defines its own `precommit`
  recipe. May change if patterns converge across enough consumers.

## History

Write-time records of each change — what moved and the reasoning available at
the time — live in [changelog.md](changelog.md), one file per entry. This
document states what the toolkit *is*; the changelog states how it got there.
