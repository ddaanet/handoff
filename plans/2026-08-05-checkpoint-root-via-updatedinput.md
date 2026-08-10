# Spec — the checkpoint takes its root from the command, not a pointer

Status: implemented 2026-08-10, including `bin/handoff-approved` (not in
scope of the original plan — see
`docs/changelog/2026-08-10-checkpoint-root-via-updatedinput.md`).

## The defect

`scripts/session-pointer.sh` samples the root at `SessionStart` and parks it at
`/tmp/claude/handoff-root-<session_id>`; `scripts/checkpoint.sh` reads it back
from the agent's Bash. The sample is taken at the one moment the cwd does not
belong to the session.

`SessionStart(resume)` fires with the **resuming process's** cwd, before the
harness moves the resumed conversation into its own project dir. So resuming a
session belonging to repo A from a pane running in repo B stamps B onto A's
pointer. Every other signal stays A — transcript, project dir, injected frame,
`CLAUDE_PROJECT_DIR`, and every other hook, which each resolve the root per
call.

Established from `~/.claude/history.jsonl`, which records every prompt with the
project it was typed in:

    16:15:51  SessionStart(startup) for 10bd3a3d, cwd gitlore  → pointer 10bd3a3d = gitlore
    16:15:58  /resume typed in 10bd3a3d, project /Users/david/code/gitlore
    16:16:27  SessionStart(resume) for 627ea2b5, cwd still gitlore → pointer 627ea2b5 = gitlore

`627ea2b5` is a handoff session whose last transcript entry was nine minutes
earlier. Four pointers on disk are stale this way, in both directions; every
pointer write in a window resolves to one root regardless of which session it is
keyed to, and each window is bracketed by a `/resume` typed in that repo. The
drift marker for `7177c50f` names `handoff` while its pointer names `gitlore` —
two hooks, one session, two answers, which is only possible if the cwd changed
between `SessionStart` and the first `UserPromptSubmit`.

The failure is silent until a checkpoint call refuses, and the refusal that did
happen was a coincidence: `file_path` containment caught a root mismatch as a
side effect, so the message named a field rather than the disagreement.

## Why not the alternatives

There is no sanctioned way for a `bin/` script invoked from the agent's Bash to
learn the project root — `plugins-reference.md` scopes `CLAUDE_PROJECT_DIR` to
"hook processes and to MCP and LSP server subprocesses" with a closed positive
list, and the Bash tool is not in it. `settings.json`'s `env` block reaches Bash
but takes static literals only and cannot be shipped by a plugin. No hook can
export env into later tool calls. No CLI subcommand reports a session's own
root. See `[[skill-bundled-scripts]]`.

So the root must be resolved in a hook and handed over. Two transports were
weighed:

- **Move the writes into `bash-post.sh`**, where the root already is, and let
  the checkpoint validate only. Rejected — not for plumbing, but because it
  moves two other things with it. The directives need the root as well
  (`checkpoint_memory_directive` gates on the gitlore submodule's registration
  and dirtiness; `checkpoint_ledger_path` globs under the root), so composition
  would migrate too and its channel would change from the checkpoint's stdout —
  which the skill bodies read deterministically — to `additionalContext`. And
  nothing would be written by the time the Bash call returns, so a hook that
  errors or never fires leaves the checkpoint reporting success with nothing on
  disk. That silent-to-everyone path is new, and the current design has none.

- **Inject the root into the command** — adopted. Preserves the failure
  semantics of an ordinary Bash call (output and exit status), and is the
  smaller diff: `checkpoint.sh` keeps its structure entirely.

## Design

A new `PreToolUse(Bash)` hook resolves the root and rewrites the command:

    export HANDOFF_ROOT=<quoted root>; <original command>

`export …;` rather than a bare `VAR=… cmd` prefix, so the value survives a
command that batches — `VAR=x a && b` would apply to `a` alone. This makes the
pattern general rather than conditional on the checkpoint being called alone.

The root is resolved exactly as every other hook resolves it, via
`handoff_root` over the payload `cwd`, at call time. That is the whole fix: the
value is sampled when it is used, not once per session.

**Matching.** Gate on the command containing `handoff-checkpoint`, loosely. The
asymmetry is deliberate — a false positive costs an unused environment variable
on an unrelated command, while a false negative produces the error below. Prefer
over-matching.

**Quoting.** The root is interpolated into a shell command, so it is quoted with
`printf %q` or single-quoted with embedded-quote escaping. A path containing
whitespace must round-trip; assert it.

**Naming.** `HANDOFF_ROOT`, not `CLAUDE_CODE_PROJECT_DIR`. The harness variable
is `CLAUDE_PROJECT_DIR` (no `CODE`), and `CLAUDE_CODE_PROJECT_DIR` exists
nowhere — so that name reads like a harness variable while being ours, and
squats on a namespace the harness may later use with different semantics. One
word overrules this.

**`checkpoint.sh`.** The pointer block (lines 37–50) becomes:

    root="${HANDOFF_ROOT:-}"
    [ -n "$root" ] || err "root" "<message>"
    [ -d "$root" ] || err "root" "…"

The unset message is the one David asked for, and it must name the *cause*, not
the symptom: the invocation form was not recognised by the `PreToolUse` hook, so
the root was never injected. It states the recognised form. `CLAUDE_CODE_SESSION_ID`
is no longer read here at all.

**`session-pointer.sh`.** Stops writing the root; keeps the context-marker
re-arm and the sweep, both session-id-keyed and both unaffected. `handoff-root-*`
comes off the sweep's name filter only after a transition period long enough to
clear existing files, or is left on it permanently to clean up what is already
on disk — decide at implementation time; leaving it costs one `-o -name`.

`handoff_pointer_path()` and `HANDOFF_POINTER_DIR`'s root duty go with it;
`handoff_context_path()` still needs the directory.

## What this does not change

The manifest, the staging in `bash-post.sh`, the directive composition and its
stdout channel, the schema including `file_path` and its containment check, and
every write semantic (FR5/FR6). FR3 is unaffected — the checkpoint remains the
only writer of `handoff-task.md`.

## Tests

Red first, in `tests/checkpoint.bats` unless noted.

1. The new hook rewrites a command containing `handoff-checkpoint`, and the
   rewritten command carries the resolved root.
2. It leaves an unrelated Bash command untouched (no `updatedInput`).
3. A root containing whitespace round-trips through the rewrite — run the
   rewritten command and assert the value the script sees, not the string.
4. The `export …;` form survives a batched command: `handoff-checkpoint … && echo`
   still sees the root. This is the row that would stay green under a bare
   `VAR=` prefix only by accident, so assert the second command's view of it.
5. `checkpoint.sh` with `HANDOFF_ROOT` unset exits non-zero and the message
   names the unrecognised invocation form.
6. `checkpoint.sh` with `HANDOFF_ROOT` naming a non-directory exits non-zero.
7. The load-bearing negative, mutation-checked: with `HANDOFF_ROOT` pointing at
   repo A and `file_path` values under repo B, nothing is written under either.
   Disable the containment check and this must go red.
8. In `tests/hook-test.bats`: `session-pointer.sh` no longer writes
   `handoff-root-<id>`, and still clears the context marker. The first assertion
   cannot go red before the write is removed, so verify it by mutation after.

The existing pointer-refusal rows in `tests/checkpoint.bats` are deleted, not
adapted — the pointer is gone, and a test kept for a mechanism that no longer
exists is the vestigial kind. The drifted-cwd negative stays and is re-expressed
against `HANDOFF_ROOT`.

## To verify at implementation time

`updatedInput` on Bash is confirmed working — cwd-safety uses it to wrap
commands in a subshell. Two `PreToolUse(Bash)` hooks both returning
`updatedInput` raises an ordering question, but not here: `handoff-checkpoint`
is invoked bare, with no `cd` prefix, so cwd-safety does not rewrite it. Confirm
this still holds if the skill bodies ever gain a prefix.

NFR2: this fires on every Bash call in every session with the plugin installed.
The negative path must be a substring test on a string already in the payload,
with no `jq` beyond the field parse and no root resolution.

## Follow-on, not in scope

Four stale pointers are on disk from 2026-08-03, all belonging to dormant
sessions. They become inert when the pointer read is deleted.
