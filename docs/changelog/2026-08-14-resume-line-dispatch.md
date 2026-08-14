# 2026-08-14 — The relaunch line is dispatched by its command, not a prefix

The second driven `restart` typed its relaunch line into the shell and stopped
there. The line sat at the prompt, correct and complete, waiting for an Enter
nobody had sent; the user pressed it by hand. The failure report named the
composer:

> `/Users/david/.local/bin/claude --settings … --resume e2dc9301…` did not land
> in the composer — a dead pane or copy mode may have swallowed it.

There is no composer. `/exit` had already been confirmed, and the pane was a
bare shell — which is exactly what `_drive_shell_line` exists for, and it never
ran. The dispatch in `main` was

```python
if line.startswith("claude --resume "):
```

and the line the walker is handed does not start with that. `stop-drive.sh`
rewrites the checkpoint-composed slot through `handoff_resume_command`, which
replays the exiting process's own `/proc/<pid>/cmdline`. argv[0] there is the
resolved binary — the launcher on PATH `exec`s it, and the exec substitutes
the full path. So the line begins `/Users/david/.local/bin/claude`, the prefix
test missed, and it fell through to `_drive_line`: `wait_for_idle` (a bare
shell is idle, so it passed), `_send_literal` (the line was typed — that part
worked), then `wait_for_landing`, polling a `❯` composer that had exited three
seconds earlier. Three seconds later it gave up and called `watcher_fail`,
before the Enter.

The foreground gate went with it. The line was typed with no check that Claude
Code had released the terminal — the whole subject of the day before's repair,
bypassed not by disabling it but by never reaching the branch it lives in.

## Why the suite was green

Every fixture spells argv[0] as the bare word `claude`. In
`tests/test_drive_when_idle.py` the shell-line rows drive `claude --resume
sess-42`; in `tests/hook-test.bats` the fake process trees are built with
`make_proc_entry "$root" 100 50 claude --plugin-dir /foo`. Both ends agreed
with each other and neither agreed with a real process, so the prefix test was
green against a string no production run ever produces.

This is the shape of 2026-08-13's predicate defect one layer up. There the
fixtures were hand-written where they should have been captures; here they are
hand-written where they should have been a real argv. In both cases the test
asserted the premise instead of checking it.

## The predicate

Recognition is content-based, which it has to be: the walker takes literal
keystrokes, one per argument, and does not know which kind composed them —
that is `handoff_drive_read`'s job, upstream. It already dispatches this way
for `/rename`, `/compact`, `/clear`, `/exit` and prose. So the relaunch line
joins the same table rather than acquiring a positional marker in argv, which
would have made the walker kind-aware to fix a string comparison.

```python
parts = shlex.split(line)
return bool(parts) and Path(parts[0]).name == "claude" and "--resume" in parts[1:]
```

`shlex`, not a regex, because the quoting is the shell's own: `printf '%q'`
emits `--settings \{\"autoMemoryDirectory\":\"…\"\}`, and the parse has to
agree with the shell that will read those keystrokes. Basename, because the
path is whatever the user's install put on PATH. And `--resume` among the
arguments, because a continuation prompt is prose and prose may open with the
word `claude`; the leading-`/` rule that keeps prose out of the command
branches does not help here, since the real relaunch line begins with `/` too.

## What the tests pin now

The red row drives the observed line — absolute argv[0], `%q`-quoted
`--settings`, `--resume` last — through the same pane fixtures the existing
bypass row uses, where nothing resembling a composer is on screen. It failed
on the assertion before the fix.

`tests/hook-test.bats` gains a producer-side row: a fake tree whose argv[0] is
`/Users/x/.local/bin/claude`, asserting the walk still finds it and the path is
replayed whole. It was green when written — it is a realism guard, not the fix
— so it was mutation-checked by narrowing `handoff_claude_pid`'s basename
match to a literal comparison, which reds that row alone.

## Left alone

Two observations from the same run are not fixed here. The relaunch re-enters
the resolved binary, so a `claude` shim on PATH is bypassed — this session
started with gitlore reporting `GITLORE_LAUNCHED is unset`, its auto-memory
directory pointing outside the submodule. Replaying the basename instead would
re-enter the shim and lose the argv the resolved path is read from; that is a
trade to weigh, not a defect to patch silently. (Weighed and taken the same
day: [the relaunch is typed by
name](2026-08-14-relaunch-through-the-shim.md).) And the `/exit`-into-a-live-TUI
hang seen in the earlier tmux probe remains unexplained, though it did not
recur in either real driven restart.
