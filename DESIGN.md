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
branch from `git rev-parse --abbrev-ref origin/HEAD` and falls back
to `"main"` if unset. Lets the recipe work on `master`, `trunk`,
fork-default branches, etc., with no behaviour change in the common
case.

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
