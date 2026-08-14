# 2026-08-14 — The relaunch is typed by name, so it re-enters the shims

The restart that exposed [the dispatch
defect](2026-08-14-resume-line-dispatch.md) came up with gitlore reporting

> GITLORE_LAUNCHED is unset — the launcher shim did not run, so CC auto-memory
> is writing to the default `~/.claude/projects/<cwd>/memory` dir, NOT the
> gitlore submodule.

The relaunch had replayed `/Users/david/.local/bin/claude`, which is the real
binary. Two shims sit ahead of it on PATH — `.bin/claude`, prepending
`--plugin-dir <repo root>` so the in-tree plugin is active, and
`.gitlore/bin/claude`, prepending `--settings '{"autoMemoryDirectory":…}'` —
and naming the binary walks straight past both. A driven restart therefore
came back with the plugin under test not loaded from the tree and auto-memory
outside the submodule, both silently.

## Why walking further up does not find it

The first instinct was to keep walking the parent chain: find the innermost
`claude`, then continue while consecutive parents are also named `claude`, and
relaunch the topmost — the shim.

There is no such chain. Both shims end in `exec "$real" <flag> "$@"`, and an
exec replaces the process image in place: same pid, no new entry, and argv[0]
becomes the resolved path. The four live sessions on this box all read the
same way —

```
1149118  /Users/david/.local/bin/claude --settings {…} --plugin-dir . -c
1148833  -fish
```

— claude directly under the shell, with the shims' contributions visible only
as the flags they injected. A shim that has already exec'ed leaves nothing to
find, which is why the walk cannot be extended to reach it.

## Why the flags were never the whole loss

Framing this as "the replayed argv is missing two flags" understates it.
gitlore's shim also does `export GITLORE_LAUNCHED=1`, which appears on no
command line — it is what the shim's own anti-double-inject guard reads on the
next invocation. Reading it off the exiting process would be possible
(`/proc/<pid>/environ` holds it, and it is set there: the claude process has
it, the fish that launched it does not), but re-exporting a variable a shim
sets for itself is reconstructing the shim's job from its output. Running the
launcher again restores the flag and the variable together, and is the only
thing that restores the variable at all.

That the parent shell lacks the variable is also what makes the re-entry
correct rather than a no-op: the guard sees a fresh launch and injects, where
a shell that had somehow inherited it would get a passthrough.

## What is left

> **Superseded 2026-08-14** (see [The relaunch stops replaying
> argv](2026-08-14-the-relaunch-stops-replaying-argv.md)). Keeping the
> replayed flags is reversed: the duplicates compound, one copy per
> restart, because the argv being replayed is the one the shims produced.
> Typing the bare name — the rest of this entry — stands.

Type the name and let the shell resolve it, exactly as the user's own
invocation did. It costs the guarantee that the relaunch is the same binary —
PATH may have changed since — but that is the point: a shim is a PATH entry,
and re-entering it is the whole objective. It also fails if `claude` is not on
PATH at all, which was already the fallback's assumption when the parent-chain
walk finds nothing.

The flags are still replayed. A shim re-injects what it injected the first
time, so the line carries two identical `--plugin-dir` or `--settings` values;
the CLI takes them (probed directly, `--version` with each flag doubled). The
alternative — dropping the replayed flags and letting the shims resupply
everything — reproduces this box's environment exactly and loses a flag a user
typed by hand, on an install with no shim to resupply it. Identical duplicates
are the cheaper mistake, and no rule guessing which flags a shim contributed
has to exist.

`-c` in the replayed argv alongside the appended `--resume <sid>` is not a
conflict: probed against a nonexistent session id, the error names the resume
id, so the explicit selector wins.

## The test that discriminates

Every fixture already spelled argv[0] `claude`, which is what let this ship —
the same blind spot as the dispatch defect, and the row added there is the one
that moves: an absolute argv[0] must come back as the bare name with its flags
intact. One row is new, for the argv that is nothing but slot 0, where the
tail slice is empty and bash 3.2 expands an empty slice under `set -u` as an
unbound variable.
