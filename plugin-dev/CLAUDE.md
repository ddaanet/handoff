# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# Agent Instructions — claude-plugin-dev

This repository is *not* a Claude Code plugin. It is a development
toolkit that gets vendored into Claude Code plugins via `git subtree`.
The artifacts here run inside *other* repositories — keep that
inversion in mind when editing.

## Layout

- `release.just` — release recipe imported into consumer plugins'
  justfiles. Defines `release` and `update-plugin-dev`. Not run from
  this repo directly.
- `version-guard.sh` — `PreToolUse(Write|Edit)` hook that fires inside
  consumer plugins to refuse agent edits to
  `.claude-plugin/plugin.json`'s `.version`.
- `install.sh` — one-shot: vendors this toolkit into a consumer plugin
  via `git subtree add`, wires the `release.just` import into the
  consumer's `justfile`, and adds the version-guard hook to its
  `.claude/settings.json`.
- `justfile` — *this repo's own* dev recipes (distinct from
  `release.just`). Defines `precommit` and the toolkit's self-`release`
  recipe.
- `VERSION` — last-released toolkit version, plain text. Bumped by
  the self-release recipe; mirrors the latest git tag. Exists so
  consumers (which vendor via subtree, where tags don't propagate) can
  identify the version they're on with `cat plugin-dev/VERSION`.
- `DESIGN.md` — living rationale for every design decision. Update
  when design choices change.

## Quality gate

```sh
just precommit
```

Runs `bash -n` and `shellcheck` on the shell scripts, plus a private
`_import-check` that imports `release.just` into a stub consumer to
catch justfile syntax errors. Must be green before committing.

## Releasing the toolkit

```sh
just release [patch|minor|major]
```

Reads `VERSION`, bumps, commits `release: X.Y.Z`, tags, pushes main +
tag, and creates a GitHub release. Refuses to run on a dirty tree or
when `VERSION` disagrees with the latest tag (same invariant as the
consumer release recipe protects on `plugin.json`).

Tags only; never expect consumers to track `main`. See DESIGN.md
"Versioning" for the reasoning.

## Conventions

- **The consumer-defined gate is `precommit`**, not `validate`. All
  documentation, example justfiles, and recipe dependencies must use
  this name. See DESIGN.md "Recipe naming".
- **Hook output is dual-channel.** When `version-guard.sh` denies an
  edit, `permissionDecisionReason` carries the verbose agent-facing
  message (no escape hatches the agent can self-authorise);
  `systemMessage` carries a one-line human notice. Don't conflate
  them. Don't soften the agent message into something an agent could
  read as instruction (e.g. "you can run X to bypass" — actively
  bad).
- **`${CLAUDE_PROJECT_DIR}` in `install.sh`'s `hook_cmd` is
  intentionally single-quoted.** Claude Code expands it at hook-fire
  time, not bash at install time. The `# shellcheck disable=SC2016`
  on that line is load-bearing.
- **Heredocs in `install.sh` that emit example justfile content are
  unquoted** (so `$import_line` expands). That means backticks inside
  the heredoc body get parsed as command substitution by bash. Avoid
  decorative backticks in those heredocs — they are not rendered as
  markdown anywhere.
- **Update `DESIGN.md` when design decisions change.** The History
  section accretes; overturned decisions are rewritten in place with
  the new reasoning, not struck through.

## Non-goals for this repo

- Don't add a `.claude-plugin/plugin.json` here. It is not a Claude
  Code plugin. The `VERSION` file is the source of truth.
- Don't run `release.just`'s recipes from this repo. They expect a
  consumer-shaped layout (`.claude-plugin/plugin.json`, a `precommit`
  recipe) and will fail or produce nonsense here. Use the local
  `release` recipe in this repo's `justfile` instead.
- Don't add hybrid Python+plugin support to `release.just`. Repos
  like `edify` are deliberately out of scope; their release shape is
  different enough that wrapping them would obscure the main path.
  See DESIGN.md "Limitations".
