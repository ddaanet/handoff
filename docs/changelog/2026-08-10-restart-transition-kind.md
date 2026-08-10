# 2026-08-10 — A fourth transition kind: exit and relaunch, conversation intact

The design brief, including the probe evidence establishing that hook
registration is per-process and that `SessionEnd` carries a `reason`, is
[`brief-driven-restart.md`](../../brief-driven-restart.md) (repo root). This
entry is what changed and why.

## The defect

A mid-session plugin upgrade, a `hooks.json` edit, a new MCP server, or an
edited `settings.json` cannot be adopted by a live session — hook
registration is per **process**, resolved once at startup. Nothing inside
the conversation can fix this; the only remedy is to exit and relaunch. Doing
that today costs the conversation, since a plain `/clear`-shaped remedy would
paraphrase it away, when `--resume` would have carried it over whole.

## What changed

`restart` is a fourth kind in the sentinel `handoff_drive_read` parses,
shaped exactly like `clear` — two required before-lines, one optional
after-line — but the first time a kind crosses out of the Claude Code TUI
entirely:

- **`/exit`**, confirmed by a new `SessionEnd` hook (`scripts/session-end.sh`)
  writing `.claude/autodrive.exited` when a `restart` is `pending` — the
  opposite polarity of `.claude/autodrive.failed`: this marker is only ever
  created, never disappears, and `stop-drive.sh` clears any stale copy before
  spawning the walker so an earlier, only-partly-successful restart cannot
  false-positive a later one. `_watcher_lib.py` gains a fourth confirmation
  primitive, `submit_exited`, alongside `submit_consumed`/`submit_titled`/
  `submit_prompted`.
- **`claude --resume <sid…>`**, typed into the bare shell `/exit` leaves
  behind, not the TUI composer. `checkpoint.py` composes only the session id
  (`CLAUDE_CODE_SESSION_ID` — it has no view of the process's own argv);
  `stop-drive.sh` fills in the rest right before the line would be typed or
  pasted, reading the exiting process's own `/proc/<pid>/cmdline` (a new
  `_lib.sh` helper, `handoff_resume_command`, with a `ps`-based macOS
  fallback that cannot distinguish an embedded space from an argument
  boundary — a known, accepted gap) and re-quoting each argument for replay.
  `drive_when_idle.py` dispatches this line to a new `_drive_shell_line`
  rather than the existing `_drive_line`: the composer-specific checks
  (`is_typing`, `is_unknown_command`) read Claude Code TUI chrome that does
  not exist on a bare shell and is not a reliable readiness signal across
  every user's shell prompt either, so this line skips them for a fixed
  settle (`HANDOFF_WATCHER_SHELL_SETTLE`) instead. Confirmed the same way
  `/compact`/`/clear` already are — `submit_consumed`, unchanged — since a
  resumed session's `SessionStart` is what clears the sentinel either way.
- The **continuation prompt**, if any, unchanged — `submit_prompted`, fired
  from a new `SessionStart(resume)` hook, `scripts/load-restart.sh`.

`load-restart.sh` is the one loader that injects no frame: `--resume`
restores the full prior conversation on its own, so there is nothing for a
frame to hand a summariser's paraphrase back to — the only effect there is
firing the continuation, which is the whole reason a restart costs no
context at all. A restart that fails after `/exit` but before the resume
lands has no live session to report into; `report-watcher-failure.sh`'s
files are project-scoped, so whatever session next opens in that directory
drains `.claude/autodrive.failed` at its own first `UserPromptSubmit` — a
deferred report, not a lost one, and no code change was needed to get it.

A new skill, `/handoff:restart`, is the fourth "neither boundary" `skill`
value on the checkpoint alongside `autoname`: its whole payload is
`{"skill": "restart", "continue": …}`, no title, no task/todo, no commit
awareness, and every boundary field is a schema error under it by the same
key-presence rule `autoname` uses. It composes no directive, for the same
reason `autoname` does not — nothing here implies a memory write, since the
conversation is never lost.

## Scope not covered here

Two things `brief-driven-restart.md` names are explicitly out of scope for
this change: the gitlore-side stale-plugin-root detector that would point a
user at `/handoff:restart` in the first place (a separate repo, tracked
separately), and `handoff-checkpoint`'s current gitlore-misdiagnosis message
in the upgrade case (a separate backlog item). This change lands the
`restart` kind on its own; nothing yet triggers it automatically or even
suggests it.

## Verification

`tests/hook-test.bats` covers the sentinel shape matrix, `handoff_drive_has_
source`, `handoff_resume_command` (including a fixture-file substitute for
`/proc/<pid>/cmdline`, since `/proc` itself cannot be faked in a test), the
new `session-end.sh` and `load-restart.sh` hooks against the same
pending/armed/other-kind gates the existing loaders are tested against, and
`stop-drive.sh`'s argv-composition and stale-marker-clearing through the
not-in-tmux paste path (a synchronous seam, unlike the detached walker).
`tests/test_watcher_lib.py` and `tests/test_drive_when_idle.py` cover
`submit_exited` and the shell-line path end-to-end against the tmux stub,
including that the shell line proceeds even when the pane text would fail
`_drive_line`'s composer checks, and that `/exit` then `claude --resume …`
run in order within one sequence.
