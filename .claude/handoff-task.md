## Current task

`plans/2026-07-29-driven-transitions-design.md` is a written but unimplemented design: split the drive-the-TUI half out of `precompact` into its own skill, add the symmetric driven skill for the `/clear` boundary, and retrofit transcript-based delivery confirmation onto the rename watcher both would depend on. No script or skill has moved toward it yet.

## Open decisions

- Whether `claude-plugin-dev` should stop tracking its own `.claude/handoff-*.md`. Every `just update-plugin-dev` vendors the toolkit's last session frame into each consumer's `plugin-dev/.claude/`, where it is inert — `handoff_root` resolves to the repo root, never there — but it churns on every toolkit release. Fixing it costs the toolkit its own versioned handoff trail; leaving it means consumers keep absorbing the noise.