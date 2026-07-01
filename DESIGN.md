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
succeeded. The step now checks `git diff --cached --quiet` and skips the
commit/push (reporting "marketplace already at X") when nothing changed.

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

The consumer-defined gate the `release` recipe depends on is called
`precommit`. `validate` was considered but rejected:

- `validate` isn't an established convention — it shows up mostly in
  schema-validation contexts (k8s, terraform), not "the gate before a
  commit/release."
- `precommit` names the *moment* it should fire, matches the
  pre-commit ecosystem's vocabulary, and is already used in adjacent
  projects (e.g. `edify`).
- `release` depending on `precommit` reads naturally: "the same
  gates that pass for a commit must pass for a release."

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
- **Solo-author workflow assumed.** The toolkit is built around one
  maintainer's plugins. Multi-contributor scenarios (e.g. forks
  proposing changes back to the toolkit) work mechanically but
  haven't been ergonomics-tested.
- **No standardised hook library yet.** The toolkit doesn't
  prescribe shellcheck, trailing-whitespace, end-of-file-fixer, etc.
  for consumer plugins — each consumer defines its own `precommit`
  recipe. May change if patterns converge across enough consumers.

## History

- **Unreleased.** Removed the interactive confirmation prompt and the
  `--yes` argument from the `release` recipe. `just release [bump]` is
  now non-interactive — the recipe runs behind Claude Code's permission
  layer (or a human's own invocation), so the inner `read -rp` prompt
  and its `--yes` skip were redundant. Pre-flight guards unchanged. See
  "No interactive confirmation in `release`".

- **v0.2.1.** Marketplace step in `release.just` made robust to the
  entry's pre-state. First publication now creates the `marketplace.json`
  entry from `plugin.json` (deriving the `github` source from `origin`)
  instead of aborting with "no entry for '<name>'". The marketplace
  commit is now idempotent — a no-op rewrite (entry already at the target
  version) is reported and skipped rather than failing the recipe after
  the release already landed. See "Marketplace entry: bump if present,
  create on first publication". Closes
  `BUG-release-marketplace-noop-commit.md`.

- **2026-04-27 — Initial extraction (`v0.1.0`).** Toolkit broken out
  of `handoff/scripts/version-guard.sh` and the inline release recipes
  in `handoff/justfile` and `gitmoji/justfile`. Unified the two
  recipes (commit-message format settled on `release: X`, dynamic
  default-branch detection from edify, manifest-vs-tag mismatch guard
  added during the work). Toolkit not yet adopted by either consumer
  — handoff's `0.2.0` release postponed pending migration.

  Next: migrate `handoff` to consume the toolkit (subtree-add, run
  `install.sh`, delete its local `scripts/version-guard.sh` and
  inline release recipe). Then `gitmoji`. After that, evaluate
  whether to absorb a small standard-hooks set (shellcheck,
  trailing-whitespace) for consumer plugins, or leave each consumer
  to define its own `precommit` shape.

- **2026-04-29 — `v0.2.0`.** Three changes shipped together:
  - **`VERSION` file + self-release recipe.** The toolkit had no way
    to self-identify from inside a consumer's subtree (tags don't
    propagate). Added a plain-text `VERSION` at the repo root and a
    local `release` recipe in this repo's `justfile` that bumps
    `VERSION`, tags, and pushes. Same manifest-vs-tag mismatch guard
    as the consumer recipe, applied to `VERSION`. See "Toolkit
    version source of truth" above.
  - **Marketplace bump in `release.just`.** The consumer release
    recipe now also bumps the corresponding entry in
    `$MARKETPLACE_DIR/.claude-plugin/marketplace.json` and pushes
    that repo. Pre-flight checks (env var set, file exists, entry
    exists, repo clean) run before any destructive op. Rationale: a
    tag without a marketplace bump is invisible to end users, so
    treating them as one atomic release matches reality.
  - **`symbolic-ref` fix for default-branch detection.** See
    "Default branch detection" above.

  Also added a hook-test for `version-guard.sh` under `tests/`.

  Adoption: `handoff` migrated to the toolkit during this cycle
  (subtree-add v0.2.0, ran `install.sh`, deleted its local
  `scripts/version-guard.sh` and inline release recipe). `gitmoji`
  migration in progress.

  Next: finish `gitmoji` migration. Then revisit the
  standard-hooks-set question with two real consumers' `precommit`
  recipes side-by-side.
