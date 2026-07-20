## Current task

Cutting the handoff `v0.10.0` release. Everything is prepared: preflight is
clean, `just precommit` green at 110 bats + 9 pytest, docs updated. The only
remaining step is the release itself, which the auto-mode classifier blocks,
so the user runs `! just release minor`. It tags and pushes `handoff` and
bumps the marketplace entry in `claude-plugins` — name both repos up front so
the authorization covers the marketplace push.

The release covers the precompact compact-and-continue driver
(`commit memory → compact → continue`, driven by `Stop` +
`SessionStart(compact)`), the shared `handoff-task.md` seam between the two
skills, and watcher-failure reporting via `.claude/autocompact.failed` +
`report-compact-failure.sh` on `UserPromptSubmit`.

## Open decisions

- Whether a watcher killed outright — pane closed, machine slept — should be
  detectable. It is the one non-delivery path still silent, because the only
  available signal is a stranded `autocompact.pending`, which is legitimately
  present for the whole `Stop` → compaction window and would false-alarm on a
  race with the user typing. Deliberately left silent; revisit only if it
  actually happens.
