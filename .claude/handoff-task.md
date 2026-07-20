## Current task

Live-testing the precompact compaction driver in the handoff plugin, then
cutting the release. This run is itself the test of two changes that have
only ever been exercised against synthetic payloads and a tmux stub:

- `4300dea` — the settle delay before the first Enter in
  `continue-when-idle.sh`, plus submit verification moved from `is_typing`
  to `is_busy` in both watchers. The previous live run needed a manual
  Enter on the continuation prompt and reported success anyway.
- `ef1f51f` / `2f19dee` — `handoff-task.md` is now written by both
  `handoff` and `precompact`, injected at `SessionStart(compact)` by
  `load-compact.sh` via the shared `handoff_frame` helper.

Three things to confirm after the compaction: the continuation prompt
submits with no keystroke from the user; this task file appears in the
post-compaction context (frame header `# Task — <stamp>`); and the write
guard permitted precompact's own task-file write, which depended on
`handoff_activated()` accepting either skill.

Then cut the release. `v0.9.0` is the last tag; unreleased range is
`c51c719..1b6214a` (12 commits — two predate the precompact work). The
command is `just release minor` — new hooks and a redefined skill, so
minor rather than patch. It is blocked by the auto-mode classifier, so
the user runs it as `! just release minor`. It tags and pushes `handoff`
and bumps the marketplace entry in `claude-plugins` (`MARKETPLACE_DIR`,
needs `direnv allow`); name both repos up front.

## Open decisions

- Whether to make watcher failure observable before releasing. Both
  watchers now exit non-zero when a submit does not land, but they are
  detached and nothing reads that status — if the settle delay proves too
  short on a slower pane, the symptom is identical to the bug just fixed:
  prompt sits in the composer, no error anywhere. Fixing it means a
  breadcrumb the next hook reports. Decide based on whether this run's
  submit looks marginal or clean; skip it if clean.
