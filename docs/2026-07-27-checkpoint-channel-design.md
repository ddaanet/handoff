# One channel, one writer — design

**Date:** 2026-07-27
**Status:** specified

## Problem

The wrap-up is spread across five mechanisms that each own a fragment of one
act. Writing the frame today means: an activation hook wipes prior files
(`_wipe-emit.sh`, reached two ways — `skill-pre-hook.sh` on the `Skill`-tool
path, `prompt-pre-hook.sh` on the slash path); the agent issues three separate
Write calls (`handoff-task.md`, `handoff-todo.md`, `.claude/autorename`); a
`PreToolUse(Write|Edit)` guard checks each against an activation predicate that
scrapes the transcript; a `PostToolUse(Write|Edit)` hook stages each; and a
separate Bash call runs the probe.

Three defects follow from that spread.

**The wipe is keyed on activation, and activation is the wrong event.** It
assumes one activation per session. Multiple compactions in a session are
normal, and repeated `/handoff` invocations — slash or agent-driven — happen
too. Every one of them destroys `handoff-todo.md` *before* the agent has
re-authored it. The todo remainder is the half of the frame a `/clear`
discards outright, and after a compaction the agent's context is a paraphrase;
wiping the durable copy at activation is exactly backwards.

**The todo file is rewritten in full every time.** It is a working list. The
agent should strike finished items and add new ones, not regenerate the whole
document from a paraphrase on each pass — which is both wasteful and how items
get silently dropped.

**The Write tool refuses to overwrite a file it has not Read in the current
conversation.** That constraint is load-bearing today: the wipe is what makes
both files absent so the skill can Write them as fresh creates. Remove the wipe
naively and the skill must Read before every write.

## What replaces it

One command. The skill assembles the whole wrap-up as JSON and pipes it to
`handoff-checkpoint` on stdin via a heredoc. The checkpoint validates the
payload against a schema, performs the writes, and prints the directives the
probes print today.

`handoff-checkpoint` is not a probe. It writes, so the name goes.

## Requirements

- **FR1** — One entry point, `handoff-checkpoint`, serves both skills. Which
  transition is in play is a payload field, not a separate binary.
- **FR2** — The payload is JSON on stdin, validated against a schema. A
  violation exits non-zero and names the offending field and what was wrong.
- **FR3** — `handoff-task.md` is written only by the checkpoint. Agent
  `Write`/`Edit` to that path is denied.
- **FR4** — `handoff-todo.md` is a scratch list by design. The agent edits it
  freely all session; the checkpoint is only the wrap-up path.
- **FR5** — The todo payload supports incremental update: an Edit form
  (`old_string`/`new_string`) as well as a Write form (`content`).
- **FR6** — A file whose body is empty is removed, and the removal staged. File
  present ⟹ content pending.
- **FR7** — Everything the checkpoint writes is staged with `git add -f`,
  including deletions.
- **FR8** — A `rename` in the payload sets the session title, by the same
  watcher path `/handoff:autoname` uses.
- **FR9** — Directive output (memory gate, SDD ledger nudge) is unchanged in
  content and composition order from the probes it replaces.

- **NFR1** — No git or tmux work runs in the agent's sandboxed Bash. See
  *The sandbox constraint* below; this is not a preference.
- **NFR2** — The `PostToolUse(Bash)` hook is on the hot path — it fires on
  every Bash call in every session with the plugin installed. Its negative case
  is one `stat`.
- **NFR3** — Skill bodies get shorter, not longer. The channel exists to move
  mechanism out of prose.

## The sandbox constraint

The checkpoint is invoked from the agent's Bash tool, which runs under the
Claude Code command sandbox. Two operations cannot happen there.

**`git add` strands `.git/index.lock`.** A sandboxed `git add` can succeed at
staging while failing to remove the lock. Nothing looks wrong until the next
command: `git commit` runs its `pre-commit` hook, the hook's own `git add`
tries to take the lock, and git reports `Unable to create '.git/index.lock':
File exists. Another git process seems to be running`, naming a process that
does not exist. In this plugin's flow that next command is the routine one —
the wrap-up is `/handoff` then `/commit`. Staging from the checkpoint would
break the commit it exists to serve.

**tmux is unreachable.** `write-rename.sh` runs as a hook precisely because
hook context reaches the tmux socket with no sandbox bypass. A checkpoint that
wrote `.claude/autorename` would leave the rename watcher unspawned, and the
promise of a rename unkept — the failure shape DESIGN.md calls indistinguishable
from success.

So the checkpoint writes files and nothing else. Git and tmux stay in hook
context, reached by the same file-IPC pattern the plugin already uses for
`autorename` and `autocompact`: the checkpoint leaves a manifest, and a
`PostToolUse(Bash)` hook consumes it.

## Architecture

### CLI

- `bin/handoff-checkpoint` — PATH-resident shim, execs `scripts/checkpoint.sh`.
  Replaces `bin/handoff-memory-probe` and `bin/handoff-precompact-probe`.
- `scripts/checkpoint.sh` — reads stdin, validates, writes, emits directives,
  writes the manifest.
- `scripts/_checkpoint-lib.sh` — renamed from `_probe-lib.sh`; `probe_*`
  functions become `checkpoint_*`.

The commit-awareness mode moves from a positional argument into the payload, so
the call is one bare name plus a heredoc.

### Schema

```json
{
  "skill":  "handoff" | "precompact",
  "commit": "with-commit" | "without-commit",
  "rename": "Session Title",
  "task":   { "file_path": "…/.claude/handoff-task.md", "content": "…" } | null,
  "todo":   { "file_path": "…/.claude/handoff-todo.md", "content": "…" }
          | { "file_path": "…", "old_string": "…", "new_string": "…" }
          | null
}
```

Validation rules:

- `skill` and `commit` are required, and each is one of two literals. No
  default for `commit` — the two answers are peers, and a default is the answer
  an agent gives when it has not thought about the question.
- `rename` is required under `skill: "handoff"` and **forbidden** under
  `skill: "precompact"`. Sending it under precompact is a schema error, not a
  silent ignore: a rename is `/handoff:autoname`'s job, and precompact already
  lists writing `autorename` as an anti-pattern.
- `task` is a Write form or null. `todo` is a Write form, an Edit form, or
  null.
- Write vs Edit is discriminated by keys present: `content` ⟹ Write,
  `old_string` + `new_string` ⟹ Edit. Both present, or a partial Edit, is a
  schema error naming the field. This matches the harness, which has no op tag
  either.
- `file_path` is required and validated strictly against `$root/.claude/<name>`
  — where `$root` is `handoff_root`, so a worktree session resolves to its own
  `.claude/`. This is where `write-guard.sh`'s cross-project branch goes for the
  channel path.

`file_path` is redundant — the checkpoint owns the paths. It is kept because
it makes "harness tool call syntax" true rather than approximate, and the agent
emits that shape reliably, being the trained one.

### Write semantics

- **Write form** — replace the file's contents wholesale.
- **Edit form** — exact string replacement, first occurrence, error if
  `old_string` is absent or ambiguous. Applied by the checkpoint, not by the
  harness.
- **Empty body** — after writing, a file whose body is empty (a `## Remaining`
  with no items; a task file with headings and no content) is removed. One
  helper in `_checkpoint-lib.sh`, shared with `write-stage.sh` so the
  agent-direct edit path behaves identically. This is the one job
  `_wipe-emit.sh` was really doing, now keyed on content instead of on
  activation.
- **null** — no action on that file. Absent is not "delete": a `todo: null` on a
  session that never touched the list leaves the list alone.

### The manifest

The checkpoint writes `.claude/checkpoint-manifest` — one path per line, each
prefixed `W ` (written) or `D ` (deleted) — and `.claude/autorename` when
`rename` is present.

`scripts/bash-post.sh`, a new `PostToolUse(Bash)` hook, consumes it:

1. Fast-exit when the manifest is absent (one `stat`; this is NFR2).
2. `git add -f` each listed path, deletions included.
3. Consume `.claude/autorename` if present and spawn the rename watcher,
   through the same helper `write-rename.sh` uses.
4. Emit the dual-channel summary — `systemMessage` for the user,
   `additionalContext` for the agent — and delete the manifest.

`write-rename.sh` stays on `PostToolUse(Write|Edit)` because `/handoff:autoname`
still writes `autorename` with the Write tool. The watcher-spawn body is
factored into `_lib.sh` so both callers share it.

### Hook inventory

**Deleted** — `_wipe-emit.sh`, `skill-pre-hook.sh`, `prompt-pre-hook.sh`,
`read-guard.sh`, `handoff_activated()` in `_lib.sh`, and the transcript
fixtures in `tests/fixtures/*.jsonl` that exist only to exercise it. In
`hooks.json`: the whole `PreToolUse(Skill)` block, and `prompt-pre-hook.sh`'s
entry under `UserPromptSubmit` (`report-watcher-failure.sh` stays).

Deleting `handoff_activated()` removes the last consumer of transcript
scraping. The predicate was always a proxy — "has a skill run?" standing in for
"is this write legitimate?" — and the channel answers the real question
directly: legitimate writes come through the checkpoint, and nothing else does.

**Re-scoped** — `write-guard.sh` covers `handoff-task.md` only, keeping its
current three-way shape: rc 1 passes, rc 2 denies as cross-project, rc 0 now
denies unconditionally with a message naming the checkpoint as the only writer.
The activation branch goes with the predicate.

`write-stage.sh` covers `handoff-todo.md` only. The agent edits that file as a
scratch list all session and those edits still need `git add -f`, which the
checkpoint never sees. It gains the empty-body removal via the shared helper.

**Unchanged** — `load-handoff.sh`, `load-compact.sh`, `handoff_frame()`,
`write-compact.sh`, `stop-compact.sh`, `report-watcher-failure.sh`, both
watchers, `worktree_root.py`.

`.claude/autocompact` stays a plain Write with its existing `write-compact.sh`
validator, deliberately outside the channel: precompact's rule is that it lands
only after the directives resolve, sometimes a turn later after an approval.
Folding it in would force a second checkpoint call in exactly the case that is
already delicate.

### Skill bodies

`handoff` Step 3 collapses to one Bash call. It loses the three separate write
bullets, the "Omit either file when it has nothing to say" paragraph, and the
"the activation hook already wiped both" clause — the first is the payload's
job, the second and third are FR6's.

`precompact` step 4 loses the same, plus the now-false warning that invoking
`handoff` would wipe the task file just written. Nothing wipes anything.

Both markdown templates stay in `handoff/SKILL.md` as the single source of
truth. The payload carries content, not shape.

## Rejected alternatives

**Keep the wipe, fix its trigger.** There is no event that means "the skill is
starting a fresh pass" — activation is the closest, and it is what misfires.
Content is the honest signal, and FR6 keys on it.

**Explicit `"op": "write" | "edit"` tag.** Easier to validate, but diverges
from the harness syntax the field is imitating, which is the whole reason the
agent emits it reliably.

**Drop `file_path`; the checkpoint owns the paths.** Would work, and would make
the payload smaller. Rejected because it makes the "harness tool call syntax"
claim approximate, and the strict validation of `file_path` is a real check —
it is where the cross-project guard lives for the channel path.

**Checkpoint stages its own writes.** Blocked by the sandbox: see *The sandbox
constraint*. This is not a style choice.

**Delete `write-guard.sh` too.** The scratch-pad defect the guards were built
for is independent of the channel: an agent can still Write `handoff-task.md`
directly. With no legitimate agent write left, the guard becomes a one-line
invariant, which is cheaper than what is there now.

**Fold `autocompact` into the payload.** Rejected on turn-boundary grounds
above.

## Testing

`tests/memory-probe.bats` and `tests/precompact-probe.bats` merge into
`tests/checkpoint.bats` over the shared `tests/probe-helpers.bash` fixtures.
Carried over intact:

- The commit-awareness contract in full: the mode's four combinations with
  memory state, and the shim forwarding the mode (now a payload field).
- The load-bearing negative — `with-commit` output never mentions the trigger
  file. It stays **mutation-checked**: disable the branch, watch it go red. A
  negative assertion on a shared output channel passes vacuously otherwise.
- The composed memory-then-SDD ordering under `skill: "precompact"`, and its
  absence under `skill: "handoff"`.
- Ledger liveness: the `.superpowers/sdd/*/progress.md` glob, the identity
  first line, the pre-6.2.0 flat path never counting, most-recently-modified
  winning among several.

New:

- Schema validation: each required field missing; each literal field with an
  unknown value; `rename` under `precompact`; `content` and `old_string`
  together; a partial Edit; `file_path` pointing outside `$root/.claude/`;
  malformed JSON. Each asserts non-zero exit **and** that the message names the
  field.
- Edit application: `old_string` absent, `old_string` ambiguous, successful
  replacement.
- Empty-body removal on both files, through both writers (checkpoint and
  `write-stage.sh`), including that the deletion reaches the manifest.
- `bash-post.sh`: manifest absent (silent no-op), manifest present (paths
  staged, deletions staged, manifest deleted), `autorename` present (watcher
  spawned against the tmux stub).

`hook-test.bats` loses its `skill-pre-hook.sh`, `prompt-pre-hook.sh` and
`read-guard.sh` cases, and its `write-guard.sh` cases lose the activation
dimension. Both suites stay listed in `precommit` and `hook-test`.

Every new test is validated by mutation, not by observing it pass.

## DESIGN.md addition

Insert verbatim, immediately before `## References`:

````markdown
## One channel, one writer (2026-07-27)

The wrap-up was five mechanisms sharing one act: an activation hook wiped the
prior files, the agent issued three Write calls, a `PreToolUse` guard vetted
each against a transcript-scraped activation predicate, a `PostToolUse` hook
staged each, and a separate Bash call ran the probe. Each piece was locally
sound. Together they encoded an assumption that does not hold — that a session
hands off once.

The wipe is where it shows. It fires on activation, and activation is not the
event it wants. Multiple compactions in a session are normal; repeated
`/handoff` invocations, slash or agent-driven, happen too. Every one destroys
`handoff-todo.md` before the agent has re-authored it. That file is the half of
the frame a `/clear` discards outright, and after a compaction the context it
would be re-authored from is a paraphrase. *precompact resets the task file
too* (2026-07-21) argued the reset was a harness guarantee where "the skill
writes the whole file" is only an agent-compliance guarantee. That reasoning
holds for the task file, which is authored fresh from the conversation every
time. It never held for the todo remainder, which is a ledger — and the two
were given one protocol because they shared one activation hook.

So the todo file stops being wiped and starts being edited. It is a scratch
list by design: the agent strikes finished items and adds new ones all session,
and the wrap-up folds in the final remainder rather than regenerating the
document from a paraphrase.

Removing the wipe exposes what it was silently paying for. The Write tool
refuses to overwrite a file it has not Read in the current conversation, and an
absent file is what let the skill Write both as fresh creates. The fix is not
to restore a deletion but to stop routing the write through the Write tool at
all. The skill assembles the whole wrap-up as JSON — the task frame, the todo
Write or Edit, the session title, the commit-awareness answer — and pipes it to
`handoff-checkpoint` on stdin. One call replaces a wipe, three writes and a
probe.

The payload uses the harness's own tool-call shape (`file_path` + `content`, or
`file_path` + `old_string`/`new_string`) rather than a bespoke one. It is
redundant — the checkpoint owns the paths — but it is the shape the agent emits
most reliably, and validating `file_path` strictly against
`$root/.claude/<name>` is where the cross-project guard lives for this path.
The cost is a new failure mode: multi-line markdown inside a JSON string is
`\n`-escaped, and a botched escape is a way the wrap-up can fail that a Write
call never had. That is what the schema validation is for, and why a violation
must name the field rather than merely exit non-zero — a silent drop lands at
exactly the moment nothing else carries the frame.

"Probe" no longer describes it. The two probes were read-only detectors; this
writes. One `handoff-checkpoint` replaces both, with the transition as a
payload field — the schema already forces a discriminator in, so two binaries
differing only by it were the duplication the channel makes redundant.

**What the checkpoint may not do.** It runs in the agent's sandboxed Bash,
where a `git add` can stage successfully yet fail to remove `.git/index.lock`,
and the failure surfaces on the *next* command as `Another git process seems to
be running`. The next command here is the routine one: the wrap-up is
`/handoff` then `/commit`. tmux is likewise unreachable, so writing
`.claude/autorename` from the checkpoint would leave the rename watcher
unspawned and the promise of a rename unkept. Both jobs stay in hook context,
reached the way this plugin already reaches them — a file the checkpoint leaves
behind and a hook consumes. `PostToolUse(Bash)` stages the manifest's paths and
spawns the watcher.

**Content, not activation, decides absence.** A file whose body is empty is
removed and the removal staged. `file present ⟹ content pending` becomes an
invariant two writers enforce, instead of an instruction the agent has to
remember. That was the wipe's real job, and it survives the wipe.

Deleting the activation hooks removes the last consumer of `handoff_activated`,
and with it the transcript scraping and its JSONL fixtures. The predicate was
always a proxy — "has a skill run?" standing in for "is this write legitimate?"
— and the channel answers the real question directly. `write-guard.sh` keeps
one file and one rule: `handoff-task.md` is written by the checkpoint or not at
all. `read-guard.sh` goes entirely; a scratch list the agent edits must be
readable, and gating reads of the task file alone protects nothing.
`write-stage.sh` narrows to the todo file, which is the one path the checkpoint
never sees.
````

## Changelog

- 2026-07-27 — specified. Ships together with the unreleased ledger-liveness
  change (*An orphaned ledger hijacks the handoff*, 2026-07-26), which this
  supersedes as the reason for the next release.
