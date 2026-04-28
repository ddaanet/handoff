# claude-plugin-dev

Shared development tooling for Claude Code plugins. Vendored into each
consumer plugin via `git subtree` so the release infra is versioned with
the repo (CI, fresh clones, and old tags all reproduce without depending
on contributor-side dotfiles).

## Contents

- **`release.just`** — release recipe + toolkit-update recipe. Imported
  into the consumer's `justfile`. The `release` recipe validates state,
  bumps `.claude-plugin/plugin.json`, commits, tags, pushes, and creates
  a GitHub release. The `update-plugin-dev` recipe pulls a newer
  toolkit version into the consumer.
- **`version-guard.sh`** — `PreToolUse(Write|Edit)` hook. Refuses agent
  edits that change `.claude-plugin/plugin.json`'s `.version`. The
  release recipe owns version bumps; manual edits desync the manifest
  from the latest tag and only get caught at release time.
- **`install.sh`** — one-shot wiring script. Run after vendoring;
  inserts the justfile import line and the version-guard hook into
  `.claude/settings.json`. Idempotent.

## Versioning

Releases are tagged `vX.Y.Z`. **Always pin to a tag** when adding or
updating the toolkit in a consumer plugin. Tracking `main` defeats
reproducibility — a consumer plugin's old git tags should still resolve
to the exact toolkit content that was vendored at the time.

## Installing in a plugin

Clone the toolkit at a tag, then run its `install.sh` from the plugin's
root directory:

```sh
git clone --depth 1 -b v0.1.0 \
    git@github.com:ddaanet/claude-plugin-dev.git /tmp/cpd
cd /path/to/your/plugin
bash /tmp/cpd/install.sh v0.1.0
```

`install.sh` does three things:

1. `git subtree add --prefix=plugin-dev … v0.1.0 --squash` (vendors the toolkit).
2. Adds `import 'plugin-dev/release.just'` to the plugin's `justfile`
   (creating one if absent).
3. Wires the version-guard hook into `.claude/settings.json`.

It's idempotent — re-running with everything already in place is a
no-op. The vendored copy at `plugin-dev/install.sh` can be re-run after
clone or after wiring drift to repair the wiring without re-vendoring.

Then define your project-specific `precommit` recipe in `justfile` —
`release` depends on it. Example:

```just
import 'plugin-dev/release.just'

precommit:
    jq . .claude-plugin/plugin.json > /dev/null
    bash -n scripts/*.sh
    # ...whatever else your plugin needs...
```

Commit:

```sh
git add plugin-dev justfile .claude/settings.json
git commit -m "add claude-plugin-dev toolkit"
```

## Updating in a plugin

```sh
just update-plugin-dev v0.2.0
```

This wraps `git subtree pull` with the prefix and URL baked in. The
recipe rejects a dirty tree and warns if you pass a branch ref instead
of a tag.

## Conventions

- Release commit message: `release: X.Y.Z` (gitmoji hook maps it to
  `🔖 release X.Y.Z`).
- Plugin manifest holds the **last released** version. `just release`
  bumps from there. Manual edits are blocked by the version-guard hook
  and the release recipe's own pre-flight check.
- Default branch is auto-detected from `origin/HEAD`; recipes don't
  hardcode `main`.
- The version-guard hook fires on Write/Edit events targeting
  `.claude-plugin/plugin.json` and is a no-op outside plugin
  repositories (no manifest, no fire).

## Requirements

`bash`, `jq`, `git`, `gh`.

## License

MIT
