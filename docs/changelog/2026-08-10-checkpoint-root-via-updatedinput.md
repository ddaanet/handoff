# 2026-08-10 — The checkpoint takes its root from the command, not a pointer

The full write-time record — the defect's transcript evidence, the
alternatives weighed, the design — is
[`plans/2026-08-05-checkpoint-root-via-updatedinput.md`](../../plans/2026-08-05-checkpoint-root-via-updatedinput.md).
This entry is what changed and why, plus one thing the plan did not
anticipate.

## The defect

`scripts/session-pointer.sh` sampled the root once, at `SessionStart`, and
parked it at a session-keyed path in `/tmp/claude`; `scripts/checkpoint.sh`
read it back from the agent's Bash, where `CLAUDE_PROJECT_DIR` is unset.
`SessionStart(resume)` fires with the **resuming process's** cwd, before the
harness moves the resumed conversation into its own project dir — the one
moment the cwd does not yet belong to the session. Resuming a session
belonging to repo A from a pane running in repo B stamped B onto A's pointer,
silently, until a checkpoint call happened to refuse for an unrelated reason
(`file_path` containment). Four stale pointers on disk, in both directions,
confirmed the mechanism from `~/.claude/history.jsonl`.

## What changed

A new `PreToolUse(Bash)` hook, `scripts/inject-checkpoint-root.sh`, resolves
the root fresh on every call whose command contains `handoff-checkpoint`
(loosely matched — a false positive costs an unused env var, a false negative
the refusal below) and rewrites it to `export HANDOFF_ROOT=<quoted>;
<original command>` via `updatedInput`. `export …;` rather than a bare
`VAR=… cmd` prefix, because the latter only scopes to the first command in a
batch — `VAR=x a && b` would apply to `a` alone, not `b` — which is the row a
careless fix would pass by accident. `checkpoint.sh` reads `HANDOFF_ROOT` from
the environment and refuses, naming the unrecognised-invocation cause, when
it is unset or not a directory; `CLAUDE_CODE_SESSION_ID` is no longer read for
root resolution at all. `session-pointer.sh` stops writing the root; the
context-marker re-arm and the stale-file sweep are unaffected (the sweep keeps
`handoff-root-*` in its filter, to clean up what the old mechanism already
left on disk). `handoff_pointer_path()` is deleted from `_lib.sh`.

The value is now sampled when it is used, not once per session — there is no
longer a moment where the cwd could be some other session's.

## Scope extension beyond the plan

`bin/handoff-approved`, introduced after the plan was written, read the exact
same pointer this change removes; the plan never mentions it. Removing
`handoff_pointer_path()` as specified would have stranded it silently. The
hook's matching was extended to also cover `handoff-approved`, and that script
was given the same `HANDOFF_ROOT`-from-environment treatment as
`checkpoint.sh`, with parallel test coverage — rather than leave a second,
now-orphaned consumer of a mechanism this change deletes.

## Verification

The batched-command row (`export …;` vs a bare `VAR=` prefix) and the new
`tests/hook-test.bats` row (`session-pointer.sh` no longer writes the pointer)
are both mutation-checked: reverting each fix reproduces the exact test
failure the fix resolves.
