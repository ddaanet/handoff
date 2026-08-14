# 2026-08-13 — Restart drive repair

The first driven `restart` to run end to end failed twice over, and both
failures have one root: nothing in the plugin ever identified the `claude`
process. `handoff_resume_command` assumed `$PPID` was it; `_drive_shell_line`
guessed at its shutdown with a fixed sleep.

## What the shell received

Captured from a live restart in `~/c/handoff`:

```
/bin/sh -c bash\ \$\{CLAUDE_PLUGIN_ROOT\}/scripts/stop-drive.sh --resume e8da0f4b-273f-4c46-831f-90c0dd42440f
bash: /scripts/stop-drive.sh: No such file or directory
```

Every part of that line is a consequence of reading the wrong process.

## D1 — the wrong process's argv was replayed

> **Superseded 2026-08-14** (see [The relaunch stops replaying
> argv](2026-08-14-the-relaunch-stops-replaying-argv.md)). Argv is no
> longer replayed at all, so the parent-chain walk this section adds is
> removed with it. D2, the foreground gate, stands.

`handoff_resume_command` read `local pid="${1:-$PPID}"`. Claude Code runs a
hook as `claude` → `/bin/sh -c "bash …/stop-drive.sh"` → `bash
stop-drive.sh`, so `$PPID` at `Stop` time is the `sh -c` wrapper. Its argv is
the *hook command line*, and `--resume <sid>` was appended to that.

The unexpanded `${CLAUDE_PLUGIN_ROOT}` is not a second bug. Claude Code puts
that literal in the `sh -c` argv and lets `sh` expand it from the
environment, so the wrapper's `/proc/<pid>/cmdline` really does contain it
unexpanded. `printf %q` froze it, and a fresh login shell — exporting no such
variable — expanded it to empty, which is why the path lost its root.

Whether the `sh -c` wrapper survives at all is the shell's exec-optimisation
choice, so the distance from the hook script up to `claude` is not fixed. The
fix is a bounded walk up the parent chain matching argv[0]'s basename against
`claude`, reading `/proc/<pid>/status`'s `PPid:` line (not `…/stat`, whose
second field is a parenthesised executable name that may itself contain
spaces and parens) with the same `ps` fallback the old reader had. A walk
that finds nothing falls back to a bare `claude --resume <sid>`: relaunching
without the original flags, which is strictly better than replaying an argv
that is not a launch line.

### Why the suite was green

All three `handoff_resume_command` tests set `HANDOFF_TEST_CMDLINE_PATH`,
which replaced the whole `/proc/$pid/cmdline` expression. The seam
substituted for exactly the subexpression that was wrong, so `${1:-$PPID}`
had never once been executed by a test. Replacing it with
`HANDOFF_TEST_PROC_ROOT` — a fake process *tree*, one directory per pid
holding `cmdline` and `status` — is what makes the defect expressible at all,
so it landed with the fix rather than as cleanup.

The seam's fifth use is `stop-drive.sh`'s not-in-tmux paste test, and it is
the only one that exercises the `$PPID` default. It builds its fixture inside
the invoking shell, keyed on that shell's own `$$`, because the pid
`stop-drive.sh` will see is not knowable when the fixture is written.

### The plan's self-parent guard, dropped

The plan carried a `[[ "$parent" != "$pid" ]] || break` line and a cycle test
for it. The test stayed green with the line deleted: the `depth < 10` bound
is the whole termination guarantee, and a self-parent check covers one cycle
length out of many. The comment claiming otherwise would have outlived the
code. The row was rebuilt against a two-pid cycle plus a depth-bound row, and
both are mutation-checked.

## D2 — the relaunch was typed into a terminal that was not listening

`_drive_shell_line` slept `HANDOFF_WATCHER_SHELL_SETTLE` (1.0s) after `/exit`
confirmed, then typed. But `/exit` confirming means `SessionEnd` fired, not
that the terminal is accepting input again. Claude Code stops consuming input
well before it releases the terminal, and a keystroke sent inside that window
is dropped leaving no trace — the pane looks untouched and the line simply
never appears. The observed symptom was the command text arriving but its
Enter never registering, needing a manual keypress.

This is not a shell *startup* race. The parent shell was running the whole
time; what it did not have was the foreground.

The line now gates on the pane's own foreground command
(`#{pane_current_command}`), against a baseline sampled in `main` before any
line is typed — while Claude Code is certainly still holding it, since after
`/exit` there is nothing left to compare. Two consecutive differing readings
open the gate, so a transient during teardown does not release it early.
Baseline-relative rather than matching the literal `claude`, so a TUI
launched under another name still works.

A timed-out gate fails loudly through `watcher_fail` rather than typing
anyway. The fail file is the only channel back from a detached walker, and
typing into a terminal known not to be listening is the defect itself.

`HANDOFF_WATCHER_SHELL_SETTLE` survives with a narrowed meaning — a bounded
residual after the gate, since the shell still redraws its prompt once it has
the foreground back and that part is not separately observable — and its
default drops from 1.0 to 0.25.

### The premise had to be checked against a real TUI

The tmux stub answers `#{pane_current_command}` with whatever a test staged,
so every offline test of the gate passes on an assumption: that tmux reports
one thing while Claude Code holds the terminal and another once it lets go.
If those readings were equal the gate could never fire and every restart
would fail closed, and no offline suite could tell — the stub is the thing
asserting the premise.

Observed 2026-08-13 on tmux 3.5a, in a pane whose command is `/bin/sh` with
the TUI launched inside it: `claude` while running (not `node`), and `sh`
0.75s after release. Pinned by a live-marked conformance test with its own
fixture. The existing `live_pane` fixture cannot serve: it runs `claude` as
the pane command itself, so there is no shell for the foreground to revert
to. That test triggers the release with a signal rather than `/exit` — what
the gate polls is the foreground reverting, and `submit_exited` already owns
whether `/exit` itself lands.

## Rejected alternatives

**Use the grandparent of the hook script.** Depth depends on whether the
shell exec-optimises the `sh -c` wrapper away, so this is the same
brittleness with a different constant.

**Derive the claude pid from tmux's `#{pane_pid}`, walking up to the pane's
own process and taking the child below it.** Exact, and independent of what
the process is named — but `handoff_resume_command` is called before the tmux
check in `stop-drive.sh`, so it must also work on the not-in-tmux paste path,
where there is no pane to ask. Kept as the fallback plan if the name-based
walk proves fragile.

**Lengthen `HANDOFF_WATCHER_SHELL_SETTLE`.** Tuning a constant against an
unbounded shutdown; the failure mode returns under load, and it is silent.

## Known soft spot

The walk identifies Claude Code by argv[0] basename `claude`. A launch as
`node …/cli.js` matches nothing and takes the bare-resume fallback, losing
the original flags. Accepted: it is strictly better than today, and the
`#{pane_pid}` alternative above is the recorded route out if it is not.
