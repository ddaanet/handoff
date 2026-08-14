# 2026-08-14 — The relaunch stops replaying argv

The first fully unattended driven restart landed, and its command line read:

```
claude --settings {…} --plugin-dir … --settings {…} --plugin-dir … -c --resume e2dc9301…
```

Two copies of each flag. [Typing the relaunch by
name](2026-08-14-relaunch-through-the-shim.md) had accepted duplicates that
morning on the strength of a probe showing the CLI parses them. The probe was
answering the wrong question. Duplicates are not a one-time cosmetic cost:
the argv being replayed is the argv the shims produced, so each restart hands
them a line they inject into again. Every cycle adds another copy, without
bound.

## What replay was for, and why nothing is left of it

It existed to carry the launch flags across the relaunch, and every flag it
was carrying on this box came from a shim — `--plugin-dir <repo root>` from
the dev launcher, `--settings '{"autoMemoryDirectory":…}'` from gitlore's.
Typing the bare name re-enters both, so they resupply exactly what the replay
was preserving, and they resupply `GITLORE_LAUNCHED=1` besides, which no argv
could have carried. The only flag left for replay to protect is one a user
typed by hand on an install with no shim; the conversation selectors (`-c`,
`-r`) are superseded by the appended `--resume <sid>` anyway.

That is a real loss, and it is silent. It is also the entire remaining
justification for ~130 lines: `handoff_resume_command`, `handoff_claude_pid`,
`handoff_proc_argv0`, `handoff_proc_ppid`, `handoff_proc_root`, the
`HANDOFF_TEST_PROC_ROOT` fake-process-tree seam, and eight bats rows covering
the walk (the `sh -c` wrapper, several intermediate levels, a cyclic chain
terminating under a `timeout`, an embedded space surviving requoting, both
fallbacks). With the flags resupplied by the launcher, the walk answers a
question nobody asks. `stop-drive.sh` now rewrites nothing, and its `restart`
branch does only what it also did before: clear a stale
`.claude/autodrive.exited`.

The design principle it was built on — *the `claude` process is found, never
assumed* — does not survive it either. The half of it about the pane's
foreground command does, and that is where it now lives: the moment Claude
Code lets go of the terminal is read from tmux, not from the process table.

## What is kept

`_is_resume_line` stays a parse (`shlex.split`, argv[0]'s basename, `--resume`
among the arguments) rather than reverting to the prefix test that now would
work again. The line reaching it is `claude --resume <sid>` today; the prefix
test is what broke when the line briefly became an absolute path, and the row
driving that shape stays too — it is what keeps the predicate from regressing
to a prefix test, since no other row would notice.

## The alternative weighed

Deduplicating repeated flag+value pairs at compose time would have kept the
walk and stopped the growth, but it settles at two copies of everything
rather than one — the shims still add theirs on top of the deduplicated line —
and keeps a subsystem whose only output is flags the launcher would have
provided.
