# claude-plugin-dev

Shared development tooling for Claude Code plugins. Vendored into each
consumer plugin via `git subtree` so the release infra is versioned with
the repo (CI, fresh clones, and old tags all reproduce without depending
on contributor-side dotfiles).

## Contents

- **`release.just`** — the recipes imported into the consumer's
  `justfile`: `release`, `resume-release`, `check-version` and
  `update-plugin-dev`. `release` and `resume-release` are one-line
  wrappers around `release.sh`; `update-plugin-dev` pulls a newer
  toolkit version into the consumer.
- **`release.sh`** — the release flow itself. Validates state, bumps
  `.claude-plugin/plugin.json`, commits, tags, pushes, creates a GitHub
  release, and bumps (or creates) the plugin's entry in
  `marketplace.json`. Its `--resume` mode completes a release that
  landed only partially — a rejected push, a failed `gh` call — by
  probing what already happened and doing only what is missing. It is a
  no-op that says so when everything already landed.
- **`check-version.sh`** — compares `plugin.json`'s version against the
  plugin's `marketplace.json` entry. Exposed as `just check-version` and
  run as a `release` pre-flight, so a release refuses to start on top of
  a previous one that never finished.
- **`version-guard.sh`** — `PreToolUse(Write|Edit)` hook. Refuses agent
  edits that change `.claude-plugin/plugin.json`'s `.version`. The
  release recipe owns version bumps; manual edits desync the manifest
  from the latest tag and only get caught at release time.
- **`install.sh`** — one-shot wiring script. Run after vendoring;
  inserts the justfile import line and the version-guard hook into
  `.claude/settings.json`. Idempotent.

## Versioning

Each release cuts **two** tags. `vX.Y.Z` is the source tag; `dist-vX.Y.Z`
is what consumers vendor — a `git subtree split --prefix=toolkit` of the
same commit, so its root tree is only the consumer-facing files. Vendoring
a source tag would copy this repo's whole working environment (its `memory`
submodule, `.claude/`, `CLAUDE.md`, its own justfile) into the plugin, so
both `install.sh` and `update-plugin-dev` refuse a `vX.Y.Z` ref and name
the `dist-` one instead.

**Always pin to a tag.** Tracking `main` defeats reproducibility — a
consumer plugin's old git tags should still resolve to the exact toolkit
content that was vendored at the time.

## Installing in a plugin

Clone the toolkit at its **source** tag to get the script, then run
`install.sh` from the plugin's root directory, passing the **dist** tag:

```sh
git clone --depth 1 -b v0.5.5 \
    git@github.com:ddaanet/claude-plugin-dev.git /tmp/cpd
cd /path/to/your/plugin
bash /tmp/cpd/toolkit/install.sh dist-v0.5.5
```

`install.sh` does three things:

1. `git subtree add --prefix=plugin-dev … dist-v0.5.5 --squash` (vendors the toolkit).
2. Adds `import 'plugin-dev/release.just'` to the plugin's `justfile`
   (creating one if absent).
3. Wires the version-guard hook into `.claude/settings.json`.

It's idempotent — re-running with everything already in place is a
no-op. The vendored copy at `plugin-dev/install.sh` can be re-run after
clone or after wiring drift to repair the wiring without re-vendoring.

Then define two project-specific recipes in `justfile`: `precommit`,
your commit gate, and `prerelease`, the gate `release` depends on.

```just
import 'plugin-dev/release.just'

precommit:
    jq . .claude-plugin/plugin.json > /dev/null
    bash -n scripts/*.sh
    # ...whatever else your plugin needs...

prerelease: precommit
```

For most plugins the two gates are the same and `prerelease: precommit`
is the whole recipe. If your release gate is bigger — slow or paid
checks you don't want on every commit — widen it there:

```just
evals:
    make evals      # slow, paid; not part of precommit

prerelease: precommit evals
```

`prerelease` is mandatory. just rejects a justfile whose dependency
names a recipe that doesn't exist, so omitting it fails every recipe
immediately with `unknown dependency prerelease` — not silently at
release time.

Commit:

```sh
git add plugin-dev justfile .claude/settings.json
git commit -m "add claude-plugin-dev toolkit"
```

## Updating in a plugin

```sh
just update-plugin-dev dist-v0.5.5
```

This wraps `git subtree pull` with the prefix and URL baked in. The
recipe rejects a dirty tree, refuses a source (`vX.Y.Z`) ref naming the
`dist-` one to use instead, and warns if you pass a branch ref.

A plugin vendored before dist refs existed carries the toolkit's leaked
working environment under `plugin-dev/` — most visibly a `plugin-dev/memory`
gitlink that makes a bare `git submodule status` fail for the whole repo.
No manual cleanup is needed: the first pull of a `dist-` tag deletes all
of it in the same commit.

## Conventions

- Release commit message: `release: X.Y.Z` (gitmoji hook maps it to
  `🔖 release X.Y.Z`).
- Plugin manifest holds the **last released** version. `just release`
  bumps from there. Manual edits are blocked by the version-guard hook
  and the release recipe's own pre-flight check.
- A plugin that has never been released has nothing to bump from, so
  its **first** `just release` — with no bump argument — publishes the
  version `plugin.json` already holds. Set that version before the
  first release; passing a bump there is refused. Afterwards the
  last-released rule above applies as normal.
- Default branch is auto-detected from `origin/HEAD`; recipes don't
  hardcode `main`.
- The version-guard hook fires on Write/Edit events targeting
  `.claude-plugin/plugin.json` and is a no-op outside plugin
  repositories (no manifest, no fire).

## Requirements

`bash`, `jq`, `git`, `gh`.

## License

MIT
