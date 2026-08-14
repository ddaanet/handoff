# 2026-08-15 — The continuation waits for the composer to exist

First end-to-end dogfood of a driven restart against the real product (this
plugin's own repo, real `--plugin-dir`, real tmux pane). `/exit` and the
relaunch both landed — the resumed session was this exact conversation,
carried over intact. The continuation line did not:

```
handoff: transition watcher did not deliver — `Report that the driven
restart landed successfully…` did not land in the composer — a dead pane or
copy mode may have swallowed it.
```

Neither of the message's two named causes held. The pane was live and in no
copy mode; the resumed session's `SessionStart(resume)` had already fired
`load-restart.sh`, which spawned the walker.

## Root cause

The continuation walker calls `_drive_line`, the same path `/rename` and
`/compact` continuations use. Its budget — `wait_for_idle`'s near-instant
resolution (nothing shows the busy spinner during boot), a 0.5s verify sleep,
a 3s landing poll — was sized for driving a TUI that is already running: for
`/compact`/`/clear`, `SessionStart(compact|clear)` fires on a live process
whose composer already exists. `restart`'s continuation is the one case
`SessionStart(resume)` fires at the very start of a brand-new process's boot,
before hooks finish, before a transcript replay under `--resume` completes,
before gitlore's `autoMemoryDirectory` settings load — none of which shows a
busy indicator, and none of which a fixed ~3.5s window survives.

Measured directly: a bare launch of this exact plugin/hook chain (no
`--resume`, no memory settings, the cheapest case) took **3.9s** to reach a
rendered composer, on a private tmux socket timing the first appearance of
`❯`. The real restart's `--resume` carried a large transcript plus
`autoMemoryDirectory` on a memory-constrained box — slower still. The walker
typed the continuation into a boot screen with nothing reading stdin yet, and
`wait_for_landing`'s 3s poll expired before a composer ever existed to show
it.

## Fix

`_watcher_lib.wait_for_composer` polls for the `❯` glyph's mere presence —
not idleness, not this line's content, just that a composer exists at all —
before `_drive_line` runs its existing `wait_for_idle` → send → verify →
land sequence. It is the first thing `_drive_line` does, ahead of every
other check, and it is a no-op mid-session: `/rename`, `/compact`, `/clear`
and prose continuations all find the glyph already there on the first poll.
Reproduced in `tests/test_drive_when_idle.py` by staging a pane with no
composer for 0.3s before one appears — red against the unfixed
`_drive_line` (times out inside a 0.1s landing window), green once the gate
is in front of it.

`_drive_shell_line` (the relaunch line itself, typed into a bare shell) is
unaffected — it never reads composer chrome to begin with.
